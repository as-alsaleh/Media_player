//! mediacore — network + metadata core for MediaPlayer.
//!
//! Exposes network files (SMB, later NFS/WebDAV) to the mpv playback engine
//! through a localhost HTTP server with Range support, and (M2) a SQLite
//! media index with TMDB metadata.

pub mod ffi;
pub mod downloads;
pub mod index;
pub mod jellyfin;
pub mod parse;
pub mod plex;
pub mod smb;
pub mod streamer;
pub mod tmdb;

pub use streamer::Streamer;

uniffi::setup_scaffolding!();
