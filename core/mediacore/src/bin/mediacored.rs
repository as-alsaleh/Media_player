//! mediacored — dev CLI for the mediacore streamer.
//!
//! Connects to an SMB share and serves it over localhost HTTP for mpv:
//!   mediacored --server 192.168.100.100 --share media --user abdulrahman --password-file pw.txt

use clap::Parser;
use mediacore::{smb::SmbFs, Streamer};

#[derive(Parser)]
struct Args {
    #[arg(long)]
    server: Option<String>,
    #[arg(long)]
    share: Option<String>,
    #[arg(long)]
    user: Option<String>,
    /// File containing the SMB password (avoids exposing it in `ps`).
    /// Alternatively set MEDIACORED_PASSWORD in the environment.
    #[arg(long)]
    password_file: Option<std::path::PathBuf>,
    /// 0 picks an ephemeral port; the bound address is printed on stdout.
    #[arg(long, default_value_t = 8291)]
    port: u16,
    /// SQLite library index path; omit to disable the library endpoints.
    #[arg(long)]
    db: Option<std::path::PathBuf>,
    /// Plex server base URL (e.g. http://192.168.100.100:32400).
    /// Token via MEDIACORED_PLEX_TOKEN.
    #[arg(long)]
    plex_url: Option<String>,
    /// Jellyfin base URL — trickplay (seek preview) provider.
    /// API key via MEDIACORED_JELLYFIN_KEY.
    #[arg(long)]
    jellyfin_url: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    let args = Args::parse();
    let fs = match (&args.server, &args.share, &args.user) {
        (Some(server), Some(share), Some(user)) => {
            let password = match &args.password_file {
                Some(p) => std::fs::read_to_string(p)?,
                None => std::env::var("MEDIACORED_PASSWORD")
                    .map_err(|_| "no --password-file and MEDIACORED_PASSWORD not set")?,
            };
            Some(SmbFs::connect(server, share, user, password.trim()).await?)
        }
        _ => None,
    };
    let mut streamer = Streamer::new(fs);
    if let Some(db) = &args.db {
        streamer = streamer.with_index(mediacore::index::Index::open(db)?);
    }
    streamer = streamer.with_tmdb_key(std::env::var("MEDIACORED_TMDB_KEY").ok());
    if let (Some(url), Ok(token)) = (&args.plex_url, std::env::var("MEDIACORED_PLEX_TOKEN")) {
        let admin = std::env::var("MEDIACORED_PLEX_ADMIN_TOKEN").ok();
        streamer = streamer.with_plex(Some(
            mediacore::plex::PlexSource::new(url.clone(), token)
                .with_media_token(admin.clone()),
        ));
        if let Some(admin) = admin {
            let token_env = std::env::var("MEDIACORED_PLEX_TOKEN").unwrap_or_default();
            streamer = streamer.with_restricted(admin != token_env);
            streamer = streamer
                .with_plex_admin(Some(mediacore::plex::PlexSource::new(url.clone(), admin)));
        }
    }
    if let (Some(url), Ok(key)) = (&args.jellyfin_url, std::env::var("MEDIACORED_JELLYFIN_KEY")) {
        streamer = streamer.with_jellyfin(Some(
            mediacore::jellyfin::JellyfinSource::new(url.clone(), key).with_user(
                std::env::var("MEDIACORED_JELLYFIN_USER_TOKEN").ok(),
                std::env::var("MEDIACORED_JELLYFIN_USER_ID").ok(),
            ),
        ));
    }
    let addr = streamer.serve(args.port).await?;
    // Machine-readable ready line — the app parses this to find the port.
    println!("LISTEN http://{addr}");
    let _ = &args; // server/share/user consumed above
    use std::io::Write;
    std::io::stdout().flush()?;
    tokio::signal::ctrl_c().await?;
    Ok(())
}
