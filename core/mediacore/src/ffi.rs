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
    plex_url: Option<String>,
    plex_token: Option<String>,
    plex_admin_token: Option<String>,
    jellyfin_url: Option<String>,
    jellyfin_api_key: Option<String>,
    jellyfin_user_token: Option<String>,
    jellyfin_user_id: Option<String>,
) -> Result<String, CoreError> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| CoreError::Serve { msg: e.to_string() })?;

    let addr = runtime.block_on(async {
        let fs = if server.is_empty() {
            None
        } else {
            // Mirrors the conditions under which the sources are actually
            // constructed below — a stray token without its URL must not
            // swallow the SMB error and boot into an empty library.
            let has_plex = plex_url.is_some() && plex_token.is_some();
            let has_jellyfin_user = jellyfin_url.is_some()
                && jellyfin_api_key.is_some()
                && jellyfin_user_token.as_deref().is_some_and(|t| !t.is_empty())
                && jellyfin_user_id.as_deref().is_some_and(|u| !u.is_empty());
            match SmbFs::connect(&server, &share, &username, &password).await {
                Ok(fs) => Some(fs),
                // A dead/stale SMB share must not take down the whole engine
                // when another source (Plex/Jellyfin) can still serve the
                // library. Only SMB-only setups treat it as fatal.
                Err(e) if !has_plex && !has_jellyfin_user => {
                    return Err(CoreError::Connect { msg: e.to_string() });
                }
                Err(e) => {
                    tracing::warn!("smb connect failed, continuing without: {e}");
                    None
                }
            }
        };
        let mut streamer = Streamer::new(fs);
        if let Some(db) = &db_path {
            let index = Index::open(std::path::Path::new(db))
                .map_err(|e| CoreError::Serve { msg: e.to_string() })?;
            streamer = streamer.with_index(index);
            // Offline downloads live next to the library database.
            let dir = std::path::Path::new(db)
                .parent()
                .map(|p| p.join("Downloads"));
            streamer = streamer.with_downloads_dir(dir);
        }
        streamer = streamer.with_tmdb_key(tmdb_api_key.clone());
        if let (Some(url), Some(token)) = (&plex_url, &plex_token) {
            streamer = streamer.with_plex(Some(
                crate::plex::PlexSource::new(url.clone(), token.clone())
                    .with_media_token(plex_admin_token.clone()),
            ));
            if let Some(admin) = &plex_admin_token {
                streamer = streamer.with_restricted(admin != token);
                streamer = streamer.with_plex_admin(Some(crate::plex::PlexSource::new(
                    url.clone(),
                    admin.clone(),
                )));
            }
        }
        if let (Some(url), Some(key)) = (&jellyfin_url, &jellyfin_api_key) {
            streamer = streamer.with_jellyfin(Some(
                crate::jellyfin::JellyfinSource::new(url.clone(), key.clone())
                    .with_user(jellyfin_user_token.clone(), jellyfin_user_id.clone()),
            ));
        }
        streamer
            .serve(0)
            .await
            .map_err(|e| CoreError::Serve { msg: e.to_string() })
    })?;

    // Keep the runtime alive for the lifetime of the process.
    std::mem::forget(runtime);
    Ok(format!("http://{addr}"))
}
