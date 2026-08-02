//! Offline downloads.
//!
//! Streams a source URL (Plex/Jellyfin direct-play or the local SMB
//! streamer) into a Downloads directory next to the library database. State
//! lives in a JSON manifest so the list survives restarts; the apps play
//! finished files straight off the local path, keyed by the same
//! progress_key the online item uses so resume points carry over.

use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadEntry {
    /// The item's progress key ("plex:42", "jf:abc…", or an SMB path).
    pub key: String,
    pub title: String,
    pub poster_url: Option<String>,
    /// Absolute path of the (finished or in-flight) local file.
    pub file: String,
    /// Local copy of the poster, fetched at start — artwork works offline.
    #[serde(default)]
    pub poster_file: Option<String>,
    pub bytes_done: u64,
    pub bytes_total: Option<u64>,
    /// "downloading" | "done" | "error"
    pub state: String,
}

pub struct DownloadStore {
    dir: PathBuf,
    entries: Mutex<HashMap<String, DownloadEntry>>,
    /// Live transfer tasks, so delete can abort an in-flight fetch.
    tasks: Mutex<HashMap<String, tokio::task::AbortHandle>>,
}

impl DownloadStore {
    pub fn new(dir: PathBuf) -> Self {
        std::fs::create_dir_all(&dir).ok();
        let mut entries: HashMap<String, DownloadEntry> =
            std::fs::read_to_string(dir.join("downloads.json"))
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
        // Anything mid-flight when the process last exited never finished.
        for e in entries.values_mut() {
            if e.state == "downloading" {
                e.state = "error".into();
            }
        }
        // Sweep stale partials from crashed/errored transfers.
        if let Ok(listing) = std::fs::read_dir(&dir) {
            for f in listing.flatten() {
                if f.path().extension().is_some_and(|e| e == "part") {
                    std::fs::remove_file(f.path()).ok();
                }
            }
        }
        Self {
            dir,
            entries: Mutex::new(entries),
            tasks: Mutex::new(HashMap::new()),
        }
    }

    fn persist_locked(&self, entries: &HashMap<String, DownloadEntry>) {
        if let Ok(json) = serde_json::to_string_pretty(entries) {
            std::fs::write(self.dir.join("downloads.json"), json).ok();
        }
    }

    pub fn list(&self) -> Vec<DownloadEntry> {
        let mut v: Vec<_> = self.entries.lock().unwrap().values().cloned().collect();
        v.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
        v
    }

    pub fn delete(&self, key: &str) -> bool {
        // Abort a live transfer first so it can't recreate files afterwards.
        if let Some(task) = self.tasks.lock().unwrap().remove(key) {
            task.abort();
        }
        let mut entries = self.entries.lock().unwrap();
        let Some(e) = entries.remove(key) else { return false };
        std::fs::remove_file(&e.file).ok();
        std::fs::remove_file(format!("{}.part", e.file)).ok();
        if let Some(p) = &e.poster_file {
            std::fs::remove_file(p).ok();
        }
        self.persist_locked(&entries);
        true
    }

    fn update(&self, key: &str, f: impl FnOnce(&mut DownloadEntry), persist: bool) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(e) = entries.get_mut(key) {
            f(e);
            if persist {
                self.persist_locked(&entries);
            }
        }
    }

    /// File extension from the URL path, defaulting to mkv (mpv sniffs the
    /// container anyway; the extension is cosmetic).
    fn extension(url: &str) -> &str {
        let path = url.split('?').next().unwrap_or("");
        match path.rsplit('.').next() {
            Some(ext @ ("mkv" | "mp4" | "m4v" | "avi" | "mov" | "ts" | "webm")) => ext,
            _ => "mkv",
        }
    }

    /// Collision-proof local file name: readable prefix + hash of the raw
    /// key, so "a/b.mkv" and "a_b.mkv" can't share one file on disk.
    fn file_name(key: &str, url: &str) -> String {
        let safe: String = key
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
            .collect();
        let mut h = DefaultHasher::new();
        key.hash(&mut h);
        format!("{safe}-{:08x}.{}", h.finish() as u32, Self::extension(url))
    }

    /// Register the entry and spawn the transfer; returns the initial state.
    /// A key that is already downloading or done is returned unchanged.
    pub fn start(
        self: &Arc<Self>,
        key: String,
        url: String,
        title: String,
        poster_url: Option<String>,
    ) -> DownloadEntry {
        let file = self
            .dir
            .join(Self::file_name(&key, &url))
            .to_string_lossy()
            .to_string();
        let entry = DownloadEntry {
            key: key.clone(),
            title,
            poster_url: poster_url.clone(),
            file: file.clone(),
            poster_file: None,
            bytes_done: 0,
            bytes_total: None,
            state: "downloading".into(),
        };
        {
            // Check-and-claim under one guard so a double-tap can't spawn
            // two transfers racing into the same .part file.
            let mut entries = self.entries.lock().unwrap();
            if let Some(existing) = entries.get(&key) {
                if existing.state != "error" {
                    return existing.clone();
                }
            }
            entries.insert(key.clone(), entry.clone());
            self.persist_locked(&entries);
        }

        // Cache the poster locally so Downloads has artwork with no server.
        if let Some(poster) = poster_url {
            let store = Arc::clone(self);
            let poster_key = key.clone();
            let poster_path = format!("{file}.poster.jpg");
            tokio::spawn(async move {
                let client = reqwest::Client::builder()
                    .danger_accept_invalid_certs(true)
                    .build()
                    .unwrap_or_default();
                let Ok(resp) = client.get(&poster).send().await else { return };
                let Ok(bytes) = resp.bytes().await else { return };
                if tokio::fs::write(&poster_path, &bytes).await.is_ok() {
                    store.update(&poster_key, |e| e.poster_file = Some(poster_path), true);
                }
            });
        }

        let store = Arc::clone(self);
        let task_key = key.clone();
        let handle = tokio::spawn(async move {
            let ok = store.fetch(&key, &url, &file).await;
            if !ok {
                tokio::fs::remove_file(format!("{file}.part")).await.ok();
            }
            store.update(
                &key,
                |e| e.state = if ok { "done".into() } else { "error".into() },
                true,
            );
            store.tasks.lock().unwrap().remove(&key);
        });
        self.tasks
            .lock()
            .unwrap()
            .insert(task_key, handle.abort_handle());
        entry
    }

    async fn fetch(&self, key: &str, url: &str, file: &str) -> bool {
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap_or_default();
        let Ok(mut resp) = client.get(url).send().await else { return false };
        if !resp.status().is_success() {
            return false;
        }
        let total = resp.content_length();
        self.update(key, |e| e.bytes_total = total, false);

        let part = format!("{file}.part");
        let Ok(mut out) = tokio::fs::File::create(&part).await else { return false };

        use tokio::io::AsyncWriteExt;
        let mut done: u64 = 0;
        let mut last_persist: u64 = 0;
        loop {
            match resp.chunk().await {
                Ok(Some(chunk)) => {
                    if out.write_all(&chunk).await.is_err() {
                        return false;
                    }
                    done += chunk.len() as u64;
                    // Manifest writes are throttled; live progress stays
                    // in memory for /downloads/list polling.
                    let persist = done - last_persist > 64 * 1024 * 1024;
                    if persist {
                        last_persist = done;
                    }
                    self.update(key, |e| e.bytes_done = done, persist);
                }
                Ok(None) => break,
                Err(_) => return false,
            }
        }
        if out.flush().await.is_err() {
            return false;
        }
        drop(out);
        tokio::fs::rename(&part, file).await.is_ok()
    }
}
