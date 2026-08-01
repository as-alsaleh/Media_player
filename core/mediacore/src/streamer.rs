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
    pub fs: Option<Arc<SmbFs>>,
    pub index: Option<Arc<Index>>,
    pub tmdb_key: Option<String>,
    pub plex: Option<Arc<crate::plex::PlexSource>>,
    /// Account-level source for Home-user listing/switching (admin token);
    /// falls back to `plex` when absent.
    pub plex_admin: Option<Arc<crate::plex::PlexSource>>,
    /// Active user is a restricted Home profile: hide local-index items and
    /// block raw share browsing so Plex library permissions are respected.
    pub restricted: bool,
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
    /// Server-side resume point (Plex), seconds.
    view_offset_secs: Option<f64>,
    watched: bool,
    last_viewed_at: Option<u64>,
    duration_secs: Option<f64>,
    tmdb_id: Option<u64>,
}

/// Loose identity for cross-source dedup: lowercase alphanumerics only.
fn norm(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
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
    view_offset_secs: Option<f64>,
    watched: bool,
    last_viewed_at: Option<u64>,
    duration_secs: Option<f64>,
    show_tmdb_id: Option<u64>,
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
    pub fn new(fs: Option<SmbFs>) -> Self {
        Self {
            state: AppState {
                fs: fs.map(Arc::new),
                index: None,
                tmdb_key: None,
                plex: None,
                plex_admin: None,
                restricted: false,
            },
        }
    }

    pub fn with_plex(mut self, plex: Option<crate::plex::PlexSource>) -> Self {
        self.state.plex = plex.map(Arc::new);
        self
    }

    pub fn with_plex_admin(mut self, plex: Option<crate::plex::PlexSource>) -> Self {
        self.state.plex_admin = plex.map(Arc::new);
        self
    }

    pub fn with_restricted(mut self, restricted: bool) -> Self {
        self.state.restricted = restricted;
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
            .route("/plex/progress", get(plex_progress))
            .route("/plex/users", get(plex_users))
            .route("/plex/switch", get(plex_switch))
            .route("/plex/markers", get(plex_markers))
            .route("/plex/rate", get(plex_rate))
            .route("/plex/watched", get(plex_watched))
            .route("/plex/login/start", get(plex_login_start))
            .route("/plex/login/poll", get(plex_login_poll))
            .route("/trakt/login/start", get(trakt_login_start))
            .route("/trakt/login/poll", get(trakt_login_poll))
            .route("/trakt/scrobble", get(trakt_scrobble))
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
    if st.restricted {
        return (StatusCode::FORBIDDEN, "restricted profile").into_response();
    }
    let Some(fs) = &st.fs else {
        return (StatusCode::NOT_IMPLEMENTED, "no file share configured").into_response();
    };
    let path = q.get("path").map(String::as_str).unwrap_or("");
    match fs.list_dir(path).await {
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
    let Some(fs) = &st.fs else {
        // Plex-only mode: nothing to scan, but enrichment can still run.
        let enriched = match &st.tmdb_key {
            Some(key) => crate::tmdb::enrich(&index, key).await,
            None => 0,
        };
        return Json(serde_json::json!({"movies": 0, "episodes": 0, "enriched": enriched}))
            .into_response();
    };
    let movies_root = q.get("movies").map(String::as_str).unwrap_or("movies");
    let tv_root = q.get("tv").map(String::as_str).unwrap_or("tv");
    match index.scan(fs, movies_root, tv_root).await {
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
    // Keyed by normalized title(+year); Plex wins on collision because it
    // carries watch state and richer metadata.
    let mut map: HashMap<String, MovieOut> = HashMap::new();
    if let (false, true, Some(Ok(rows))) = (st.restricted, st.fs.is_some(), st.index.as_ref().map(|i| i.movies())) {
        for m in rows {
            let key = format!("{}|{}", norm(&m.title), m.year.unwrap_or(0));
            map.insert(
                key,
                MovieOut {
                    uid: format!("local-m{}", m.id),
                    title: m.title,
                    year: m.year,
                    poster_url: m.poster_url,
                    backdrop_url: m.backdrop_url,
                    overview: m.overview,
                    stream_url: local_stream_url(&m.path),
                    progress_key: m.path,
                    source: "local",
                    view_offset_secs: None,
                    watched: false,
                    last_viewed_at: None,
                    duration_secs: None,
                    tmdb_id: None,
                },
            );
        }
    }
    if let Some(plex) = &st.plex {
        for m in plex.movies().await {
            let key = format!("{}|{}", norm(&m.title), m.year.unwrap_or(0));
            map.insert(
                key,
                MovieOut {
                    uid: format!("plex-m{}", m.rating_key),
                    title: m.title,
                    year: m.year,
                    poster_url: m.poster_url,
                    backdrop_url: m.backdrop_url,
                    overview: m.overview,
                    stream_url: m.stream_url,
                    progress_key: format!("plex:{}", m.rating_key),
                    source: "plex",
                    view_offset_secs: m.view_offset_secs,
                    watched: m.watched,
                    last_viewed_at: m.last_viewed_at,
                    duration_secs: m.duration_secs,
                    tmdb_id: m.tmdb_id,
                },
            );
        }
    }
    let mut out: Vec<MovieOut> = map.into_values().collect();
    out.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Json(out).into_response()
}

async fn library_episodes(State(st): State<AppState>) -> Response {
    let mut map: HashMap<String, EpisodeOut> = HashMap::new();
    if let (false, true, Some(Ok(rows))) = (st.restricted, st.fs.is_some(), st.index.as_ref().map(|i| i.episodes())) {
        for e in rows {
            let key = format!("{}|{}|{}", norm(&e.show), e.season, e.episode);
            map.insert(
                key,
                EpisodeOut {
                    uid: format!("local-e{}", e.id),
                    show: e.show,
                    season: e.season,
                    episode: e.episode,
                    stream_url: local_stream_url(&e.path),
                    progress_key: e.path,
                    source: "local",
                    view_offset_secs: None,
                    watched: false,
                    last_viewed_at: None,
                    duration_secs: None,
                    show_tmdb_id: None,
                },
            );
        }
    }
    if let Some(plex) = &st.plex {
        let show_ids: HashMap<String, Option<u64>> = plex
            .shows()
            .await
            .into_iter()
            .map(|s| (norm(&s.name), s.tmdb_id))
            .collect();
        for e in plex.episodes().await {
            let key = format!("{}|{}|{}", norm(&e.show), e.season, e.episode);
            map.insert(
                key,
                EpisodeOut {
                    uid: format!("plex-e{}", e.rating_key),
                    show_tmdb_id: show_ids.get(&norm(&e.show)).copied().flatten(),
                    show: e.show,
                    season: e.season,
                    episode: e.episode,
                    stream_url: e.stream_url,
                    progress_key: format!("plex:{}", e.rating_key),
                    source: "plex",
                    view_offset_secs: e.view_offset_secs,
                    watched: e.watched,
                    last_viewed_at: e.last_viewed_at,
                    duration_secs: e.duration_secs,
                },
            );
        }
    }
    let mut out: Vec<EpisodeOut> = map.into_values().collect();
    out.sort_by(|a, b| {
        (a.show.to_lowercase(), a.season, a.episode)
            .cmp(&(b.show.to_lowercase(), b.season, b.episode))
    });
    Json(out).into_response()
}

async fn library_shows(State(st): State<AppState>) -> Response {
    let mut map: HashMap<String, ShowOut> = HashMap::new();
    if let (false, true, Some(Ok(rows))) = (st.restricted, st.fs.is_some(), st.index.as_ref().map(|i| i.shows())) {
        for s in rows {
            map.insert(
                norm(&s.name),
                ShowOut {
                    uid: format!("local-s{}", s.name),
                    name: s.name,
                    episode_count: s.episode_count,
                    poster_url: s.poster_url,
                    backdrop_url: s.backdrop_url,
                    overview: s.overview,
                    source: "local",
                },
            );
        }
    }
    if let Some(plex) = &st.plex {
        for s in plex.shows().await {
            map.insert(
                norm(&s.name),
                ShowOut {
                    uid: format!("plex-s{}", s.name),
                    name: s.name,
                    episode_count: s.episode_count,
                    poster_url: s.poster_url,
                    backdrop_url: s.backdrop_url,
                    overview: s.overview,
                    source: "plex",
                },
            );
        }
    }
    let mut out: Vec<ShowOut> = map.into_values().collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Json(out).into_response()
}

async fn plex_progress(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let Some(plex) = &st.plex else {
        return (StatusCode::NOT_IMPLEMENTED, "no plex source").into_response();
    };
    let (Some(key), Some(time), Some(duration)) = (
        q.get("rating_key"),
        q.get("time").and_then(|t| t.parse::<f64>().ok()),
        q.get("duration").and_then(|d| d.parse::<f64>().ok()),
    ) else {
        return (StatusCode::BAD_REQUEST, "rating_key, time, duration required").into_response();
    };
    let state = q.get("state").map(String::as_str).unwrap_or("playing");
    let ok = plex.report_progress(key, time, duration, state).await;
    Json(serde_json::json!({"ok": ok})).into_response()
}

async fn plex_markers(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let (Some(plex), Some(key)) = (&st.plex, q.get("rating_key")) else {
        return (StatusCode::BAD_REQUEST, "plex + rating_key required").into_response();
    };
    Json(plex.markers(key).await).into_response()
}

async fn plex_rate(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let (Some(plex), Some(key), Some(rating)) = (
        &st.plex,
        q.get("rating_key"),
        q.get("rating").and_then(|r| r.parse::<f32>().ok()),
    ) else {
        return (StatusCode::BAD_REQUEST, "plex + rating_key + rating required").into_response();
    };
    Json(serde_json::json!({"ok": plex.rate(key, rating).await})).into_response()
}

async fn plex_watched(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let (Some(plex), Some(key)) = (&st.plex, q.get("rating_key")) else {
        return (StatusCode::BAD_REQUEST, "plex + rating_key required").into_response();
    };
    let watched = q.get("watched").map(|w| w == "true").unwrap_or(true);
    Json(serde_json::json!({"ok": plex.set_watched(key, watched).await})).into_response()
}

async fn plex_login_start() -> Response {
    match crate::plex::pin_create().await {
        Some(pin) => Json(pin).into_response(),
        None => (StatusCode::BAD_GATEWAY, "plex.tv unreachable").into_response(),
    }
}

/// Poll the pin; once signed in, resolve the user's own server too so the
/// client gets everything it needs in one payload.
async fn plex_login_poll(Query(q): Query<HashMap<String, String>>) -> Response {
    let Some(id) = q.get("id").and_then(|v| v.parse::<u64>().ok()) else {
        return (StatusCode::BAD_REQUEST, "id required").into_response();
    };
    match crate::plex::pin_check(id).await {
        None => Json(serde_json::json!({"pending": true})).into_response(),
        Some(account_token) => match crate::plex::discover_server(&account_token).await {
            Some(server) => Json(serde_json::json!({
                "pending": false,
                "server_name": server.name,
                "server_url": server.url,
                "token": server.token,
            }))
            .into_response(),
            None => (
                StatusCode::NOT_FOUND,
                "signed in, but no owned Plex server was found on the account",
            )
                .into_response(),
        },
    }
}

async fn trakt_login_start(Query(q): Query<HashMap<String, String>>) -> Response {
    let Some(client_id) = q.get("client_id") else {
        return (StatusCode::BAD_REQUEST, "client_id required").into_response();
    };
    match crate::trakt::device_code(client_id).await {
        Some(code) => Json(code).into_response(),
        None => (StatusCode::BAD_GATEWAY, "trakt.tv unreachable").into_response(),
    }
}

async fn trakt_login_poll(Query(q): Query<HashMap<String, String>>) -> Response {
    let (Some(id), Some(secret), Some(code)) = (
        q.get("client_id"),
        q.get("client_secret"),
        q.get("device_code"),
    ) else {
        return (StatusCode::BAD_REQUEST, "client_id, client_secret, device_code required")
            .into_response();
    };
    match crate::trakt::device_token(id, secret, code).await {
        Some(t) => Json(serde_json::json!({
            "pending": false,
            "access_token": t.access_token,
            "refresh_token": t.refresh_token,
        }))
        .into_response(),
        None => Json(serde_json::json!({"pending": true})).into_response(),
    }
}

async fn trakt_scrobble(Query(q): Query<HashMap<String, String>>) -> Response {
    let (Some(client_id), Some(token), Some(state), Some(progress), Some(kind)) = (
        q.get("client_id"),
        q.get("token"),
        q.get("state"),
        q.get("progress").and_then(|p| p.parse::<f64>().ok()),
        q.get("kind"),
    ) else {
        return (StatusCode::BAD_REQUEST, "client_id, token, state, progress, kind required")
            .into_response();
    };
    let body = match kind.as_str() {
        "movie" => {
            let Some(tmdb) = q.get("tmdb").and_then(|t| t.parse::<u64>().ok()) else {
                return (StatusCode::BAD_REQUEST, "tmdb required").into_response();
            };
            serde_json::json!({"movie": {"ids": {"tmdb": tmdb}}})
        }
        "episode" => {
            let (Some(tmdb), Some(season), Some(episode)) = (
                q.get("tmdb").and_then(|t| t.parse::<u64>().ok()),
                q.get("season").and_then(|v| v.parse::<u32>().ok()),
                q.get("episode").and_then(|v| v.parse::<u32>().ok()),
            ) else {
                return (StatusCode::BAD_REQUEST, "tmdb, season, episode required")
                    .into_response();
            };
            serde_json::json!({
                "show": {"ids": {"tmdb": tmdb}},
                "episode": {"season": season, "number": episode},
            })
        }
        _ => return (StatusCode::BAD_REQUEST, "kind must be movie|episode").into_response(),
    };
    let ok = crate::trakt::scrobble(client_id, token, state, body, progress).await;
    Json(serde_json::json!({"ok": ok})).into_response()
}

async fn plex_users(State(st): State<AppState>) -> Response {
    match st.plex_admin.as_ref().or(st.plex.as_ref()) {
        Some(plex) => Json(plex.home_users().await).into_response(),
        None => (StatusCode::NOT_IMPLEMENTED, "no plex source").into_response(),
    }
}

async fn plex_switch(
    State(st): State<AppState>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let Some(plex) = st.plex_admin.as_ref().or(st.plex.as_ref()) else {
        return (StatusCode::NOT_IMPLEMENTED, "no plex source").into_response();
    };
    let Some(uuid) = q.get("uuid") else {
        return (StatusCode::BAD_REQUEST, "uuid required").into_response();
    };
    match plex.switch_user(uuid, q.get("pin").map(String::as_str)).await {
        Some(token) => Json(serde_json::json!({"token": token})).into_response(),
        None => (StatusCode::BAD_GATEWAY, "switch failed").into_response(),
    }
}

async fn stream(
    State(st): State<AppState>,
    AxPath(path): AxPath<String>,
    headers: HeaderMap,
) -> Response {
    let Some(fs) = &st.fs else {
        return (StatusCode::NOT_IMPLEMENTED, "no file share configured").into_response();
    };
    let file = match fs.open(&path).await {
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
