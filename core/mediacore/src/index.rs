//! Library index: scans the share and stores parsed media in SQLite.

use crate::parse::{parse_episode, parse_movie};
use crate::smb::SmbFs;
use rusqlite::Connection;
use std::path::Path;
use std::sync::{Arc, Mutex};

const VIDEO_EXT: &[&str] = &[
    "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "flv",
];

#[derive(Debug, Clone, serde::Serialize)]
pub struct MovieRow {
    pub id: i64,
    pub title: String,
    pub year: Option<u16>,
    pub path: String,
    pub size: u64,
    pub poster_url: Option<String>,
    pub overview: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct EpisodeRow {
    pub id: i64,
    pub show: String,
    pub season: u16,
    pub episode: u16,
    pub path: String,
    pub size: u64,
}

pub struct Index {
    conn: Mutex<Connection>,
}

impl Index {
    pub fn open(db_path: &Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS movies (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                year INTEGER,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                poster_url TEXT,
                overview TEXT
            );
            CREATE TABLE IF NOT EXISTS episodes (
                id INTEGER PRIMARY KEY,
                show TEXT NOT NULL,
                season INTEGER NOT NULL,
                episode INTEGER NOT NULL,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL
            );
            "#,
        )?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Recursively scan `movies_root` and `tv_root` on the share.
    /// Returns (movies found, episodes found).
    pub async fn scan(
        &self,
        fs: &Arc<SmbFs>,
        movies_root: &str,
        tv_root: &str,
    ) -> Result<(usize, usize), crate::smb::SmbError> {
        let mut movies = 0usize;
        let mut episodes = 0usize;

        for file in walk(fs, movies_root, 2).await? {
            let stem = stem(&file.0);
            let parsed = parse_movie(stem);
            let conn = self.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO movies (title, year, path, size) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(path) DO UPDATE SET size = excluded.size",
                rusqlite::params![parsed.title, parsed.year, file.0, file.1 as i64],
            )
            .ok();
            movies += 1;
        }

        for file in walk(fs, tv_root, 3).await? {
            let stem = stem(&file.0);
            if let Some(ep) = parse_episode(stem) {
                let conn = self.conn.lock().unwrap();
                conn.execute(
                    "INSERT INTO episodes (show, season, episode, path, size)
                     VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(path) DO UPDATE SET size = excluded.size",
                    rusqlite::params![ep.show, ep.season, ep.episode, file.0, file.1 as i64],
                )
                .ok();
                episodes += 1;
            }
        }
        Ok((movies, episodes))
    }

    pub fn movies(&self) -> rusqlite::Result<Vec<MovieRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, title, year, path, size, poster_url, overview
             FROM movies ORDER BY title COLLATE NOCASE",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(MovieRow {
                    id: r.get(0)?,
                    title: r.get(1)?,
                    year: r.get(2)?,
                    path: r.get(3)?,
                    size: r.get::<_, i64>(4)? as u64,
                    poster_url: r.get(5)?,
                    overview: r.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn episodes(&self) -> rusqlite::Result<Vec<EpisodeRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, show, season, episode, path, size
             FROM episodes ORDER BY show COLLATE NOCASE, season, episode",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(EpisodeRow {
                    id: r.get(0)?,
                    show: r.get(1)?,
                    season: r.get(2)?,
                    episode: r.get(3)?,
                    path: r.get(4)?,
                    size: r.get::<_, i64>(5)? as u64,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn set_movie_meta(&self, id: i64, poster_url: Option<&str>, overview: Option<&str>) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE movies SET poster_url = ?2, overview = ?3 WHERE id = ?1",
            rusqlite::params![id, poster_url, overview],
        )
        .ok();
    }
}

fn stem(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name)
}

fn is_video(name: &str) -> bool {
    name.rsplit_once('.')
        .map(|(_, ext)| VIDEO_EXT.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// Breadth-first walk up to `depth` levels, returning (path, size) of video files.
async fn walk(
    fs: &Arc<SmbFs>,
    root: &str,
    depth: u32,
) -> Result<Vec<(String, u64)>, crate::smb::SmbError> {
    let mut files = Vec::new();
    let mut dirs = vec![(root.to_string(), 0u32)];
    while let Some((dir, level)) = dirs.pop() {
        let entries = match fs.list_dir(&dir).await {
            Ok(e) => e,
            Err(_) => continue, // unreadable subdir — skip, keep scanning
        };
        for e in entries {
            let child = if dir.is_empty() { e.name.clone() } else { format!("{dir}/{}", e.name) };
            if e.is_dir {
                if level < depth {
                    dirs.push((child, level + 1));
                }
            } else if is_video(&e.name) {
                files.push((child, e.size));
            }
        }
    }
    Ok(files)
}
