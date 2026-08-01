//! TMDB metadata enrichment (user-supplied API key).

use crate::index::Index;
use std::sync::Arc;

#[derive(serde::Deserialize)]
struct SearchResponse {
    results: Vec<SearchResult>,
}

#[derive(serde::Deserialize)]
struct SearchResult {
    poster_path: Option<String>,
    overview: Option<String>,
}

/// Fill poster/overview for movies that don't have them yet.
/// Returns the number of movies enriched.
pub async fn enrich_movies(index: &Arc<Index>, api_key: &str) -> usize {
    let movies = match index.movies() {
        Ok(m) => m,
        Err(_) => return 0,
    };
    let client = reqwest::Client::new();
    let mut enriched = 0;

    for movie in movies.iter().filter(|m| m.poster_url.is_none()) {
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

        let poster = hit
            .poster_path
            .as_ref()
            .map(|p| format!("https://image.tmdb.org/t/p/w342{p}"));
        index.set_movie_meta(movie.id, poster.as_deref(), hit.overview.as_deref());
        if poster.is_some() {
            enriched += 1;
        }
    }
    enriched
}
