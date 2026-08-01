//! Media filename parsing heuristics.

use regex::Regex;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ParsedMovie {
    pub title: String,
    pub year: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ParsedEpisode {
    pub show: String,
    pub season: u16,
    pub episode: u16,
}

static YEAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?<title>.+?)[ .(\[]+(?<year>(19|20)\d{2})\b").unwrap());
static SXXEYY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?<show>.*?)[ .\-]*S(?<s>\d{1,2})[ .]?E(?<e>\d{1,3})\b").unwrap()
});
/// Alternative `1x02` episode style.
static NXM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?<show>.*?)[ .\-]+(?<s>\d{1,2})x(?<e>\d{2,3})\b").unwrap()
});

fn clean(raw: &str) -> String {
    let mut s = raw.replace(['.', '_'], " ");
    s = s.trim().trim_end_matches('-').trim().to_string();
    // Collapse whitespace.
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Parse a movie name from a folder or file name (extension already stripped).
pub fn parse_movie(name: &str) -> ParsedMovie {
    if let Some(c) = YEAR.captures(name) {
        return ParsedMovie {
            title: clean(&c["title"]),
            year: c["year"].parse().ok(),
        };
    }
    ParsedMovie { title: clean(name), year: None }
}

/// Parse `SxxEyy` / `NxMM` episode naming.
pub fn parse_episode(name: &str) -> Option<ParsedEpisode> {
    let c = SXXEYY.captures(name).or_else(|| NXM.captures(name))?;
    let show = clean(&c["show"]);
    if show.is_empty() {
        return None;
    }
    Some(ParsedEpisode {
        show,
        season: c["s"].parse().ok()?,
        episode: c["e"].parse().ok()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movies() {
        assert_eq!(
            parse_movie("Tuner.2025.HDR.2160p.WEB.h265-ETHEL"),
            ParsedMovie { title: "Tuner".into(), year: Some(2025) }
        );
        assert_eq!(
            parse_movie("Avatar - The Way of Water (2022)"),
            ParsedMovie { title: "Avatar - The Way of Water".into(), year: Some(2022) }
        );
        assert_eq!(
            parse_movie("Bronson"),
            ParsedMovie { title: "Bronson".into(), year: None }
        );
    }

    #[test]
    fn episodes() {
        let e = parse_episode("Archer.2009.S05E03.1080p.BluRay").unwrap();
        assert_eq!((e.show.as_str(), e.season, e.episode), ("Archer 2009", 5, 3));
        let e = parse_episode("BEEF - 1x05 - Such Inward Secret Creatures").unwrap();
        assert_eq!((e.show.as_str(), e.season, e.episode), ("BEEF", 1, 5));
        assert!(parse_episode("Some Movie (2020)").is_none());
    }
}
