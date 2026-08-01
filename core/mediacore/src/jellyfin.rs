//! Jellyfin — used as the trickplay (scrub-preview thumbnail) provider.
//!
//! Playback and watch state stay on Plex; both servers index the same files,
//! so items are matched by their absolute file path and Jellyfin serves the
//! pre-generated preview tile images for the seek bar.

use serde::Deserialize;
use std::collections::HashMap;

#[derive(Clone)]
pub struct JellyfinSource {
    base: String,
    api_key: String,
    client: reqwest::Client,
}

/// Trickplay manifest for one item, resolved to concrete tile URLs.
/// `tile_url_template` contains "{i}" for the tile-grid image index.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TrickplayInfo {
    pub tile_url_template: String,
    /// Milliseconds between consecutive thumbnails.
    pub interval_ms: u64,
    /// Grid layout of each tile image.
    pub tile_cols: u32,
    pub tile_rows: u32,
    /// Size of one thumbnail within the grid.
    pub thumb_width: u32,
    pub thumb_height: u32,
    pub thumbnail_count: u32,
}

#[derive(Deserialize)]
struct ItemsResp {
    #[serde(rename = "Items", default)]
    items: Vec<JfItem>,
}

#[derive(Deserialize)]
struct JfItem {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Path")]
    path: Option<String>,
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

impl JellyfinSource {
    pub fn new(base: String, api_key: String) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
            api_key,
            client: reqwest::Client::builder()
                .danger_accept_invalid_certs(true)
                .build()
                .unwrap_or_default(),
        }
    }

    /// Trickplay manifest for the item whose media file is at `path`.
    pub async fn trickplay_for_path(&self, path: &str) -> Option<TrickplayInfo> {
        // One shot: list all movie/episode items with Path + Trickplay fields
        // and match by absolute path (both servers see the same /media tree).
        let url = format!(
            "{}/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=Path,Trickplay&api_key={}",
            self.base, self.api_key
        );
        let resp = self.client.get(&url).send().await.ok()?;
        let items = resp.json::<ItemsResp>().await.ok()?.items;
        let item = items
            .into_iter()
            .find(|i| i.path.as_deref() == Some(path))?;
        // Trickplay: {mediaSourceId: {width: manifest}} — take the first
        // (largest-width) manifest of the first media source.
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
}
