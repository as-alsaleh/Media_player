//! mediacored — dev CLI for the mediacore streamer.
//!
//! Connects to an SMB share and serves it over localhost HTTP for mpv:
//!   mediacored --server 192.168.100.100 --share media --user abdulrahman --password-file pw.txt

use clap::Parser;
use mediacore::{smb::SmbFs, Streamer};

#[derive(Parser)]
struct Args {
    #[arg(long)]
    server: String,
    #[arg(long)]
    share: String,
    #[arg(long)]
    user: String,
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
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    let args = Args::parse();
    let password = match &args.password_file {
        Some(p) => std::fs::read_to_string(p)?,
        None => std::env::var("MEDIACORED_PASSWORD")
            .map_err(|_| "no --password-file and MEDIACORED_PASSWORD not set")?,
    };
    let fs = SmbFs::connect(&args.server, &args.share, &args.user, password.trim()).await?;
    let mut streamer = Streamer::new(fs);
    if let Some(db) = &args.db {
        streamer = streamer.with_index(mediacore::index::Index::open(db)?);
    }
    let addr = streamer.serve(args.port).await?;
    // Machine-readable ready line — the app parses this to find the port.
    println!("LISTEN http://{addr}");
    use std::io::Write;
    std::io::stdout().flush()?;
    tokio::signal::ctrl_c().await?;
    Ok(())
}
