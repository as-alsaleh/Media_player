//! TMDB metadata enrichment (user-supplied API key).

use crate::index::Index;
use std::sync::Arc;

/// Fallback if /configuration is unreachable — the documented CDN today.
const IMG_FALLBACK: &str = "https://image.tmdb.org/t/p";

#[derive(serde::Deserialize)]
struct Configuration {
    images: ImagesConfig,
}

#[derive(serde::Deserialize)]
struct ImagesConfig {
    secure_base_url: String,
}

/// TMDB asks clients to read the image CDN base from /configuration so they
/// can move it. Cached per enrich() run; falls back to the known host.
async fn image_base(client: &reqwest::Client, api_key: &str) -> String {
    let resp = client
        .get("https://api.themoviedb.org/3/configuration")
        .query(&[("api_key", api_key)])
        .send()
        .await;
    if let Ok(resp) = resp {
        if let Ok(cfg) = resp.json::<Configuration>().await {
            return cfg.images.secure_base_url.trim_end_matches('/').to_string();
        }
    }
    IMG_FALLBACK.to_string()
}

#[derive(serde::Deserialize)]
struct SearchResponse {
    results: Vec<SearchResult>,
}

#[derive(serde::Deserialize)]
struct SearchResult {
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    overview: Option<String>,
}

fn poster(img: &str, hit: &SearchResult) -> Option<String> {
    hit.poster_path.as_ref().map(|p| format!("{img}/w342{p}"))
}

fn backdrop(img: &str, hit: &SearchResult) -> Option<String> {
    hit.backdrop_path.as_ref().map(|p| format!("{img}/w1280{p}"))
}

/// Fill poster/backdrop/overview for movies and shows that lack them.
/// `language` is a BCP-47 tag ("en-US", "ar") for localized text/art.
/// Returns the number of items enriched.
pub async fn enrich(index: &Arc<Index>, api_key: &str, language: &str) -> usize {
    let client = reqwest::Client::new();
    let img = image_base(&client, api_key).await;
    let mut enriched = 0;
    let language = if language.is_empty() { "en-US" } else { language };

    if let Ok(movies) = index.movies() {
        for movie in movies.iter().filter(|m| m.poster_url.is_none() || m.backdrop_url.is_none()) {
            let mut req = client
                .get("https://api.themoviedb.org/3/search/movie")
                .query(&[
                    ("api_key", api_key),
                    ("query", &movie.title),
                    ("include_adult", "false"),
                    ("language", language),
                ]);
            if let Some(year) = movie.year {
                req = req.query(&[("year", year.to_string())]);
            }
            let Ok(resp) = req.send().await else { continue };
            let Ok(body) = resp.json::<SearchResponse>().await else { continue };
            let Some(hit) = body.results.first() else { continue };
            index.set_movie_meta(
                movie.id,
                poster(&img, hit).as_deref(),
                hit.overview.as_deref(),
                backdrop(&img, hit).as_deref(),
            );
            enriched += 1;
        }
    }

    if let Ok(shows) = index.shows() {
        for show in shows.iter().filter(|s| s.poster_url.is_none()) {
            // Strip a trailing year ("Archer 2009") for better matching.
            let query = crate::parse::parse_movie(&show.name).title;
            let Ok(resp) = client
                .get("https://api.themoviedb.org/3/search/tv")
                .query(&[("api_key", api_key), ("query", &query), ("language", language)])
                .send()
                .await
            else {
                continue;
            };
            let Ok(body) = resp.json::<SearchResponse>().await else { continue };
            let Some(hit) = body.results.first() else { continue };
            index.set_show_meta(
                &show.name,
                poster(&img, hit).as_deref(),
                backdrop(&img, hit).as_deref(),
                hit.overview.as_deref(),
            );
            enriched += 1;
        }
    }

    enriched
}
