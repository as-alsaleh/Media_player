//! Loopback HTTP streamer.
//!
//! Serves SMB files to mpv as `http://127.0.0.1:{port}/stream/{path}` with
//! HTTP Range support, so mpv's own cache/demuxer drives buffering and seeks.

use crate::index::Index;
use crate::smb::SmbFs;
use axum::{
    body::Body,
    extract::{Path as AxPath, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

/// Read chunk size per SMB round-trip (max SMB2 read is typically 1–8 MiB).
const CHUNK: usize = 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub fs: Arc<SmbFs>,
    pub index: Option<Arc<Index>>,
}

pub struct Streamer {
    state: AppState,
}

impl Streamer {
    pub fn new(fs: SmbFs) -> Self {
        Self { state: AppState { fs: Arc::new(fs), index: None } }
    }

    pub fn with_index(mut self, index: Index) -> Self {
        self.state.index = Some(Arc::new(index));
        self
    }

    /// Bind 127.0.0.1:`port` (0 = ephemeral) and serve until the task is dropped.
    /// Returns the bound local address.
    pub async fn serve(self, port: u16) -> std::io::Result<SocketAddr> {
        let app = Router::new()
            .route("/list", get(list))
            .route("/stream/*path", get(stream))
            .route("/library/scan", get(library_scan))
            .route("/library/movies", get(library_movies))
            .route("/library/episodes", get(library_episodes))
            .with_state(self.state);
        let listener =
            tokio::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port))).await?;
        let addr = listener.local_addr()?;
        tokio::spawn(async move {
            if let Err(e) = axum::serve(listener, app).await {
                tracing::error!("streamer exited: {e}");
            }
        });
        Ok(addr)
    }
}

async fn list(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let path = q.get("path").map(String::as_str).unwrap_or("");
    match st.fs.list_dir(path).await {
        Ok(entries) => Json(entries).into_response(),
        Err(e) => (StatusCode::BAD_GATEWAY, e.to_string()).into_response(),
    }
}

async fn library_scan(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let Some(index) = st.index else {
        return (StatusCode::NOT_IMPLEMENTED, "no index configured").into_response();
    };
    let movies_root = q.get("movies").map(String::as_str).unwrap_or("movies");
    let tv_root = q.get("tv").map(String::as_str).unwrap_or("tv");
    match index.scan(&st.fs, movies_root, tv_root).await {
        Ok((m, e)) => Json(serde_json::json!({"movies": m, "episodes": e})).into_response(),
        Err(err) => (StatusCode::BAD_GATEWAY, err.to_string()).into_response(),
    }
}

async fn library_movies(State(st): State<AppState>) -> Response {
    match st.index.as_ref().map(|i| i.movies()) {
        Some(Ok(rows)) => Json(rows).into_response(),
        Some(Err(e)) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        None => (StatusCode::NOT_IMPLEMENTED, "no index configured").into_response(),
    }
}

async fn library_episodes(State(st): State<AppState>) -> Response {
    match st.index.as_ref().map(|i| i.episodes()) {
        Some(Ok(rows)) => Json(rows).into_response(),
        Some(Err(e)) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        None => (StatusCode::NOT_IMPLEMENTED, "no index configured").into_response(),
    }
}

async fn stream(
    State(st): State<AppState>,
    AxPath(path): AxPath<String>,
    headers: HeaderMap,
) -> Response {
    let file = match st.fs.open(&path).await {
        Ok(f) => f,
        Err(e) => return (StatusCode::NOT_FOUND, e.to_string()).into_response(),
    };
    let size = file.size();

    // Parse a single `bytes=start-end` range (mpv only ever sends one).
    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| parse_range(v, size));

    let (start, end) = match range {
        Some((s, e)) => (s, e),
        None => (0, size.saturating_sub(1)),
    };
    if start >= size {
        return (
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{size}"))],
        )
            .into_response();
    }
    let len = end - start + 1;

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(4);
    tokio::spawn(async move {
        let mut pos = start;
        let mut remaining = len;
        let mut buf = vec![0u8; CHUNK];
        while remaining > 0 {
            let want = CHUNK.min(remaining as usize);
            match file.read_at(&mut buf[..want], pos).await {
                Ok(0) => break,
                Ok(n) => {
                    pos += n as u64;
                    remaining -= n as u64;
                    if tx.send(Ok(buf[..n].to_vec())).await.is_err() {
                        break; // client hung up (e.g. mpv seeked)
                    }
                }
                Err(e) => {
                    let _ = tx
                        .send(Err(std::io::Error::other(e.to_string())))
                        .await;
                    break;
                }
            }
        }
    });

    let body = Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx));
    let mut resp = Response::builder()
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, len)
        .header(header::CONTENT_TYPE, "application/octet-stream");
    resp = if range.is_some() {
        resp.status(StatusCode::PARTIAL_CONTENT).header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{size}"),
        )
    } else {
        resp.status(StatusCode::OK)
    };
    resp.body(body).unwrap()
}

fn parse_range(header: &str, size: u64) -> Option<(u64, u64)> {
    let spec = header.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (start_s, end_s) = spec.split_once('-')?;
    if start_s.is_empty() {
        // suffix form: bytes=-N (last N bytes)
        let n: u64 = end_s.parse().ok()?;
        let start = size.saturating_sub(n);
        return Some((start, size.saturating_sub(1)));
    }
    let start: u64 = start_s.parse().ok()?;
    let end = if end_s.is_empty() {
        size.saturating_sub(1)
    } else {
        end_s.parse::<u64>().ok()?.min(size.saturating_sub(1))
    };
    (start <= end).then_some((start, end))
}

#[cfg(test)]
mod tests {
    use super::parse_range;

    #[test]
    fn range_forms() {
        assert_eq!(parse_range("bytes=0-499", 1000), Some((0, 499)));
        assert_eq!(parse_range("bytes=500-", 1000), Some((500, 999)));
        assert_eq!(parse_range("bytes=-200", 1000), Some((800, 999)));
        assert_eq!(parse_range("bytes=0-9999", 1000), Some((0, 999)));
        assert_eq!(parse_range("bytes=700-600", 1000), None);
        assert_eq!(parse_range("garbage", 1000), None);
    }
}
