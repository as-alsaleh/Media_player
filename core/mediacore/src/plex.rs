//! Plex Media Server source.
//!
//! Talks the Plex HTTP API directly (X-Plex-Token auth) and yields items in
//! the same shape as the local index, with absolute direct-play stream URLs
//! that mpv can open without any proxying.

use serde::Deserialize;

#[derive(Clone)]
pub struct PlexSource {
    base: String,
    token: String,
    /// Token used for media part URLs. Managed/restricted Home users often
    /// can't fetch raw parts (Plex 503s), so clients stream with the owner
    /// token while metadata and watch state stay on the user token.
    media_token: Option<String>,
    client: reqwest::Client,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexMovie {
    pub title: String,
    pub year: Option<u16>,
    pub overview: Option<String>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub stream_url: String,
    pub rating_key: String,
    /// Server-side resume point, seconds.
    pub view_offset_secs: Option<f64>,
    pub watched: bool,
    pub last_viewed_at: Option<u64>,
    pub duration_secs: Option<f64>,
    pub tmdb_id: Option<u64>,
    pub added_at: Option<u64>,
    /// Critic score 0–10 (Rotten Tomatoes on most servers).
    pub critic_rating: Option<f64>,
    /// Audience score 0–10.
    pub audience_rating: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexMarker {
    /// "intro", "credits", or "commercial".
    pub kind: String,
    pub start_secs: f64,
    pub end_secs: f64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexUser {
    pub uuid: String,
    pub title: String,
    pub protected: bool,
    /// Avatar URL. plex.tv serves these unauthenticated, so clients can use
    /// them directly.
    pub thumb: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexShow {
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
pub struct PlexEpisode {
    pub show: String,
    pub season: u16,
    pub episode: u16,
    pub title: String,
    pub thumb_url: Option<String>,
    pub overview: Option<String>,
    pub stream_url: String,
    pub rating_key: String,
    pub view_offset_secs: Option<f64>,
    pub watched: bool,
    pub last_viewed_at: Option<u64>,
    pub duration_secs: Option<f64>,
    /// When this episode landed in the library — drives Recently Added.
    pub added_at: Option<u64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexSubtitle {
    pub url: String,
    pub lang: Option<String>,
    pub title: Option<String>,
    pub codec: Option<String>,
}

#[derive(Deserialize)]
struct Envelope<T> {
    #[serde(rename = "MediaContainer")]
    container: T,
}

#[derive(Deserialize)]
struct SectionList {
    #[serde(rename = "Directory", default)]
    directories: Vec<Section>,
}

#[derive(Deserialize)]
struct Section {
    key: String,
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Deserialize)]
struct ItemList {
    #[serde(rename = "Metadata", default)]
    items: Vec<Item>,
}

#[derive(Deserialize)]
struct Item {
    #[serde(rename = "ratingKey")]
    rating_key: String,
    title: String,
    year: Option<u16>,
    summary: Option<String>,
    thumb: Option<String>,
    art: Option<String>,
    #[serde(rename = "grandparentTitle")]
    grandparent_title: Option<String>,
    #[serde(rename = "parentIndex")]
    parent_index: Option<u16>,
    index: Option<u16>,
    #[serde(rename = "leafCount")]
    leaf_count: Option<u32>,
    #[serde(rename = "viewOffset")]
    view_offset: Option<u64>,
    #[serde(rename = "viewCount")]
    view_count: Option<u32>,
    #[serde(rename = "lastViewedAt")]
    last_viewed_at: Option<u64>,
    #[serde(rename = "addedAt")]
    added_at: Option<u64>,
    rating: Option<f64>,
    #[serde(rename = "audienceRating")]
    audience_rating: Option<f64>,
    duration: Option<u64>,
    #[serde(rename = "Marker", default)]
    markers: Vec<MarkerRaw>,
    #[serde(rename = "Guid", default)]
    guids: Vec<GuidRaw>,
    #[serde(rename = "Media", default)]
    media: Vec<Media>,
}

#[derive(Deserialize)]
struct GuidRaw {
    id: String,
}

#[derive(Deserialize)]
struct MarkerRaw {
    #[serde(rename = "type")]
    kind: String,
    #[serde(rename = "startTimeOffset")]
    start: u64,
    #[serde(rename = "endTimeOffset")]
    end: u64,
}

impl Item {
    fn offset_secs(&self) -> Option<f64> {
        self.view_offset.map(|ms| ms as f64 / 1000.0)
    }

    fn duration_secs(&self) -> Option<f64> {
        self.duration.map(|ms| ms as f64 / 1000.0)
    }

    fn watched(&self) -> bool {
        self.view_count.unwrap_or(0) > 0
    }

    fn tmdb_id(&self) -> Option<u64> {
        self.guids.iter().find_map(|g| {
            g.id.strip_prefix("tmdb://").and_then(|v| v.parse().ok())
        })
    }
}

#[derive(Deserialize)]
struct Media {
    #[serde(rename = "Part", default)]
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct Part {
    key: String,
    id: Option<u64>,
    /// Absolute path of the media file on the server.
    file: Option<String>,
    /// "sd" when the server has generated video preview thumbnails (BIF).
    indexes: Option<String>,
    #[serde(rename = "Stream", default)]
    streams: Vec<StreamRaw>,
}

#[derive(Deserialize)]
struct StreamRaw {
    #[serde(rename = "streamType")]
    stream_type: u8,
    /// Present only for external/sidecar subtitles (incl. agent downloads).
    key: Option<String>,
    #[serde(rename = "languageTag")]
    language_tag: Option<String>,
    language: Option<String>,
    #[serde(rename = "displayTitle")]
    display_title: Option<String>,
    codec: Option<String>,
}

const CLIENT_ID: &str = "dev.mediaplayer.app";
const PRODUCT: &str = "MediaPlayer";

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexPin {
    pub id: u64,
    pub code: String,
    /// Open this in a browser; after login the pin resolves to a token.
    pub auth_url: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexServerInfo {
    pub name: String,
    pub url: String,
    pub token: String,
}

fn plex_headers(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("Accept", "application/json")
        .header("X-Plex-Client-Identifier", CLIENT_ID)
        .header("X-Plex-Product", PRODUCT)
        .header("X-Plex-Version", "1.0")
}

/// Start the plex.tv PIN login flow.
pub async fn pin_create() -> Option<PlexPin> {
    #[derive(Deserialize)]
    struct Pin {
        id: u64,
        code: String,
    }
    let client = reqwest::Client::new();
    let resp = plex_headers(client.post("https://plex.tv/api/v2/pins?strong=true"))
        .send()
        .await
        .ok()?;
    let pin = resp.json::<Pin>().await.ok()?;
    let auth_url = format!(
        "https://app.plex.tv/auth#?clientID={CLIENT_ID}&code={}&context%5Bdevice%5D%5Bproduct%5D={PRODUCT}",
        pin.code
    );
    Some(PlexPin { id: pin.id, code: pin.code, auth_url })
}

/// Poll a pin; returns the account token once the user has signed in.
pub async fn pin_check(id: u64) -> Option<String> {
    #[derive(Deserialize)]
    struct Pin {
        #[serde(rename = "authToken")]
        auth_token: Option<String>,
    }
    let client = reqwest::Client::new();
    let resp = plex_headers(client.get(format!("https://plex.tv/api/v2/pins/{id}")))
        .send()
        .await
        .ok()?;
    resp.json::<Pin>().await.ok()?.auth_token
}

/// Find the account's own media server and its access token.
/// Prefers a local (LAN) connection.
pub async fn discover_server(account_token: &str) -> Option<PlexServerInfo> {
    #[derive(Deserialize)]
    struct Conn {
        uri: String,
        local: bool,
        protocol: String,
    }
    #[derive(Deserialize)]
    struct Resource {
        name: String,
        provides: String,
        owned: bool,
        #[serde(rename = "accessToken")]
        access_token: Option<String>,
        #[serde(default)]
        connections: Vec<Conn>,
    }
    let client = reqwest::Client::new();
    let resp = plex_headers(client.get(format!(
        "https://plex.tv/api/v2/resources?includeHttps=1&X-Plex-Token={account_token}"
    )))
    .send()
    .await
    .ok()?;
    let resources = resp.json::<Vec<Resource>>().await.ok()?;
    let server = resources
        .into_iter()
        .filter(|r| r.provides.contains("server"))
        .max_by_key(|r| r.owned)?;
    let token = server.access_token?;
    let conn = server
        .connections
        .iter()
        .find(|c| c.local && c.protocol == "http")
        .or_else(|| server.connections.iter().find(|c| c.local))
        .or_else(|| server.connections.first())?;
    Some(PlexServerInfo { name: server.name, url: conn.uri.clone(), token })
}

impl PlexSource {
    pub fn new(base: String, token: String) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
            token,
            media_token: None,
            client: reqwest::Client::new(),
        }
    }

    pub fn with_media_token(mut self, token: Option<String>) -> Self {
        self.media_token = token.filter(|t| !t.is_empty());
        self
    }

    fn url(&self, path: &str) -> String {
        let sep = if path.contains('?') { '&' } else { '?' };
        format!("{}{path}{sep}X-Plex-Token={}", self.base, self.token)
    }

    fn image(&self, path: &Option<String>) -> Option<String> {
        path.as_ref().map(|p| self.url(p))
    }

    async fn get<T: serde::de::DeserializeOwned>(&self, path: &str) -> Option<T> {
        self.client
            .get(self.url(path))
            .header("Accept", "application/json")
            .send()
            .await
            .ok()?
            .json::<Envelope<T>>()
            .await
            .ok()
            .map(|e| e.container)
    }

    async fn sections(&self, kind: &str) -> Vec<String> {
        let list: Option<SectionList> = self.get("/library/sections").await;
        list.map(|l| {
            l.directories
                .into_iter()
                .filter(|d| d.kind == kind)
                .map(|d| d.key)
                .collect()
        })
        .unwrap_or_default()
    }

    fn stream_url(&self, item: &Item) -> Option<String> {
        let part = item.media.first()?.parts.first()?;
        let token = self.media_token.as_deref().unwrap_or(&self.token);
        let sep = if part.key.contains('?') { '&' } else { '?' };
        Some(format!("{}{}{sep}X-Plex-Token={token}", self.base, part.key))
    }

    pub async fn movies(&self) -> Vec<PlexMovie> {
        let mut out = Vec::new();
        for key in self.sections("movie").await {
            let Some(list): Option<ItemList> =
                self.get(&format!("/library/sections/{key}/all")).await
            else {
                continue;
            };
            for item in &list.items {
                let Some(stream) = self.stream_url(item) else { continue };
                out.push(PlexMovie {
                    title: item.title.clone(),
                    year: item.year,
                    overview: item.summary.clone(),
                    poster_url: self.image(&item.thumb),
                    backdrop_url: self.image(&item.art),
                    stream_url: stream,
                    rating_key: item.rating_key.clone(),
                    view_offset_secs: item.offset_secs(),
                    watched: item.watched(),
                    last_viewed_at: item.last_viewed_at,
                    duration_secs: item.duration_secs(),
                    tmdb_id: item.tmdb_id(),
                    added_at: item.added_at,
                    critic_rating: item.rating,
                    audience_rating: item.audience_rating,
                });
            }
        }
        out
    }

    pub async fn shows(&self) -> Vec<PlexShow> {
        let mut out = Vec::new();
        for key in self.sections("show").await {
            let Some(list): Option<ItemList> =
                self.get(&format!("/library/sections/{key}/all")).await
            else {
                continue;
            };
            for item in &list.items {
                out.push(PlexShow {
                    name: item.title.clone(),
                    episode_count: item.leaf_count.unwrap_or(0),
                    poster_url: self.image(&item.thumb),
                    backdrop_url: self.image(&item.art),
                    overview: item.summary.clone(),
                    tmdb_id: item.tmdb_id(),
                    added_at: item.added_at,
                    critic_rating: item.rating,
                    audience_rating: item.audience_rating,
                });
            }
        }
        out
    }

    /// Intro/credits/commercial markers for one item.
    pub async fn markers(&self, rating_key: &str) -> Vec<PlexMarker> {
        let Some(list): Option<ItemList> = self
            .get(&format!("/library/metadata/{rating_key}?includeMarkers=1"))
            .await
        else {
            return Vec::new();
        };
        list.items
            .first()
            .map(|item| {
                item.markers
                    .iter()
                    .map(|m| PlexMarker {
                        kind: m.kind.clone(),
                        start_secs: m.start as f64 / 1000.0,
                        end_secs: m.end as f64 / 1000.0,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Set a 0–10 user rating on an item.
    pub async fn rate(&self, rating_key: &str, rating: f32) -> bool {
        let path = format!(
            "/:/rate?identifier=com.plexapp.plugins.library&key={rating_key}&rating={rating}"
        );
        self.client
            .put(self.url(&path))
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    /// Mark an item watched (`scrobble`) or unwatched (`unscrobble`).
    pub async fn set_watched(&self, rating_key: &str, watched: bool) -> bool {
        let verb = if watched { "scrobble" } else { "unscrobble" };
        let path =
            format!("/:/{verb}?identifier=com.plexapp.plugins.library&key={rating_key}");
        self.client
            .get(self.url(&path))
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    /// Drop the item from Continue Watching without marking it watched.
    /// Modern servers have a dedicated action; older ones at least clear the
    /// resume point via an unscrobble (which also resets viewOffset).
    pub async fn clear_progress(&self, rating_key: &str) -> bool {
        let path = format!("/actions/removeFromContinueWatching?ratingKey={rating_key}");
        let dedicated = self
            .client
            .put(self.url(&path))
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false);
        if dedicated {
            return true;
        }
        self.set_watched(rating_key, false).await
    }

    /// Report playback progress back to the server so watch state stays in
    /// sync with other Plex clients. `state` is "playing", "paused", "stopped".
    pub async fn report_progress(
        &self,
        rating_key: &str,
        time_secs: f64,
        duration_secs: f64,
        state: &str,
    ) -> bool {
        let path = format!(
            "/:/timeline?ratingKey={rating_key}&key=%2Flibrary%2Fmetadata%2F{rating_key}\
             &identifier=com.plexapp.plugins.library&state={state}\
             &time={}&duration={}",
            (time_secs * 1000.0) as u64,
            (duration_secs * 1000.0) as u64,
        );
        self.client
            .get(self.url(&path))
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    /// List Plex Home users on the account that owns this token.
    pub async fn home_users(&self) -> Vec<PlexUser> {
        #[derive(Deserialize)]
        struct Users {
            users: Vec<User>,
        }
        #[derive(Deserialize)]
        struct User {
            uuid: String,
            title: String,
            protected: bool,
            thumb: Option<String>,
        }
        let Ok(resp) = self
            .client
            .get(format!(
                "https://plex.tv/api/v2/home/users?X-Plex-Token={}",
                self.token
            ))
            .header("Accept", "application/json")
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
        else {
            return Vec::new();
        };
        resp.json::<Users>()
            .await
            .map(|u| {
                u.users
                    .into_iter()
                    .map(|u| PlexUser {
                        uuid: u.uuid,
                        title: u.title,
                        protected: u.protected,
                        // Plex sends an empty string for users without an
                        // avatar; treat that as absent so clients can fall
                        // back to an initial.
                        thumb: u.thumb.filter(|t| !t.is_empty()),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Switch to a Plex Home user; returns that user's *server access token*.
    ///
    /// The plex.tv switch endpoint returns an account-level token which the
    /// media server resolves to the owner. The per-user server token comes
    /// from the resources API afterwards — official clients do the same.
    pub async fn switch_user(&self, uuid: &str, pin: Option<&str>) -> Option<String> {
        #[derive(Deserialize)]
        struct Switched {
            #[serde(rename = "authToken")]
            auth_token: String,
        }
        let mut url = format!(
            "https://plex.tv/api/v2/home/users/{uuid}/switch?X-Plex-Token={}",
            self.token
        );
        if let Some(pin) = pin {
            url.push_str(&format!("&pin={pin}"));
        }
        let resp = self
            .client
            .post(url)
            .header("Accept", "application/json")
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .ok()?;
        let account_token = resp.json::<Switched>().await.ok()?.auth_token;

        // Exchange for the per-user access token of *this* server. No
        // fallback to the account token: the media server resolves that to
        // the OWNER, which would silently hand a restricted profile (e.g. a
        // kids account) the full library. Failing the switch is safer than
        // succeeding with escalated access.
        self.server_access_token(&account_token).await
    }

    /// Our server's machineIdentifier.
    async fn machine_id(&self) -> Option<String> {
        #[derive(Deserialize)]
        struct Identity {
            #[serde(rename = "machineIdentifier")]
            machine_identifier: String,
        }
        let resp = self
            .client
            .get(self.url("/identity"))
            .header("Accept", "application/json")
            .send()
            .await
            .ok()?;
        resp.json::<Envelope<Identity>>()
            .await
            .ok()
            .map(|e| e.container.machine_identifier)
    }

    /// Look up the given account token's access token for this server.
    async fn server_access_token(&self, account_token: &str) -> Option<String> {
        #[derive(Deserialize)]
        struct Resource {
            #[serde(rename = "clientIdentifier")]
            client_identifier: String,
            #[serde(rename = "accessToken")]
            access_token: Option<String>,
            provides: String,
        }
        let machine = self.machine_id().await?;
        let resp = self
            .client
            .get(format!(
                "https://plex.tv/api/v2/resources?X-Plex-Token={account_token}"
            ))
            .header("Accept", "application/json")
            .header("X-Plex-Client-Identifier", "dev.mediaplayer.app")
            .send()
            .await
            .ok()?;
        let resources = resp.json::<Vec<Resource>>().await.ok()?;
        resources
            .into_iter()
            .find(|r| r.provides.contains("server") && r.client_identifier == machine)
            .and_then(|r| r.access_token)
    }

    /// Absolute path of an item's media file on the server (for matching
    /// the same file in other indexers, e.g. Jellyfin trickplay).
    pub async fn file_path(&self, rating_key: &str) -> Option<String> {
        let list: ItemList = self.get(&format!("/library/metadata/{rating_key}")).await?;
        list.items
            .first()?
            .media
            .first()?
            .parts
            .first()?
            .file
            .clone()
    }

    /// Seek-preview thumbnail URL template ("{ms}" placeholder) for an item,
    /// available when the server has generated video preview thumbnails.
    pub async fn preview_template(&self, rating_key: &str) -> Option<String> {
        let list: ItemList = self.get(&format!("/library/metadata/{rating_key}")).await?;
        let part = list.items.first()?.media.first()?.parts.first()?;
        if part.indexes.as_deref() != Some("sd") {
            return None;
        }
        let id = part.id?;
        let token = self.media_token.as_deref().unwrap_or(&self.token);
        Some(format!(
            "{}/library/parts/{id}/indexes/sd/{{ms}}?X-Plex-Token={token}",
            self.base
        ))
    }

    /// External subtitle streams for one item — sidecar files next to the
    /// media and anything Plex agents (e.g. OpenSubtitles) downloaded.
    pub async fn subtitles(&self, rating_key: &str) -> Vec<PlexSubtitle> {
        let Some(list): Option<ItemList> = self
            .get(&format!("/library/metadata/{rating_key}"))
            .await
        else {
            return Vec::new();
        };
        let token = self.media_token.as_deref().unwrap_or(&self.token);
        let mut out = Vec::new();
        for item in &list.items {
            for media in &item.media {
                for part in &media.parts {
                    for s in &part.streams {
                        // streamType 3 = subtitle; only external ones have a key.
                        let (3, Some(key)) = (s.stream_type, s.key.as_ref()) else { continue };
                        let sep = if key.contains('?') { '&' } else { '?' };
                        out.push(PlexSubtitle {
                            url: format!("{}{}{sep}X-Plex-Token={token}", self.base, key),
                            lang: s.language_tag.clone().or_else(|| s.language.clone()),
                            title: s.display_title.clone(),
                            codec: s.codec.clone(),
                        });
                    }
                }
            }
        }
        out
    }

    pub async fn episodes(&self) -> Vec<PlexEpisode> {
        let mut out = Vec::new();
        for key in self.sections("show").await {
            // type=4 lists every episode in the section in one call.
            let Some(list): Option<ItemList> = self
                .get(&format!("/library/sections/{key}/all?type=4"))
                .await
            else {
                continue;
            };
            for item in &list.items {
                let Some(stream) = self.stream_url(item) else { continue };
                out.push(PlexEpisode {
                    show: item.grandparent_title.clone().unwrap_or_default(),
                    season: item.parent_index.unwrap_or(0),
                    episode: item.index.unwrap_or(0),
                    title: item.title.clone(),
                    thumb_url: self.image(&item.thumb),
                    overview: item.summary.clone(),
                    stream_url: stream,
                    rating_key: item.rating_key.clone(),
                    view_offset_secs: item.offset_secs(),
                    watched: item.watched(),
                    last_viewed_at: item.last_viewed_at,
                    duration_secs: item.duration_secs(),
                    added_at: item.added_at,
                });
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A trimmed /library/sections/N/all payload with the fields we map.
    const SAMPLE: &str = r#"{
        "MediaContainer": {
            "Metadata": [{
                "ratingKey": "42",
                "title": "Manchester by the Sea",
                "year": 2016,
                "summary": "Lee Chandler is a brooding, irritable loner.",
                "thumb": "/library/metadata/42/thumb/1",
                "art": "/library/metadata/42/art/1",
                "rating": 9.6,
                "audienceRating": 7.8,
                "viewOffset": 90000,
                "viewCount": 1,
                "addedAt": 1754000000,
                "duration": 8220000,
                "Guid": [
                    {"id": "imdb://tt4034228"},
                    {"id": "tmdb://334543"}
                ],
                "Marker": [
                    {"type": "credits", "startTimeOffset": 8000000, "endTimeOffset": 8220000}
                ],
                "Media": [{"Part": [{"key": "/library/parts/9/file.mkv", "id": 9}]}]
            }]
        }
    }"#;

    #[test]
    fn parses_item_fields() {
        let env: Envelope<ItemList> = serde_json::from_str(SAMPLE).unwrap();
        let item = &env.container.items[0];
        assert_eq!(item.rating_key, "42");
        assert_eq!(item.year, Some(2016));
        assert_eq!(item.rating, Some(9.6));
        assert_eq!(item.audience_rating, Some(7.8));
        assert_eq!(item.tmdb_id(), Some(334543));
        assert!(item.watched());
        assert_eq!(item.offset_secs(), Some(90.0));
        assert_eq!(item.duration_secs(), Some(8220.0));
        assert_eq!(item.added_at, Some(1754000000));
        assert_eq!(item.markers.len(), 1);
        assert_eq!(item.markers[0].kind, "credits");
    }

    /// A dead server must degrade to "no data", never an error the caller
    /// has to handle — playback of an already-resolved stream URL (or a
    /// downloaded file) continues without markers/subtitles/ratings.
    #[tokio::test]
    async fn unreachable_server_degrades_to_empty() {
        // Reserved port on localhost — connections fail fast.
        let plex = PlexSource::new("http://127.0.0.1:9".into(), "token".into());
        assert!(plex.markers("1").await.is_empty());
        assert!(plex.subtitles("1").await.is_empty());
        assert!(plex.movies().await.is_empty());
        assert_eq!(plex.preview_template("1").await, None);
        assert_eq!(plex.file_path("1").await, None);
        assert!(!plex.rate("1", 8.0).await);
        assert!(!plex.set_watched("1", true).await);
    }

    #[test]
    fn missing_optionals_do_not_fail() {
        // Plex omits fields freely; the minimum payload must still parse.
        let minimal = r#"{"MediaContainer": {"Metadata": [{"ratingKey": "1", "title": "X"}]}}"#;
        let env: Envelope<ItemList> = serde_json::from_str(minimal).unwrap();
        let item = &env.container.items[0];
        assert_eq!(item.rating, None);
        assert_eq!(item.tmdb_id(), None);
        assert!(!item.watched());
    }
}
