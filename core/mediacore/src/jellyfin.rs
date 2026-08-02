//! Jellyfin source: sign-in, library, watch state, progress reporting, and
//! trickplay (scrub-preview thumbnails).
//!
//! Dual role: with a user token it is a full library source (like Plex);
//! with just the admin API key it still serves trickplay previews for items
//! matched by file path (used while Plex is the primary source).

use serde::Deserialize;
use std::collections::HashMap;

#[derive(Clone)]
pub struct JellyfinSource {
    base: String,
    api_key: String,
    user_token: Option<String>,
    user_id: Option<String>,
    client: reqwest::Client,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JfMovie {
    pub id: String,
    pub title: String,
    pub year: Option<u16>,
    pub overview: Option<String>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub stream_url: String,
    pub view_offset_secs: Option<f64>,
    pub watched: bool,
    pub last_viewed_at: Option<u64>,
    pub duration_secs: Option<f64>,
    pub tmdb_id: Option<u64>,
    pub added_at: Option<u64>,
    /// Critic score 0–10 (Jellyfin stores CriticRating as 0–100).
    pub critic_rating: Option<f64>,
    /// Community score 0–10.
    pub audience_rating: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JfShow {
    pub id: String,
    pub name: String,
    pub episode_count: u32,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub overview: Option<String>,
    pub tmdb_id: Option<u64>,
    pub added_at: Option<u64>,
    pub critic_rating: Option<f64>,
    pub audience_rating: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JfEpisode {
    pub id: String,
    pub show: String,
    pub season: u16,
    pub episode: u16,
    pub title: String,
    pub thumb_url: Option<String>,
    pub overview: Option<String>,
    pub stream_url: String,
    pub view_offset_secs: Option<f64>,
    pub watched: bool,
    pub last_viewed_at: Option<u64>,
    pub duration_secs: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JfPublicUser {
    pub id: String,
    pub name: String,
    pub has_password: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JfLogin {
    pub token: String,
    pub user_id: String,
    pub name: String,
}

/// Trickplay manifest for one item, resolved to concrete tile URLs.
/// `tile_url_template` contains "{i}" for the tile-grid image index.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TrickplayInfo {
    pub tile_url_template: String,
    pub interval_ms: u64,
    pub tile_cols: u32,
    pub tile_rows: u32,
    pub thumb_width: u32,
    pub thumb_height: u32,
    pub thumbnail_count: u32,
}

#[derive(Deserialize)]
struct ItemsResp {
    #[serde(rename = "Items", default)]
    items: Vec<JfItem>,
}

#[derive(Deserialize, Default)]
struct JfUserData {
    #[serde(rename = "PlaybackPositionTicks")]
    position_ticks: Option<u64>,
    #[serde(rename = "Played")]
    played: Option<bool>,
    #[serde(rename = "LastPlayedDate")]
    last_played: Option<String>,
}

#[derive(Deserialize)]
struct JfItem {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "ProductionYear")]
    year: Option<u16>,
    #[serde(rename = "Overview")]
    overview: Option<String>,
    #[serde(rename = "Path")]
    path: Option<String>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<u64>,
    #[serde(rename = "SeriesName")]
    series_name: Option<String>,
    #[serde(rename = "ParentIndexNumber")]
    season: Option<u16>,
    #[serde(rename = "IndexNumber")]
    episode: Option<u16>,
    #[serde(rename = "RecursiveItemCount")]
    recursive_count: Option<u32>,
    #[serde(rename = "DateCreated")]
    date_created: Option<String>,
    #[serde(rename = "CommunityRating")]
    community_rating: Option<f64>,
    #[serde(rename = "CriticRating")]
    critic_rating: Option<f64>,
    #[serde(rename = "ProviderIds", default)]
    provider_ids: HashMap<String, String>,
    #[serde(rename = "ImageTags", default)]
    image_tags: HashMap<String, String>,
    #[serde(rename = "BackdropImageTags", default)]
    backdrop_tags: Vec<String>,
    #[serde(rename = "UserData", default)]
    user_data: Option<JfUserData>,
    #[serde(rename = "Trickplay")]
    trickplay: Option<HashMap<String, HashMap<String, TrickplayRaw>>>,
}

#[derive(Deserialize)]
struct TrickplayRaw {
    #[serde(rename = "Width")]
    width: Option<u32>,
    #[serde(rename = "Height")]
    height: Option<u32>,
    #[serde(rename = "TileWidth")]
    tile_width: Option<u32>,
    #[serde(rename = "TileHeight")]
    tile_height: Option<u32>,
    #[serde(rename = "ThumbnailCount")]
    thumbnail_count: Option<u32>,
    #[serde(rename = "Interval")]
    interval: Option<u64>,
}

fn iso_to_epoch(s: &Option<String>) -> Option<u64> {
    // "2026-08-01T12:34:56.789Z" — parse without a chrono dependency.
    let s = s.as_deref()?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
    );
    let hms: Vec<i64> = time
        .trim_end_matches('Z')
        .split(':')
        .take(3)
        .filter_map(|p| p.split('.').next()?.parse().ok())
        .collect();
    if hms.len() < 3 || y < 1970 {
        return None;
    }
    // Days since epoch (civil-from-days algorithm).
    let (y2, m2) = if m <= 2 { (y - 1, m + 12) } else { (y, m) };
    let era = y2 / 400;
    let yoe = y2 - era * 400;
    let doy = (153 * (m2 - 3) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some((days * 86400 + hms[0] * 3600 + hms[1] * 60 + hms[2]) as u64)
}

impl JellyfinSource {
    pub fn new(base: String, api_key: String) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
            api_key,
            user_token: None,
            user_id: None,
            client: reqwest::Client::builder()
                .danger_accept_invalid_certs(true)
                .build()
                .unwrap_or_default(),
        }
    }

    pub fn with_user(mut self, token: Option<String>, user_id: Option<String>) -> Self {
        self.user_token = token.filter(|t| !t.is_empty());
        self.user_id = user_id.filter(|u| !u.is_empty());
        self
    }

    pub fn has_user(&self) -> bool {
        self.user_token.is_some() && self.user_id.is_some()
    }

    fn token(&self) -> &str {
        self.user_token.as_deref().unwrap_or(&self.api_key)
    }

    fn image(&self, id: &str, kind: &str, tag: Option<&str>) -> Option<String> {
        tag?;
        Some(format!(
            "{}/Items/{id}/Images/{kind}?maxWidth=1280&api_key={}",
            self.base,
            self.token()
        ))
    }

    async fn get_json<T: serde::de::DeserializeOwned>(&self, path: &str) -> Option<T> {
        let sep = if path.contains('?') { '&' } else { '?' };
        let url = format!("{}{path}{sep}api_key={}", self.base, self.token());
        self.client.get(&url).send().await.ok()?.json().await.ok()
    }

    async fn items(&self, query: &str) -> Vec<JfItem> {
        let Some(uid) = self.user_id.as_deref() else { return Vec::new() };
        self.get_json::<ItemsResp>(&format!("/Users/{uid}/Items?{query}"))
            .await
            .map(|r| r.items)
            .unwrap_or_default()
    }

    // ---- Auth / users ----

    /// Users visible on the server's login screen.
    pub async fn public_users(base: &str) -> Vec<JfPublicUser> {
        #[derive(Deserialize)]
        struct U {
            #[serde(rename = "Id")]
            id: String,
            #[serde(rename = "Name")]
            name: String,
            #[serde(rename = "HasPassword")]
            has_password: Option<bool>,
        }
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap_or_default();
        let url = format!("{}/Users/Public", base.trim_end_matches('/'));
        let Ok(resp) = client.get(&url).send().await else { return Vec::new() };
        resp.json::<Vec<U>>()
            .await
            .map(|us| {
                us.into_iter()
                    .map(|u| JfPublicUser {
                        id: u.id,
                        name: u.name,
                        has_password: u.has_password.unwrap_or(false),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    pub async fn login(base: &str, username: &str, password: &str) -> Option<JfLogin> {
        #[derive(Deserialize)]
        struct Resp {
            #[serde(rename = "AccessToken")]
            token: String,
            #[serde(rename = "User")]
            user: RespUser,
        }
        #[derive(Deserialize)]
        struct RespUser {
            #[serde(rename = "Id")]
            id: String,
            #[serde(rename = "Name")]
            name: String,
        }
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap_or_default();
        let url = format!("{}/Users/AuthenticateByName", base.trim_end_matches('/'));
        let resp = client
            .post(&url)
            .header(
                "X-Emby-Authorization",
                "MediaBrowser Client=\"MediaPlayer\", Device=\"MediaPlayer\", \
                 DeviceId=\"dev.mediaplayer.app\", Version=\"1.0\"",
            )
            .json(&serde_json::json!({"Username": username, "Pw": password}))
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let r = resp.json::<Resp>().await.ok()?;
        Some(JfLogin { token: r.token, user_id: r.user.id, name: r.user.name })
    }

    // ---- Library ----

    pub async fn movies(&self) -> Vec<JfMovie> {
        self.items(
            "IncludeItemTypes=Movie&Recursive=true&Fields=Overview,Path,ProviderIds,DateCreated,CommunityRating,CriticRating",
        )
        .await
        .into_iter()
        .map(|i| {
            let ud = i.user_data.unwrap_or_default();
            JfMovie {
                stream_url: format!(
                    "{}/Videos/{}/stream?static=true&api_key={}",
                    self.base, i.id, self.token()
                ),
                poster_url: self.image(&i.id, "Primary", i.image_tags.get("Primary").map(|s| s.as_str())),
                backdrop_url: self
                    .image(&i.id, "Backdrop/0", i.backdrop_tags.first().map(|s| s.as_str()))
                    .or_else(|| self.image(&i.id, "Primary", i.image_tags.get("Primary").map(|s| s.as_str()))),
                title: i.name.unwrap_or_default(),
                year: i.year,
                overview: i.overview,
                view_offset_secs: ud.position_ticks.filter(|t| *t > 0).map(|t| t as f64 / 1e7),
                watched: ud.played.unwrap_or(false),
                last_viewed_at: iso_to_epoch(&ud.last_played),
                duration_secs: i.runtime_ticks.map(|t| t as f64 / 1e7),
                tmdb_id: i.provider_ids.get("Tmdb").and_then(|v| v.parse().ok()),
                added_at: iso_to_epoch(&i.date_created),
                critic_rating: i.critic_rating.map(|r| r / 10.0),
                audience_rating: i.community_rating,
                id: i.id,
            }
        })
        .collect()
    }

    pub async fn shows(&self) -> Vec<JfShow> {
        self.items(
            "IncludeItemTypes=Series&Recursive=true&Fields=Overview,ProviderIds,DateCreated,RecursiveItemCount,CommunityRating,CriticRating",
        )
        .await
        .into_iter()
        .map(|i| JfShow {
            poster_url: self.image(&i.id, "Primary", i.image_tags.get("Primary").map(|s| s.as_str())),
            backdrop_url: self
                .image(&i.id, "Backdrop/0", i.backdrop_tags.first().map(|s| s.as_str())),
            name: i.name.unwrap_or_default(),
            episode_count: i.recursive_count.unwrap_or(0),
            overview: i.overview,
            tmdb_id: i.provider_ids.get("Tmdb").and_then(|v| v.parse().ok()),
            added_at: iso_to_epoch(&i.date_created),
            critic_rating: i.critic_rating.map(|r| r / 10.0),
            audience_rating: i.community_rating,
            id: i.id,
        })
        .collect()
    }

    pub async fn episodes(&self) -> Vec<JfEpisode> {
        self.items("IncludeItemTypes=Episode&Recursive=true&Fields=Overview,Path")
            .await
            .into_iter()
            .map(|i| {
                let ud = i.user_data.unwrap_or_default();
                JfEpisode {
                    stream_url: format!(
                        "{}/Videos/{}/stream?static=true&api_key={}",
                        self.base, i.id, self.token()
                    ),
                    thumb_url: self.image(&i.id, "Primary", i.image_tags.get("Primary").map(|s| s.as_str())),
                    show: i.series_name.unwrap_or_default(),
                    season: i.season.unwrap_or(0),
                    episode: i.episode.unwrap_or(0),
                    title: i.name.unwrap_or_default(),
                    overview: i.overview,
                    view_offset_secs: ud.position_ticks.filter(|t| *t > 0).map(|t| t as f64 / 1e7),
                    watched: ud.played.unwrap_or(false),
                    last_viewed_at: iso_to_epoch(&ud.last_played),
                    duration_secs: i.runtime_ticks.map(|t| t as f64 / 1e7),
                    id: i.id,
                }
            })
            .collect()
    }

    // ---- Watch state ----

    /// Report playback state. `state`: "playing" | "paused" | "stopped".
    pub async fn report_progress(&self, item_id: &str, secs: f64, state: &str) -> bool {
        let ticks = (secs * 1e7) as u64;
        let (path, body) = match state {
            "stopped" => (
                "/Sessions/Playing/Stopped",
                serde_json::json!({"ItemId": item_id, "PositionTicks": ticks}),
            ),
            _ => (
                "/Sessions/Playing/Progress",
                serde_json::json!({
                    "ItemId": item_id,
                    "PositionTicks": ticks,
                    "IsPaused": state == "paused",
                    "PlayMethod": "DirectPlay",
                }),
            ),
        };
        let url = format!("{}{path}?api_key={}", self.base, self.token());
        self.client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    pub async fn set_watched(&self, item_id: &str, watched: bool) -> bool {
        let Some(uid) = self.user_id.as_deref() else { return false };
        let url = format!(
            "{}/Users/{uid}/PlayedItems/{item_id}?api_key={}",
            self.base, self.token()
        );
        let req = if watched {
            self.client.post(&url)
        } else {
            self.client.delete(&url)
        };
        req.send().await.map(|r| r.status().is_success()).unwrap_or(false)
    }

    /// Skip markers from Jellyfin media segments (10.10+). Mapped onto the
    /// same kinds the Plex markers use so the apps treat them identically.
    pub async fn markers(&self, item_id: &str) -> Vec<crate::plex::PlexMarker> {
        #[derive(Deserialize)]
        struct SegmentsResp {
            #[serde(rename = "Items", default)]
            items: Vec<Segment>,
        }
        #[derive(Deserialize)]
        struct Segment {
            #[serde(rename = "Type")]
            kind: Option<String>,
            #[serde(rename = "StartTicks")]
            start_ticks: Option<u64>,
            #[serde(rename = "EndTicks")]
            end_ticks: Option<u64>,
        }
        let Some(resp) = self
            .get_json::<SegmentsResp>(&format!("/MediaSegments/{item_id}"))
            .await
        else {
            return Vec::new();
        };
        resp.items
            .into_iter()
            .filter_map(|s| {
                let kind = match s.kind.as_deref() {
                    Some("Intro") => "intro",
                    Some("Outro") => "credits",
                    Some("Commercial") => "commercial",
                    _ => return None,
                };
                Some(crate::plex::PlexMarker {
                    kind: kind.to_string(),
                    start_secs: s.start_ticks? as f64 / 1e7,
                    end_secs: s.end_ticks? as f64 / 1e7,
                })
            })
            .collect()
    }

    /// External text subtitles for an item, shaped like Plex's.
    pub async fn subtitles(&self, item_id: &str) -> Vec<crate::plex::PlexSubtitle> {
        #[derive(Deserialize)]
        struct ItemResp {
            #[serde(rename = "MediaSources", default)]
            sources: Vec<Source>,
        }
        #[derive(Deserialize)]
        struct Source {
            #[serde(rename = "Id")]
            id: String,
            #[serde(rename = "MediaStreams", default)]
            streams: Vec<Stream>,
        }
        #[derive(Deserialize)]
        struct Stream {
            #[serde(rename = "Type")]
            kind: Option<String>,
            #[serde(rename = "Codec")]
            codec: Option<String>,
            #[serde(rename = "Language")]
            lang: Option<String>,
            #[serde(rename = "DisplayTitle")]
            title: Option<String>,
            #[serde(rename = "Index")]
            index: Option<u32>,
            #[serde(rename = "IsExternal")]
            external: Option<bool>,
        }
        let Some(uid) = self.user_id.as_deref() else { return Vec::new() };
        let Some(item) = self
            .get_json::<ItemResp>(&format!("/Users/{uid}/Items/{item_id}?Fields=MediaSources"))
            .await
        else {
            return Vec::new();
        };
        const TEXT: [&str; 5] = ["srt", "subrip", "ass", "ssa", "vtt"];
        let mut out = Vec::new();
        for source in &item.sources {
            for s in &source.streams {
                if s.kind.as_deref() != Some("Subtitle") || !s.external.unwrap_or(false) {
                    continue;
                }
                let codec = s.codec.clone().unwrap_or_else(|| "srt".into());
                if !TEXT.contains(&codec.as_str()) {
                    continue;
                }
                let ext = if codec == "subrip" { "srt" } else { codec.as_str() };
                let Some(index) = s.index else { continue };
                out.push(crate::plex::PlexSubtitle {
                    url: format!(
                        "{}/Videos/{item_id}/{}/Subtitles/{index}/0/Stream.{ext}?api_key={}",
                        self.base,
                        source.id,
                        self.token()
                    ),
                    lang: s.lang.clone(),
                    title: s.title.clone(),
                    codec: Some(codec),
                });
            }
        }
        out
    }

    /// Jellyfin has likes, not a 0–10 scale: ≥6 → liked, <6 → disliked,
    /// 0 clears the rating.
    pub async fn rate(&self, item_id: &str, rating: f32) -> bool {
        let Some(uid) = self.user_id.as_deref() else { return false };
        let base_url = format!(
            "{}/Users/{uid}/Items/{item_id}/Rating?api_key={}",
            self.base, self.token()
        );
        let req = if rating <= 0.0 {
            self.client.delete(&base_url)
        } else {
            self.client
                .post(format!("{base_url}&likes={}", rating >= 6.0))
        };
        req.send().await.map(|r| r.status().is_success()).unwrap_or(false)
    }

    // ---- Trickplay ----

    fn trickplay_from_item(&self, item: JfItem) -> Option<TrickplayInfo> {
        let sources = item.trickplay?;
        let per_width = sources.into_values().next()?;
        let (width_key, raw) = per_width
            .into_iter()
            .max_by_key(|(w, _)| w.parse::<u32>().unwrap_or(0))?;
        Some(TrickplayInfo {
            tile_url_template: format!(
                "{}/Videos/{}/Trickplay/{}/{{i}}.jpg?api_key={}",
                self.base, item.id, width_key, self.api_key
            ),
            interval_ms: raw.interval.unwrap_or(10_000),
            tile_cols: raw.tile_width.unwrap_or(10),
            tile_rows: raw.tile_height.unwrap_or(10),
            thumb_width: raw.width.unwrap_or(320),
            thumb_height: raw.height.unwrap_or(180),
            thumbnail_count: raw.thumbnail_count.unwrap_or(0),
        })
    }

    /// Trickplay manifest by Jellyfin item id.
    pub async fn trickplay_for_item(&self, item_id: &str) -> Option<TrickplayInfo> {
        let url = format!(
            "{}/Items?Ids={item_id}&Fields=Trickplay&api_key={}",
            self.base, self.api_key
        );
        let resp = self.client.get(&url).send().await.ok()?;
        let items = resp.json::<ItemsResp>().await.ok()?.items;
        items.into_iter().next().and_then(|i| self.trickplay_from_item(i))
    }

    /// Trickplay manifest for the item whose media file is at `path`
    /// (matching a Plex-played file to the same file in Jellyfin).
    pub async fn trickplay_for_path(&self, path: &str) -> Option<TrickplayInfo> {
        let url = format!(
            "{}/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=Path,Trickplay&api_key={}",
            self.base, self.api_key
        );
        let resp = self.client.get(&url).send().await.ok()?;
        let items = resp.json::<ItemsResp>().await.ok()?.items;
        let item = items.into_iter().find(|i| i.path.as_deref() == Some(path))?;
        self.trickplay_from_item(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_dates_to_epoch() {
        assert_eq!(
            iso_to_epoch(&Some("2026-08-01T12:34:56.789Z".to_string())),
            Some(1785587696)
        );
        assert_eq!(iso_to_epoch(&Some("1970-01-01T00:00:00Z".to_string())), Some(0));
        assert_eq!(iso_to_epoch(&None), None);
        assert_eq!(iso_to_epoch(&Some("not a date".to_string())), None);
    }

    #[test]
    fn parses_item_with_ratings_and_userdata() {
        let raw = r#"{
            "Items": [{
                "Id": "abc123",
                "Name": "Conclave",
                "ProductionYear": 2024,
                "RunTimeTicks": 72000000000,
                "CommunityRating": 7.4,
                "CriticRating": 93.0,
                "DateCreated": "2026-08-01T12:34:56.789Z",
                "ProviderIds": {"Tmdb": "974576"},
                "UserData": {"PlaybackPositionTicks": 600000000, "Played": false}
            }]
        }"#;
        let resp: ItemsResp = serde_json::from_str(raw).unwrap();
        let item = &resp.items[0];
        assert_eq!(item.community_rating, Some(7.4));
        assert_eq!(item.critic_rating, Some(93.0));
        assert_eq!(item.runtime_ticks, Some(72000000000));
        assert_eq!(item.provider_ids.get("Tmdb").unwrap(), "974576");
        let ud = item.user_data.as_ref().unwrap();
        // 600000000 ticks = 60 seconds.
        assert_eq!(ud.position_ticks, Some(600000000));
    }

    #[test]
    fn trickplay_picks_widest_grid() {
        let raw = r#"{
            "Items": [{
                "Id": "vid1",
                "Trickplay": {
                    "src1": {
                        "192": {"Width": 192, "Height": 108, "TileWidth": 10,
                                "TileHeight": 10, "ThumbnailCount": 500, "Interval": 10000},
                        "320": {"Width": 320, "Height": 180, "TileWidth": 10,
                                "TileHeight": 10, "ThumbnailCount": 500, "Interval": 10000}
                    }
                }
            }]
        }"#;
        let resp: ItemsResp = serde_json::from_str(raw).unwrap();
        let jf = JellyfinSource::new("http://example".into(), "key".into());
        let info = jf.trickplay_from_item(resp.items.into_iter().next().unwrap()).unwrap();
        assert!(info.tile_url_template.contains("/Trickplay/320/"));
        assert_eq!(info.tile_cols, 10);
        assert_eq!(info.interval_ms, 10000);
        assert_eq!(info.thumbnail_count, 500);
    }
}
