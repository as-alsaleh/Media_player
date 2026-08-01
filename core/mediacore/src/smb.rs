//! SMB2/3 client abstraction.
//!
//! Backend TBD (M1 step 1): evaluate the pure-Rust `smb` crate first; fall
//! back to a wrapper over libsmb2 (C, proven on Apple platforms) if seek
//! latency or throughput is insufficient for 80–120 Mbps streams.

use std::io;

#[derive(Debug, Clone)]
pub struct ShareCredentials {
    pub server: String,
    pub share: String,
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// A random-access handle to a remote file, sized reads at arbitrary offsets.
/// This is the only interface the streamer needs from any protocol backend.
pub trait RemoteFile: Send + Sync {
    fn size(&self) -> u64;
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<usize>;
}

pub trait RemoteFs: Send + Sync {
    fn list_dir(&self, path: &str) -> io::Result<Vec<DirEntry>>;
    fn open(&self, path: &str) -> io::Result<Box<dyn RemoteFile>>;
}
