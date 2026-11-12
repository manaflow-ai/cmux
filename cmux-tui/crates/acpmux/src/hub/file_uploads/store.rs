//! Every finished upload's bytes are kept once, by their SHA-256, however many chats or prompts
//! carry them: `<uploads>/.store/<first two hex digits>/<sha256>`, owner-only and read-only. The
//! path a chat's upload was given, `<uploads>/<chat>/<upload id>/<name>`, stays where it was
//! and is another hard link to those bytes, so an agent opens it by path as before and every
//! reader (`prompt_uploads.rs`, `model_copies.rs`, `media_read.rs`) is unchanged.
//!
//! Leo, 2026-11-05: "am I just getting infinitely stored things? ... how are we storing them
//! these days? How should we store them?" The same screenshot pasted again used to be a second
//! copy on disk.
//!
//! - **Record.** Each upload's folder holds `.record`, `{name, source, at, sha256, size}`: the
//!   name it was shown as, the app it came from when the sender said, when it was stored, and
//!   which stored bytes it is.
//! - **References.** A stored file's references are its other hard links (its link count less
//!   the store's own), so the count can never drift from what is on disk, a crash included.
//! - **Deletion.** Stored bytes go once no upload links them ([`release`] when an upload folder
//!   goes, [`collect`] after each age sweep), and only then.
//! - **Kept chats.** A chat marked kept ([`set_kept`]: pinned or starred) is passed over by the
//!   age sweep, so its uploads, and the bytes they share, stay until the chat is deleted.
//!
//! Hard links need one file system for the uploads folder; where linking fails (another file
//! system, Windows) the upload keeps its own copy, as before.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The store's folder under the uploads folder. A dot name, so it is never a chat's
/// (`session_dir` takes letters, digits, `-` and `_` only).
pub(crate) const STORE: &str = ".store";
/// An upload folder's record of what it holds (module docs).
pub(crate) const RECORD: &str = ".record";
/// A chat folder's mark that it is kept (pinned or starred): the age sweep passes it over.
pub(crate) const KEEP: &str = ".keep";

/// Held while bytes go into the store or out of it, so a release never deletes stored bytes an
/// upload is being linked to, and two uploads of one file never both store it. Always taken
/// last, inside `IN_USE` and an upload's own lock.
static STORE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn store_lock() -> std::sync::MutexGuard<'static, ()> {
    STORE_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Whether `hash` is 64 lowercase hex digits (a SHA-256 this store names a file by).
pub(crate) fn is_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Where the bytes with SHA-256 `hash` are stored under uploads folder `root`; none for a string
/// that is not one.
pub(crate) fn stored_path(root: &Path, hash: &str) -> Option<PathBuf> {
    let shard = hash.get(..2).filter(|_| is_hash(hash))?;
    Some(root.join(STORE).join(shard).join(hash))
}

/// One upload's record (`.record`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Record {
    /// The name the upload was given and is shown as.
    pub name: String,
    /// The app it came from, when its sender said (`file_put_begin`'s `source`).
    pub source: Option<String>,
    /// When it was stored, Unix ms.
    pub at: u64,
    pub sha256: String,
    pub size: u64,
}

impl Record {
    fn to_json(&self) -> Value {
        json!({"name": self.name, "source": self.source, "at": self.at,
            "sha256": self.sha256, "size": self.size})
    }

    fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            name: value.get("name")?.as_str()?.to_owned(),
            source: value.get("source").and_then(Value::as_str).map(str::to_owned),
            at: value.get("at")?.as_u64()?,
            sha256: value.get("sha256")?.as_str().filter(|h| is_hash(h))?.to_owned(),
            size: value.get("size")?.as_u64()?,
        })
    }
}

/// The record in upload folder `dir`, if it has one (an upload from before the store has none).
pub(crate) fn record(dir: &Path) -> Option<Record> {
    let file = crate::config::private_state_file(&dir.join(RECORD)).ok()?;
    Record::from_json(&serde_json::from_reader(file).ok()?)
}

/// Lowercase hex SHA-256 of the file at `path`, read 1 MiB at a time.
pub(crate) fn sha256_of(path: &Path) -> std::io::Result<String> {
    use sha2::Digest;
    use std::io::Read;
    let mut file = crate::config::private_state_file(path).map_err(std::io::Error::other)?;
    let mut hash = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(buf.get(..n).unwrap_or_default());
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Puts the finished upload at `file` (`<root>/<chat>/<upload id>/<name>`) into the store and
/// writes its record: bytes the store already holds are linked in place of `file`'s own copy,
/// which goes; new bytes are linked into the store. `file`'s path never stops naming the bytes
/// (the swap is a rename). `sha256` is the file's hash when the caller already has it. Blocking.
pub(crate) fn adopt(
    root: &Path,
    file: &Path,
    sha256: Option<&str>,
    source: Option<&str>,
    now_ms: u64,
) -> anyhow::Result<Record> {
    let dir = file.parent().ok_or_else(|| anyhow::anyhow!("{} has no folder", file.display()))?;
    let name = file.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
    let size = std::fs::symlink_metadata(file)?.len();
    let hash = match sha256 {
        Some(h) if is_hash(h) => h.to_owned(),
        _ => sha256_of(file)?,
    };
    let record = Record { name, source: source.map(str::to_owned), at: now_ms, sha256: hash, size };
    #[cfg(unix)]
    link_into_store(root, file, &record)?;
    #[cfg(not(unix))]
    let _ = root;
    let bytes = serde_json::to_vec(&record.to_json())?;
    crate::agent_tools::write_private(&dir.join(RECORD), &bytes)?;
    Ok(record)
}

/// [`adopt`]'s link: `file` becomes a name of the stored bytes for `record.sha256`. A failure to
/// link (another file system) leaves `file` its own copy, which is no error.
#[cfg(unix)]
fn link_into_store(root: &Path, file: &Path, record: &Record) -> anyhow::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let stored = stored_path(root, &record.sha256)
        .ok_or_else(|| anyhow::anyhow!("not a sha256: {}", record.sha256))?;
    let shard = stored.parent().ok_or_else(|| anyhow::anyhow!("the store has no folder"))?;
    let _store = store_lock();
    crate::config::private_state_dir(&root.join(STORE))?;
    crate::config::private_state_dir(shard)?;
    let held = std::fs::symlink_metadata(&stored)
        .ok()
        .filter(|m| m.is_file() && m.len() == record.size && m.uid() == uid());
    if let Some(held) = held {
        let mine = std::fs::symlink_metadata(file)?;
        if mine.dev() == held.dev() && mine.ino() == held.ino() {
            return Ok(());
        }
        // The store has these bytes: name them at `file`'s path, then drop `file`'s copy, in one
        // rename so the path always names the bytes.
        let swap = file.with_file_name(format!(".link-{}", uuid::Uuid::now_v7()));
        match std::fs::hard_link(&stored, &swap) {
            Ok(()) => {
                if let Err(e) = std::fs::rename(&swap, file) {
                    let _ = std::fs::remove_file(&swap);
                    return Err(e.into());
                }
                Ok(())
            }
            Err(e) => {
                tracing::debug!("upload kept as its own copy: cannot link {}: {e}", file.display());
                Ok(())
            }
        }
    } else {
        // Something else at the stored name (not a regular file of this size): left alone; this
        // upload keeps its own copy.
        if std::fs::symlink_metadata(&stored).is_ok() {
            tracing::warn!("{} is not the stored upload it names; not linked", stored.display());
            return Ok(());
        }
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o400))?;
        if let Err(e) = std::fs::hard_link(file, &stored) {
            tracing::debug!("upload kept as its own copy: cannot link {}: {e}", stored.display());
        }
        Ok(())
    }
}

/// This process's user.
#[cfg(unix)]
fn uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

/// How many uploads link the stored bytes for `hash` under `root`: 0 when the store does not hold
/// them, or when only the store does.
pub(crate) fn references(root: &Path, hash: &str) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        stored_path(root, hash)
            .and_then(|p| std::fs::symlink_metadata(p).ok())
            .filter(std::fs::Metadata::is_file)
            .map_or(0, |m| m.nlink().saturating_sub(1))
    }
    #[cfg(not(unix))]
    {
        let _ = (root, hash);
        0
    }
}

/// The stored hashes the upload folders under `dir` hold (a chat folder's, or one upload's),
/// read before they are deleted so [`release`] can check just those.
pub(crate) fn hashes_under(dir: &Path) -> Vec<String> {
    if let Some(record) = record(dir) {
        return vec![record.sha256];
    }
    let entries = std::fs::read_dir(dir).into_iter().flatten().flatten();
    entries
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir() && !t.is_symlink()))
        .filter_map(|e| record(&e.path()))
        .map(|r| r.sha256)
        .collect()
}

/// Deletes the stored bytes for each of `hashes` that no upload links any more; answers how
/// many went. Blocking.
pub(crate) fn release(root: &Path, hashes: &[String]) -> usize {
    let _store = store_lock();
    hashes.iter().filter(|h| release_one(root, h)).count()
}

fn release_one(root: &Path, hash: &str) -> bool {
    let Some(path) = stored_path(root, hash) else { return false };
    let unlinked =
        std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file()) && references(root, hash) == 0;
    // A platform without link counts never deletes stored bytes (it never stores any).
    if cfg!(unix) && unlinked && std::fs::remove_file(&path).is_ok() {
        if let Some(shard) = path.parent() {
            let _ = std::fs::remove_dir(shard);
        }
        return true;
    }
    false
}

/// Deletes all stored bytes no upload links (after the age sweep, and for any left by a crash
/// between an upload's removal and its release); answers how many went. Blocking.
pub(crate) fn collect(root: &Path) -> usize {
    let store = root.join(STORE);
    let real_dirs = |dir: &Path| {
        std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| t.is_dir() && !t.is_symlink()))
            .map(|e| e.path())
            .collect::<Vec<_>>()
    };
    let mut hashes = Vec::new();
    for shard in real_dirs(&store) {
        for entry in std::fs::read_dir(&shard).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if is_hash(&name) {
                hashes.push(name);
            }
        }
    }
    release(root, &hashes)
}

/// Marks chat folder `chat` kept (pinned or starred) or not: a kept chat's uploads stay past the
/// age cap, until the chat is deleted. Blocking.
pub(crate) fn set_kept(chat: &Path, kept: bool) -> anyhow::Result<()> {
    let mark = chat.join(KEEP);
    if kept {
        crate::agent_tools::write_private(&mark, &[])
    } else {
        match std::fs::remove_file(&mark) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

/// Whether chat folder `chat` is marked kept ([`set_kept`]).
pub(crate) fn is_kept(chat: &Path) -> bool {
    std::fs::symlink_metadata(chat.join(KEEP)).is_ok_and(|m| m.is_file())
}

/// Whether the open upload `file` at `path`, which has more than one name, is linked only from
/// the store: its folder's record names stored bytes that are this very file. Anything else with
/// another name (a link someone made to a file outside the uploads) is refused.
#[cfg(unix)]
pub(crate) fn is_stored_link(root: &Path, path: &Path, file: &std::fs::File) -> bool {
    use std::os::unix::fs::MetadataExt;
    let Some(record) = path.parent().and_then(record) else { return false };
    let Some(stored) = stored_path(root, &record.sha256) else { return false };
    let (Ok(open), Ok(held)) = (file.metadata(), std::fs::symlink_metadata(&stored)) else {
        return false;
    };
    held.is_file() && open.dev() == held.dev() && open.ino() == held.ino()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;

    struct Rig {
        root: PathBuf,
    }

    impl Rig {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("acpmux-store-{}", uuid::Uuid::now_v7()));
            crate::config::private_state_dir(&root).unwrap();
            Self { root }
        }

        /// A finished upload of `bytes` named `name` in chat `chat`, put into the store.
        fn upload(&self, chat: &str, name: &str, bytes: &[u8]) -> (PathBuf, Record) {
            let file = self.root.join(chat).join(uuid::Uuid::now_v7().to_string()).join(name);
            crate::agent_tools::write_private(&file, bytes).unwrap();
            let record = adopt(&self.root, &file, None, Some("Safari"), 42).unwrap();
            (file, record)
        }
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn the_same_bytes_are_stored_once_however_often_they_are_uploaded() {
        let rig = Rig::new();
        let (a, ra) = rig.upload("chat-a", "image.png", b"same pixels");
        let (b, rb) = rig.upload("chat-a", "image.png", b"same pixels");
        let (c, rc) = rig.upload("chat-b", "Screenshot 3.png", b"same pixels");
        let (d, rd) = rig.upload("chat-b", "image.png", b"other pixels");
        assert_eq!(ra.sha256, rb.sha256);
        assert_eq!(ra.sha256, rc.sha256);
        assert_ne!(ra.sha256, rd.sha256);
        let ino = |p: &Path| std::fs::metadata(p).unwrap().ino();
        assert_eq!(ino(&a), ino(&b));
        assert_eq!(ino(&a), ino(&c));
        assert_ne!(ino(&a), ino(&d));
        let stored = stored_path(&rig.root, &ra.sha256).unwrap();
        assert_eq!(ino(&stored), ino(&a));
        assert_eq!(std::fs::read(&stored).unwrap(), b"same pixels");
        // Two stored files: one per distinct content.
        let shards = std::fs::read_dir(rig.root.join(STORE)).unwrap().flatten();
        let held: usize = shards.map(|s| std::fs::read_dir(s.path()).unwrap().count()).sum();
        assert_eq!(held, 2);
        // Stored bytes are read-only, so no upload's agent changes another's file.
        assert_eq!(std::fs::metadata(&stored).unwrap().mode() & 0o777, 0o400);
    }

    #[test]
    fn each_upload_keeps_its_own_record() {
        let rig = Rig::new();
        let (a, ra) = rig.upload("chat-a", "image.png", b"x");
        let (c, rc) = rig.upload("chat-b", "Screenshot 3.png", b"x");
        assert_eq!(record(a.parent().unwrap()).unwrap(), ra);
        assert_eq!(record(c.parent().unwrap()).unwrap(), rc);
        assert_eq!(rc.name, "Screenshot 3.png");
        assert_eq!(rc.source.as_deref(), Some("Safari"));
        assert_eq!(rc.at, 42);
        assert_eq!(rc.size, 1);
        assert_eq!(rc.sha256, sha256_of(&c).unwrap());
    }

    #[test]
    fn references_count_the_uploads_that_link_the_bytes() {
        let rig = Rig::new();
        let (a, r) = rig.upload("chat-a", "image.png", b"pixels");
        assert_eq!(references(&rig.root, &r.sha256), 1);
        let (b, _) = rig.upload("chat-b", "image.png", b"pixels");
        let (c, _) = rig.upload("chat-c", "image.png", b"pixels");
        assert_eq!(references(&rig.root, &r.sha256), 3);
        // Putting the same upload in again adds nothing.
        adopt(&rig.root, &a, Some(&r.sha256), None, 43).unwrap();
        assert_eq!(references(&rig.root, &r.sha256), 3);
        std::fs::remove_dir_all(b.parent().unwrap()).unwrap();
        assert_eq!(references(&rig.root, &r.sha256), 2);
        std::fs::remove_dir_all(c.parent().unwrap()).unwrap();
        assert_eq!(references(&rig.root, &r.sha256), 1);
    }

    #[test]
    fn stored_bytes_go_only_once_no_chat_links_them() {
        let rig = Rig::new();
        let (a, r) = rig.upload("chat-a", "image.png", b"pixels");
        let (b, _) = rig.upload("chat-b", "image.png", b"pixels");
        let stored = stored_path(&rig.root, &r.sha256).unwrap();
        // Chat A is deleted: chat B still links the bytes, so they stay, and B's path still
        // opens them.
        let hashes = hashes_under(&rig.root.join("chat-a"));
        assert_eq!(hashes, vec![r.sha256.clone()]);
        std::fs::remove_dir_all(rig.root.join("chat-a")).unwrap();
        assert_eq!(release(&rig.root, &hashes), 0);
        assert!(stored.exists() && !a.exists());
        assert_eq!(std::fs::read(&b).unwrap(), b"pixels");
        // Chat B goes too: nothing links them, and they go.
        let hashes = hashes_under(&rig.root.join("chat-b"));
        std::fs::remove_dir_all(rig.root.join("chat-b")).unwrap();
        assert_eq!(release(&rig.root, &hashes), 1);
        assert!(!stored.exists());
        assert!(!stored.parent().unwrap().exists(), "an emptied shard folder goes");
    }

    #[test]
    fn collect_deletes_only_what_nothing_links() {
        let rig = Rig::new();
        let (_, kept) = rig.upload("chat-a", "a.png", b"kept");
        let (gone, orphan) = rig.upload("chat-b", "b.png", b"orphan");
        // A crash between an upload's removal and its release left stored bytes behind.
        std::fs::remove_dir_all(gone.parent().unwrap()).unwrap();
        // Something the store did not name is never deleted.
        let stray = rig.root.join(STORE).join("zz").join("notes.txt");
        crate::agent_tools::write_private(&stray, b"x").unwrap();
        assert_eq!(collect(&rig.root), 1);
        assert!(stored_path(&rig.root, &kept.sha256).unwrap().exists());
        assert!(!stored_path(&rig.root, &orphan.sha256).unwrap().exists());
        assert!(stray.exists());
        assert_eq!(collect(&rig.root), 0);
    }

    #[test]
    fn an_uploads_path_stays_the_one_the_agent_was_given() {
        let rig = Rig::new();
        let (first, _) = rig.upload("chat-a", "image.png", b"pixels");
        let given = first.clone();
        // The same bytes again in another chat: the first path is untouched and still opens.
        let (second, _) = rig.upload("chat-b", "image.png", b"pixels");
        assert_eq!(std::fs::read(&given).unwrap(), b"pixels");
        assert_eq!(std::fs::read(&second).unwrap(), b"pixels");
        // Its folder holds the file and its record, and no swap file was left beside it.
        let mut names: Vec<String> = std::fs::read_dir(second.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, vec![RECORD.to_owned(), "image.png".to_owned()]);
        // The first chat goes; the second's path still opens the bytes.
        let hashes = hashes_under(&rig.root.join("chat-a"));
        std::fs::remove_dir_all(rig.root.join("chat-a")).unwrap();
        release(&rig.root, &hashes);
        assert_eq!(std::fs::read(&second).unwrap(), b"pixels");
    }

    #[test]
    fn a_stored_link_is_told_from_a_link_to_another_file() {
        let rig = Rig::new();
        let (a, _) = rig.upload("chat-a", "image.png", b"pixels");
        let _ = rig.upload("chat-b", "image.png", b"pixels");
        let open = |p: &Path| crate::config::private_state_file(p).unwrap();
        assert!(is_stored_link(&rig.root, &a, &open(&a)));
        // A file linked in from outside the uploads, under a forged record, is not the stored
        // bytes the record names.
        let elsewhere = rig.root.with_extension("outside");
        let outside = elsewhere.join("secret.txt");
        crate::agent_tools::write_private(&outside, b"secret").unwrap();
        let planted = rig.root.join("chat-c").join(uuid::Uuid::now_v7().to_string());
        crate::config::private_state_dir(&planted).unwrap();
        std::fs::hard_link(&outside, planted.join("x.txt")).unwrap();
        std::fs::copy(a.parent().unwrap().join(RECORD), planted.join(RECORD)).unwrap();
        assert!(!is_stored_link(&rig.root, &planted.join("x.txt"), &open(&outside)));
        std::fs::remove_dir_all(&elsewhere).unwrap();
    }

    #[test]
    fn a_kept_chat_is_marked_and_unmarked() {
        let rig = Rig::new();
        let chat = rig.root.join("chat-a");
        assert!(!is_kept(&chat));
        set_kept(&chat, true).unwrap();
        assert!(is_kept(&chat));
        set_kept(&chat, false).unwrap();
        assert!(!is_kept(&chat));
        set_kept(&chat, false).unwrap();
    }
}
