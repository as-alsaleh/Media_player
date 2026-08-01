//! Loopback HTTP streamer.
//!
//! Serves remote files to mpv as `http://127.0.0.1:{port}/stream/{token}`
//! with HTTP Range support, so mpv's own cache/demuxer handles buffering and
//! seeking. Read-ahead windowing lives here (M1 step 2).

use crate::smb::RemoteFile;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub struct Streamer {
    port: u16,
    files: Arc<Mutex<HashMap<String, Arc<dyn RemoteFile>>>>,
}

impl Streamer {
    pub fn new() -> Self {
        Self { port: 0, files: Arc::default() }
    }

    /// Register a remote file and return the localhost URL mpv should open.
    pub fn register(&self, token: String, file: Arc<dyn RemoteFile>) -> String {
        self.files.lock().unwrap().insert(token.clone(), file);
        format!("http://127.0.0.1:{}/stream/{token}", self.port)
    }

    // TODO(M1): axum server binding 127.0.0.1:0, GET /stream/:token with
    // Range parsing, chunked reads via RemoteFile::read_at, read-ahead task.
}
