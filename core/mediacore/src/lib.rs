//! mediacore — network + metadata core for MediaPlayer.
//!
//! Exposes network files (SMB, later NFS/WebDAV) to the mpv playback engine
//! through a localhost HTTP server with Range support, and (M2) a SQLite
//! media index with TMDB metadata.

pub mod smb;
pub mod streamer;

pub use streamer::Streamer;
