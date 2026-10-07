//! The seven `fs-v1` ops on the daemon's roots. Params and results are the
//! shapes of the request file `daemon-fs-for-cloud.md` ("Exact wire JSON").

use std::fs::File;
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt as _;
use std::sync::Mutex;
use std::time::Instant;

use base64::Engine as _;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::entry::{Entry, EntryKind, Meta, StatResult, check_name, mode_display};
use super::error::FsError;
use super::listing::{Filter, Listings, MAX_BATCH, Sort, sort_entries};
use super::resolve::{Resolved, Roots};
use super::sys;
use super::write::{PendingWrite, WriteMode, remove_tree};

/// Largest `fs.read` answer (decision D2): `max_bytes` above this is cut
/// and answered with `truncated: true`.
pub const MAX_READ_BYTES: u64 = 16 * 1024 * 1024;
/// Largest single-call `fs.write` (decision D2; a request line is at most
/// 16 MiB, so 12 MiB of bytes fit in base64). Larger pushes use the stream.
pub const MAX_WRITE_BYTES: usize = 12 * 1024 * 1024;
/// Most paths one `fs.delete` takes.
const MAX_DELETE_PATHS: usize = 1000;
/// At most this many symlinks per listing get their target resolved.
const MAX_RESOLVED_SYMLINKS: usize = 256;

#[derive(Deserialize)]
struct PathParams {
    path: String,
}

#[derive(Deserialize)]
struct ListParams {
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    sort: Sort,
    #[serde(default)]
    filter: Filter,
    #[serde(default = "default_limit")]
    limit: usize,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    listing: Option<String>,
}

fn default_limit() -> usize {
    200
}

#[derive(Deserialize)]
struct ReadParams {
    path: String,
    #[serde(default)]
    offset: u64,
    max_bytes: u64,
}

#[derive(Deserialize)]
struct WriteParams {
    path: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    bytes_base64: Option<String>,
    mode: String,
    #[serde(default)]
    expected: Option<String>,
}

#[derive(Deserialize)]
struct NameParams {
    path: String,
    name: String,
}

#[derive(Deserialize)]
struct DeleteParams {
    paths: Vec<String>,
    #[serde(default)]
    permanent: bool,
}

/// The daemon's file system owner for `fs-v1`.
pub struct FsService {
    roots: Roots,
    listings: Mutex<Listings>,
}

impl FsService {
    #[must_use]
    pub fn new(roots: Roots) -> Self {
        Self { roots, listings: Mutex::new(Listings::default()) }
    }

    #[must_use]
    pub fn roots(&self) -> &Roots {
        &self.roots
    }

    /// Removes leftover write temporaries older than an hour (daemon start).
    pub fn sweep_stale_temporaries(&self) -> usize {
        super::sweep::remove_stale_temporaries(&self.roots, std::time::SystemTime::now())
    }

    /// Runs the op `cmd` with the request object `params` (flat, next to
    /// `id` and `cmd`). `owner` keys the caller's listing snapshots.
    pub fn call(&self, owner: &str, cmd: &str, params: Value) -> Result<Value, FsError> {
        match cmd {
            "fs.stat" => to_value(&self.stat(&parse::<PathParams>(params)?.path)?),
            "fs.list" => self.list(owner, parse(params)?),
            "fs.read" => self.read(parse(params)?),
            "fs.write" => self.write(parse(params)?),
            "fs.mkdir" => {
                let params: NameParams = parse(params)?;
                Ok(json!({ "entry": self.mkdir(&params.path, &params.name)? }))
            }
            "fs.rename" => {
                let params: NameParams = parse(params)?;
                Ok(json!({ "entry": self.rename(&params.path, &params.name)? }))
            }
            "fs.delete" => self.delete(parse(params)?),
            _ => Err(FsError::ParamsInvalid("unknown fs op".into())),
        }
    }

    pub fn stat(&self, path: &str) -> Result<StatResult, FsError> {
        let resolved = self.roots.resolve(path, false)?;
        let stat = lstat_resolved(&resolved)?;
        let meta = Meta::of(&stat);
        let name = display_name(path);
        let mut entry = Entry::new(&name, &meta);
        if entry.kind == EntryKind::Symlink {
            entry.target_kind = self.roots.target_kind(path);
        }
        Ok(StatResult {
            entry,
            mode_display: mode_display(meta.mode),
            owner_display: sys::user_name(meta.uid).unwrap_or_else(|| meta.uid.to_string()),
            revision: meta.revision(),
        })
    }

    fn list(&self, owner: &str, params: ListParams) -> Result<Value, FsError> {
        if !(1..=MAX_BATCH).contains(&params.limit) {
            return Err(FsError::ParamsInvalid("limit is 1..1000".into()));
        }
        let now = Instant::now();
        if let Some(listing) = &params.listing {
            let page =
                self.lock().page(owner, listing, params.cursor.as_deref(), params.limit, now)?;
            return to_value(&page);
        }
        let path = params.path.ok_or_else(|| FsError::ParamsInvalid("path is required".into()))?;
        let (entries, revision) = self.read_directory(&path)?;
        let mut entries: Vec<Entry> =
            entries.into_iter().filter(|entry| params.filter.admits(entry)).collect();
        sort_entries(&mut entries, params.sort);
        let page = self.lock().insert(owner, entries, revision, params.limit, now)?;
        to_value(&page)
    }

    /// Every entry of the folder at `path` (unsorted) and its revision.
    pub fn read_directory(&self, path: &str) -> Result<(Vec<Entry>, String), FsError> {
        let resolved = self.roots.resolve(path, true)?;
        let dir = match &resolved.name {
            Some(name) => {
                let meta = Meta::of(&sys::lstat_at(resolved.dir(), name)?);
                if meta.kind != EntryKind::Dir {
                    return Err(FsError::NotADirectory);
                }
                sys::open_dir_at(resolved.dir(), name)?
            }
            None => resolved.dir,
        };
        let revision = Meta::of(&sys::stat_fd(dir.as_fd())?).revision();
        let names = sys::read_dir_names(dir.as_fd()).map_err(|error| match error {
            sys::ReadDirError::Io(error) => FsError::from(error),
            sys::ReadDirError::TooMany => {
                FsError::TooLarge { total: Some(sys::MAX_DIRECTORY_NAMES as u64) }
            }
        })?;
        let mut entries = Vec::with_capacity(names.len());
        let mut resolved_links = 0;
        for raw in names {
            let Ok(name) = String::from_utf8(raw) else { continue };
            if check_name(&name).is_err() {
                continue;
            }
            // A name removed since the read is skipped.
            let Ok(stat) = sys::lstat_at(dir.as_fd(), &name) else { continue };
            let mut entry = Entry::new(&name, &Meta::of(&stat));
            if entry.kind == EntryKind::Symlink && resolved_links < MAX_RESOLVED_SYMLINKS {
                resolved_links += 1;
                entry.target_kind = self.roots.target_kind(&join(path, &name));
            }
            entries.push(entry);
        }
        Ok((entries, revision))
    }

    fn read(&self, params: ReadParams) -> Result<Value, FsError> {
        let (file, meta) = self.open_file(&params.path)?;
        let wanted =
            params.max_bytes.min(MAX_READ_BYTES).min(meta.size.saturating_sub(params.offset));
        let mut bytes = vec![0u8; usize::try_from(wanted).unwrap_or(0)];
        let mut filled = 0;
        while filled < bytes.len() {
            let read = file.read_at(&mut bytes[filled..], params.offset + filled as u64)?;
            if read == 0 {
                break;
            }
            filled += read;
        }
        bytes.truncate(filled);
        let truncated = params.offset.saturating_add(filled as u64) < meta.size;
        // Text whose JSON escapes would outgrow base64 is sent as base64,
        // so an answer stays near 4/3 of the bytes read.
        let text = match String::from_utf8(bytes) {
            Ok(text) if !escape_heavy(&text) => Ok(text),
            Ok(text) => Err(text.into_bytes()),
            Err(error) => Err(error.into_bytes()),
        };
        Ok(match text {
            Ok(text) => {
                json!({ "text": text, "truncated": truncated, "size": meta.size, "encoding": "utf-8" })
            }
            Err(bytes) => json!({
                "bytes_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
                "truncated": truncated,
                "size": meta.size,
                "encoding": "base64",
            }),
        })
    }

    /// Opens the regular file at `path` for reading (never a FIFO or a
    /// device: `O_NONBLOCK` keeps the open from blocking, and the kind is
    /// checked on the open descriptor).
    pub(crate) fn open_file(&self, path: &str) -> Result<(File, Meta), FsError> {
        let resolved = self.roots.resolve(path, true)?;
        let Some(name) = &resolved.name else { return Err(FsError::NotAFile) };
        if Meta::of(&sys::lstat_at(resolved.dir(), name)?).kind != EntryKind::File {
            return Err(FsError::NotAFile);
        }
        let fd = sys::open_at(resolved.dir(), name, libc::O_RDONLY | libc::O_NONBLOCK, 0)?;
        let meta = Meta::of(&sys::stat_fd(fd.as_fd())?);
        if meta.kind != EntryKind::File {
            return Err(FsError::NotAFile);
        }
        Ok((File::from(fd), meta))
    }

    fn write(&self, params: WriteParams) -> Result<Value, FsError> {
        let data = match (params.text, params.bytes_base64) {
            (Some(text), None) => text.into_bytes(),
            (None, Some(encoded)) => base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map_err(|_| FsError::ParamsInvalid("bytes_base64 is not base64".into()))?,
            _ => return Err(FsError::ParamsInvalid("exactly one of text and bytes_base64".into())),
        };
        if data.len() > MAX_WRITE_BYTES {
            return Err(FsError::TooLarge { total: Some(data.len() as u64) });
        }
        let mode = WriteMode::parse(&params.mode, params.expected)?;
        let mut pending =
            PendingWrite::begin(&self.roots, &params.path, mode, Some(data.len() as u64))?;
        pending.write(&data)?;
        Ok(json!({ "entry": pending.commit()? }))
    }

    pub fn mkdir(&self, path: &str, name: &str) -> Result<Entry, FsError> {
        check_name(name)?;
        let resolved = self.roots.resolve(path, true)?;
        let dir = match &resolved.name {
            Some(parent) => sys::open_dir_at(resolved.dir(), parent)?,
            None => resolved.dir,
        };
        sys::mkdir_at(dir.as_fd(), name, 0o755)?;
        Entry::at(dir.as_fd(), name)
    }

    pub fn rename(&self, path: &str, new_name: &str) -> Result<Entry, FsError> {
        check_name(new_name)?;
        let resolved = self.roots.resolve(path, false)?;
        let Some(name) = &resolved.name else { return Err(FsError::PermissionDenied) };
        sys::lstat_at(resolved.dir(), name)?;
        sys::rename_no_replace(resolved.dir(), name, new_name)?;
        sys::fsync(resolved.dir())?;
        Entry::at(resolved.dir(), new_name)
    }

    fn delete(&self, params: DeleteParams) -> Result<Value, FsError> {
        if !params.permanent {
            return Err(FsError::ParamsInvalid("fs.delete needs permanent: true".into()));
        }
        if params.paths.is_empty() || params.paths.len() > MAX_DELETE_PATHS {
            return Err(FsError::ParamsInvalid("paths holds 1..1000 paths".into()));
        }
        // Check every path before removing anything (one descriptor at a
        // time), then resolve each again to remove it.
        for path in &params.paths {
            let resolved = self.roots.resolve(path, false)?;
            let Some(name) = &resolved.name else { return Err(FsError::PermissionDenied) };
            sys::lstat_at(resolved.dir(), name)?;
        }
        for path in &params.paths {
            // A target inside an earlier one is already gone.
            let resolved = match self.roots.resolve(path, false) {
                Ok(resolved) => resolved,
                Err(FsError::NotFound) => continue,
                Err(error) => return Err(error),
            };
            let Some(name) = &resolved.name else { return Err(FsError::PermissionDenied) };
            match remove_tree(resolved.dir(), name) {
                Ok(()) | Err(FsError::NotFound) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(json!({}))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Listings> {
        self.listings.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// True when JSON escapes (`\u00XX`, 6 bytes each) would make `text`
/// longer than its base64 (4/3 of its bytes).
fn escape_heavy(text: &str) -> bool {
    let escaped =
        text.chars().filter(|c| c.is_control() && !matches!(c, '\n' | '\t' | '\r')).count();
    escaped.saturating_mul(5) > text.len() / 3
}

fn lstat_resolved(resolved: &Resolved) -> Result<libc::stat, FsError> {
    Ok(match &resolved.name {
        Some(name) => sys::lstat_at(resolved.dir(), name)?,
        None => sys::stat_fd(resolved.dir())?,
    })
}

/// The last component of a request path (`/` for the file system root).
fn display_name(path: &str) -> String {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or("/")
        .to_owned()
}

fn join(folder: &str, name: &str) -> String {
    format!("{}/{name}", folder.trim_end_matches('/'))
}

fn parse<T: DeserializeOwned>(params: Value) -> Result<T, FsError> {
    serde_json::from_value(params).map_err(|error| FsError::ParamsInvalid(error.to_string()))
}

fn to_value<T: serde::Serialize>(value: &T) -> Result<Value, FsError> {
    serde_json::to_value(value).map_err(|error| FsError::Failure(error.to_string()))
}
