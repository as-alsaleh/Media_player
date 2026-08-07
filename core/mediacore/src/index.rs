//! Library index: scans the share and stores parsed media in SQLite.

use crate::parse::{parse_episode, parse_movie};
use crate::smb::SmbFs;
use rusqlite::Connection;
use std::path::Path;
use std::sync::{Arc, Mutex};

const VIDEO_EXT: &[&str] = &[
    "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "flv",
];

#[derive(Debug, Clone, serde::Serialize)]
pub struct MovieRow {
    pub id: i64,
    pub title: String,
    pub year: Option<u16>,
    pub path: String,
    pub size: u64,
    pub poster_url: Option<String>,
    pub overview: Option<String>,
    pub backdrop_url: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ShowRow {
    pub name: String,
    pub episode_count: u32,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub overview: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct EpisodeRow {
    pub id: i64,
    pub show: String,
    pub season: u16,
    pub episode: u16,
    pub path: String,
    pub size: u64,
}

pub struct Index {
    conn: Mutex<Connection>,
}

impl Index {
    pub fn open(db_path: &Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS movies (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                year INTEGER,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                poster_url TEXT,
                overview TEXT
            );
            CREATE TABLE IF NOT EXISTS episodes (
                id INTEGER PRIMARY KEY,
                show TEXT NOT NULL,
                season INTEGER NOT NULL,
                episode INTEGER NOT NULL,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS show_meta (
                name TEXT PRIMARY KEY,
                poster_url TEXT,
                backdrop_url TEXT,
                overview TEXT
            );
            "#,
        )?;
        // Migration for databases created before backdrops existed.
        let _ = conn.execute("ALTER TABLE movies ADD COLUMN backdrop_url TEXT", []);
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Recursively scan `movies_root` and `tv_root` on the share.
    /// Returns (movies found, episodes found).
    pub async fn scan(
        &self,
        fs: &Arc<SmbFs>,
        movies_root: &str,
        tv_root: &str,
    ) -> Result<(usize, usize), crate::smb::SmbError> {
        let mut movies = 0usize;
        let mut episodes = 0usize;

        for file in walk(fs, movies_root, 2).await? {
            let stem = stem(&file.0);
            let parsed = parse_movie(stem);
            let conn = self.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO movies (title, year, path, size) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(path) DO UPDATE SET size = excluded.size",
                rusqlite::params![parsed.title, parsed.year, file.0, file.1 as i64],
            )
            .ok();
            movies += 1;
        }

        for file in walk(fs, tv_root, 3).await? {
            let stem = stem(&file.0);
            if let Some(ep) = parse_episode(stem) {
                let conn = self.conn.lock().unwrap();
                conn.execute(
                    "INSERT INTO episodes (show, season, episode, path, size)
                     VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(path) DO UPDATE SET size = excluded.size",
                    rusqlite::params![ep.show, ep.season, ep.episode, file.0, file.1 as i64],
                )
                .ok();
                episodes += 1;
            }
        }
        Ok((movies, episodes))
    }

    pub fn movies(&self) -> rusqlite::Result<Vec<MovieRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, title, year, path, size, poster_url, overview, backdrop_url
             FROM movies ORDER BY title COLLATE NOCASE",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(MovieRow {
                    id: r.get(0)?,
                    title: r.get(1)?,
                    year: r.get(2)?,
                    path: r.get(3)?,
                    size: r.get::<_, i64>(4)? as u64,
                    poster_url: r.get(5)?,
                    overview: r.get(6)?,
                    backdrop_url: r.get(7)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn shows(&self) -> rusqlite::Result<Vec<ShowRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT e.show, COUNT(*), m.poster_url, m.backdrop_url, m.overview
             FROM episodes e LEFT JOIN show_meta m ON m.name = e.show
             GROUP BY e.show ORDER BY e.show COLLATE NOCASE",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(ShowRow {
                    name: r.get(0)?,
                    episode_count: r.get(1)?,
                    poster_url: r.get(2)?,
                    backdrop_url: r.get(3)?,
                    overview: r.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn set_show_meta(
        &self,
        name: &str,
        poster_url: Option<&str>,
        backdrop_url: Option<&str>,
        overview: Option<&str>,
    ) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO show_meta (name, poster_url, backdrop_url, overview)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(name) DO UPDATE SET poster_url = excluded.poster_url,
               backdrop_url = excluded.backdrop_url, overview = excluded.overview",
            rusqlite::params![name, poster_url, backdrop_url, overview],
        )
        .ok();
    }

    pub fn episodes(&self) -> rusqlite::Result<Vec<EpisodeRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, show, season, episode, path, size
             FROM episodes ORDER BY show COLLATE NOCASE, season, episode",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(EpisodeRow {
                    id: r.get(0)?,
                    show: r.get(1)?,
                    season: r.get(2)?,
                    episode: r.get(3)?,
                    path: r.get(4)?,
                    size: r.get::<_, i64>(5)? as u64,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn set_movie_meta(
        &self,
        id: i64,
        poster_url: Option<&str>,
        overview: Option<&str>,
        backdrop_url: Option<&str>,
    ) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE movies SET poster_url = ?2, overview = ?3, backdrop_url = ?4 WHERE id = ?1",
            rusqlite::params![id, poster_url, overview, backdrop_url],
        )
        .ok();
    }
}

fn stem(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name)
}

fn is_video(name: &str) -> bool {
    name.rsplit_once('.')
        .map(|(_, ext)| VIDEO_EXT.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// Breadth-first walk up to `depth` levels, returning (path, size) of video files.
async fn walk(
    fs: &Arc<SmbFs>,
    root: &str,
    depth: u32,
) -> Result<Vec<(String, u64)>, crate::smb::SmbError> {
    let mut files = Vec::new();
    let mut dirs = vec![(root.to_string(), 0u32)];
    while let Some((dir, level)) = dirs.pop() {
        let entries = match fs.list_dir(&dir).await {
            Ok(e) => e,
            Err(_) => continue, // unreadable subdir — skip, keep scanning
        };
        for e in entries {
            let child = if dir.is_empty() { e.name.clone() } else { format!("{dir}/{}", e.name) };
            if e.is_dir {
                if level < depth {
                    dirs.push((child, level + 1));
                }
            } else if is_video(&e.name) {
                files.push((child, e.size));
            }
        }
    }
    Ok(files)
}

#[cfg(test)]
impl Index {
    /// Test-only row insertion — production rows only enter via scan(),
    /// which needs a live SMB share.
    fn insert_movie_for_test(&self, title: &str, year: Option<u16>, path: &str, size: u64) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO movies (title, year, path, size) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(path) DO UPDATE SET size = excluded.size",
            rusqlite::params![title, year, path, size as i64],
        )
        .unwrap();
    }

    fn insert_episode_for_test(&self, show: &str, season: u16, episode: u16, path: &str) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO episodes (show, season, episode, path, size)
             VALUES (?1, ?2, ?3, ?4, 1)
             ON CONFLICT(path) DO UPDATE SET size = excluded.size",
            rusqlite::params![show, season, episode, path],
        )
        .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_index(name: &str) -> (Index, std::path::PathBuf) {
        let path = std::env::temp_dir()
            .join(format!("mediacore-test-{}-{}.sqlite", std::process::id(), name));
        std::fs::remove_file(&path).ok();
        (Index::open(&path).unwrap(), path)
    }

    #[test]
    fn stem_and_video_detection() {
        assert_eq!(stem("movies/Heat (1995)/Heat.1995.1080p.mkv"), "Heat.1995.1080p");
        assert_eq!(stem("no_extension"), "no_extension");
        assert!(is_video("a.MKV"));
        assert!(is_video("b.mp4"));
        assert!(!is_video("c.srt"));
        assert!(!is_video("noext"));
    }

    #[test]
    fn open_is_idempotent_and_migrates() {
        let (_first, path) = temp_index("reopen");
        // Second open on the same file must not fail (CREATE IF NOT EXISTS
        // + tolerated ALTER TABLE failure).
        let again = Index::open(&path);
        assert!(again.is_ok());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn movie_roundtrip_upsert_and_meta() {
        let (idx, path) = temp_index("movies");
        idx.insert_movie_for_test("Heat", Some(1995), "movies/heat.mkv", 100);
        // Same path again = upsert, not a duplicate.
        idx.insert_movie_for_test("Heat", Some(1995), "movies/heat.mkv", 200);
        let rows = idx.movies().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "Heat");
        assert_eq!(rows[0].size, 200);
        assert_eq!(rows[0].poster_url, None);

        idx.set_movie_meta(rows[0].id, Some("poster"), Some("plot"), Some("backdrop"));
        let rows = idx.movies().unwrap();
        assert_eq!(rows[0].poster_url.as_deref(), Some("poster"));
        assert_eq!(rows[0].overview.as_deref(), Some("plot"));
        assert_eq!(rows[0].backdrop_url.as_deref(), Some("backdrop"));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn shows_group_episodes_and_join_meta() {
        let (idx, path) = temp_index("shows");
        idx.insert_episode_for_test("Archer", 1, 1, "tv/archer/s01e01.mkv");
        idx.insert_episode_for_test("Archer", 1, 2, "tv/archer/s01e02.mkv");
        idx.insert_episode_for_test("Bluey", 2, 5, "tv/bluey/s02e05.mkv");
        idx.set_show_meta("Archer", Some("p"), Some("b"), Some("o"));
        // Upsert replaces, not duplicates.
        idx.set_show_meta("Archer", Some("p2"), Some("b2"), Some("o2"));

        let shows = idx.shows().unwrap();
        assert_eq!(shows.len(), 2);
        let archer = shows.iter().find(|s| s.name == "Archer").unwrap();
        assert_eq!(archer.episode_count, 2);
        assert_eq!(archer.poster_url.as_deref(), Some("p2"));
        let bluey = shows.iter().find(|s| s.name == "Bluey").unwrap();
        assert_eq!(bluey.episode_count, 1);
        assert_eq!(bluey.poster_url, None);

        // Episode ordering: show, then season, then episode.
        let eps = idx.episodes().unwrap();
        assert_eq!(
            eps.iter().map(|e| (e.season, e.episode)).collect::<Vec<_>>(),
            vec![(1, 1), (1, 2), (2, 5)]
        );
        std::fs::remove_file(&path).ok();
    }
}
