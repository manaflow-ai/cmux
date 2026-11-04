//! Complete tool-result image originals. Each chat owns its files under its uploads directory;
//! unlike temporary prompt uploads these survive until the chat is purged. Content addressing
//! gives a replay the same path. No decoded image or second full base64 buffer is allocated.

use anyhow::{Context as _, Result};
use base64::Engine as _;
use sha2::{Digest as _, Sha256};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt as _;

// A decode/write chunk, aligned to a base64 quartet. This bounds working memory, not the source.
const ENCODED_CHUNK: usize = 64 << 10;

pub(crate) fn root(session: &str) -> Option<PathBuf> {
    Some(super::file_uploads::session_dir(session)?.join("tool-results"))
}

/// Only names the result writer makes, below this exact session's root. The reader still
/// verifies the descriptor, private places, file type and identity before every range.
pub(crate) fn is_original(root: &Path, path: &Path) -> bool {
    let Ok(rest) = path.strip_prefix(root) else { return false };
    let Some(name) = rest.to_str().filter(|_| rest.components().count() == 1) else { return false };
    let Some((hash, ext)) = name.split_once('.') else { return false };
    hash.len() == 64
        && hash.bytes().all(|b| b.is_ascii_hexdigit())
        && matches!(ext, "png" | "jpg" | "gif" | "webp" | "bin")
}

struct Target {
    root: PathBuf,
    temporary: PathBuf,
    file: Option<std::fs::File>,
}

impl Target {
    fn open(root: PathBuf) -> Result<Self> {
        crate::config::private_state_dir(&root)?;
        let temporary = root.join(format!(".image-{}", uuid::Uuid::now_v7()));
        let file = crate::config::private_state_rw(&temporary)?;
        Ok(Self { root, temporary, file: Some(file) })
    }

    fn finish(mut self, hash: Sha256, mime: &str) -> Result<PathBuf> {
        self.file.take();
        let path = self.root.join(file_name(hash, mime));
        // Publish without replacing an equal original: replaying it must not invalidate a
        // reader's existing descriptor/identity. A link appears only after every byte is synced.
        match std::fs::hard_link(&self.temporary, &path) {
            Ok(()) => std::fs::remove_file(&self.temporary)?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                anyhow::ensure!(
                    std::fs::symlink_metadata(&path)?.is_file(),
                    "original image path is not a regular file"
                );
            }
            Err(error) => return Err(error.into()),
        }
        Ok(path)
    }
}

fn file_name(hash: Sha256, mime: &str) -> String {
    let extension = match mime {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        _ => "bin",
    };
    format!("{:x}.{extension}", hash.finalize())
}

impl Drop for Target {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.temporary);
    }
}

fn chunks(data: &str) -> impl Iterator<Item = Result<Vec<u8>>> + '_ {
    data.as_bytes().chunks(ENCODED_CHUNK).map(|encoded| {
        base64::engine::general_purpose::STANDARD.decode(encoded).context("invalid image base64")
    })
}

/// Synchronous callers (transcript adoption and code-mode MCP) run on a blocking worker.
pub fn save(session: &str, data: &str, mime: &str) -> Result<PathBuf> {
    let mut target = Target::open(root(session).context("invalid image session")?)?;
    let file = target.file.as_mut().context("image file is closed")?;
    let mut hash = Sha256::new();
    for bytes in chunks(data) {
        let bytes = bytes?;
        hash.update(&bytes);
        file.write_all(&bytes)?;
    }
    file.sync_all()?;
    target.finish(hash, mime)
}

/// Live translation yields between each bounded write. The provider's already-parsed base64
/// is borrowed throughout; tokio's file adapter sends writes to blocking workers.
pub(crate) async fn save_async(session: &str, data: &str, mime: &str) -> Result<PathBuf> {
    let root = root(session).context("invalid image session")?;
    let mut target = tokio::task::spawn_blocking(move || Target::open(root)).await??;
    let mut file = tokio::fs::File::from_std(target.file.take().context("image file is closed")?);
    let mut hash = Sha256::new();
    for bytes in chunks(data) {
        let bytes = bytes?;
        hash.update(&bytes);
        file.write_all(&bytes).await?;
    }
    file.sync_all().await?;
    drop(file);
    let mime = mime.to_owned();
    tokio::task::spawn_blocking(move || target.finish(hash, &mime)).await?
}

#[cfg(test)]
#[path = "result_image_files_tests.rs"]
mod tests;
