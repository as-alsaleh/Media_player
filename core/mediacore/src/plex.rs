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
    #[serde(rename = "Media", default)]
    media: Vec<Media>,
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
                });
            }
        }
        out
    }
}
