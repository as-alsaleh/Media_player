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
    #[arg(long)]
    password_file: std::path::PathBuf,
    #[arg(long, default_value_t = 8291)]
    port: u16,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    let args = Args::parse();
    let password = std::fs::read_to_string(&args.password_file)?;
    let fs = SmbFs::connect(&args.server, &args.share, &args.user, password.trim()).await?;
    let addr = Streamer::new(fs).serve(args.port).await?;
    println!("serving //{}/{} on http://{addr}", args.server, args.share);
    println!("  list:   http://{addr}/list?path=movies");
    println!("  stream: http://{addr}/stream/movies/<file>");
    tokio::signal::ctrl_c().await?;
    Ok(())
}
