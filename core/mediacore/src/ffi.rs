//! UniFFI surface for embedding mediacore in-process (required on iOS/tvOS,
//! where helper processes are not allowed).
//!
//! The surface is deliberately tiny: start the streamer, get its base URL.
//! Everything else (listing, library, streaming) stays on the local HTTP API
//! the Swift side already speaks.

use crate::index::Index;
use crate::smb::SmbFs;
use crate::streamer::Streamer;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("connect failed: {msg}")]
    Connect { msg: String },
    #[error("serve failed: {msg}")]
    Serve { msg: String },
}

/// Connect to an SMB share and start the loopback streamer.
/// Returns the base URL (e.g. `http://127.0.0.1:52341`).
///
/// Blocking; call from a background thread/Task. The streamer lives for the
/// rest of the process (one per app run is the intended usage).
#[uniffi::export]
pub fn start_streamer(
    server: String,
    share: String,
    username: String,
    password: String,
    db_path: Option<String>,
    tmdb_api_key: Option<String>,
) -> Result<String, CoreError> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| CoreError::Serve { msg: e.to_string() })?;

    let addr = runtime.block_on(async {
        let fs = SmbFs::connect(&server, &share, &username, &password)
            .await
            .map_err(|e| CoreError::Connect { msg: e.to_string() })?;
        let mut streamer = Streamer::new(fs);
        if let Some(db) = &db_path {
            let index = Index::open(std::path::Path::new(db))
                .map_err(|e| CoreError::Serve { msg: e.to_string() })?;
            streamer = streamer.with_index(index);
        }
        streamer = streamer.with_tmdb_key(tmdb_api_key.clone());
        streamer
            .serve(0)
            .await
            .map_err(|e| CoreError::Serve { msg: e.to_string() })
    })?;

    // Keep the runtime alive for the lifetime of the process.
    std::mem::forget(runtime);
    Ok(format!("http://{addr}"))
}
