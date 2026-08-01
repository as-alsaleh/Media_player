//! SMB2/3 backend built on the pure-Rust `smb` crate (smb-rs).

use smb::{
    Client, ClientConfig, FileAccessMask, FileCreateArgs, FileDirectoryInformation, UncPath,
};
use std::str::FromStr;
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
pub enum SmbError {
    #[error("smb: {0}")]
    Smb(#[from] smb::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid path")]
    InvalidPath,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// A connected share. Path arguments are share-relative, `/`-separated.
pub struct SmbFs {
    client: Client,
    root: UncPath,
}

impl SmbFs {
    pub async fn connect(
        server: &str,
        share: &str,
        username: &str,
        password: &str,
    ) -> Result<Self, SmbError> {
        let root = UncPath::from_str(&format!(r"\\{server}\{share}"))
            .map_err(|_| SmbError::InvalidPath)?;
        let client = Client::new(ClientConfig::default());
        client
            .share_connect(&root, username, password.to_string())
            .await?;
        Ok(Self { client, root })
    }

    fn unc(&self, path: &str) -> UncPath {
        let win = path.trim_matches('/').replace('/', "\\");
        self.root.clone().with_path(&win)
    }

    pub async fn list_dir(&self, path: &str) -> Result<Vec<DirEntry>, SmbError> {
        use futures_util::StreamExt;

        let access: FileAccessMask = smb::DirAccessMask::new()
            .with_list_directory(true)
            .with_read_attributes(true)
            .into();
        let args = FileCreateArgs::make_open_existing(access);
        let dir = Arc::new(
            self.client
                .create_file(&self.unc(path), &args)
                .await?
                .unwrap_dir(),
        );
        let mut stream = smb::Directory::query::<FileDirectoryInformation>(&dir, "*").await?;
        let mut entries = Vec::new();
        while let Some(item) = stream.next().await {
            let info = item?;
            let name = info.file_name.to_string();
            if name == "." || name == ".." {
                continue;
            }
            entries.push(DirEntry {
                is_dir: info.file_attributes.directory(),
                size: info.end_of_file,
                name,
            });
        }
        entries.sort_by(|a, b| (b.is_dir, &a.name).cmp(&(a.is_dir, &b.name)));
        Ok(entries)
    }

    pub async fn open(&self, path: &str) -> Result<SmbFile, SmbError> {
        let args = FileCreateArgs::make_open_existing(
            FileAccessMask::new().with_generic_read(true),
        );
        let file = self
            .client
            .create_file(&self.unc(path), &args)
            .await?
            .unwrap_file();
        use smb::GetLen;
        let size = file.get_len().await?;
        Ok(SmbFile { file, size })
    }
}

/// Random-access handle to a remote file.
pub struct SmbFile {
    file: smb::File,
    size: u64,
}

impl SmbFile {
    pub fn size(&self) -> u64 {
        self.size
    }

    pub async fn read_at(&self, buf: &mut [u8], pos: u64) -> Result<usize, SmbError> {
        Ok(self.file.read_block(buf, pos, None, false).await?)
    }
}
