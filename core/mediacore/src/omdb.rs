//! OMDb ratings enrichment for SMB-only libraries (user-supplied key).
//!
//! Plex and Jellyfin items arrive with server-side ratings; plain SMB
//! libraries have none. OMDb's free tier (1,000 req/day) fills in Rotten
//! Tomatoes critic scores and IMDb ratings by title lookup. Only items
//! still missing a rating are queried, so repeat scans cost nothing.

use crate::index::Index;
use std::sync::Arc;

#[derive(serde::Deserialize)]
struct OmdbItem {
    #[serde(rename = "Ratings", default)]
    ratings: Vec<OmdbRating>,
    #[serde(rename = "imdbRating")]
    imdb_rating: Option<String>,
    #[serde(rename = "Response")]
    response: Option<String>,
}

#[derive(serde::Deserialize)]
struct OmdbRating {
    #[serde(rename = "Source")]
    source: String,
    #[serde(rename = "Value")]
    value: String,
}

/// ("96%" → 9.6, imdb "8.2" → 8.2) on the same 0–10 scale the servers use.
fn scores(item: &OmdbItem) -> (Option<f64>, Option<f64>) {
    let critic = item
        .ratings
        .iter()
        .find(|r| r.source == "Rotten Tomatoes")
        .and_then(|r| r.value.trim_end_matches('%').parse::<f64>().ok())
        .map(|pct| pct / 10.0);
    let audience = item
        .imdb_rating
        .as_deref()
        .and_then(|v| v.parse::<f64>().ok());
    (critic, audience)
}

async fn lookup(
    client: &reqwest::Client,
    api_key: &str,
    title: &str,
    year: Option<u16>,
    series: bool,
) -> Option<(Option<f64>, Option<f64>)> {
    let mut req = client.get("https://www.omdbapi.com/").query(&[
        ("apikey", api_key),
        ("t", title),
        ("type", if series { "series" } else { "movie" }),
    ]);
    if let Some(year) = year {
        req = req.query(&[("y", year.to_string())]);
    }
    let item = req.send().await.ok()?.json::<OmdbItem>().await.ok()?;
    if item.response.as_deref() == Some("False") {
        return None;
    }
    Some(scores(&item))
}

/// Fill critic/audience ratings for movies and shows that lack them.
/// Returns the number of items enriched.
pub async fn enrich(index: &Arc<Index>, api_key: &str) -> usize {
    let client = reqwest::Client::new();
    let mut enriched = 0;

    if let Ok(movies) = index.movies() {
        for movie in movies
            .iter()
            .filter(|m| m.critic_rating.is_none() && m.audience_rating.is_none())
        {
            let Some((critic, audience)) =
                lookup(&client, api_key, &movie.title, movie.year, false).await
            else {
                continue;
            };
            if critic.is_some() || audience.is_some() {
                index.set_movie_ratings(movie.id, critic, audience);
                enriched += 1;
            }
        }
    }

    if let Ok(shows) = index.shows() {
        for show in shows
            .iter()
            .filter(|s| s.critic_rating.is_none() && s.audience_rating.is_none())
        {
            let query = crate::parse::parse_movie(&show.name).title;
            let Some((critic, audience)) =
                lookup(&client, api_key, &query, None, true).await
            else {
                continue;
            };
            if critic.is_some() || audience.is_some() {
                index.set_show_ratings(&show.name, critic, audience);
                enriched += 1;
            }
        }
    }

    enriched
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_omdb_score_formats() {
        let item: OmdbItem = serde_json::from_str(
            r#"{
                "Ratings": [
                    {"Source": "Internet Movie Database", "Value": "8.3/10"},
                    {"Source": "Rotten Tomatoes", "Value": "96%"}
                ],
                "imdbRating": "8.3",
                "Response": "True"
            }"#,
        )
        .unwrap();
        let (critic, audience) = scores(&item);
        assert_eq!(critic, Some(9.6));
        assert_eq!(audience, Some(8.3));
    }

    #[test]
    fn missing_fields_yield_none() {
        let item: OmdbItem =
            serde_json::from_str(r#"{"imdbRating": "N/A", "Response": "True"}"#).unwrap();
        let (critic, audience) = scores(&item);
        assert_eq!(critic, None);
        assert_eq!(audience, None);
    }
}
