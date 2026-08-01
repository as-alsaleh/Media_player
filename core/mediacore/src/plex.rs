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
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexShow {
    pub name: String,
    pub episode_count: u32,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub overview: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlexEpisode {
    pub show: String,
    pub season: u16,
    pub episode: u16,
    pub title: String,
    pub stream_url: String,
    pub rating_key: String,
    pub view_offset_secs: Option<f64>,
    pub watched: bool,
    pub last_viewed_at: Option<u64>,
    pub duration_secs: Option<f64>,
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
    duration: Option<u64>,
    #[serde(rename = "Marker", default)]
    markers: Vec<MarkerRaw>,
    #[serde(rename = "Media", default)]
    media: Vec<Media>,
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
}

#[derive(Deserialize)]
struct Media {
    #[serde(rename = "Part", default)]
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct Part {
    key: String,
}

impl PlexSource {
    pub fn new(base: String, token: String) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
            token,
            client: reqwest::Client::new(),
        }
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
        Some(self.url(&part.key))
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
                    .map(|u| PlexUser { uuid: u.uuid, title: u.title, protected: u.protected })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Switch to a Plex Home user; returns the user-scoped auth token.
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
        resp.json::<Switched>().await.ok().map(|s| s.auth_token)
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
                    stream_url: stream,
                    rating_key: item.rating_key.clone(),
                    view_offset_secs: item.offset_secs(),
                    watched: item.watched(),
                    last_viewed_at: item.last_viewed_at,
                    duration_secs: item.duration_secs(),
                });
            }
        }
        out
    }
}
