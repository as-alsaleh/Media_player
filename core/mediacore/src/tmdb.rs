//! TMDB metadata enrichment (user-supplied API key).

use crate::index::Index;
use std::sync::Arc;

const IMG: &str = "https://image.tmdb.org/t/p";

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

fn poster(hit: &SearchResult) -> Option<String> {
    hit.poster_path.as_ref().map(|p| format!("{IMG}/w342{p}"))
}

fn backdrop(hit: &SearchResult) -> Option<String> {
    hit.backdrop_path.as_ref().map(|p| format!("{IMG}/w1280{p}"))
}

/// Fill poster/backdrop/overview for movies and shows that lack them.
/// Returns the number of items enriched.
pub async fn enrich(index: &Arc<Index>, api_key: &str) -> usize {
    let client = reqwest::Client::new();
    let mut enriched = 0;

    if let Ok(movies) = index.movies() {
        for movie in movies.iter().filter(|m| m.poster_url.is_none() || m.backdrop_url.is_none()) {
            let mut req = client
                .get("https://api.themoviedb.org/3/search/movie")
                .query(&[
                    ("api_key", api_key),
                    ("query", &movie.title),
                    ("include_adult", "false"),
                ]);
            if let Some(year) = movie.year {
                req = req.query(&[("year", year.to_string())]);
            }
            let Ok(resp) = req.send().await else { continue };
            let Ok(body) = resp.json::<SearchResponse>().await else { continue };
            let Some(hit) = body.results.first() else { continue };
            index.set_movie_meta(
                movie.id,
                poster(hit).as_deref(),
                hit.overview.as_deref(),
                backdrop(hit).as_deref(),
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
                .query(&[("api_key", api_key), ("query", &query)])
                .send()
                .await
            else {
                continue;
            };
            let Ok(body) = resp.json::<SearchResponse>().await else { continue };
            let Some(hit) = body.results.first() else { continue };
            index.set_show_meta(
                &show.name,
                poster(hit).as_deref(),
                backdrop(hit).as_deref(),
                hit.overview.as_deref(),
            );
            enriched += 1;
        }
    }

    enriched
}
