//! The helper's state directory, the mount table, and the `upper` and `status` commands.
//!
//! `STATE/` holds `lower/` (the FUSE mountpoint), `upper/` and `work/` (the overlay's),
//! `cache/` (the chunk cache), `helper.pid` while a helper serves it, and `stats.json`.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use cmux_file_lock::{FileLock, Kind, LockError};
use serde_json::{Map, Value, json};

use super::{Failure, Opts};
use crate::core::Stats;
use crate::upper::{ChangeKind, read_upper};

/// The filesystem type the lower layer has in the mount table.
pub(super) const LOWER_FSTYPE: &str = "fuse.cmux-projfs";

/// The paths of one projection.
#[derive(Debug, Clone)]
pub(super) struct Paths {
    /// The merged directory (only `unmount` and `mount` take it).
    pub at: Option<PathBuf>,
    pub state: PathBuf,
    pub lower: PathBuf,
    pub upper: PathBuf,
    pub work: PathBuf,
    pub cache: PathBuf,
}

impl Paths {
    /// `--state` (and `--at` when `with_at`), made absolute without following anything. An
    /// overlay option cannot carry `,` `:` or `\` safely, so a state path holding one is
    /// refused.
    pub(super) fn from_opts(opts: &Opts, with_at: bool) -> Result<Paths, String> {
        let allowed: &[&str] = if with_at { &["at", "state"] } else { &["state"] };
        opts.only(allowed)?;
        let at = if with_at { Some(opts.need("at")?) } else { None };
        Paths::parse(at, opts.need("state")?)
    }

    /// The paths for `--at` (when given) and `--state`.
    pub(super) fn parse(at: Option<&str>, state: &str) -> Result<Paths, String> {
        let at = at.map(absolute).transpose()?;
        Paths::new(at, &absolute(state)?)
    }

    pub(super) fn new(at: Option<PathBuf>, state: &Path) -> Result<Paths, String> {
        let text = state.to_str().ok_or("--state is not UTF-8")?;
        if text.contains([',', ':', '\\']) || text.contains(char::is_control) {
            return Err(format!(
                "--state {text:?} holds a character an overlay option cannot carry (, : \\ or a control character)"
            ));
        }
        Ok(Paths {
            at,
            state: state.to_path_buf(),
            lower: state.join("lower"),
            upper: state.join("upper"),
            work: state.join("work"),
            cache: state.join("cache"),
        })
    }

    pub(super) fn pid_file(&self) -> PathBuf {
        self.state.join("helper.pid")
    }

    pub(super) fn stats_file(&self) -> PathBuf {
        self.state.join("stats.json")
    }
}

/// `path` as an absolute, normalized path (`.` and `..` resolved lexically).
fn absolute(path: &str) -> Result<PathBuf, String> {
    let p = Path::new(path);
    let base = if p.is_absolute() {
        PathBuf::new()
    } else {
        std::env::current_dir().map_err(|e| format!("no working directory: {e}"))?
    };
    let mut out = PathBuf::from("/");
    for c in base.join(p).components() {
        match c {
            std::path::Component::Normal(n) => out.push(n),
            std::path::Component::ParentDir => {
                out.pop();
            }
            _ => {}
        }
    }
    Ok(out)
}

/// One line of `/proc/self/mountinfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MountEntry {
    pub point: PathBuf,
    pub fstype: String,
    pub super_options: String,
}

/// The mount table as this process sees it.
pub(super) fn mounts() -> Vec<MountEntry> {
    std::fs::read_to_string("/proc/self/mountinfo").map(|t| parse_mountinfo(&t)).unwrap_or_default()
}

/// The mount at exactly `point`, the last one when several are stacked.
pub(super) fn mount_at(point: &Path) -> Option<MountEntry> {
    mounts().into_iter().rev().find(|m| m.point == point)
}

pub(super) fn parse_mountinfo(text: &str) -> Vec<MountEntry> {
    let mut out = Vec::new();
    for line in text.lines() {
        let fields: Vec<&str> = line.split(' ').collect();
        let Some(dash) = fields.iter().position(|f| *f == "-") else { continue };
        let (Some(point), Some(fstype), Some(super_options)) =
            (fields.get(4), fields.get(dash + 1), fields.get(dash + 3))
        else {
            continue;
        };
        out.push(MountEntry {
            point: PathBuf::from(unescape(point)),
            fstype: (*fstype).to_owned(),
            super_options: unescape(super_options),
        });
    }
    out
}

/// Undoes the kernel's octal escapes (`\040` for a space, `\134` for a backslash).
fn unescape(field: &str) -> String {
    let mut rest = field.as_bytes();
    let mut out = Vec::with_capacity(rest.len());
    while let Some((&c, tail)) = rest.split_first() {
        let octal = match tail {
            [a, b, d, ..] if c == b'\\' => {
                let digits = [*a, *b, *d];
                digits.iter().all(|x| (b'0'..=b'7').contains(x)).then(|| {
                    digits
                        .iter()
                        .fold(0u8, |n, x| n.wrapping_mul(8).wrapping_add(x.wrapping_sub(b'0')))
                })
            }
            _ => None,
        };
        match octal {
            Some(byte) => {
                out.push(byte);
                rest = tail.get(3..).unwrap_or_default();
            }
            None => {
                out.push(c);
                rest = tail;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `upper --state DIR`.
pub(super) fn upper(paths: &Paths) -> Result<Value, Failure> {
    let changes = read_upper(&paths.upper)
        .map_err(|e| Failure::new("io", format!("cannot read {}: {e}", paths.upper.display())))?;
    let changes: Vec<Value> = changes
        .into_iter()
        .map(|c| {
            let mut v = Map::new();
            v.insert("path".into(), json!(c.path));
            let (kind, extra) = match c.kind {
                ChangeKind::File => ("file", None),
                ChangeKind::MetadataOnly => ("metadata", None),
                ChangeKind::Symlink(t) => ("symlink", Some(("link", t))),
                ChangeKind::Dir => ("dir", None),
                ChangeKind::OpaqueDir => ("opaque_dir", None),
                ChangeKind::Redirect(r) => ("redirect", Some(("from", r))),
                ChangeKind::Delete => ("delete", None),
                ChangeKind::Unsupported(why) => ("unsupported", Some(("reason", why))),
            };
            v.insert("kind".into(), json!(kind));
            if let Some((k, text)) = extra {
                v.insert(k.into(), json!(text));
            }
            Value::Object(v)
        })
        .collect();
    Ok(json!({ "ok": true, "changes": changes }))
}

/// `status --state DIR`: what the helper last wrote, and whether it still runs.
pub(super) fn status(paths: &Paths) -> Result<Value, Failure> {
    let text = std::fs::read_to_string(paths.stats_file()).map_err(|_| {
        Failure::new("no_stats", format!("no helper has served {}", paths.state.display()))
    })?;
    let stats: Value = serde_json::from_str(&text)
        .map_err(|e| Failure::new("io", format!("stats.json is not JSON: {e}")))?;
    let mut stats = match stats {
        Value::Object(m) => m,
        Value::Null => Map::new(),
        _ => return Err(Failure::new("io", "stats.json is not a JSON object")),
    };
    stats.insert("ok".into(), json!(true));
    stats.insert("running".into(), json!(running_helper(paths).is_some()));
    Ok(Value::Object(stats))
}

/// The counters as the helper writes them to `stats.json`.
pub(super) fn stats_json(mount: &str, stats: &Stats) -> Value {
    json!({
        "mount": mount,
        "pid": std::process::id(),
        "hits": stats.hits,
        "remote_reads": stats.remote_reads,
        "shared_waits": stats.shared_waits,
        "bytes_fetched": stats.bytes_fetched,
        "round_trips": stats.round_trips,
        "changed": stats.changed,
        "away": stats.away,
        "failed": stats.failed,
    })
}

/// Writes `value` to `path` whole (a temporary file renamed over it).
pub(super) fn write_atomic(path: &Path, value: &Value) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, value.to_string())?;
    std::fs::rename(&tmp, path)
}

/// A serving helper's hold on its state directory: an exclusive lock on `helper.pid`, kept for as
/// long as it serves and gone with the process however it ends. Whether a helper serves a
/// directory is then a lock test on that file, never a look at another process.
pub(super) struct HelperLock(
    #[allow(dead_code, reason = "held for its lock, released on drop")] FileLock,
);

/// Takes `paths`' helper lock and records this process's pid in the file. `Ok(None)`: another
/// helper holds it.
pub(super) fn lock_helper(paths: &Paths) -> std::io::Result<Option<HelperLock>> {
    let file = File::options()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(paths.pid_file())?;
    let mut lock = match FileLock::try_take(file, Kind::Exclusive) {
        Ok(lock) => lock,
        Err(LockError::Busy(_)) => return Ok(None),
        Err(LockError::Io(e)) => return Err(e),
    };
    lock.file().set_len(0)?;
    lock.file_mut().write_all(std::process::id().to_string().as_bytes())?;
    Ok(Some(HelperLock(lock)))
}

/// The pid of the helper serving `paths` (the holder of its lock), if one is.
pub(super) fn running_helper(paths: &Paths) -> Option<i32> {
    let mut file = File::open(paths.pid_file()).ok()?;
    if !FileLock::held_elsewhere(&file, Kind::Exclusive).ok()? {
        return None;
    }
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    let pid: i32 = text.trim().parse().ok()?;
    (pid > 0).then_some(pid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mountinfo_lines_parse_with_escapes() {
        let text = "36 35 98:0 / /mnt/a\\040b rw,noatime master:1 - overlay overlay rw,lowerdir=/s/lower,upperdir=/s/upper\n\
                    40 35 0:52 / /s/lower ro,nosuid - fuse.cmux-projfs cmux-projfs ro,user_id=1000\n";
        let m = parse_mountinfo(text);
        assert_eq!(m.len(), 2);
        assert_eq!(m[0].point, PathBuf::from("/mnt/a b"));
        assert_eq!(m[0].fstype, "overlay");
        assert!(m[0].super_options.contains("lowerdir=/s/lower"));
        assert_eq!(m[1].fstype, LOWER_FSTYPE);
    }

    #[test]
    fn state_paths_refuse_overlay_separators() {
        for bad in ["/s,t", "/s:t", "/s\\t", "/s\nt"] {
            assert!(Paths::new(None, Path::new(bad)).is_err(), "{bad:?}");
        }
        let p = Paths::new(None, Path::new("/home/cmux/.projfs/m1")).unwrap();
        assert_eq!(p.lower, PathBuf::from("/home/cmux/.projfs/m1/lower"));
        assert_eq!(absolute("/a/./b/../c").unwrap(), PathBuf::from("/a/c"));
    }
}
