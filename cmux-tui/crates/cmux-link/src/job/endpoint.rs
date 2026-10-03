//! The two ends a copy job reads from and writes to: a local root (the
//! machine the link runs on) and a root on an SFTP host.

use std::path::{Path, PathBuf};

use bytes::Bytes;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use crate::fs::remote::{read_range, write_all};
use crate::fs::{EntryKind, FsError, Rights, SftpRoot, WriteMode, components};
use crate::sftp::Handle;

/// Bytes a source hands to the bulk channel at a time.
pub const SPAN_BYTES: u64 = 512 * 1024;

/// A folder on the link's own machine. Paths are checked the same way as
/// on SFTP roots: no `..`, and no symlink on the way.
#[derive(Clone, Debug)]
pub struct LocalRoot {
    pub base: PathBuf,
    pub rights: Rights,
}

impl LocalRoot {
    fn walk(&self, relative: &str) -> Result<(PathBuf, Option<std::fs::Metadata>), FsError> {
        let parts = components(relative)?;
        let mut path = self.base.clone();
        let mut metadata = Some(std::fs::symlink_metadata(&path).map_err(io_error)?);
        for part in parts {
            match &metadata {
                Some(found) if found.file_type().is_symlink() => {
                    return Err(FsError::NotInsideRoot);
                }
                Some(found) if !found.is_dir() => return Err(FsError::NotADirectory),
                None => return Err(FsError::NotFound),
                Some(_) => {}
            }
            path.push(part);
            metadata = match std::fs::symlink_metadata(&path) {
                Ok(found) => Some(found),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(io_error(error)),
            };
        }
        if metadata.as_ref().is_some_and(|found| found.file_type().is_symlink()) {
            return Err(FsError::NotInsideRoot);
        }
        Ok((path, metadata))
    }
}

/// One end of a copy.
#[derive(Clone)]
pub enum Endpoint {
    Local(LocalRoot),
    Sftp(SftpRoot),
}

/// A source item found while preparing a job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// Path relative to the source root.
    pub source: String,
    /// Path relative to the destination folder.
    pub destination: String,
    pub kind: EntryKind,
    pub size: u64,
}

impl Endpoint {
    /// Kind and size of `relative`, or `None` when absent. A symlink counts
    /// as `Symlink` and is never followed.
    pub async fn kind_of(&self, relative: &str) -> Result<Option<(EntryKind, u64)>, FsError> {
        match self {
            Self::Sftp(root) => root.kind_of(relative).await,
            Self::Local(root) => match root.walk(relative) {
                Ok((_, None)) | Err(FsError::NotFound) => Ok(None),
                Ok((_, Some(metadata))) => {
                    let kind = if metadata.is_dir() {
                        EntryKind::Dir
                    } else if metadata.is_file() {
                        EntryKind::File
                    } else {
                        EntryKind::Other
                    };
                    Ok(Some((kind, metadata.len())))
                }
                Err(error) => Err(error),
            },
        }
    }

    /// The names and kinds in a directory.
    pub async fn children(&self, relative: &str) -> Result<Vec<(String, EntryKind, u64)>, FsError> {
        match self {
            Self::Sftp(root) => Ok(root
                .read_directory(relative)
                .await?
                .0
                .into_iter()
                .map(|entry| (entry.name, entry.kind, entry.size.unwrap_or(0)))
                .collect()),
            Self::Local(root) => {
                let (path, _) = root.walk(relative)?;
                let mut children = Vec::new();
                for entry in std::fs::read_dir(path).map_err(io_error)? {
                    let entry = entry.map_err(io_error)?;
                    let Ok(name) = entry.file_name().into_string() else { continue };
                    let metadata = entry.metadata().map_err(io_error)?;
                    let kind = if metadata.file_type().is_symlink() {
                        EntryKind::Symlink
                    } else if metadata.is_dir() {
                        EntryKind::Dir
                    } else if metadata.is_file() {
                        EntryKind::File
                    } else {
                        EntryKind::Other
                    };
                    children.push((name, kind, metadata.len()));
                }
                Ok(children)
            }
        }
    }

    pub async fn ensure_directory(&self, relative: &str) -> Result<(), FsError> {
        match self {
            Self::Sftp(root) => root.ensure_directory(relative).await,
            Self::Local(root) => {
                if root.rights != Rights::ReadWrite {
                    return Err(FsError::ReadOnly);
                }
                match root.walk(relative)? {
                    (_, Some(metadata)) if metadata.is_dir() => Ok(()),
                    (_, Some(_)) => Err(FsError::Exists),
                    (path, None) => std::fs::create_dir(path).map_err(io_error),
                }
            }
        }
    }

    pub async fn open_source(&self, relative: &str) -> Result<Source, FsError> {
        match self {
            Self::Sftp(root) => {
                let (handle, size) = root.open_read(relative).await?;
                Ok(Source::Sftp { root: root.clone(), handle, offset: 0, size })
            }
            Self::Local(root) => {
                let (path, metadata) = root.walk(relative)?;
                if !metadata.is_some_and(|metadata| metadata.is_file()) {
                    return Err(FsError::NotFound);
                }
                Ok(Source::Local(tokio::fs::File::open(path).await.map_err(io_error)?))
            }
        }
    }

    pub async fn create_sink(&self, relative: &str) -> Result<Sink, FsError> {
        match self {
            Self::Sftp(root) => {
                let (handle, temporary, target) = root.create_temporary(relative).await?;
                Ok(Sink::Sftp { root: root.clone(), handle, temporary, target, offset: 0 })
            }
            Self::Local(root) => {
                if root.rights != Rights::ReadWrite {
                    return Err(FsError::ReadOnly);
                }
                let parts = components(relative)?;
                let (name, parent) = parts.split_last().ok_or(FsError::NameInvalid)?;
                let (parent_path, metadata) = root.walk(&parent.join("/"))?;
                if !metadata.is_some_and(|metadata| metadata.is_dir()) {
                    return Err(FsError::NotADirectory);
                }
                let temporary =
                    parent_path.join(format!(".{name}.cmux-{}.tmp", crate::ids::random_id("")));
                let file = tokio::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&temporary)
                    .await
                    .map_err(io_error)?;
                Ok(Sink::Local { file, temporary, target: parent_path.join(name) })
            }
        }
    }

    /// Removes `relative` and everything below it.
    pub async fn remove_tree(&self, relative: &str) -> Result<(), FsError> {
        match self {
            Self::Sftp(root) => super::remove_tree(root, relative).await,
            Self::Local(root) => {
                if root.rights != Rights::ReadWrite {
                    return Err(FsError::ReadOnly);
                }
                if components(relative)?.is_empty() {
                    return Err(FsError::NotInsideRoot);
                }
                match root.walk(relative)? {
                    (path, Some(metadata)) if metadata.is_dir() => {
                        std::fs::remove_dir_all(path).map_err(io_error)
                    }
                    (path, Some(_)) => std::fs::remove_file(path).map_err(io_error),
                    (_, None) => Err(FsError::NotFound),
                }
            }
        }
    }
}

/// Reads a file in spans.
pub enum Source {
    Local(tokio::fs::File),
    Sftp { root: SftpRoot, handle: Handle, offset: u64, size: u64 },
}

impl Source {
    /// The next span, or `None` at the end.
    pub async fn next_span(&mut self) -> Result<Option<Bytes>, FsError> {
        match self {
            Self::Local(file) => {
                let mut buffer = vec![0_u8; usize::try_from(SPAN_BYTES).unwrap_or(512 * 1024)];
                let read = file.read(&mut buffer).await.map_err(io_error)?;
                buffer.truncate(read);
                Ok((read > 0).then(|| Bytes::from(buffer)))
            }
            Self::Sftp { root, handle, offset, size } => {
                if *offset >= *size {
                    return Ok(None);
                }
                let span =
                    read_range(root.client(), handle, *offset, SPAN_BYTES.min(*size - *offset))
                        .await?;
                if span.is_empty() {
                    return Ok(None);
                }
                *offset += span.len() as u64;
                Ok(Some(Bytes::from(span)))
            }
        }
    }

    pub async fn close(self) {
        if let Self::Sftp { root, handle, .. } = self {
            let _ = root.client().close(&handle).await;
        }
    }
}

/// Writes a temporary file and commits it by rename.
pub enum Sink {
    Local { file: tokio::fs::File, temporary: PathBuf, target: PathBuf },
    Sftp { root: SftpRoot, handle: Handle, temporary: String, target: String, offset: u64 },
}

impl Sink {
    pub async fn write(&mut self, chunk: Bytes) -> Result<(), FsError> {
        match self {
            Self::Local { file, .. } => file.write_all(&chunk).await.map_err(io_error),
            Self::Sftp { root, handle, offset, .. } => {
                let length = chunk.len() as u64;
                write_all(root.client(), handle, *offset, chunk).await?;
                *offset += length;
                Ok(())
            }
        }
    }

    /// Syncs and renames the temporary file over the target.
    pub async fn commit(self, mode: WriteMode) -> Result<(), FsError> {
        match self {
            Self::Local { file, temporary, target } => {
                let result = async {
                    file.sync_all().await.map_err(io_error)?;
                    drop(file);
                    if matches!(mode, WriteMode::Create) && Path::new(&target).exists() {
                        return Err(FsError::Exists);
                    }
                    std::fs::rename(&temporary, &target).map_err(io_error)
                }
                .await;
                if result.is_err() {
                    let _ = std::fs::remove_file(&temporary);
                }
                result
            }
            Self::Sftp { root, handle, temporary, target, .. } => {
                let synced = root.client().fsync(&handle).await;
                let closed = root.client().close(&handle).await;
                let result = match synced.and(closed) {
                    Ok(()) => root.commit(&temporary, &target, mode).await,
                    Err(error) => Err(error.into()),
                };
                if result.is_err() {
                    let _ = root.client().remove(&temporary).await;
                }
                result
            }
        }
    }

    /// Drops the temporary file.
    pub async fn abort(self) {
        match self {
            Self::Local { file, temporary, .. } => {
                drop(file);
                let _ = std::fs::remove_file(temporary);
            }
            Self::Sftp { root, handle, temporary, .. } => {
                let _ = root.client().close(&handle).await;
                let _ = root.client().remove(&temporary).await;
            }
        }
    }
}

pub(crate) fn io_error(error: std::io::Error) -> FsError {
    match error.kind() {
        std::io::ErrorKind::NotFound => FsError::NotFound,
        std::io::ErrorKind::PermissionDenied => FsError::PermissionDenied,
        std::io::ErrorKind::AlreadyExists => FsError::Exists,
        _ => FsError::Failure { message: error.to_string() },
    }
}
