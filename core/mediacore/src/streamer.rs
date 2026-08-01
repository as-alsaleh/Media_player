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
    pub tmdb_key: Option<String>,
    pub plex: Option<Arc<crate::plex::PlexSource>>,
}

/// Unified library item shapes served to the UI, regardless of source.
#[derive(serde::Serialize)]
struct MovieOut {
    uid: String,
    title: String,
    year: Option<u16>,
    poster_url: Option<String>,
    backdrop_url: Option<String>,
    overview: Option<String>,
    /// Absolute URL mpv can open. Local items point at /stream/…
    stream_url: String,
    /// Stable identity for resume points.
    progress_key: String,
    source: &'static str,
}

#[derive(serde::Serialize)]
struct ShowOut {
    uid: String,
    name: String,
    episode_count: u32,
    poster_url: Option<String>,
    backdrop_url: Option<String>,
    overview: Option<String>,
    source: &'static str,
}

#[derive(serde::Serialize)]
struct EpisodeOut {
    uid: String,
    show: String,
    season: u16,
    episode: u16,
    stream_url: String,
    progress_key: String,
    source: &'static str,
}

fn local_stream_url(path: &str) -> String {
    let escaped = path
        .split('/')
        .map(|seg| urlencoding(seg))
        .collect::<Vec<_>>()
        .join("/");
    format!("/stream/{escaped}")
}

fn urlencoding(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

pub struct Streamer {
    state: AppState,
}

impl Streamer {
    pub fn new(fs: SmbFs) -> Self {
        Self {
            state: AppState { fs: Arc::new(fs), index: None, tmdb_key: None, plex: None },
        }
    }

    pub fn with_plex(mut self, plex: Option<crate::plex::PlexSource>) -> Self {
        self.state.plex = plex.map(Arc::new);
        self
    }

    pub fn with_index(mut self, index: Index) -> Self {
        self.state.index = Some(Arc::new(index));
        self
    }

    pub fn with_tmdb_key(mut self, key: Option<String>) -> Self {
        self.state.tmdb_key = key.filter(|k| !k.is_empty());
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
            .route("/library/shows", get(library_shows))
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
        Ok((m, e)) => {
            let enriched = match &st.tmdb_key {
                Some(key) => crate::tmdb::enrich(&index, key).await,
                None => 0,
            };
            Json(serde_json::json!({"movies": m, "episodes": e, "enriched": enriched}))
                .into_response()
        }
        Err(err) => (StatusCode::BAD_GATEWAY, err.to_string()).into_response(),
    }
}

async fn library_movies(State(st): State<AppState>) -> Response {
    let mut out: Vec<MovieOut> = Vec::new();
    if let Some(Ok(rows)) = st.index.as_ref().map(|i| i.movies()) {
        out.extend(rows.into_iter().map(|m| MovieOut {
            uid: format!("local-m{}", m.id),
            title: m.title,
            year: m.year,
            poster_url: m.poster_url,
            backdrop_url: m.backdrop_url,
            overview: m.overview,
            stream_url: local_stream_url(&m.path),
            progress_key: m.path,
            source: "local",
        }));
    }
    if let Some(plex) = &st.plex {
        out.extend(plex.movies().await.into_iter().map(|m| MovieOut {
            uid: format!("plex-m{}", m.rating_key),
            title: m.title,
            year: m.year,
            poster_url: m.poster_url,
            backdrop_url: m.backdrop_url,
            overview: m.overview,
            stream_url: m.stream_url,
            progress_key: format!("plex:{}", m.rating_key),
            source: "plex",
        }));
    }
    out.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    out.dedup_by(|a, b| a.title == b.title && a.year == b.year);
    Json(out).into_response()
}

async fn library_episodes(State(st): State<AppState>) -> Response {
    let mut out: Vec<EpisodeOut> = Vec::new();
    if let Some(Ok(rows)) = st.index.as_ref().map(|i| i.episodes()) {
        out.extend(rows.into_iter().map(|e| EpisodeOut {
            uid: format!("local-e{}", e.id),
            show: e.show,
            season: e.season,
            episode: e.episode,
            stream_url: local_stream_url(&e.path),
            progress_key: e.path,
            source: "local",
        }));
    }
    if let Some(plex) = &st.plex {
        out.extend(plex.episodes().await.into_iter().map(|e| EpisodeOut {
            uid: format!("plex-e{}", e.rating_key),
            show: e.show,
            season: e.season,
            episode: e.episode,
            stream_url: e.stream_url,
            progress_key: format!("plex:{}", e.rating_key),
            source: "plex",
        }));
    }
    out.sort_by(|a, b| {
        (a.show.to_lowercase(), a.season, a.episode)
            .cmp(&(b.show.to_lowercase(), b.season, b.episode))
    });
    out.dedup_by(|a, b| a.show == b.show && a.season == b.season && a.episode == b.episode);
    Json(out).into_response()
}

async fn library_shows(State(st): State<AppState>) -> Response {
    let mut out: Vec<ShowOut> = Vec::new();
    if let Some(Ok(rows)) = st.index.as_ref().map(|i| i.shows()) {
        out.extend(rows.into_iter().map(|s| ShowOut {
            uid: format!("local-s{}", s.name),
            name: s.name,
            episode_count: s.episode_count,
            poster_url: s.poster_url,
            backdrop_url: s.backdrop_url,
            overview: s.overview,
            source: "local",
        }));
    }
    if let Some(plex) = &st.plex {
        out.extend(plex.shows().await.into_iter().map(|s| ShowOut {
            uid: format!("plex-s{}", s.name),
            name: s.name,
            episode_count: s.episode_count,
            poster_url: s.poster_url,
            backdrop_url: s.backdrop_url,
            overview: s.overview,
            source: "plex",
        }));
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out.dedup_by(|a, b| a.name.to_lowercase() == b.name.to_lowercase());
    Json(out).into_response()
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
