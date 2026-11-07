//! `_acpmux/browse`: one directory's entries on this machine or on a peer, for the composer's
//! folder browser (HQ#7442 row 4). Part of the request handler (`requests.rs`).
//!
//! - Names and kinds only (a file's size at most), never a file's contents.
//! - Served to this machine's own clients (the unix socket, the app) and under `Control::Peer`:
//!   a peer daemon with this launch's peer token, or a paired `client` machine (both the
//!   owner's; `pairing.rs` `origin_of`). A Web connection, a read-only device, a phone and a
//!   peer forwarding for its own Web client (`via: web`) get Method not found, as for
//!   `_acpmux/directories`. Only this machine's own client may name a `peer`, one hop.
//! - A peer lists only inside the folders it may start a chat in (`web_roots`), so every
//!   folder it shows can be picked; with no `path` it lists those roots.
//! - A `path` is absolute (or `~`), with no `.` or `..`, and is resolved before it is read.
//!   A link is reported as a link with the kind of what it names, never listed through.
//! - One listing reads at most `SCAN_CAP` entries within `DEADLINE` and says which bound cut
//!   it (`truncated`); a page holds at most `PAGE_MAX` of them.

use super::Conn;
use crate::hub::{Control, Hub};
use crate::rpc::RpcError;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(super) const METHOD: &str = "_acpmux/browse";

/// Entries a listing reads before it stops and says `truncated: cap`.
const SCAN_CAP: usize = 5_000;
/// How long a listing may read before it stops and says `truncated: deadline`.
const DEADLINE: Duration = Duration::from_millis(1_500);
const PAGE_DEFAULT: usize = 200;
const PAGE_MAX: usize = 500;
/// How long a peer's listing may take, link included.
const PEER_WAIT: Duration = Duration::from_secs(10);

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let control = super::remote_guard::control_of(conn.origin, conn.auth, params);
    if control == Control::Web {
        return Err(RpcError::method_not_found(&format!(
            "{METHOD} (not served to a remote WebSocket connection)"
        )));
    }
    if let Some(peer) = params.get("peer") {
        if control != Control::Local {
            return Err(RpcError::invalid_params(
                "a peer cannot select another peer on this daemon",
            )
            .with_data(json!({"reason": "peer.forward_refused"})));
        }
        let name = peer
            .as_str()
            .filter(|n| !n.is_empty())
            .ok_or_else(|| RpcError::invalid_params("peer must be a nonempty peer name"))?;
        return forward(hub, name, params).await;
    }
    let roots = match control {
        Control::Peer => Some(super::remote_guard::web_roots(hub).await),
        _ => None,
    };
    let ask = Ask::from(params)?;
    tokio::task::spawn_blocking(move || {
        let now = Instant::now();
        list(&ask, roots.as_deref(), SCAN_CAP, now.checked_add(DEADLINE).unwrap_or(now))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
}

/// The same request on the peer `name`, without the selector (it picks this hop only).
async fn forward(hub: &Hub, name: &str, params: &Value) -> Result<Value, RpcError> {
    let peer =
        hub.peer_by_name(name).ok_or_else(|| RpcError::not_found(format!("no peer {name:?}")))?;
    let mut forwarded = params.clone();
    if let Some(object) = forwarded.as_object_mut() {
        object.remove("peer");
    }
    let mut result = tokio::time::timeout(PEER_WAIT, peer.request(METHOD, forwarded))
        .await
        .map_err(|_| peer.unreachable_error())??;
    if let Some(object) = result.as_object_mut() {
        object.insert("peer".into(), Value::String(peer.name.clone()));
    }
    Ok(result)
}

struct Ask {
    path: Option<String>,
    hidden: bool,
    dirs_only: bool,
    offset: usize,
    limit: usize,
}

impl Ask {
    fn from(params: &Value) -> Result<Self, RpcError> {
        let count = |key: &str| {
            params.get(key).and_then(Value::as_u64).and_then(|n| usize::try_from(n).ok())
        };
        // No `path` (or null) is the top level; anything else must be a folder's name. An empty
        // string or an array is refused, never read as "none" (that would list the home folder).
        let path = match params.get("path") {
            None | Some(Value::Null) => None,
            Some(Value::String(p)) if !p.is_empty() => Some(p.clone()),
            Some(_) => return Err(refused("browse.path", "path must be a nonempty string")),
        };
        Ok(Ask {
            path,
            hidden: params.get("hidden").and_then(Value::as_bool) == Some(true),
            dirs_only: params.get("dirsOnly").and_then(Value::as_bool) == Some(true),
            offset: count("offset").unwrap_or(0),
            limit: count("limit").unwrap_or(PAGE_DEFAULT).clamp(1, PAGE_MAX),
        })
    }
}

fn refused(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// `ask.path` read under `roots` (None: anywhere on this machine), from `scan_cap` entries at
/// most, until `deadline`.
fn list(
    ask: &Ask,
    roots: Option<&[PathBuf]>,
    scan_cap: usize,
    deadline: Instant,
) -> Result<Value, RpcError> {
    let home = dirs::home_dir().unwrap_or_default();
    let Some(asked) = ask.path.as_deref() else {
        return Ok(match roots {
            Some(roots) => roots_page(ask, roots, &home),
            None => list(
                &Ask { path: Some(home.to_string_lossy().into_owned()), ..*ask },
                None,
                scan_cap,
                deadline,
            )?,
        });
    };
    let path = expand(asked, &home)?;
    let dir = std::fs::canonicalize(&path)
        .map_err(|e| refused("browse.path", format!("{}: {e}", path.display())))?;
    let inside = |p: &Path| roots.is_none_or(|roots| roots.iter().any(|root| p.starts_with(root)));
    if !inside(&dir) {
        return Err(refused(
            "browse.outside_roots",
            "this machine starts a peer's chat only inside its webRoots and known projects",
        ));
    }
    // Opened once and listed through that open folder, checked by what it names now: a rename
    // or a link swapped in after the check above never lists another folder. Where a listing
    // can only read by name, nothing holds it to the roots, so a peer gets nothing.
    if roots.is_some() && !opened::HOLDS_ITS_FOLDER {
        return Err(refused("browse.path", "this machine can't list a folder for a peer"));
    }
    let opened = opened::open(&dir).map_err(|e| match e.raw_os_error() {
        Some(code) if code == libc::ENOTDIR => {
            refused("browse.not_directory", format!("{} is not a folder", dir.display()))
        }
        _ => refused("browse.path", format!("{}: {e}", dir.display())),
    })?;
    let outside = || {
        refused(
            "browse.outside_roots",
            "this machine starts a peer's chat only inside its webRoots and known projects",
        )
    };
    let dir = opened
        .path()
        .ok_or_else(|| refused("browse.path", "the folder moved while it was opened"))?;
    if !inside(&dir) {
        return Err(outside());
    }
    let read =
        opened.read().map_err(|e| refused("browse.path", format!("{}: {e}", dir.display())))?;
    let mut entries = Vec::new();
    let mut scanned = 0;
    let mut cut = None;
    for entry in read {
        if scanned >= scan_cap {
            cut = Some("cap");
            break;
        }
        if Instant::now() >= deadline {
            cut = Some("deadline");
            break;
        }
        scanned = scanned.saturating_add(1);
        let name = entry.name.to_string_lossy().into_owned();
        if !ask.hidden && name.starts_with('.') {
            continue;
        }
        let path = dir.join(&name);
        let mut row = Map::new();
        row.insert("name".into(), json!(name));
        row.insert("path".into(), json!(path));
        let opens = match entry.kind {
            opened::Kind::Symlink => {
                // Reported as a link; only what it names is read, and only to say its kind.
                let target = match std::fs::metadata(&path) {
                    Ok(m) if m.is_dir() => "dir",
                    Ok(_) => "file",
                    Err(_) => "missing",
                };
                row.insert("kind".into(), json!("symlink"));
                row.insert("target".into(), json!(target));
                if target != "missing"
                    && roots.is_some()
                    && !std::fs::canonicalize(&path).is_ok_and(|p| inside(&p))
                {
                    row.insert("outside".into(), json!(true));
                }
                target == "dir"
            }
            opened::Kind::Dir => {
                row.insert("kind".into(), json!("dir"));
                true
            }
            kind => {
                let file = kind == opened::Kind::File;
                row.insert("kind".into(), json!(if file { "file" } else { "other" }));
                if file
                    && !ask.dirs_only
                    && let Some(size) = opened.size_of(&entry.name)
                {
                    row.insert("size".into(), json!(size));
                }
                false
            }
        };
        if ask.dirs_only && !opens {
            continue;
        }
        entries.push((opens, row));
    }
    // Still inside after the read: one moved out while it was listed lists nothing.
    if !opened.path().is_some_and(|now| inside(&now)) {
        return Err(outside());
    }
    // Folders first, then by name as a person reads it.
    entries.sort_by_cached_key(|(opens, row)| {
        (!*opens, row.get("name").and_then(Value::as_str).unwrap_or("").to_lowercase())
    });
    let parent = dir.parent().filter(|p| inside(p)).map(Path::to_path_buf);
    let mut reply = page(ask, entries.into_iter().map(|(_, row)| Value::Object(row)).collect());
    reply.insert("path".into(), json!(dir));
    reply.insert("parent".into(), json!(parent));
    reply.insert("home".into(), json!(home));
    if let Some(roots) = roots {
        reply.insert("roots".into(), json!(roots));
    }
    if let Some(reason) = cut {
        reply.insert("truncated".into(), json!({"reason": reason, "scanned": scanned}));
    }
    Ok(Value::Object(reply))
}

/// A folder opened once (no link followed at its last name), its entries read from that open
/// descriptor (`fdopendir`), and the path the descriptor names now, from the kernel.
mod opened {
    use std::ffi::OsString;

    /// An entry's own kind, never what a link names.
    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(super) enum Kind {
        Dir,
        File,
        Symlink,
        Other,
    }

    pub(super) struct Entry {
        pub(super) name: OsString,
        pub(super) kind: Kind,
    }

    #[cfg(not(unix))]
    pub(super) use other::{HOLDS_ITS_FOLDER, open};
    #[cfg(unix)]
    pub(super) use unix::{HOLDS_ITS_FOLDER, open};

    #[cfg(unix)]
    mod unix {
        /// A listing reads through the folder it opened (`fdopendir`), not its name.
        pub(in super::super) const HOLDS_ITS_FOLDER: bool = true;

        use super::{Entry, Kind};
        use std::ffi::{CStr, CString, OsString};
        use std::fs::File;
        use std::io;
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::ffi::{OsStrExt, OsStringExt};
        use std::path::{Path, PathBuf};

        pub(in super::super) struct Opened {
            file: File,
        }

        pub(in super::super) fn open(dir: &Path) -> io::Result<Opened> {
            use std::os::unix::fs::OpenOptionsExt;
            let file = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(dir)?;
            Ok(Opened { file })
        }

        impl Opened {
            /// What the open folder is now, or None once it is gone.
            #[cfg(target_os = "linux")]
            pub(in super::super) fn path(&self) -> Option<PathBuf> {
                let fd = PathBuf::from(format!("/proc/self/fd/{}", self.file.as_raw_fd()));
                let path = std::fs::read_link(fd).ok()?;
                // A removed folder reads "<path> (deleted)", which names nothing.
                path.is_absolute().then_some(path).filter(|p| p.is_dir())
            }

            #[cfg(target_os = "macos")]
            pub(in super::super) fn path(&self) -> Option<PathBuf> {
                let mut buf = vec![0u8; libc::PATH_MAX as usize];
                // SAFETY: F_GETPATH writes at most PATH_MAX bytes into `buf`, which holds
                // PATH_MAX bytes, for a descriptor this value owns.
                let r = unsafe {
                    libc::fcntl(self.file.as_raw_fd(), libc::F_GETPATH, buf.as_mut_ptr())
                };
                if r == -1 {
                    return None;
                }
                buf.truncate(buf.iter().position(|&b| b == 0)?);
                Some(PathBuf::from(OsString::from_vec(buf)))
            }

            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            pub(in super::super) fn path(&self) -> Option<PathBuf> {
                None
            }

            /// The open folder's entries, read from a copy of its descriptor, one at a time.
            pub(in super::super) fn read(&self) -> io::Result<Entries<'_>> {
                // SAFETY: dup of a descriptor this value owns; the copy is owned below.
                let copy = unsafe { libc::dup(self.file.as_raw_fd()) };
                if copy < 0 {
                    return Err(io::Error::last_os_error());
                }
                // SAFETY: `copy` is a fresh descriptor nothing else owns.
                let copy = unsafe { OwnedFd::from_raw_fd(copy) };
                // SAFETY: fdopendir takes the descriptor over when it succeeds (closedir closes it).
                let dir = unsafe { libc::fdopendir(copy.as_raw_fd()) };
                if dir.is_null() {
                    return Err(io::Error::last_os_error());
                }
                std::mem::forget(copy);
                Ok(Entries { dir, opened: self })
            }

            /// A regular file's size, read beside its folder's descriptor without following a link.
            pub(in super::super) fn size_of(&self, name: &std::ffi::OsStr) -> Option<u64> {
                let stat = self.stat(name)?;
                ((stat.st_mode & libc::S_IFMT) == libc::S_IFREG).then_some(stat.st_size as u64)
            }

            fn stat(&self, name: &std::ffi::OsStr) -> Option<libc::stat> {
                let name = CString::new(name.as_bytes()).ok()?;
                let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
                // SAFETY: `name` is NUL-terminated and `stat` has room for one stat.
                let r = unsafe {
                    libc::fstatat(
                        self.file.as_raw_fd(),
                        name.as_ptr(),
                        stat.as_mut_ptr(),
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                };
                // SAFETY: fstatat filled it when it returned 0.
                (r == 0).then(|| unsafe { stat.assume_init() })
            }
        }

        pub(in super::super) struct Entries<'a> {
            dir: *mut libc::DIR,
            opened: &'a Opened,
        }

        impl Drop for Entries<'_> {
            fn drop(&mut self) {
                // SAFETY: `dir` came from fdopendir and is closed once, here.
                unsafe { libc::closedir(self.dir) };
            }
        }

        impl Iterator for Entries<'_> {
            type Item = Entry;

            fn next(&mut self) -> Option<Entry> {
                loop {
                    // SAFETY: `dir` is open until drop; only this iterator reads it.
                    let entry = unsafe { libc::readdir(self.dir) };
                    if entry.is_null() {
                        return None;
                    }
                    // SAFETY: readdir's entry stays valid until the next readdir on `dir`.
                    let (name, d_type) = unsafe {
                        (
                            CStr::from_ptr((*entry).d_name.as_ptr()).to_bytes().to_vec(),
                            (*entry).d_type,
                        )
                    };
                    if name == b"." || name == b".." {
                        continue;
                    }
                    let name = OsString::from_vec(name);
                    let kind = match d_type {
                        libc::DT_DIR => Kind::Dir,
                        libc::DT_REG => Kind::File,
                        libc::DT_LNK => Kind::Symlink,
                        libc::DT_UNKNOWN => {
                            match self.opened.stat(&name).map(|s| s.st_mode & libc::S_IFMT) {
                                Some(libc::S_IFDIR) => Kind::Dir,
                                Some(libc::S_IFREG) => Kind::File,
                                Some(libc::S_IFLNK) => Kind::Symlink,
                                Some(_) => Kind::Other,
                                None => continue,
                            }
                        }
                        _ => Kind::Other,
                    };
                    return Some(Entry { name, kind });
                }
            }
        }
    }

    #[cfg(not(unix))]
    mod other {
        /// A listing reads by name: a folder swapped for a link mid-read would be read instead,
        /// so this platform never lists under roots (a peer's listing).
        pub(in super::super) const HOLDS_ITS_FOLDER: bool = false;

        use super::{Entry, Kind};
        use std::io;
        use std::path::{Path, PathBuf};

        pub(in super::super) struct Opened {
            dir: PathBuf,
        }

        pub(in super::super) fn open(dir: &Path) -> io::Result<Opened> {
            if !dir.is_dir() {
                return Err(io::Error::from_raw_os_error(libc::ENOTDIR));
            }
            Ok(Opened { dir: dir.to_path_buf() })
        }

        pub(in super::super) type Entries<'a> = Box<dyn Iterator<Item = Entry> + 'a>;

        impl Opened {
            pub(in super::super) fn path(&self) -> Option<PathBuf> {
                std::fs::canonicalize(&self.dir).ok()
            }

            pub(in super::super) fn read(&self) -> io::Result<Entries<'_>> {
                Ok(Box::new(std::fs::read_dir(&self.dir)?.filter_map(Result::ok).filter_map(|e| {
                    let t = e.file_type().ok()?;
                    let kind = if t.is_symlink() {
                        Kind::Symlink
                    } else if t.is_dir() {
                        Kind::Dir
                    } else if t.is_file() {
                        Kind::File
                    } else {
                        Kind::Other
                    };
                    Some(Entry { name: e.file_name(), kind })
                })))
            }

            pub(in super::super) fn size_of(&self, name: &std::ffi::OsStr) -> Option<u64> {
                std::fs::symlink_metadata(self.dir.join(name))
                    .ok()
                    .filter(|m| m.is_file())
                    .map(|m| m.len())
            }
        }
    }
}

/// A peer's top level: the folders it may start a chat in, each once (none inside another).
fn roots_page(ask: &Ask, roots: &[PathBuf], home: &Path) -> Value {
    let mut sorted: Vec<&PathBuf> = roots.iter().collect();
    sorted.sort();
    let mut kept: Vec<&PathBuf> = Vec::new();
    for root in sorted {
        if !kept.iter().any(|k| root.starts_with(k)) {
            kept.push(root);
        }
    }
    let rows = kept
        .iter()
        .map(|root| {
            let name =
                root.file_name().map_or_else(|| root.to_string_lossy(), |n| n.to_string_lossy());
            json!({"name": name, "path": root, "kind": "dir"})
        })
        .collect();
    let mut reply = page(ask, rows);
    reply.insert("path".into(), Value::Null);
    reply.insert("parent".into(), Value::Null);
    reply.insert("home".into(), json!(home));
    reply.insert("roots".into(), json!(roots));
    Value::Object(reply)
}

fn page(ask: &Ask, rows: Vec<Value>) -> Map<String, Value> {
    let total = rows.len();
    let offset = ask.offset.min(total);
    let end = offset.saturating_add(ask.limit).min(total);
    let shown: Vec<Value> =
        rows.into_iter().skip(offset).take(end.saturating_sub(offset)).collect();
    let mut reply = Map::new();
    reply.insert("entries".into(), Value::Array(shown));
    reply.insert("total".into(), json!(total));
    reply.insert("offset".into(), json!(offset));
    if end < total {
        reply.insert("nextOffset".into(), json!(end));
    }
    reply
}

/// `~` and `~/x` from the home folder; anything else must be absolute, and no `.` or `..` is
/// taken anywhere (the client moves up with the reply's `parent`).
fn expand(asked: &str, home: &Path) -> Result<PathBuf, RpcError> {
    let path = match asked.strip_prefix('~') {
        Some("") => home.to_path_buf(),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => PathBuf::from(asked),
    };
    let plain = path.is_absolute()
        && !asked.contains('\0')
        // The spelling asked, not `components()`, which drops a `.` inside a path unseen.
        && !path.to_string_lossy().split(['/', '\\']).any(|part| part == "." || part == "..");
    if !plain {
        return Err(refused("browse.path", "path must be absolute, with no . or .. in it"));
    }
    Ok(path)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn ask(path: &Path) -> Ask {
        Ask {
            path: Some(path.to_string_lossy().into_owned()),
            hidden: false,
            dirs_only: false,
            offset: 0,
            limit: PAGE_DEFAULT,
        }
    }

    fn later() -> Instant {
        Instant::now() + Duration::from_secs(30)
    }

    fn names(reply: &Value) -> Vec<String> {
        reply["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["name"].as_str().unwrap().to_owned())
            .collect()
    }

    fn reason(e: RpcError) -> String {
        e.data.unwrap()["reason"].as_str().unwrap().to_owned()
    }

    #[test]
    fn folders_come_first_and_hidden_entries_only_when_asked() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir(t.path().join("b-dir")).unwrap();
        std::fs::create_dir(t.path().join(".git")).unwrap();
        std::fs::write(t.path().join("a-file"), "secret contents").unwrap();
        std::fs::write(t.path().join(".env"), "TOKEN=1").unwrap();
        let reply = list(&ask(t.path()), None, SCAN_CAP, later()).unwrap();
        assert_eq!(names(&reply), ["b-dir", "a-file"]);
        assert_eq!(reply["entries"][1]["size"], json!(15));
        // Names, kinds and sizes only: nothing a file holds is in the reply.
        assert!(!reply.to_string().contains("secret contents"));
        let reply = list(&Ask { hidden: true, ..ask(t.path()) }, None, SCAN_CAP, later()).unwrap();
        assert_eq!(names(&reply), [".git", "b-dir", ".env", "a-file"]);
        let reply =
            list(&Ask { dirs_only: true, ..ask(t.path()) }, None, SCAN_CAP, later()).unwrap();
        assert_eq!(names(&reply), ["b-dir"]);
    }

    #[test]
    fn a_path_that_is_not_a_folder_name_is_refused_not_read_as_none() {
        for path in [json!(""), json!([]), json!(["/"]), json!(7), json!({"p": "/"}), json!(true)] {
            let Err(e) = Ask::from(&json!({"path": path, "hidden": true})) else {
                panic!("{path} was taken as a path or as none");
            };
            assert_eq!(reason(e), "browse.path", "{path}");
        }
        assert!(Ask::from(&json!({"path": null})).unwrap().path.is_none());
        assert!(Ask::from(&json!({})).unwrap().path.is_none());
    }

    #[test]
    fn a_path_with_dots_or_no_root_is_refused() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir(t.path().join("in")).unwrap();
        for asked in [
            format!("{}/in/..", t.path().display()),
            format!("{}/./in", t.path().display()),
            "in".into(),
            "~x".into(),
        ] {
            let e =
                list(&Ask { path: Some(asked.clone()), ..ask(t.path()) }, None, SCAN_CAP, later())
                    .unwrap_err();
            assert_eq!(reason(e), "browse.path", "{asked}");
        }
        let e = list(&ask(&t.path().join("in/missing")), None, SCAN_CAP, later()).unwrap_err();
        assert_eq!(reason(e), "browse.path");
        std::fs::write(t.path().join("f"), "").unwrap();
        let e = list(&ask(&t.path().join("f")), None, SCAN_CAP, later()).unwrap_err();
        assert_eq!(reason(e), "browse.not_directory");
    }

    #[test]
    fn a_link_is_reported_as_a_link_and_never_listed_through() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("root");
        let away = t.path().join("away");
        std::fs::create_dir_all(root.join("real")).unwrap();
        std::fs::create_dir_all(away.join("held-behind-the-link")).unwrap();
        std::os::unix::fs::symlink(&away, root.join("to-away")).unwrap();
        std::os::unix::fs::symlink(root.join("real"), root.join("to-real")).unwrap();
        std::os::unix::fs::symlink(t.path().join("gone"), root.join("dangling")).unwrap();
        std::fs::write(away.join("notes.txt"), "x").unwrap();
        std::fs::write(root.join("real/here.txt"), "x").unwrap();
        std::os::unix::fs::symlink(away.join("notes.txt"), root.join("to-away-file")).unwrap();
        std::os::unix::fs::symlink(root.join("real/here.txt"), root.join("to-here-file")).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let roots = [root.clone()];
        let reply = list(&ask(&root), Some(&roots), SCAN_CAP, later()).unwrap();
        let row = |name: &str| {
            reply["entries"].as_array().unwrap().iter().find(|e| e["name"] == name).unwrap().clone()
        };
        assert_eq!(row("to-away")["kind"], "symlink");
        assert_eq!(row("to-away")["target"], "dir");
        assert_eq!(row("to-away")["outside"], true, "a link out of the roots says so");
        assert_eq!(row("to-real")["target"], "dir");
        assert!(row("to-real").get("outside").is_none());
        assert_eq!(row("dangling")["target"], "missing");
        assert_eq!(row("to-away-file")["target"], "file");
        assert_eq!(
            row("to-away-file")["outside"],
            true,
            "a link to a file out of the roots says so"
        );
        assert!(row("to-here-file").get("outside").is_none());
        assert!(
            !reply.to_string().contains("held-behind-the-link"),
            "what a link names is not listed"
        );
        // Opening the link resolves it, and the roots still hold.
        let e = list(&ask(&root.join("to-away")), Some(&roots), SCAN_CAP, later()).unwrap_err();
        assert_eq!(reason(e), "browse.outside_roots");
        let inside = list(&ask(&root.join("to-real")), Some(&roots), SCAN_CAP, later()).unwrap();
        assert_eq!(inside["path"], json!(root.join("real")));
    }

    #[test]
    fn a_folder_is_listed_through_what_was_opened_and_judged_by_where_it_is_now() {
        let t = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(t.path()).unwrap();
        std::fs::create_dir_all(base.join("root/a/mine")).unwrap();
        std::fs::create_dir_all(base.join("away/theirs")).unwrap();
        let opened = opened::open(&base.join("root/a")).unwrap();
        // The path is swapped for a link out of the root after the open: the read is still `a`'s.
        std::fs::rename(base.join("root/a"), base.join("root/moved")).unwrap();
        std::os::unix::fs::symlink(base.join("away"), base.join("root/a")).unwrap();
        let names: Vec<String> =
            opened.read().unwrap().map(|e| e.name.to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["mine"]);
        assert_eq!(opened.path(), Some(base.join("root/moved")));
        // Moved out of the root: what it names now is outside, which the listing refuses.
        std::fs::rename(base.join("root/moved"), base.join("away/moved")).unwrap();
        assert_eq!(opened.path(), Some(base.join("away/moved")));
        // A link at the last name is never opened.
        let e = opened::open(&base.join("root/a")).err().unwrap();
        assert!(matches!(e.raw_os_error(), Some(libc::ELOOP) | Some(libc::ENOTDIR)), "{e}");
    }

    #[test]
    fn a_peer_lists_its_roots_and_nothing_outside_them() {
        let t = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(t.path()).unwrap();
        for d in ["p/one/deep", "p/one/deep/nested", "q", "other"] {
            std::fs::create_dir_all(base.join(d)).unwrap();
        }
        let roots = [base.join("p/one"), base.join("p/one/deep/nested"), base.join("q")];
        let reply =
            list(&Ask { path: None, ..ask(&base) }, Some(&roots), SCAN_CAP, later()).unwrap();
        assert_eq!(reply["path"], Value::Null);
        assert_eq!(names(&reply), ["one", "q"], "a root inside another is listed once, under it");
        let e = list(&ask(&base.join("other")), Some(&roots), SCAN_CAP, later()).unwrap_err();
        assert_eq!(reason(e), "browse.outside_roots");
        let e = list(&ask(&base.join("p")), Some(&roots), SCAN_CAP, later()).unwrap_err();
        assert_eq!(reason(e), "browse.outside_roots");
        let reply = list(&ask(&base.join("p/one")), Some(&roots), SCAN_CAP, later()).unwrap();
        assert_eq!(reply["parent"], Value::Null, "a root's parent is outside the roots");
        let reply = list(&ask(&base.join("p/one/deep")), Some(&roots), SCAN_CAP, later()).unwrap();
        assert_eq!(reply["parent"], json!(base.join("p/one")));
        assert_eq!(names(&reply), ["nested"]);
    }

    #[test]
    fn a_big_folder_stops_at_the_cap_or_the_deadline_and_says_which() {
        let t = tempfile::tempdir().unwrap();
        for i in 0..30 {
            std::fs::create_dir(t.path().join(format!("d{i:02}"))).unwrap();
        }
        let reply = list(&ask(t.path()), None, 10, later()).unwrap();
        assert_eq!(reply["truncated"], json!({"reason": "cap", "scanned": 10}));
        assert_eq!(reply["total"], 10);
        let reply = list(&ask(t.path()), None, SCAN_CAP, Instant::now()).unwrap();
        assert_eq!(reply["truncated"], json!({"reason": "deadline", "scanned": 0}));
        let reply = list(&ask(t.path()), None, SCAN_CAP, later()).unwrap();
        assert!(reply.get("truncated").is_none());
    }

    #[test]
    fn pages_hold_at_most_the_limit_and_name_the_next_offset() {
        let t = tempfile::tempdir().unwrap();
        for i in 0..5 {
            std::fs::create_dir(t.path().join(format!("d{i}"))).unwrap();
        }
        let first = list(&Ask { limit: 2, ..ask(t.path()) }, None, SCAN_CAP, later()).unwrap();
        assert_eq!(names(&first), ["d0", "d1"]);
        assert_eq!((first["total"].clone(), first["nextOffset"].clone()), (json!(5), json!(2)));
        let last =
            list(&Ask { limit: 2, offset: 4, ..ask(t.path()) }, None, SCAN_CAP, later()).unwrap();
        assert_eq!(names(&last), ["d4"]);
        assert!(last.get("nextOffset").is_none());
        let asked = Ask::from(&json!({"limit": 100_000})).unwrap();
        assert_eq!(asked.limit, PAGE_MAX);
    }
}
