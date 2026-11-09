//! Which classic save a run reads, what identifies a save, and whether
//! classic is running and may still save.
//!
//! Classic saves `~/Library/Application Support/cmux/session-<bundle>.json`
//! per channel, a `-previous` copy, and archives in `session-history/`. The
//! finder reads the channel saved last, whichever classic app that was;
//! equal save times go to this build's own channel. When no file of that
//! channel decodes, the next channel's are read. Classic debug builds are
//! never a source.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Classic's shipping channels, stable first.
pub const CHANNELS: [&str; 4] = [
    "com.cmuxterm.app",
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.rc",
    "com.cmuxterm.app.staging",
];

/// The classic session file a run read, and what tells a later save of it
/// apart. Its JSON is the ledger's `source`, as earlier builds wrote it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Source {
    /// The file read (the session file, its `-previous` copy, or an archive).
    pub path: String,
    /// The classic bundle id whose session it is.
    #[serde(rename = "bundleID")]
    pub bundle_id: String,
    pub size: u64,
    /// Its modification time, seconds since 1970.
    #[serde(rename = "modifiedAt")]
    pub modified_at: f64,
    /// The snapshot's own `createdAt`.
    #[serde(rename = "createdAt", default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
}

impl Source {
    /// Whether `other` is the same save of the same channel's session. The
    /// path is left out: the session file and its `-previous` copy of one
    /// save are the same state.
    pub fn is_same_save(&self, other: &Source) -> bool {
        self.bundle_id == other.bundle_id
            && match self.created_at {
                Some(created) => other.created_at == Some(created),
                None => self.size == other.size && self.modified_at == other.modified_at,
            }
    }
}

/// Seconds since 1970.
pub fn seconds(time: SystemTime) -> f64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(after) => after.as_secs_f64(),
        Err(before) => -before.duration().as_secs_f64(),
    }
}

/// Whether `path` is a regular file itself, not a link to one.
pub(crate) fn is_regular(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).ok()?.modified().ok()
}

/// Finds the classic session file a run reads, without reading it.
#[derive(Debug, Clone)]
pub struct Finder {
    /// The Application Support folder (classic's files are in its `cmux` folder).
    pub support: PathBuf,
    /// This build's bundle id; none prefers no channel.
    pub own_bundle_id: Option<String>,
}

impl Finder {
    pub fn new(support: &Path, own_bundle_id: Option<&str>) -> Self {
        Self { support: support.to_path_buf(), own_bundle_id: own_bundle_id.map(str::to_string) }
    }

    /// The classic channel this build replaces: its bundle id without a
    /// cmux NEXT suffix (`com.cmuxterm.app.nightly.cmux-next` is nightly).
    pub fn own_channel(&self) -> Option<&'static str> {
        let own = self.own_bundle_id.as_deref()?;
        CHANNELS.iter().rev().copied().find(|channel| {
            own == *channel || own.strip_prefix(channel).is_some_and(|rest| rest.starts_with('.'))
        })
    }

    /// The channel to read: the one whose session changed last.
    pub fn channel(&self) -> Option<&'static str> {
        self.channels_by_recency().into_iter().next()
    }

    /// Every channel classic saved, the newest save first; equal times put
    /// this build's own channel first, then stable before nightly, rc and
    /// staging. A channel whose session file is gone still counts by its
    /// `-previous` copy, then its newest archive. A cmux NEXT nightly
    /// installed beside the classic stable someone still uses brings
    /// stable's session, not an older classic nightly one.
    pub fn channels_by_recency(&self) -> Vec<&'static str> {
        let own = self.own_channel();
        let mut saved: Vec<(&'static str, SystemTime, isize)> = CHANNELS
            .iter()
            .enumerate()
            .filter_map(|(index, channel)| {
                let date = modified(&self.primary(channel))
                    .or_else(|| modified(&self.previous(channel)))
                    .or_else(|| modified(&self.newest_archive(channel)?))?;
                let rank = if Some(*channel) == own { -1 } else { index as isize };
                Some((*channel, date, rank))
            })
            .collect();
        saved.sort_by(|a, b| b.1.cmp(&a.1).then(a.2.cmp(&b.2)));
        saved.into_iter().map(|(channel, _, _)| channel).collect()
    }

    /// [`Finder::candidates`] of every channel in
    /// [`Finder::channels_by_recency`] order: a reader that cannot decode
    /// the newest channel's files goes on to the next.
    pub fn all_candidates(&self) -> Vec<(PathBuf, String)> {
        self.channels_by_recency()
            .into_iter()
            .flat_map(|channel| self.candidates(Some(channel)))
            .collect()
    }

    /// The files to try, best first, for `channel` (else [`Finder::channel`]):
    /// the session file, its `-previous` copy, then the newest archive.
    pub fn candidates(&self, channel: Option<&str>) -> Vec<(PathBuf, String)> {
        let Some(channel) =
            channel.map(str::to_string).or_else(|| self.channel().map(str::to_string))
        else {
            return Vec::new();
        };
        let mut files = vec![self.primary(&channel), self.previous(&channel)];
        files.extend(self.newest_archive(&channel));
        files
            .into_iter()
            .filter(|file| is_regular(file))
            .map(|file| (file, channel.clone()))
            .collect()
    }

    /// `channel`'s newest `session-history` archive.
    fn newest_archive(&self, channel: &str) -> Option<PathBuf> {
        let history = self.folder().join("session-history");
        let prefix = format!("session-{channel}-");
        // `session-<bundle>-<millis>-w..-p...json`; a longer bundle id (nightly vs stable) is another channel.
        let mut archived: Vec<(u64, String)> = std::fs::read_dir(&history)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().into_string().ok()?;
                let rest = name.strip_prefix(&prefix)?;
                if !name.ends_with(".json") || !rest.starts_with(|c: char| c.is_ascii_digit()) {
                    return None;
                }
                let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
                Some((digits.parse().unwrap_or(0), name))
            })
            .collect();
        archived.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        archived.into_iter().next().map(|(_, newest)| history.join(newest))
    }

    /// What identifies `path`'s current save; none when it cannot be read.
    pub fn source(&self, path: &Path, bundle_id: &str, created_at: Option<f64>) -> Option<Source> {
        let metadata = std::fs::metadata(path).ok()?;
        Some(Source {
            path: path.to_string_lossy().into_owned(),
            bundle_id: bundle_id.to_string(),
            size: metadata.len(),
            modified_at: metadata.modified().map(seconds).unwrap_or(0.0),
            created_at,
        })
    }

    /// Whether `path` is exactly one of the files a run of some classic
    /// channel reads (its session file, `-previous` copy or newest archive),
    /// a regular file, not a link, in classic's own folder. A caller may
    /// only ever name these for a backup or a resume.
    pub fn is_session_file(&self, path: &Path) -> bool {
        if !is_regular(path) {
            return false;
        }
        let folder = self.folder();
        let Some(parent) = path.parent().and_then(|parent| parent.canonicalize().ok()) else {
            return false;
        };
        let in_folder = [folder.clone(), folder.join("session-history")]
            .iter()
            .any(|allowed| allowed.canonicalize().is_ok_and(|allowed| allowed == parent));
        in_folder
            && CHANNELS
                .iter()
                .any(|channel| self.candidates(Some(channel)).iter().any(|(file, _)| file == path))
    }

    fn folder(&self) -> PathBuf {
        self.support.join("cmux")
    }

    fn primary(&self, channel: &str) -> PathBuf {
        self.folder().join(format!("session-{channel}.json"))
    }

    fn previous(&self, channel: &str) -> PathBuf {
        self.folder().join(format!("session-{channel}-previous.json"))
    }
}

/// Whether classic cmux is running now, so it may still save.
///
/// Classic writes a launch sentinel, `<state>/lifecycle/<bundle id>/running.sentinel`,
/// when it launches and removes it at the end of a clean quit. No sentinel
/// means classic quit: the update relaunch starts cmux NEXT seconds after
/// classic's quit save, and that save migrates. A sentinel with a save older
/// than [`RunningProbe::QUIET_SECONDS`] is a classic that crashed (it
/// autosaves every 8 s while it runs). No process scan.
#[derive(Debug, Clone)]
pub struct RunningProbe {
    /// Classic's state folder, holding `lifecycle/`.
    pub state_root: PathBuf,
}

impl RunningProbe {
    /// How long after its last save a classic that left its sentinel still counts as running.
    pub const QUIET_SECONDS: f64 = 90.0;

    /// Classic's state folder: `$XDG_STATE_HOME/cmux` when set, else `<home>/.local/state/cmux`.
    pub fn default_state_root(home: &Path, xdg_state_home: Option<&str>) -> PathBuf {
        match xdg_state_home.map(str::trim).filter(|xdg| !xdg.is_empty()) {
            Some(xdg) => {
                let expanded = match xdg.strip_prefix('~') {
                    Some(rest) if rest.is_empty() || rest.starts_with('/') => {
                        home.join(rest.trim_start_matches('/'))
                    }
                    _ => PathBuf::from(xdg),
                };
                expanded.join("cmux")
            }
            None => home.join(".local/state/cmux"),
        }
    }

    /// The sentinel classic of `channel` (a bundle id) keeps while it runs.
    pub fn sentinel(&self, channel: &str) -> PathBuf {
        self.state_root.join("lifecycle").join(channel).join("running.sentinel")
    }

    /// Whether the classic that wrote `source` is running at `now` (seconds
    /// since 1970), by its launch sentinel and a recent save.
    pub fn is_running(&self, source: &Source, now: f64) -> bool {
        self.sentinel(&source.bundle_id).exists() && now - source.modified_at < Self::QUIET_SECONDS
    }

    /// The lock files classic of `channel` (a bundle id) holds while it
    /// listens: `<socket>.lock` beside `~/.local/state/cmux/cmux[-<channel>].sock`,
    /// then beside the `/tmp` one (`tmp`). cmux NEXT uses the same socket
    /// names but never takes these locks.
    pub fn lock_paths(channel: &str, home: &Path, tmp: &Path) -> [PathBuf; 2] {
        let suffix = match channel {
            "com.cmuxterm.app.nightly" => "-nightly",
            "com.cmuxterm.app.rc" => "-rc",
            "com.cmuxterm.app.staging" => "-staging",
            _ => "",
        };
        let name = format!("cmux{suffix}.sock.lock");
        [home.join(".local/state/cmux").join(&name), tmp.join(name)]
    }

    /// Whether a process holds the `flock` on `path`, asked without
    /// blocking. A missing file, one another user owns, or a free lock is
    /// not held; a free lock is taken shared for an instant and let go.
    #[cfg(unix)]
    pub fn is_lock_held(path: &Path) -> bool {
        use std::os::unix::ffi::OsStrExt;
        let Ok(text) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return false };
        // SAFETY: `text` is a valid C string; the descriptor is closed below.
        let fd = unsafe {
            libc::open(
                text.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return false;
        }
        // SAFETY: `fd` is open, `info` is a zeroed stat buffer, and every
        // call below only reads it or changes its lock.
        let held = unsafe {
            let mut info: libc::stat = std::mem::zeroed();
            if libc::fstat(fd, &mut info) != 0 || info.st_uid != libc::getuid() {
                false
            } else if libc::flock(fd, libc::LOCK_SH | libc::LOCK_NB) == 0 {
                libc::flock(fd, libc::LOCK_UN);
                false
            } else {
                std::io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK)
            }
        };
        // SAFETY: `fd` was opened above and is closed once.
        unsafe { libc::close(fd) };
        held
    }

    /// Never held where there is no `flock`.
    #[cfg(not(unix))]
    pub fn is_lock_held(_path: &Path) -> bool {
        false
    }

    /// Whether the classic that saved `source` is open and may still save:
    /// it holds a lock beside its control socket, or its launch sentinel and
    /// a recent save say so. Classic builds older than the sentinel write
    /// none, which is why the lock is asked too.
    pub fn is_open(&self, source: &Source, home: &Path, tmp: &Path, now: f64) -> bool {
        Self::lock_paths(&source.bundle_id, home, tmp).iter().any(|path| Self::is_lock_held(path))
            || self.is_running(source, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::time::Duration;

    fn write(root: &Path, path: &str, modified: Option<u64>) -> PathBuf {
        let file = root.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "{}").unwrap();
        if let Some(seconds) = modified {
            File::options()
                .write(true)
                .open(&file)
                .unwrap()
                .set_modified(UNIX_EPOCH + Duration::from_secs(seconds))
                .unwrap();
        }
        file
    }

    /// The newest save wins whichever build reads it: a cmux NEXT nightly
    /// beside the classic stable someone still uses brings stable's session.
    #[test]
    fn the_newest_channel_is_read_and_a_tie_goes_to_the_own_channel() {
        let root = tempfile::tempdir().unwrap();
        write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(1));
        write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(2));
        write(root.path(), "support/cmux/session-com.cmuxterm.app.debug.json", Some(9));
        let support = root.path().join("support");
        for own in ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.rc"]
        {
            assert_eq!(
                Finder::new(&support, Some(own)).channel(),
                Some("com.cmuxterm.app.nightly")
            );
        }
        assert_eq!(
            Finder::new(&support, Some("com.cmuxterm.app")).channels_by_recency(),
            ["com.cmuxterm.app.nightly", "com.cmuxterm.app"]
        );
        // Equal times: the own channel, then stable before the others.
        write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(5));
        write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(5));
        write(root.path(), "support/cmux/session-com.cmuxterm.app.rc.json", Some(5));
        assert_eq!(
            Finder::new(&support, Some("com.cmuxterm.app.rc.cmux-next")).channels_by_recency(),
            ["com.cmuxterm.app.rc", "com.cmuxterm.app", "com.cmuxterm.app.nightly"]
        );
        assert_eq!(
            Finder::new(&support, None).channels_by_recency(),
            ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"]
        );
    }

    /// Every channel's files, the newest channel's first.
    #[test]
    fn all_candidates_go_channel_by_channel_newest_first() {
        let root = tempfile::tempdir().unwrap();
        let stable = write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(1));
        let nightly =
            write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(3));
        let copy = write(
            root.path(),
            "support/cmux/session-com.cmuxterm.app.nightly-previous.json",
            Some(2),
        );
        let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
        let all: Vec<PathBuf> = finder.all_candidates().into_iter().map(|(file, _)| file).collect();
        assert_eq!(all, [nightly, copy, stable]);
    }

    #[test]
    fn the_socket_lock_paths_follow_the_channel() {
        let home = Path::new("/Users/me");
        let tmp = Path::new("/tmp");
        assert_eq!(
            RunningProbe::lock_paths("com.cmuxterm.app", home, tmp),
            [home.join(".local/state/cmux/cmux.sock.lock"), PathBuf::from("/tmp/cmux.sock.lock")]
        );
        assert_eq!(
            RunningProbe::lock_paths("com.cmuxterm.app.nightly", home, tmp)[0],
            home.join(".local/state/cmux/cmux-nightly.sock.lock")
        );
        assert_eq!(
            RunningProbe::lock_paths("com.cmuxterm.app.rc", home, tmp)[1],
            PathBuf::from("/tmp/cmux-rc.sock.lock")
        );
        assert_eq!(
            RunningProbe::lock_paths("com.cmuxterm.app.staging", home, tmp)[1],
            PathBuf::from("/tmp/cmux-staging.sock.lock")
        );
    }

    /// A lock another open file description holds is held; a free one, a
    /// missing file and a link are not.
    #[cfg(unix)]
    #[test]
    fn a_held_socket_lock_says_classic_is_open() {
        use std::os::unix::io::AsRawFd;
        let root = tempfile::tempdir().unwrap();
        let lock = write(root.path(), "cmux.sock.lock", None);
        assert!(!RunningProbe::is_lock_held(&lock));
        assert!(!RunningProbe::is_lock_held(&root.path().join("missing.lock")));
        let holder = File::open(&lock).unwrap();
        // SAFETY: the descriptor is open for the call.
        assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        assert!(RunningProbe::is_lock_held(&lock));
        let link = root.path().join("link.lock");
        std::os::unix::fs::symlink(&lock, &link).unwrap();
        assert!(!RunningProbe::is_lock_held(&link));
        drop(holder);
        assert!(!RunningProbe::is_lock_held(&lock));
    }

    #[test]
    fn a_channel_with_only_its_previous_copy_is_still_found() {
        let root = tempfile::tempdir().unwrap();
        write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly-previous.json", Some(5));
        let finder = Finder::new(&root.path().join("support"), None);
        assert_eq!(finder.channel(), Some("com.cmuxterm.app.nightly"));
    }

    #[test]
    fn a_channel_with_only_an_archive_is_still_found() {
        let root = tempfile::tempdir().unwrap();
        let archive = write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app.nightly-9000-w1-p1.json",
            None,
        );
        let finder = Finder::new(&root.path().join("support"), None);
        assert_eq!(finder.channel(), Some("com.cmuxterm.app.nightly"));
        let files: Vec<PathBuf> =
            finder.candidates(None).into_iter().map(|(file, _)| file).collect();
        assert_eq!(files, [archive]);
    }

    /// The session file, its `-previous` copy, then the newest archive of the same channel only.
    #[test]
    fn candidates_are_the_file_its_copy_then_the_newest_archive() {
        let root = tempfile::tempdir().unwrap();
        let primary = write(root.path(), "support/cmux/session-com.cmuxterm.app.json", None);
        let previous =
            write(root.path(), "support/cmux/session-com.cmuxterm.app-previous.json", None);
        write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app-1000-w1-p1.json",
            None,
        );
        let newest = write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app-2000-w1-p1.json",
            None,
        );
        write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app.nightly-9000-w1-p1.json",
            None,
        );
        let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
        let files: Vec<PathBuf> =
            finder.candidates(Some("com.cmuxterm.app")).into_iter().map(|(file, _)| file).collect();
        assert_eq!(files, [primary.clone(), previous, newest.clone()]);
        assert!(finder.is_session_file(&primary) && finder.is_session_file(&newest));
        assert!(!finder.is_session_file(&root.path().join("support/cmux/other.json")));
        assert!(
            !finder.is_session_file(&root.path().join("elsewhere/session-com.cmuxterm.app.json"))
        );
    }

    /// Only the exact files a run reads count: not a link to another file,
    /// not an older archive, not a look-alike name, not a path through `..`.
    #[cfg(unix)]
    #[test]
    fn a_session_file_is_a_regular_file_a_run_reads_and_nothing_else() {
        let root = tempfile::tempdir().unwrap();
        let secret = write(root.path(), "elsewhere/secret.json", None);
        let primary = root.path().join("support/cmux/session-com.cmuxterm.app.json");
        std::fs::create_dir_all(primary.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&secret, &primary).unwrap();
        let older = write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app-1000-w1-p1.json",
            None,
        );
        write(
            root.path(),
            "support/cmux/session-history/session-com.cmuxterm.app-2000-w1-p1.json",
            None,
        );
        let look_alike = write(root.path(), "support/cmux/session-evil.json", None);
        let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
        assert!(!finder.is_session_file(&primary));
        assert!(finder.candidates(None).iter().all(|(file, _)| file != &primary));
        assert!(!finder.is_session_file(&older));
        assert!(!finder.is_session_file(&look_alike));
        let through = root.path().join(
            "support/cmux/session-history/../session-history/session-com.cmuxterm.app-2000-w1-p1.json",
        );
        assert!(!finder.is_session_file(&through));
    }

    #[test]
    fn the_same_save_is_its_created_at_else_its_size_and_date() {
        let source = |path: &str, size, created| Source {
            path: path.into(),
            bundle_id: "com.cmuxterm.app".into(),
            size,
            modified_at: 5.0,
            created_at: created,
        };
        assert!(source("/a", 1, Some(1.0)).is_same_save(&source("/a-previous", 99, Some(1.0))));
        assert!(!source("/a", 1, Some(1.0)).is_same_save(&source("/a", 1, Some(2.0))));
        assert!(source("/a", 1, None).is_same_save(&source("/b", 1, None)));
        assert!(!source("/a", 1, None).is_same_save(&source("/a", 2, None)));
    }

    #[test]
    fn classic_runs_while_its_sentinel_is_there_and_it_saved_lately() {
        let root = tempfile::tempdir().unwrap();
        let probe = RunningProbe { state_root: root.path().to_path_buf() };
        let source = Source {
            path: "/s".into(),
            bundle_id: "com.cmuxterm.app".into(),
            size: 1,
            modified_at: 1000.0,
            created_at: None,
        };
        assert!(!probe.is_running(&source, 1010.0));
        write(root.path(), "lifecycle/com.cmuxterm.app/running.sentinel", None);
        assert!(probe.is_running(&source, 1010.0));
        // An old save with a sentinel is a classic that crashed.
        assert!(!probe.is_running(&source, 1100.0));
        let home = Path::new("/Users/me");
        assert_eq!(RunningProbe::default_state_root(home, None), home.join(".local/state/cmux"));
        assert_eq!(RunningProbe::default_state_root(home, Some(" ~/st ")), home.join("st/cmux"));
        assert_eq!(RunningProbe::default_state_root(home, Some("/x")), PathBuf::from("/x/cmux"));
    }
}
