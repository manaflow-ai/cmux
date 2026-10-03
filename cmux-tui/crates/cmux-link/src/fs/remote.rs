//! File operations under one root of an SFTP host.
//!
//! Containment: every relative path is split into checked components and
//! walked with `lstat`; a symlink anywhere on the way is refused, so an op
//! never follows a link out of the root. SFTP has no `openat`, so a
//! concurrent change on the host between the walk and the op is not
//! excluded (the same window as any SFTP client).

use base64::Engine as _;
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tokio::task::JoinSet;

use super::{Entry, EntryKind, FsError, check_name, components, mode_display};
use crate::sftp::proto::{SSH_FXF_CREAT, SSH_FXF_EXCL, SSH_FXF_READ, SSH_FXF_TRUNC, SSH_FXF_WRITE};
use crate::sftp::{Attrs, FileType, Handle, SftpClient, SftpError, StatusCode};

/// Bytes per SFTP read or write request.
pub const CHUNK_BYTES: u32 = 32 * 1024;
/// Requests kept in flight for one transfer.
const IN_FLIGHT: usize = 16;
/// Largest `fs.read` (finder.md 4.4).
pub const MAX_READ_BYTES: u64 = 1024 * 1024;
/// At most this many symlinks per listing get their target resolved.
const MAX_RESOLVED_SYMLINKS: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Rights {
    Read,
    ReadWrite,
}

/// A file's revision: size and modification time. SFTP has no change
/// counter, so these two stand in for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Revision {
    pub size: u64,
    pub mtime: u32,
}

impl Revision {
    fn of(attrs: &Attrs) -> Option<Self> {
        Some(Self { size: attrs.size?, mtime: attrs.mtime()? })
    }

    #[must_use]
    pub fn token(&self) -> String {
        format!("s{}-m{}", self.size, self.mtime)
    }
}

/// How a write treats an existing file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum WriteMode {
    /// Fail with `fs.exists` when the file exists.
    Create,
    /// Replace only when the file still has this revision.
    Replace { expected: Revision },
    /// Replace whatever is there.
    Overwrite,
}

/// `fs.read` result (finder.md 4.4).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadResult {
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes_base64: Option<String>,
    pub truncated: bool,
    pub size: u64,
    pub encoding: &'static str,
}

/// `fs.stat` result: an entry plus display strings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatResult {
    #[serde(flatten)]
    pub entry: Entry,
    pub mode_display: String,
    pub owner_display: String,
    pub revision: Option<String>,
}

/// One root on one SFTP host.
#[derive(Clone)]
pub struct SftpRoot {
    client: SftpClient,
    base: String,
    rights: Rights,
}

impl SftpRoot {
    /// Opens the root at `base` (absolute, or relative to the login
    /// directory). The base must be a directory and is canonicalized once.
    pub async fn open(client: SftpClient, base: &str, rights: Rights) -> Result<Self, FsError> {
        let base = client.realpath(base).await?;
        let attrs = client.lstat(&base).await?;
        if attrs.file_type() != FileType::Dir {
            return Err(FsError::NotADirectory);
        }
        Ok(Self { client, base, rights })
    }

    #[must_use]
    pub fn client(&self) -> &SftpClient {
        &self.client
    }

    fn join(&self, parts: &[&str]) -> String {
        let mut path = self.base.trim_end_matches('/').to_owned();
        for part in parts {
            path.push('/');
            path.push_str(part);
        }
        if path.is_empty() { "/".to_owned() } else { path }
    }

    fn writable(&self) -> Result<(), FsError> {
        match self.rights {
            Rights::ReadWrite => Ok(()),
            Rights::Read => Err(FsError::ReadOnly),
        }
    }

    /// Walks `relative` and returns the absolute path and the `lstat` of
    /// its last component. Every directory on the way must be a real
    /// directory; `final_may_be_link` allows a symlink at the end only.
    async fn walk(
        &self,
        relative: &str,
        final_may_be_link: bool,
    ) -> Result<(String, Attrs), FsError> {
        let parts = components(relative)?;
        let mut attrs = self.client.lstat(&self.base).await?;
        for depth in 1..=parts.len() {
            if attrs.file_type() != FileType::Dir {
                return Err(if attrs.file_type() == FileType::Symlink {
                    FsError::NotInsideRoot
                } else {
                    FsError::NotADirectory
                });
            }
            attrs = self.client.lstat(&self.join(&parts[..depth])).await?;
        }
        if attrs.file_type() == FileType::Symlink && !final_may_be_link {
            return Err(FsError::NotInsideRoot);
        }
        Ok((self.join(&parts), attrs))
    }

    /// Splits `relative` into its parent (walked) and its checked name.
    async fn parent_and_name<'a>(&self, relative: &'a str) -> Result<(String, &'a str), FsError> {
        let parts = components(relative)?;
        let (name, parent) = parts.split_last().ok_or(FsError::NameInvalid)?;
        let (parent_path, attrs) = self.walk(&parent.join("/"), false).await?;
        if attrs.file_type() != FileType::Dir {
            return Err(FsError::NotADirectory);
        }
        Ok((parent_path, name))
    }

    async fn entry_at(&self, path: &str, name: &str) -> Result<Entry, FsError> {
        let attrs = self.client.lstat(path).await?;
        let mut entry = Entry::from_attrs(name, &attrs);
        if entry.kind == EntryKind::Symlink {
            entry.target_kind = self.link_target_kind(path).await;
        }
        Ok(entry)
    }

    /// The kind of a symlink's target if it resolves inside the root.
    async fn link_target_kind(&self, path: &str) -> Option<EntryKind> {
        let target = self.client.realpath(path).await.ok()?;
        let base = self.base.trim_end_matches('/');
        if target != base && !target.starts_with(&format!("{base}/")) {
            return None;
        }
        let attrs = self.client.stat(&target).await.ok()?;
        Some(attrs.file_type().into())
    }

    /// Reads a directory once: its entries (unsorted) and its revision.
    pub async fn read_directory(&self, relative: &str) -> Result<(Vec<Entry>, String), FsError> {
        let (path, attrs) = self.walk(relative, false).await?;
        if attrs.file_type() != FileType::Dir {
            return Err(FsError::NotADirectory);
        }
        let mut entries = Vec::new();
        let mut links = Vec::new();
        for raw in self.client.read_dir(&path).await? {
            // Names that are not UTF-8 cannot be addressed by apps.
            let Ok(name) = std::str::from_utf8(&raw.filename) else { continue };
            if name == "." || name == ".." {
                continue;
            }
            let entry = Entry::from_attrs(name, &raw.attrs);
            if entry.kind == EntryKind::Symlink && links.len() < MAX_RESOLVED_SYMLINKS {
                links.push(entries.len());
            }
            entries.push(entry);
        }
        let mut resolved = JoinSet::new();
        for index in links {
            let root = self.clone();
            let link_path = format!("{}/{}", path.trim_end_matches('/'), entries[index].name);
            resolved.spawn(async move { (index, root.link_target_kind(&link_path).await) });
        }
        while let Some(Ok((index, kind))) = resolved.join_next().await {
            entries[index].target_kind = kind;
        }
        let revision = Revision::of(&attrs).map_or_else(String::new, |revision| revision.token());
        Ok((entries, revision))
    }

    /// `fs.stat`.
    pub async fn stat(&self, relative: &str) -> Result<StatResult, FsError> {
        let (path, attrs) = self.walk(relative, true).await?;
        let name = components(relative)?.last().map_or(".", |name| name).to_owned();
        let mut entry = Entry::from_attrs(&name, &attrs);
        if entry.kind == EntryKind::Symlink {
            entry.target_kind = self.link_target_kind(&path).await;
        }
        Ok(StatResult {
            entry,
            mode_display: attrs.permissions.map(mode_display).unwrap_or_default(),
            owner_display: attrs
                .uid_gid
                .map(|(uid, gid)| format!("{uid}:{gid}"))
                .unwrap_or_default(),
            revision: Revision::of(&attrs).map(|revision| revision.token()),
        })
    }

    /// `fs.read`: at most 1 MiB from `offset`.
    pub async fn read(
        &self,
        relative: &str,
        offset: u64,
        max_bytes: u64,
    ) -> Result<ReadResult, FsError> {
        let (path, attrs) = self.walk(relative, false).await?;
        if attrs.file_type() != FileType::File {
            return Err(FsError::NotAFile);
        }
        let size = attrs.size.unwrap_or(0);
        let wanted = max_bytes.min(MAX_READ_BYTES).min(size.saturating_sub(offset));
        let handle = self.client.open(&path, SSH_FXF_READ, &Attrs::default()).await?;
        let read = read_range(&self.client, &handle, offset, wanted).await;
        let closed = self.client.close(&handle).await;
        let bytes = read?;
        closed?;
        let truncated = offset + (bytes.len() as u64) < size;
        Ok(match String::from_utf8(bytes) {
            Ok(text) => ReadResult {
                text: Some(text),
                bytes_base64: None,
                truncated,
                size,
                encoding: "utf8",
            },
            Err(error) => ReadResult {
                text: None,
                bytes_base64: Some(
                    base64::engine::general_purpose::STANDARD.encode(error.into_bytes()),
                ),
                truncated,
                size,
                encoding: "binary",
            },
        })
    }

    /// Writes `data` to `relative` atomically: a temporary file in the same
    /// directory, synced, then renamed over the target after the revision
    /// check. A failure removes the temporary file and leaves the target
    /// as it was.
    pub async fn write(
        &self,
        relative: &str,
        data: &[u8],
        mode: WriteMode,
    ) -> Result<Entry, FsError> {
        self.writable()?;
        let (parent, name) = self.parent_and_name(relative).await?;
        let target = format!("{}/{name}", parent.trim_end_matches('/'));
        let existing = match self.client.lstat(&target).await {
            Ok(attrs) => Some(attrs),
            Err(SftpError::Status { code: StatusCode::NoSuchFile, .. }) => None,
            Err(error) => return Err(error.into()),
        };
        if let Some(attrs) = &existing
            && attrs.file_type() != FileType::File
        {
            return Err(FsError::Exists);
        }
        let permissions = existing
            .as_ref()
            .and_then(|attrs| attrs.permissions)
            .map_or(0o644, |mode| mode & 0o7777);
        let temporary = format!(
            "{}/.{name}.cmux-{}.tmp",
            parent.trim_end_matches('/'),
            crate::ids::random_id("")
        );
        let flags = SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL;
        let handle =
            self.client.open(&temporary, flags, &Attrs::with_permissions(permissions)).await?;
        let result = async {
            write_all(&self.client, &handle, 0, Bytes::copy_from_slice(data)).await?;
            self.client.fsync(&handle).await?;
            Ok::<(), FsError>(())
        }
        .await;
        let closed = self.client.close(&handle).await.map_err(FsError::from);
        let committed = match result.and(closed) {
            Ok(()) => self.commit(&temporary, &target, mode).await,
            Err(error) => Err(error),
        };
        if committed.is_err() {
            let _ = self.client.remove(&temporary).await;
        }
        committed?;
        self.entry_at(&target, name).await
    }

    /// Moves a finished temporary file over `target` after the revision
    /// check of `mode`.
    pub(crate) async fn commit(
        &self,
        temporary: &str,
        target: &str,
        mode: WriteMode,
    ) -> Result<(), FsError> {
        let current = match self.client.lstat(target).await {
            Ok(attrs) => Some(attrs),
            Err(SftpError::Status { code: StatusCode::NoSuchFile, .. }) => None,
            Err(error) => return Err(error.into()),
        };
        match (mode, &current) {
            (WriteMode::Create, Some(_)) => return Err(FsError::Exists),
            (WriteMode::Replace { expected }, current) => {
                let found = current.as_ref().and_then(Revision::of);
                if found != Some(expected) {
                    return Err(FsError::RevisionMismatch {
                        current: found.map(|revision| revision.token()),
                    });
                }
            }
            _ => {}
        }
        if current.is_none() {
            // Version 3 rename never replaces, so a file created in the
            // meantime fails here instead of being overwritten.
            return self.client.rename(temporary, target).await.map_err(|error| match error {
                SftpError::Status { code: StatusCode::Failure, .. } => FsError::Exists,
                other => other.into(),
            });
        }
        if self.client.can_replace_atomically() {
            return Ok(self.client.posix_rename(temporary, target).await?);
        }
        // Without posix-rename the replace is two steps; the server is too
        // old for an atomic one.
        self.client.remove(target).await?;
        Ok(self.client.rename(temporary, target).await?)
    }

    /// `fs.mkdir {path, name}`.
    pub async fn mkdir(&self, parent_relative: &str, name: &str) -> Result<Entry, FsError> {
        self.writable()?;
        check_name(name)?;
        let (parent, attrs) = self.walk(parent_relative, false).await?;
        if attrs.file_type() != FileType::Dir {
            return Err(FsError::NotADirectory);
        }
        let path = format!("{}/{name}", parent.trim_end_matches('/'));
        if self.client.lstat(&path).await.is_ok() {
            return Err(FsError::Exists);
        }
        self.client.mkdir(&path, 0o755).await?;
        self.entry_at(&path, name).await
    }

    /// `fs.rename {path, name}`: a new name in the same directory.
    pub async fn rename(&self, relative: &str, new_name: &str) -> Result<Entry, FsError> {
        self.writable()?;
        check_name(new_name)?;
        let (parent, name) = self.parent_and_name(relative).await?;
        let from = format!("{}/{name}", parent.trim_end_matches('/'));
        self.client.lstat(&from).await?;
        let to = format!("{}/{new_name}", parent.trim_end_matches('/'));
        if self.client.lstat(&to).await.is_ok() {
            return Err(FsError::Exists);
        }
        self.client.rename(&from, &to).await?;
        self.entry_at(&to, new_name).await
    }

    /// Removes a file, a symlink or an empty directory (the root itself
    /// never).
    pub async fn remove(&self, relative: &str) -> Result<(), FsError> {
        self.writable()?;
        let (parent, name) = self.parent_and_name(relative).await?;
        let path = format!("{}/{name}", parent.trim_end_matches('/'));
        let attrs = self.client.lstat(&path).await?;
        if attrs.file_type() == FileType::Dir {
            return self.client.rmdir(&path).await.map_err(|error| match error {
                SftpError::Status { code: StatusCode::Failure, .. } => FsError::NotEmpty,
                other => other.into(),
            });
        }
        Ok(self.client.remove(&path).await?)
    }

    /// `fs.trash` on a host without a Trash: moves each item to
    /// `~/.cmux-trash/<job>/` on that host (finder.md 3.5 item 3).
    pub async fn trash(&self, relatives: &[String], job: &str) -> Result<(), FsError> {
        self.writable()?;
        check_name(job)?;
        let home = self.client.realpath(".").await?;
        let trash = format!("{}/.cmux-trash", home.trim_end_matches('/'));
        if self.client.lstat(&trash).await.is_err() {
            self.client.mkdir(&trash, 0o700).await?;
        }
        let folder = format!("{trash}/{job}");
        if self.client.lstat(&folder).await.is_err() {
            self.client.mkdir(&folder, 0o700).await?;
        }
        for relative in relatives {
            let (parent, name) = self.parent_and_name(relative).await?;
            let from = format!("{}/{name}", parent.trim_end_matches('/'));
            self.client.lstat(&from).await?;
            self.client.rename(&from, &format!("{folder}/{name}")).await?;
        }
        Ok(())
    }

    /// Opens `relative` for a bulk read: the handle and the file's size.
    pub(crate) async fn open_read(&self, relative: &str) -> Result<(Handle, u64), FsError> {
        let (path, attrs) = self.walk(relative, false).await?;
        if attrs.file_type() != FileType::File {
            return Err(FsError::NotAFile);
        }
        let handle = self.client.open(&path, SSH_FXF_READ, &Attrs::default()).await?;
        Ok((handle, attrs.size.unwrap_or(0)))
    }

    /// Creates a temporary file next to `relative` for a bulk write and
    /// returns its handle, its path and the final path.
    pub(crate) async fn create_temporary(
        &self,
        relative: &str,
    ) -> Result<(Handle, String, String), FsError> {
        self.writable()?;
        let (parent, name) = self.parent_and_name(relative).await?;
        let parent = parent.trim_end_matches('/');
        let temporary = format!("{parent}/.{name}.cmux-{}.tmp", crate::ids::random_id(""));
        let flags = SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL | SSH_FXF_TRUNC;
        let handle = self.client.open(&temporary, flags, &Attrs::with_permissions(0o644)).await?;
        Ok((handle, temporary, format!("{parent}/{name}")))
    }

    /// Walks `relative` and reports whether it is a directory, a file, or
    /// absent (`None`).
    pub(crate) async fn kind_of(
        &self,
        relative: &str,
    ) -> Result<Option<(EntryKind, u64)>, FsError> {
        match self.walk(relative, true).await {
            Ok((_, attrs)) => Ok(Some((attrs.file_type().into(), attrs.size.unwrap_or(0)))),
            Err(FsError::NotFound) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Makes the directory `relative` if it is absent.
    pub(crate) async fn ensure_directory(&self, relative: &str) -> Result<(), FsError> {
        self.writable()?;
        match self.kind_of(relative).await? {
            Some((EntryKind::Dir, _)) => Ok(()),
            Some(_) => Err(FsError::Exists),
            None => {
                let (parent, name) = self.parent_and_name(relative).await?;
                Ok(self
                    .client
                    .mkdir(&format!("{}/{name}", parent.trim_end_matches('/')), 0o755)
                    .await?)
            }
        }
    }
}

/// Reads `length` bytes from `offset` with several requests in flight.
pub(crate) async fn read_range(
    client: &SftpClient,
    handle: &Handle,
    offset: u64,
    length: u64,
) -> Result<Vec<u8>, FsError> {
    let mut chunks: Vec<Option<Bytes>> = Vec::new();
    let mut requests = JoinSet::new();
    let mut next = 0_u64;
    let mut done = false;
    while !done || !requests.is_empty() {
        while !done && requests.len() < IN_FLIGHT && next < length {
            let index = chunks.len();
            chunks.push(None);
            let size =
                u32::try_from((length - next).min(u64::from(CHUNK_BYTES))).unwrap_or(CHUNK_BYTES);
            let (client, handle, at) = (client.clone(), handle.clone(), offset + next);
            requests.spawn(async move { (index, client.read(&handle, at, size).await) });
            next += u64::from(size);
        }
        done |= next >= length;
        let Some(joined) = requests.join_next().await else { break };
        let (index, result) =
            joined.map_err(|error| FsError::Failure { message: error.to_string() })?;
        chunks[index] = Some(result?.unwrap_or_default());
    }
    let mut bytes = Vec::with_capacity(usize::try_from(length).unwrap_or(0));
    for chunk in chunks.into_iter().flatten() {
        let short = chunk.len() < CHUNK_BYTES as usize;
        bytes.extend_from_slice(&chunk);
        if short {
            // The file was shorter than its size said; stop at the gap.
            break;
        }
    }
    bytes.truncate(usize::try_from(length).unwrap_or(usize::MAX));
    Ok(bytes)
}

/// Writes `data` at `offset` with several requests in flight.
pub(crate) async fn write_all(
    client: &SftpClient,
    handle: &Handle,
    offset: u64,
    data: Bytes,
) -> Result<(), FsError> {
    let mut requests = JoinSet::new();
    let mut position = 0_usize;
    while position < data.len() || !requests.is_empty() {
        while position < data.len() && requests.len() < IN_FLIGHT {
            let end = (position + CHUNK_BYTES as usize).min(data.len());
            let (client, handle, chunk, at) = (
                client.clone(),
                handle.clone(),
                data.slice(position..end),
                offset + position as u64,
            );
            requests.spawn(async move { client.write(&handle, at, &chunk).await });
            position = end;
        }
        if let Some(joined) = requests.join_next().await {
            joined.map_err(|error| FsError::Failure { message: error.to_string() })??;
        }
    }
    Ok(())
}
