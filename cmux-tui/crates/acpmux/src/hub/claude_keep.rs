//! A chat's Claude transcript, kept for as long as the chat. Part of `Hub`;
//! see `hub/mod.rs`.
//!
//! Claude Code resumes a conversation from its own store
//! (`<CLAUDE_CONFIG_DIR>/projects/<project>/<id>.jsonl`) and deletes the
//! transcripts older than its retention (`cleanupPeriodDays`, which managed
//! settings can set to a day). A chat left a day then lost its conversation:
//! the next start found nothing to `--resume`, so a fresh one started with
//! only the chat's plain text, and the agent forgot every tool call and
//! everything it had read.
//!
//! So each chat holds a hard link to its transcript in its own folder
//! (`<session dir>/claude/<project>/<id>.jsonl`). Claude deleting its name
//! leaves the file under ours, and the next start links it back. A link costs
//! no copy and sees every line Claude appends; where the two folders cannot
//! share a file (another volume), the kept file is a copy taken again at each
//! turn's end. Deleting the chat deletes its folder, and the transcript with it.

use super::*;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

impl Hub {
    /// Notes the Claude store of the profile `session` runs on, for an agent
    /// that did not come through `cold_start` (a pooled one, one adopted from
    /// its host after a restart): its turns keep the transcript too.
    pub(super) async fn note_claude_store(&self, session: &Session) {
        let meta = session.meta();
        let store = {
            let cfg = self.config.read().await;
            cfg.profile(&meta.harness)
                .filter(|p| p.kind == crate::config::HarnessKind::ClaudeStdio)
                .map(|p| meta.claude_store(&p.env))
        };
        *session.claude_store.lock().unwrap() = store;
    }

    /// Keeps the transcript of `session`'s running Claude after a turn, off
    /// the runtime's threads: a turn's end never waits on it.
    pub(super) fn keep_claude_transcript(&self, session: &Session) {
        let Some(store) = session.claude_store.lock().unwrap().clone() else { return };
        let Some(sid) = session.meta().agent_session_id else { return };
        let Some(dir) = self.store.session_dir(&session.id) else { return };
        let id = session.id.clone();
        tokio::task::spawn_blocking(move || {
            if let Err(e) = keep(&dir, &store, &sid) {
                tracing::warn!(session = %id, agent_session = %sid, "keeping the Claude transcript: {e}");
            }
        });
    }

    /// Before `session` starts Claude on `store` to resume (or fork)
    /// conversation `sid`: puts a transcript Claude deleted back, from this
    /// chat's folder or the one of the chat it forks, and keeps it when it is
    /// this chat's `own` (a fork keeps the conversation it starts, not its
    /// parent's: that one goes with the parent).
    pub(super) async fn restore_claude_transcript(
        &self,
        session: &Session,
        store: PathBuf,
        sid: String,
        own: bool,
    ) {
        let Some(dir) = self.store.session_dir(&session.id) else { return };
        let id = session.id.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let restored = restore(&dir, &store, &sid).unwrap_or_else(|e| {
                tracing::warn!(session = %id, agent_session = %sid, "putting the Claude transcript back: {e}");
                false
            });
            if restored && own && let Err(e) = keep(&dir, &store, &sid) {
                tracing::warn!(session = %id, agent_session = %sid, "keeping the Claude transcript: {e}");
            }
        })
        .await;
    }
}

/// The folder in a chat's session dir that holds its Claude transcript.
const KEPT_DIR: &str = "claude";
/// How much of a transcript's first record tells two files apart: its uuid and time come first.
const FIRST_RECORD_BYTES: u64 = 64 * 1024;
/// One keep or restore at a time in this process: a turn's keep and the next
/// start's restore of the same chat must not both append a recreated file's
/// lines, or share the staged name `replace` renames from.
static KEEPING: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Whether the store `store` holds Claude conversation `sid` with a prompt
/// in it: a file Claude wrote before any prompt reached it holds nothing
/// `--resume` can load.
pub(super) fn stored_with_prompt(store: &Path, sid: &str) -> bool {
    let Some(file) =
        crate::adopt::is_bare_id(sid).then(|| crate::adopt::find_claude(store, sid)).flatten()
    else {
        return false;
    };
    let Ok(file) = File::open(file) else { return false };
    BufReader::new(file).lines().map_while(Result::ok).any(|line| {
        serde_json::from_str::<Value>(&line).is_ok_and(|record| super::fork_at::is_prompt(&record))
    })
}

/// Keeps Claude session `sid`'s transcript in the store `store` under
/// `session_dir`, after a turn (or before a start) that may have moved it on.
///
/// When Claude wrote a new file under that name after deleting the old one
/// (a process still running when another one cleaned up), the new file holds
/// only the lines since: they are appended to the kept transcript, and
/// Claude's name points at the whole of it again.
pub(super) fn keep(session_dir: &Path, store: &Path, sid: &str) -> io::Result<()> {
    let _one = KEEPING.lock().unwrap_or_else(|e| e.into_inner());
    // A chat deleted meanwhile: its folder is not made again for a transcript nobody keeps.
    if !crate::adopt::is_bare_id(sid) || !session_dir.is_dir() {
        return Ok(());
    }
    let Some(live) = crate::adopt::find_claude(store, sid) else { return Ok(()) };
    let Some(project) = live.parent().and_then(Path::file_name) else { return Ok(()) };
    let kept = match kept_file(session_dir, sid) {
        Some(kept) => kept,
        None => {
            let kept = session_dir.join(KEPT_DIR).join(project).join(file_name(sid));
            fs::create_dir_all(kept.parent().unwrap_or(session_dir))?;
            return share(&live, &kept);
        }
    };
    if same_file(&live, &kept) {
        return Ok(());
    }
    let first = first_record(&live)?;
    if first == first_record(&kept)? {
        // The same conversation: Claude's file is the whole of it (a copy
        // kept on another volume is only as new as the last turn).
        return replace(&live, &kept);
    }
    if first.is_empty() || holds_line(&kept, &first)? {
        // Nothing written yet, or lines the kept file already has (a merge
        // whose rename failed): appending them would put them in twice, so
        // Claude's name only points at the kept file again.
        return if first.is_empty() { Ok(()) } else { replace(&kept, &live) };
    }
    // Claude started its file again: what it holds came after the kept lines.
    let mut whole = OpenOptions::new().append(true).open(&kept)?;
    if !ends_with_newline(&kept)? {
        io::Write::write_all(&mut whole, b"\n")?;
    }
    // Read to the end again after each copy: Claude may still append while
    // this runs, and a line written before the rename would be lost with it.
    let mut copied = 0;
    loop {
        let mut from = File::open(&live)?;
        from.seek(SeekFrom::Start(copied))?;
        let mut more = Vec::new();
        from.read_to_end(&mut more)?;
        if more.is_empty() {
            break;
        }
        copied += more.len() as u64;
        io::Write::write_all(&mut whole, &more)?;
    }
    drop(whole);
    replace(&kept, &live)
}

/// Puts session `sid`'s kept transcript back in the store `store` when Claude
/// deleted it, before a start resumes it, from this chat's folder or another
/// chat's in the same sessions folder (the chat a fork starts from). Answers
/// whether the store has it now.
///
/// Its time is set to now either way: a transcript with the time it was last
/// written can be past the retention, and the cleanup of the very process that
/// resumes it could delete it from under that process.
pub(super) fn restore(session_dir: &Path, store: &Path, sid: &str) -> io::Result<bool> {
    let _one = KEEPING.lock().unwrap_or_else(|e| e.into_inner());
    if !crate::adopt::is_bare_id(sid) {
        return Ok(false);
    }
    let live = match crate::adopt::find_claude(store, sid) {
        Some(live) => live,
        None => {
            let Some(kept) = kept_file(session_dir, sid).or_else(|| {
                let sessions = session_dir.parent()?;
                fs::read_dir(sessions).ok()?.flatten().find_map(|chat| kept_file(&chat.path(), sid))
            }) else {
                return Ok(false);
            };
            let Some(project) = kept.parent().and_then(Path::file_name) else { return Ok(false) };
            let live = store.join("projects").join(project).join(file_name(sid));
            fs::create_dir_all(live.parent().unwrap_or(store))?;
            share(&kept, &live)?;
            live
        }
    };
    OpenOptions::new().write(true).open(&live)?.set_modified(std::time::SystemTime::now())?;
    Ok(true)
}

fn file_name(sid: &str) -> String {
    format!("{sid}.jsonl")
}

/// `<session dir>/claude/<project>/<sid>.jsonl`, whichever project it was kept under.
fn kept_file(session_dir: &Path, sid: &str) -> Option<PathBuf> {
    let name = file_name(sid);
    fs::read_dir(session_dir.join(KEPT_DIR))
        .ok()?
        .flatten()
        .map(|project| project.path().join(&name))
        .find(|file| file.is_file())
}

/// Gives `to` the file at `from`: a hard link, or a copy across volumes.
fn share(from: &Path, to: &Path) -> io::Result<()> {
    match fs::hard_link(from, to) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(e),
        Err(_) => fs::copy(from, to).map(|_| ()),
    }
}

/// Points `to` at the file at `from`, replacing what `to` named.
fn replace(from: &Path, to: &Path) -> io::Result<()> {
    let staged = to.with_extension("jsonl.keeping");
    let _ = fs::remove_file(&staged);
    share(from, &staged)?;
    fs::rename(&staged, to)
}

#[cfg(unix)]
fn same_file(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// No file identity in stable std here: the kept file is taken again, which
/// a hard link makes a rename.
#[cfg(not(unix))]
fn same_file(_: &Path, _: &Path) -> bool {
    false
}

fn first_record(path: &Path) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    BufReader::new(File::open(path)?.take(FIRST_RECORD_BYTES)).read_until(b'\n', &mut line)?;
    Ok(line)
}

/// Whether a line of the file at `path` starts with `record` (a first record, cut at its bound).
fn holds_line(path: &Path, record: &[u8]) -> io::Result<bool> {
    let record = record.strip_suffix(b"\n").unwrap_or(record);
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    while reader.read_until(b'\n', &mut line)? > 0 {
        if line.starts_with(record) {
            return Ok(true);
        }
        line.clear();
    }
    Ok(false)
}

fn ends_with_newline(path: &Path) -> io::Result<bool> {
    let mut file = File::open(path)?;
    if file.metadata()?.len() == 0 {
        return Ok(true);
    }
    file.seek(SeekFrom::End(-1))?;
    let mut last = [0u8; 1];
    file.read_exact(&mut last)?;
    Ok(last[0] == b'\n')
}

#[cfg(test)]
mod tests {
    use super::*;

    const SID: &str = "01a1613b-5c32-7883-92f9-5859cbdac786";

    struct Dirs {
        root: PathBuf,
    }
    impl Dirs {
        fn new() -> Self {
            let root =
                std::env::temp_dir().join(format!("acpmux-claude-keep-{}", uuid::Uuid::now_v7()));
            fs::create_dir_all(root.join("store/projects/-Users-me-work")).unwrap();
            fs::create_dir_all(root.join("session")).unwrap();
            Self { root }
        }
        fn store(&self) -> PathBuf {
            self.root.join("store")
        }
        fn session(&self) -> PathBuf {
            self.root.join("session")
        }
        fn live(&self) -> PathBuf {
            self.store().join("projects/-Users-me-work").join(file_name(SID))
        }
    }
    impl Drop for Dirs {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn append(path: &Path, text: &str) {
        let mut file = OpenOptions::new().create(true).append(true).open(path).unwrap();
        io::Write::write_all(&mut file, text.as_bytes()).unwrap();
    }

    /// The bug: Claude's retention cleanup deleted a chat's transcript, and the
    /// next start found nothing to resume. The kept file brings all of it back.
    #[test]
    fn a_transcript_claude_deleted_is_put_back_whole() {
        let dirs = Dirs::new();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n{\"uuid\":\"b\"}\n");
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        // Lines Claude appends after the chat kept it are kept too.
        append(&dirs.live(), "{\"uuid\":\"c\"}\n");
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        fs::remove_file(dirs.live()).unwrap();

        assert!(restore(&dirs.session(), &dirs.store(), SID).unwrap());
        assert_eq!(
            fs::read_to_string(dirs.live()).unwrap(),
            "{\"uuid\":\"a\"}\n{\"uuid\":\"b\"}\n{\"uuid\":\"c\"}\n"
        );
        assert!(crate::adopt::claude_session_exists(&dirs.store(), SID));
    }

    /// Put back with an old time, the resuming process's own cleanup would delete it again.
    #[test]
    fn a_transcript_put_back_is_not_past_the_retention() {
        let dirs = Dirs::new();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n");
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(40 * 86_400);
        OpenOptions::new().write(true).open(dirs.live()).unwrap().set_modified(old).unwrap();
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        fs::remove_file(dirs.live()).unwrap();

        assert!(restore(&dirs.session(), &dirs.store(), SID).unwrap());
        let age =
            fs::metadata(dirs.live()).unwrap().modified().unwrap().elapsed().unwrap_or_default();
        assert!(age < std::time::Duration::from_secs(3_600), "restored with an old time: {age:?}");
    }

    /// A Claude still running when its transcript was deleted writes a new
    /// file with only the lines since: they join the kept ones, in order.
    #[test]
    fn lines_written_after_a_deletion_join_the_kept_transcript() {
        let dirs = Dirs::new();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n");
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        fs::remove_file(dirs.live()).unwrap();
        append(&dirs.live(), "{\"uuid\":\"b\"}\n");
        keep(&dirs.session(), &dirs.store(), SID).unwrap();

        assert_eq!(
            fs::read_to_string(dirs.live()).unwrap(),
            "{\"uuid\":\"a\"}\n{\"uuid\":\"b\"}\n"
        );
        // Kept again at the next turn, nothing is appended twice.
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        fs::remove_file(dirs.live()).unwrap();
        assert!(restore(&dirs.session(), &dirs.store(), SID).unwrap());
        assert_eq!(
            fs::read_to_string(dirs.live()).unwrap(),
            "{\"uuid\":\"a\"}\n{\"uuid\":\"b\"}\n"
        );
    }

    /// An app update in the middle of a chat's first long turn: the turn never
    /// finished, but Claude wrote it as it ran. The respawn resumes it instead
    /// of starting over with only the chat's text.
    #[test]
    fn a_first_turn_cut_short_resumes_what_claude_stored() {
        let dirs = Dirs::new();
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "claude",
            "family": "claude", "cwd": "/tmp", "status": "ready", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        meta.chat_store = Some(dirs.store());
        meta.agent_session_id = Some(SID.into());
        meta.claude_unstored = true;
        let profile: crate::config::HarnessProfile =
            serde_json::from_value(json!({"argv": ["claude"], "kind": "claude-stdio"})).unwrap();
        let refusal = super::super::new_request::claude_resume_refusal;

        assert_eq!(
            refusal(&meta, &profile, SID),
            Some("never finished a turn"),
            "Claude stored nothing"
        );
        // A start that died before its prompt reached Claude: nothing `--resume` can load.
        append(&dirs.live(), "{\"type\":\"queue-operation\"}\n");
        assert_eq!(refusal(&meta, &profile, SID), Some("never finished a turn"));
        append(
            &dirs.live(),
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one\"}}\n",
        );
        assert_eq!(refusal(&meta, &profile, SID), None);
    }

    /// A transcript still in the store but last written past the retention is
    /// made new before the resuming process's cleanup can take it.
    #[test]
    fn a_stored_transcript_past_the_retention_is_made_new_before_a_resume() {
        let dirs = Dirs::new();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n");
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(40 * 86_400);
        OpenOptions::new().write(true).open(dirs.live()).unwrap().set_modified(old).unwrap();

        assert!(restore(&dirs.session(), &dirs.store(), SID).unwrap());
        let age =
            fs::metadata(dirs.live()).unwrap().modified().unwrap().elapsed().unwrap_or_default();
        assert!(age < std::time::Duration::from_secs(3_600), "left with an old time: {age:?}");
    }

    /// A fork of a chat older than the retention: the transcript it forks is
    /// kept in that chat's folder, beside this one's.
    #[test]
    fn a_fork_puts_back_the_transcript_another_chat_kept() {
        let dirs = Dirs::new();
        let parent = dirs.root.join("parent");
        fs::create_dir_all(&parent).unwrap();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n");
        keep(&parent, &dirs.store(), SID).unwrap();
        fs::remove_file(dirs.live()).unwrap();

        assert!(restore(&dirs.session(), &dirs.store(), SID).unwrap());
        assert_eq!(fs::read_to_string(dirs.live()).unwrap(), "{\"uuid\":\"a\"}\n");
    }

    /// A chat deleted while its last turn's keep was on its way: its folder
    /// is not made again.
    #[test]
    fn a_deleted_chat_keeps_nothing() {
        let dirs = Dirs::new();
        append(&dirs.live(), "{\"uuid\":\"a\"}\n");
        fs::remove_dir_all(dirs.session()).unwrap();
        keep(&dirs.session(), &dirs.store(), SID).unwrap();
        assert!(!dirs.session().exists());
    }

    #[test]
    fn nothing_kept_and_nothing_stored_restores_nothing() {
        let dirs = Dirs::new();
        assert!(!restore(&dirs.session(), &dirs.store(), SID).unwrap());
        assert!(!dirs.live().exists());
    }
}
