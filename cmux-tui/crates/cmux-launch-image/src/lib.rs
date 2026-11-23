//! Each cmux window's last committed frame, kept on disk for the next
//! launch's first frame (stage 0 of cmuxterm-hq
//! `docs/design/launch-shell-first.md`: "The image is the window's last
//! committed frame, kept per window and capped by size").
//!
//! The macOS app captures a window and encodes it as PNG; everything else is
//! here: where a window's image lives, its atomic publish, the caps, pruning,
//! and when a capture is due ([`schedule`]).
//!
//! # Files
//!
//! One folder (the app passes it: `Application Support/<bundle id>/launch-images/`,
//! beside the launch record). A window's image is
//! `<window key>.<generation>.png`:
//!
//! - the window key is the window id when it is 1 to 64 of `[A-Za-z0-9_-]`, else
//!   `w-` and the id's 64-bit FNV-1a in hex ([`window_key`]);
//! - the generation is a `u64`, strictly greater than every generation the
//!   window had in the folder, and at least the publish's wall-clock
//!   nanoseconds, so a name is never reused for different bytes.
//!
//! A published path never changes: [`Store::publish`] writes a hidden
//! `.tmp` file, syncs it, renames it to a new name and syncs the folder. The
//! launch record names that path with the pixel size read from the same bytes,
//! so the record and the image always describe the same frame.
//!
//! # Caps
//!
//! [`Caps`]: an image over `max_image_bytes` is refused (the window keeps its
//! previous image); each window keeps its newest `keep_per_window` images (the
//! one the current launch record names survives until the next publish after
//! it); at most `max_windows` windows keep images (the least recently published
//! go first). A closed window's images go at once ([`Store::remove_window`]);
//! [`Store::prune`] keeps only the given live windows and drops stray `.tmp`
//! files.
//!
//! # No image is valid
//!
//! [`Store::current`] returns `None` for a missing, oversized, truncated or
//! non-PNG file: the launch then draws its empty first frame. Nothing here is
//! an error at launch.

pub mod ffi;
mod png;
pub mod schedule;

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub use png::png_pixel_size;

/// The image file's extension.
pub const EXTENSION: &str = "png";
/// The suffix of a file being written ([`Store::publish`]); never read, removed by [`Store::prune`].
pub const TMP_SUFFIX: &str = ".tmp";
/// How old a `.tmp` file or another window's image must be before [`Store::prune`] removes it, so a
/// prune never takes a publish in progress or a window that opened after its live list was read.
pub const PRUNE_GRACE: Duration = Duration::from_millis(ffi::CMUX_LAUNCH_IMAGE_PRUNE_GRACE_MS);
/// How many generations a publish tries when another publish took its name.
const PUBLISH_ATTEMPTS: u64 = 8;

/// The longest window id used as its own key.
pub const MAX_PLAIN_KEY: usize = 64;
/// The longest path the launch record carries (`cmux_launch_record.h`: image paths of 1025 bytes or
/// more are refused), less its NUL.
pub const MAX_PATH_BYTES: usize = 1024;

/// The store's limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps {
    /// A larger encoded image is refused at publish and ignored at read.
    pub max_image_bytes: u64,
    /// At most this many windows keep images.
    pub max_windows: usize,
    /// Each window keeps its newest this many images (at least 1).
    pub keep_per_window: usize,
}

impl Default for Caps {
    /// 8 MiB per image (a 5K window's PNG is 2 to 6 MiB), 16 windows, 2 per window: at most 256 MiB
    /// in the worst case, about 2 to 12 MiB for one window in practice.
    fn default() -> Self {
        Self { max_image_bytes: 8_388_608, max_windows: 16, keep_per_window: 2 }
    }
}

/// A window's published image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    pub path: PathBuf,
    pub generation: u64,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub bytes: u64,
}

/// Why a publish wrote nothing (the window's previous image stays).
#[derive(Debug)]
pub enum PublishError {
    /// The window id is empty.
    EmptyWindowId,
    /// The bytes are not a PNG with a nonzero size.
    NotPng,
    /// The image is over [`Caps::max_image_bytes`].
    TooLarge { bytes: u64, cap: u64 },
    /// The path would be over [`MAX_PATH_BYTES`].
    PathTooLong,
    /// The write, sync or rename failed.
    Io(io::Error),
}

impl std::fmt::Display for PublishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyWindowId => write!(f, "empty window id"),
            Self::NotPng => write!(f, "not a PNG with a nonzero size"),
            Self::TooLarge { bytes, cap } => {
                write!(f, "image is {bytes} bytes, over the {cap} byte cap")
            }
            Self::PathTooLong => write!(f, "image path over {MAX_PATH_BYTES} bytes"),
            Self::Io(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for PublishError {}

impl From<io::Error> for PublishError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// The file-safe key of `window_id`: the id itself when it is 1 to [`MAX_PLAIN_KEY`] of
/// `[A-Za-z0-9_-]`, else `w-` and its FNV-1a 64 in hex. Never contains a `.`.
pub fn window_key(window_id: &str) -> String {
    let plain = !window_id.is_empty()
        && window_id.len() <= MAX_PLAIN_KEY
        && window_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    if plain {
        return window_id.to_owned();
    }
    let digest = window_id
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
    format!("w-{digest:016x}")
}

/// A file name of the store split into its key and generation; `None` for any other name
/// (`.tmp` files included).
fn parse_name(name: &str) -> Option<(&str, u64)> {
    let stem = name.strip_suffix(EXTENSION)?.strip_suffix('.')?;
    let (key, generation) = stem.rsplit_once('.')?;
    if key.is_empty()
        || key.starts_with('.')
        || generation.is_empty()
        || !generation.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    Some((key, generation.parse().ok()?))
}

/// One window's files in the folder, newest first.
struct Entry {
    key: String,
    generation: u64,
    name: String,
}

/// The folder of the windows' images.
#[derive(Debug, Clone)]
pub struct Store {
    dir: PathBuf,
    caps: Caps,
}

impl Store {
    pub fn new(dir: impl Into<PathBuf>, caps: Caps) -> Self {
        let keep_per_window = caps.keep_per_window.max(1);
        let max_windows = caps.max_windows.max(1);
        Self { dir: dir.into(), caps: Caps { keep_per_window, max_windows, ..caps } }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn caps(&self) -> Caps {
        self.caps
    }

    /// Every image file in the folder, by name; empty when the folder is missing.
    fn entries(&self) -> Vec<Entry> {
        let Ok(read) = fs::read_dir(&self.dir) else { return Vec::new() };
        let mut entries: Vec<Entry> = read
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .filter_map(|name| {
                parse_name(&name).map(|(key, generation)| Entry {
                    key: key.to_owned(),
                    generation,
                    name: name.clone(),
                })
            })
            .collect();
        entries.sort_by(|a, b| b.generation.cmp(&a.generation).then_with(|| a.name.cmp(&b.name)));
        entries
    }

    /// Writes `png` as `window_id`'s newest image and returns it, then drops what the caps no longer
    /// keep. The bytes are checked first (a PNG with a nonzero size, within
    /// [`Caps::max_image_bytes`]); a refused or failed publish leaves the window's images as they were.
    pub fn publish(&self, window_id: &str, png: &[u8]) -> Result<Image, PublishError> {
        self.publish_at(window_id, png, now_nanos())
    }

    /// [`Self::publish`] with the clock's nanoseconds given (tests).
    pub fn publish_at(
        &self,
        window_id: &str,
        png: &[u8],
        now_nanos: u64,
    ) -> Result<Image, PublishError> {
        if window_id.is_empty() {
            return Err(PublishError::EmptyWindowId);
        }
        let bytes = png.len() as u64;
        if bytes > self.caps.max_image_bytes {
            return Err(PublishError::TooLarge { bytes, cap: self.caps.max_image_bytes });
        }
        let (pixel_width, pixel_height) = png_pixel_size(png).ok_or(PublishError::NotPng)?;
        let key = window_key(window_id);
        let entries = self.entries();
        let newest =
            entries.iter().filter(|e| e.key == key).map(|e| e.generation).max().unwrap_or(0);
        let first = now_nanos.max(newest.saturating_add(1));
        let longest = self.dir.join(format!("{key}.{}.{EXTENSION}", u64::MAX));
        if longest.as_os_str().len() > MAX_PATH_BYTES {
            return Err(PublishError::PathTooLong);
        }
        fs::create_dir_all(&self.dir)?;
        static NONCE: AtomicU64 = AtomicU64::new(0);
        let nonce = NONCE.fetch_add(1, Ordering::Relaxed);
        let tmp = self.dir.join(format!(".{key}.{}.{nonce}{TMP_SUFFIX}", std::process::id()));
        if let Err(error) = write_synced(&tmp, png) {
            let _ = fs::remove_file(&tmp);
            return Err(error.into());
        }
        // A hard link never replaces: a name another publish took is skipped, so a published path
        // never gets other bytes.
        let mut published = None;
        let mut last_error = None;
        for offset in 0..PUBLISH_ATTEMPTS {
            let generation = first.saturating_add(offset);
            let path = self.dir.join(format!("{key}.{generation}.{EXTENSION}"));
            match fs::hard_link(&tmp, &path) {
                Ok(()) => {
                    published = Some((generation, path));
                    break;
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    last_error = Some(error);
                }
                Err(error) => {
                    last_error = Some(error);
                    break;
                }
            }
        }
        let _ = fs::remove_file(&tmp);
        let Some((generation, path)) = published else {
            return Err(last_error.unwrap_or_else(|| io::Error::other("no free name")).into());
        };
        // The rename is durable once the folder is synced; a failure here only risks the newest
        // image after a power loss, which reads as the previous one or none.
        let _ = File::open(&self.dir).and_then(|dir| dir.sync_all());
        self.enforce_caps(&key);
        Ok(Image { path, generation, pixel_width, pixel_height, bytes })
    }

    /// Drops each window's images past [`Caps::keep_per_window`], then whole windows past
    /// [`Caps::max_windows`] (least recently published first, never `just_published`).
    fn enforce_caps(&self, just_published: &str) {
        let entries = self.entries();
        let mut windows: Vec<&str> = Vec::new();
        let mut kept: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        let mut doomed: Vec<&str> = Vec::new();
        // Newest first: a window's first entry is its newest, and windows come in recency order.
        for entry in &entries {
            let count = kept.entry(entry.key.as_str()).or_insert(0);
            if *count == 0 {
                windows.push(entry.key.as_str());
            }
            *count = count.saturating_add(1);
            if *count > self.caps.keep_per_window {
                doomed.push(&entry.name);
            }
        }
        let mut evict: Vec<&str> =
            windows.iter().copied().filter(|k| *k != just_published).collect();
        let keep_others =
            self.caps.max_windows.saturating_sub(usize::from(windows.contains(&just_published)));
        let evict: Vec<&str> =
            if evict.len() > keep_others { evict.split_off(keep_others) } else { Vec::new() };
        doomed.extend(
            entries.iter().filter(|e| evict.contains(&e.key.as_str())).map(|e| e.name.as_str()),
        );
        for name in doomed {
            let _ = fs::remove_file(self.dir.join(name));
        }
    }

    /// `window_id`'s newest readable image, or `None` (no image: the launch's empty first frame).
    /// Reads at most the PNG header of each candidate, never the whole file.
    pub fn current(&self, window_id: &str) -> Option<Image> {
        if window_id.is_empty() {
            return None;
        }
        let key = window_key(window_id);
        self.entries().into_iter().filter(|e| e.key == key).find_map(|e| self.read_image(&e))
    }

    fn read_image(&self, entry: &Entry) -> Option<Image> {
        let path = self.dir.join(&entry.name);
        let meta = fs::metadata(&path).ok()?;
        if !meta.is_file() || meta.len() > self.caps.max_image_bytes {
            return None;
        }
        let mut header = [0_u8; png::HEADER_BYTES];
        let mut file = File::open(&path).ok()?;
        io::Read::read_exact(&mut file, &mut header).ok()?;
        let (pixel_width, pixel_height) = png_pixel_size(&header)?;
        Some(Image {
            path,
            generation: entry.generation,
            pixel_width,
            pixel_height,
            bytes: meta.len(),
        })
    }

    /// Removes every image of `window_id` (the window closed). Returns how many files went.
    pub fn remove_window(&self, window_id: &str) -> usize {
        if window_id.is_empty() {
            return 0;
        }
        let key = window_key(window_id);
        self.entries()
            .into_iter()
            .filter(|e| e.key == key)
            .filter(|e| fs::remove_file(self.dir.join(&e.name)).is_ok())
            .count()
    }

    /// Keeps only the images of `live` windows and removes `.tmp` files (a publish a crash cut
    /// short), each only once older than [`PRUNE_GRACE`]. Files the store did not name are left
    /// alone. Returns how many files went.
    pub fn prune<S: AsRef<str>>(&self, live: &[S]) -> usize {
        self.prune_older_than(live, PRUNE_GRACE)
    }

    /// [`Self::prune`] with the age a file must reach given (tests pass zero).
    pub fn prune_older_than<S: AsRef<str>>(&self, live: &[S], grace: Duration) -> usize {
        let live: std::collections::HashSet<String> =
            live.iter().map(|id| window_key(id.as_ref())).collect();
        let Ok(read) = fs::read_dir(&self.dir) else { return 0 };
        let mut removed: usize = 0;
        for name in read.filter_map(Result::ok).filter_map(|e| e.file_name().into_string().ok()) {
            let stale = match parse_name(&name) {
                Some((key, _)) => !live.contains(key),
                None => name.starts_with('.') && name.ends_with(TMP_SUFFIX),
            };
            let path = self.dir.join(&name);
            let old = || {
                fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|age| age >= grace)
            };
            if stale && old() && fs::remove_file(&path).is_ok() {
                removed = removed.saturating_add(1_usize);
            }
        }
        removed
    }
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.sync_all()
}

fn now_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip_and_reject_others() {
        assert_eq!(parse_name("abc.12.png"), Some(("abc", 12)));
        assert_eq!(parse_name("w-00ff.1.png"), Some(("w-00ff", 1)));
        assert_eq!(parse_name(".abc.12.png.7.tmp"), None);
        assert_eq!(parse_name("abc.png"), None);
        assert_eq!(parse_name("abc.x1.png"), None);
        assert_eq!(parse_name("notes.txt"), None);
    }

    #[test]
    fn keys_are_file_safe() {
        assert_eq!(window_key("7f3a-WIN_1"), "7f3a-WIN_1");
        for id in ["../../etc/passwd", "a.b", "", "é", &"x".repeat(65)] {
            let key = window_key(id);
            assert!(key.starts_with("w-") && key.len() == 18, "{id:?} -> {key}");
        }
        assert_ne!(window_key("a.b"), window_key("a.c"));
    }
}
