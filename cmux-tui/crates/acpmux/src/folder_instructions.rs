//! The cross-harness fallback for a folder's agent instructions.
//!
//! Each harness reads its own instruction file from the session folder: Claude
//! `CLAUDE.md`, Codex `AGENTS.md`, Gemini `GEMINI.md`. A folder set up for one
//! harness is opened with another all the time (a Codex repository in a Claude
//! chat), and that agent then never sees what the folder says about itself
//! (Leo, 2026-11-05: "you should be able to see all that and then be able to do
//! stuff based off that").
//!
//! When the session's harness has none of its own files in the folder, the first
//! other instruction file found ([`CANDIDATES`], `AGENTS.md` first) goes to the
//! session as one more first-turn context part, on the same user-context channel
//! and exactly once, like cmux's own guidance (`context_inventory::append_snapshot`).
//! A harness that has its own file gets nothing: it already reads it. The text is
//! the folder's own, which the harness would have read had it been named for it,
//! so this widens nothing a native file could not already do.

use std::path::Path;

use crate::context_inventory::{ContextPart, estimated_tokens};

/// The part's `source`; `append_snapshot` delivers it.
pub const SOURCE: &str = "cmux-folder";

/// The instruction file a harness `family` reads first, the one a new file is made as.
pub(crate) fn own_file(family: &str) -> &'static str {
    native(family).first().copied().unwrap_or("AGENTS.md")
}

/// The file a fact learned in a chat of `family` in `cwd` goes to (`memory_inbox.rs`): the
/// harness's own file when the folder has one, else the file this fallback carries to it, else
/// a new file of the harness's own (`AGENTS.md` for a harness with none).
pub(crate) fn learned_target(family: &str, cwd: &Path) -> &'static str {
    let own = native(family);
    // A personal file (`CLAUDE.local.md`, `AGENTS.override.md`) is not the shared one.
    let shared = |name: &&&str| !name.contains(".local.") && !name.contains(".override.");
    if let Some(name) = own.iter().filter(shared).find(|name| open_beneath(cwd, name).is_some()) {
        return name;
    }
    CANDIDATES
        .iter()
        .filter(|name| !own.contains(name) && name.ends_with(".md"))
        .find(|name| readable(cwd, name).is_some())
        .copied()
        .unwrap_or_else(|| own_file(family))
}

/// The most of a file that goes to the agent; the rest is cut with a note.
const MAX_BYTES: usize = 32 * 1024;

/// The files a folder may carry instructions in, in the order the fallback
/// takes them: `AGENTS.md` is the cross-harness convention, the others are one
/// harness's or editor's own.
const CANDIDATES: &[&str] =
    &["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".github/copilot-instructions.md", ".cursorrules"];

/// The files a harness family reads itself from the session folder. A family
/// not listed reads none, so any candidate is carried to it.
fn native(family: &str) -> &'static [&'static str] {
    match family {
        "claude" => &["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"],
        "codex" => &["AGENTS.md", "AGENTS.override.md"],
        "gemini" => &["GEMINI.md"],
        // opencode reads AGENTS.md, and CLAUDE.md when there is none.
        "opencode" => &["AGENTS.md", "CLAUDE.md"],
        _ => &[],
    }
}

/// `rel` (one or more `/`-separated names) opened beneath `root` without following a link
/// at any step: each folder is opened with `O_NOFOLLOW` from the one before it, so a
/// linked `.github` or a swapped component never leads out of the session folder.
#[cfg(unix)]
pub(crate) fn open_beneath(root: &Path, rel: &str) -> Option<std::fs::File> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};

    let (dir, name) = folder_beneath(root, rel)?;
    // SAFETY: `dir` is an open descriptor and `name` is NUL-terminated; O_NONBLOCK keeps a fifo
    // from blocking the open.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return None;
    }
    // SAFETY: `fd` was just opened and nothing else owns it.
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    // A regular file only: never a fifo or a device.
    file.metadata().ok()?.is_file().then_some(file)
}

/// The folder `rel`'s last name is in, opened beneath `root` without following a link at any
/// step, and that last name.
#[cfg(unix)]
fn folder_beneath(root: &Path, rel: &str) -> Option<(std::os::fd::OwnedFd, std::ffi::CString)> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    let mut folders: Vec<&str> = rel.split('/').collect();
    let last = folders.pop()?;
    // The session folder itself may be a link (`/tmp` on macOS); it must be a directory, and
    // O_NONBLOCK keeps a fifo swapped in for it from blocking the open.
    let root = CString::new(root.as_os_str().as_encoded_bytes()).ok()?;
    // SAFETY: `root` is NUL-terminated.
    let fd = unsafe {
        libc::openat(
            libc::AT_FDCWD,
            root.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return None;
    }
    // SAFETY: `fd` was just opened and nothing else owns it.
    let mut dir = unsafe { OwnedFd::from_raw_fd(fd) };
    for name in folders {
        let name = CString::new(name).ok()?;
        // SAFETY: `dir` is an open descriptor and `name` is NUL-terminated.
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return None;
        }
        // SAFETY: `fd` was just opened and nothing else owns it.
        dir = unsafe { OwnedFd::from_raw_fd(fd) };
    }
    Some((dir, CString::new(last).ok()?))
}

/// The temporary copy's mode until it takes the file's own.
#[cfg(unix)]
const OWNER_ONLY: libc::c_uint = 0o600;

/// What a file was when it was read: [`replace_beneath`] replaces it only while it still is.
#[cfg(unix)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stamp {
    dev: libc::dev_t,
    ino: libc::ino_t,
    size: libc::off_t,
    mtime: libc::time_t,
    mtime_nsec: libc::c_long,
}

#[cfg(unix)]
impl Stamp {
    fn of(st: &libc::stat) -> Self {
        Self {
            dev: st.st_dev,
            ino: st.st_ino,
            size: st.st_size,
            mtime: st.st_mtime,
            mtime_nsec: st.st_mtime_nsec,
        }
    }
}

/// Elsewhere nothing is read for an edit, so nothing is stamped.
#[cfg(not(unix))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stamp;

/// The whole of `rel` beneath `root` and its [`Stamp`], for an edit: `None` only when there is
/// no such file. Any other failure (no permission, a read error, a non-file, more than `max`
/// bytes, a size that changed while it was read) is an error, so an edit never takes a file it
/// could not read for an empty one.
#[cfg(unix)]
pub(crate) fn read_whole_beneath(
    root: &Path,
    rel: &str,
    max: u64,
) -> Result<Option<(Vec<u8>, Stamp)>, String> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};

    let (dir, name) = folder_beneath(root, rel)
        .ok_or_else(|| format!("{rel}'s folder could not be opened in {}", root.display()))?;
    // SAFETY: `dir` is open and `name` is NUL-terminated; O_NONBLOCK keeps a fifo from blocking.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let e = std::io::Error::last_os_error();
        return match e.raw_os_error() {
            Some(libc::ENOENT) => Ok(None),
            _ => Err(format!("{rel} could not be read: {e}")),
        };
    }
    // SAFETY: `fd` was just opened and nothing else owns it.
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    // SAFETY: a zeroed `stat` is a valid out-parameter.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `file` is open and `st` is writable.
    if unsafe { libc::fstat(file.as_raw_fd(), &mut st) } != 0 {
        return Err(format!("{rel}: {}", std::io::Error::last_os_error()));
    }
    if st.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(format!("{rel} is not a regular file; edit it by hand"));
    }
    let size = u64::try_from(st.st_size).unwrap_or(u64::MAX);
    if size > max {
        return Err(format!("{rel} is over {} KB; edit it by hand", max / 1024));
    }
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut std::io::Read::take(&file, max.saturating_add(1)), &mut bytes)
        .map_err(|e| format!("{rel} could not be read: {e}"))?;
    if u64::try_from(bytes.len()).ok() != Some(size) {
        return Err(format!("{rel} changed while it was read; try again"));
    }
    Ok(Some((bytes, Stamp::of(&st))))
}

/// Replaces `rel` beneath `root` with `bytes` all at once (`memory_inbox.rs`): written to a new
/// file beside it, synced, then renamed over it, so a crash or a full disk leaves the old file
/// whole. It keeps the old file's mode (`0644` for a new one); a link, a folder or any other
/// non-file at `rel`, or a linked folder on the way, is refused, never replaced. `read` is
/// the [`Stamp`] it was read at, None when there was no file: a file that changed or appeared
/// since is left as it is.
#[cfg(unix)]
pub(crate) fn replace_beneath(
    root: &Path,
    rel: &str,
    bytes: &[u8],
    read: Option<Stamp>,
) -> Result<(), String> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd as _, FromRawFd as _};

    let (dir, name) = folder_beneath(root, rel)
        .ok_or_else(|| format!("{rel}'s folder could not be opened in {}", root.display()))?;
    // SAFETY: a zeroed `stat` is a valid out-parameter.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `dir` is open, `name` is NUL-terminated and `st` is writable.
    let found = unsafe {
        libc::fstatat(dir.as_raw_fd(), name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW)
    } == 0;
    let now = found.then(|| Stamp::of(&st));
    if now != read {
        return Err(format!("{rel} changed while it was being edited; try again"));
    }
    let mode = if found {
        if st.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Err(format!("{rel} is not a regular file; edit it by hand"));
        }
        st.st_mode & 0o7777
    } else {
        0o644
    };
    let tmp =
        CString::new(format!(".{}.cmux-{}.tmp", name.to_string_lossy(), uuid::Uuid::now_v7()))
            .map_err(|e| e.to_string())?;
    // SAFETY: as above; O_EXCL makes a new file, never an existing one or a link's target.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            tmp.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            OWNER_ONLY,
        )
    };
    if fd < 0 {
        return Err(format!("{rel}: {}", std::io::Error::last_os_error()));
    }
    // SAFETY: `fd` was just opened and nothing else owns it.
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let written = std::io::Write::write_all(&mut file, bytes)
        .and_then(|()| {
            // SAFETY: `file` is open; `mode` is a permission mask.
            if unsafe { libc::fchmod(file.as_raw_fd(), mode) } == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        })
        .and_then(|()| file.sync_all());
    let dirfd = dir.as_raw_fd();
    // SAFETY: as above; only ever called while the temporary name holds our own copy.
    let drop_tmp = || unsafe { libc::unlinkat(dirfd, tmp.as_ptr(), 0) };
    if let Err(e) = written {
        drop_tmp();
        return Err(format!("{rel}: {e}"));
    }
    // Our copy as written: after a swap back, the temporary name is removed only while it
    // still holds exactly this.
    // SAFETY: `file` is open and `st` is writable.
    if unsafe { libc::fstat(file.as_raw_fd(), &mut st) } != 0 {
        let e = std::io::Error::last_os_error();
        drop_tmp();
        return Err(format!("{rel}: {e}"));
    }
    let ours = Stamp::of(&st);
    #[cfg(test)]
    swap_hook(&name, "before");
    let changed = || format!("{rel} changed while it was being edited; try again");
    // A version someone saved meanwhile, left under the temporary name rather than removed.
    let kept = || {
        format!(
            "{rel} changed while it was being edited; the other version is kept as {}",
            tmp.to_string_lossy()
        )
    };
    let at_tmp = |st: &mut libc::stat| {
        // SAFETY: as above.
        (unsafe { libc::fstatat(dirfd, tmp.as_ptr(), st, libc::AT_SYMLINK_NOFOLLOW) } == 0)
            .then(|| Stamp::of(st))
    };
    match read {
        // No file was read: made only while there is still none.
        None => match rename(dirfd, &tmp, &name, Rename::NoReplace) {
            Ok(()) => Ok(()),
            Err(e) => {
                drop_tmp();
                Err(if e.raw_os_error() == Some(libc::EEXIST) {
                    changed()
                } else {
                    format!("{rel}: {e}")
                })
            }
        },
        // The two swap at once; when the one swapped out is not the file read (an editor saved
        // or appended meanwhile), they swap back. Nothing but our own copy is ever removed: a
        // version saved over ours between the two swaps stays under the temporary name.
        Some(read) => match rename(dirfd, &tmp, &name, Rename::Exchange) {
            Ok(()) => {
                if at_tmp(&mut st) == Some(read) {
                    drop_tmp();
                    return Ok(());
                }
                #[cfg(test)]
                swap_hook(&name, "after");
                if rename(dirfd, &tmp, &name, Rename::Exchange).is_err() {
                    return Err(kept());
                }
                if at_tmp(&mut st) == Some(ours) {
                    drop_tmp();
                    return Err(changed());
                }
                Err(kept())
            }
            Err(e) => {
                drop_tmp();
                Err(format!("{rel}: {e}"))
            }
        },
    }
}

/// How [`rename`] treats a file already at the new name.
#[cfg(unix)]
#[derive(Clone, Copy)]
enum Rename {
    /// Refused when there is one.
    NoReplace,
    /// Swapped with it, both in one step.
    Exchange,
}

/// `from` renamed to `to`, both in `dir`, in one step that either refuses an existing `to`
/// or swaps with it. A system with neither refuses (`ENOSYS`): a plain rename could lose an
/// edit made meanwhile.
#[cfg(unix)]
fn rename(
    dir: std::os::fd::RawFd,
    from: &std::ffi::CStr,
    to: &std::ffi::CStr,
    how: Rename,
) -> std::io::Result<()> {
    #[cfg(target_os = "linux")]
    let done = {
        let flags = match how {
            Rename::NoReplace => libc::RENAME_NOREPLACE,
            Rename::Exchange => libc::RENAME_EXCHANGE,
        };
        // SAFETY: both names are NUL-terminated and beneath the open folder `dir`; the raw call
        // is used because not every C library wraps renameat2.
        let r = unsafe {
            libc::syscall(libc::SYS_renameat2, dir, from.as_ptr(), dir, to.as_ptr(), flags)
        };
        r == 0
    };
    #[cfg(target_vendor = "apple")]
    let done = {
        let flags = match how {
            Rename::NoReplace => libc::RENAME_EXCL,
            Rename::Exchange => libc::RENAME_SWAP,
        };
        // SAFETY: as above.
        let r = unsafe { libc::renameatx_np(dir, from.as_ptr(), dir, to.as_ptr(), flags) };
        r == 0
    };
    #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
    let done = {
        let _ = how;
        return Err(std::io::Error::from_raw_os_error(libc::ENOSYS));
    };
    if done { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

/// A test's hook: given the file's name and the window.
#[cfg(test)]
type SwapFn = Box<dyn FnMut(&str, &str)>;
/// Each `(name, window)` a hook was reached in.
#[cfg(test)]
type Reached = std::rc::Rc<std::cell::RefCell<Vec<(String, String)>>>;

#[cfg(test)]
thread_local! {
    /// A test's write into the windows of a replace: `before` the swap, and `after` a swap that
    /// found a change, before the swap back. Given the file's name and the window.
    ///
    /// One per test thread, not per process: the harness runs tests on parallel threads, and a
    /// process-wide hook let one test's hook replace or clear another's before its replace ran,
    /// so the race it forced never happened. A replace on another thread never sees it, which a
    /// test catches through [`SwapHook::reached`].
    static SWAP_HOOK: std::cell::RefCell<Option<(SwapFn, Reached)>> =
        const { std::cell::RefCell::new(None) };
}

/// The hook [`on_swap`] put on this thread; dropping it takes it off.
#[cfg(test)]
pub(crate) struct SwapHook {
    reached: Reached,
}

#[cfg(test)]
impl SwapHook {
    /// Each `(name, window)` the hook was reached in, in order.
    pub(crate) fn reached(&self) -> Vec<(String, String)> {
        self.reached.borrow().clone()
    }
}

#[cfg(test)]
impl Drop for SwapHook {
    fn drop(&mut self) {
        SWAP_HOOK.with(|slot| slot.borrow_mut().take());
    }
}

/// Runs `hook` in the windows of every replace on this thread until the returned guard drops.
#[cfg(test)]
pub(crate) fn on_swap(hook: impl FnMut(&str, &str) + 'static) -> SwapHook {
    let reached = Reached::default();
    SWAP_HOOK.with(|slot| {
        let mut slot = slot.borrow_mut();
        assert!(slot.is_none(), "a swap hook is already on this thread");
        *slot = Some((Box::new(hook), std::rc::Rc::clone(&reached)));
    });
    SwapHook { reached }
}

#[cfg(test)]
fn swap_hook(name: &std::ffi::CStr, window: &str) {
    // Out of the slot while it runs, so the hook may itself replace a file.
    let Some((mut hook, reached)) = SWAP_HOOK.with(|slot| slot.borrow_mut().take()) else {
        return;
    };
    let name = name.to_string_lossy();
    reached.borrow_mut().push((name.to_string(), window.to_owned()));
    hook(&name, window);
    SWAP_HOOK.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot.is_none() {
            *slot = Some((hook, reached));
        }
    });
}

/// Elsewhere there is no link-safe open of each step, so no folder file is read.
#[cfg(not(unix))]
pub(crate) fn open_beneath(_root: &Path, _rel: &str) -> Option<std::fs::File> {
    None
}

/// Elsewhere no folder file is written either.
#[cfg(not(unix))]
pub(crate) fn replace_beneath(
    _root: &Path,
    rel: &str,
    _bytes: &[u8],
    _read: Option<Stamp>,
) -> Result<(), String> {
    Err(format!("{rel} can only be written on macOS and Linux"))
}

/// Elsewhere no folder file is read for an edit either.
#[cfg(not(unix))]
pub(crate) fn read_whole_beneath(
    _root: &Path,
    rel: &str,
    _max: u64,
) -> Result<Option<(Vec<u8>, Stamp)>, String> {
    Err(format!("{rel} can only be edited on macOS and Linux"))
}

/// The start of `rel` beneath `cwd` (at most the cap and a few bytes) and its full size;
/// `None` when it is not there as a regular file or holds only whitespace.
fn readable(cwd: &Path, rel: &str) -> Option<(String, u64)> {
    let file = open_beneath(cwd, rel)?;
    let size = file.metadata().ok()?.len();
    // Never more than the cap and a little: a huge file must not fill memory.
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut std::io::Read::take(file, MAX_BYTES as u64 + 4), &mut bytes)
        .ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    (!text.trim().is_empty()).then_some((text, size))
}

/// `parts` with the folder part for `cwd` in place of any earlier one: a fork
/// into another folder carries that folder's instructions, not its parent's.
pub fn retarget(mut parts: Vec<ContextPart>, family: &str, cwd: &Path) -> Vec<ContextPart> {
    parts.retain(|p| p.source != SOURCE);
    parts.extend(part(family, cwd));
    parts
}

/// `parts` for a fork moved from `from` into `cwd` whose agent keeps its own transcript
/// (a native fork), which already holds `from`'s instructions and cannot be edited: this
/// folder's instructions, or none, under a note that the earlier ones no longer apply.
pub fn moved(parts: Vec<ContextPart>, family: &str, cwd: &Path, from: &Path) -> Vec<ContextPart> {
    let mut parts = retarget(parts, family, cwd);
    let note = format!(
        "This chat moved here from {}. Folder instructions given earlier in this conversation were for that folder and no longer apply.",
        from.display()
    );
    match parts.iter_mut().find(|p| p.source == SOURCE) {
        Some(part) => {
            let text = format!("{note}\n\n{}", part.text.as_deref().unwrap_or_default());
            part.tokens = estimated_tokens(&text);
            part.text = Some(text);
        }
        None => parts.push(ContextPart {
            id: format!("{SOURCE}-moved"),
            source: SOURCE.into(),
            label: "Folder instructions (moved)".into(),
            tokens: estimated_tokens(&note),
            included: true,
            editable: false,
            measurement: "estimated".into(),
            source_bytes: None,
            channel: Some("user-context".into()),
            text: Some(note),
        }),
    }
    parts
}

/// The fallback part for a session of `family` in `cwd`, or `None` when the
/// harness reads its own file there or the folder carries no instructions.
pub fn part(family: &str, cwd: &Path) -> Option<ContextPart> {
    let own = native(family);
    // The harness's own file, even an empty one, is what it reads: nothing else is sent.
    if own.iter().any(|name| open_beneath(cwd, name).is_some()) {
        return None;
    }
    let (name, text, bytes) = CANDIDATES
        .iter()
        .filter(|name| !own.contains(name))
        .find_map(|name| readable(cwd, name).map(|(text, bytes)| (*name, text, bytes)))?;
    let body = if text.len() > MAX_BYTES {
        let mut end = MAX_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        format!(
            "{}\n\n[cut: {name} is {bytes} bytes; read the file for the rest]",
            text.get(..end).unwrap_or_default()
        )
    } else {
        text
    };
    let text = format!(
        "This folder's {name} (instructions for agents working here; this harness does not read that file itself):\n\n{body}"
    );
    Some(ContextPart {
        id: format!("{SOURCE}-instructions"),
        source: SOURCE.into(),
        label: format!("Folder instructions ({name})"),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(bytes),
        channel: Some("user-context".into()),
        text: Some(text),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (name, text) in files {
            let path = dir.path().join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        dir
    }

    #[test]
    fn claude_gets_agents_md_when_the_folder_has_no_claude_md() {
        let dir = folder(&[("AGENTS.md", "codeword KESTREL"), (".codex/config.toml", "")]);
        let got = part("claude", dir.path()).unwrap();
        assert_eq!(got.source, SOURCE);
        assert_eq!(got.label, "Folder instructions (AGENTS.md)");
        assert!(got.text.unwrap().contains("codeword KESTREL"));
    }

    #[test]
    fn a_harness_with_its_own_file_gets_nothing() {
        let dir = folder(&[("AGENTS.md", "a"), ("CLAUDE.md", "c")]);
        assert!(part("claude", dir.path()).is_none());
        assert!(part("codex", dir.path()).is_none());
        let dir = folder(&[(".claude/CLAUDE.md", "c"), ("AGENTS.md", "a")]);
        assert!(part("claude", dir.path()).is_none());
    }

    #[test]
    fn codex_and_gemini_get_another_harness_file() {
        let dir = folder(&[("CLAUDE.md", "from claude")]);
        assert!(part("codex", dir.path()).unwrap().text.unwrap().contains("from claude"));
        let dir = folder(&[(".cursorrules", "from cursor")]);
        let got = part("gemini", dir.path()).unwrap();
        assert_eq!(got.label, "Folder instructions (.cursorrules)");
        let dir = folder(&[(".github/copilot-instructions.md", "from vscode")]);
        assert!(part("claude", dir.path()).unwrap().text.unwrap().contains("from vscode"));
    }

    #[test]
    fn agents_md_wins_over_the_others_and_an_empty_folder_gets_nothing() {
        let dir = folder(&[("GEMINI.md", "g"), ("AGENTS.md", "a")]);
        assert_eq!(part("claude", dir.path()).unwrap().label, "Folder instructions (AGENTS.md)");
        assert!(part("claude", folder(&[]).path()).is_none());
        assert!(part("claude", folder(&[("AGENTS.md", "  \n")]).path()).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_is_never_followed() {
        let outside = folder(&[("secret.md", "outside")]);
        let dir = folder(&[]);
        std::os::unix::fs::symlink(outside.path().join("secret.md"), dir.path().join("AGENTS.md"))
            .unwrap();
        assert!(part("claude", dir.path()).is_none());
    }

    #[test]
    fn a_claude_sessions_first_turn_carries_the_folders_agents_md_once_captured() {
        let dir = folder(&[("AGENTS.md", "codeword KESTREL")]);
        let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "claude",
            "cwd": dir.path(), "status": "idle", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        let parts =
            crate::context_inventory::snapshot_session(&meta, &crate::config::Config::default());
        // The file changing after the session began changes nothing it was given.
        std::fs::write(dir.path().join("AGENTS.md"), "later").unwrap();
        let mut blocks = Vec::new();
        crate::context_inventory::append_snapshot(Some(&parts), &mut blocks);
        let text: Vec<&str> = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        let folder = text.iter().find(|t| t.starts_with("<cmux-folder-context>")).unwrap();
        assert!(folder.contains("codeword KESTREL"));
        assert!(!folder.contains("later"));
    }

    #[test]
    fn a_native_fork_moved_elsewhere_says_the_old_folders_instructions_no_longer_apply() {
        let from = folder(&[("AGENTS.md", "old words")]);
        let to = folder(&[("AGENTS.md", "codeword OSPREY")]);
        let parts = moved(
            part("claude", from.path()).into_iter().collect(),
            "claude",
            to.path(),
            from.path(),
        );
        let text: Vec<&str> = parts.iter().filter_map(|p| p.text.as_deref()).collect();
        assert_eq!(text.len(), 1, "the parent's part is replaced, not kept beside the new one");
        assert!(text[0].contains("no longer apply") && text[0].contains("codeword OSPREY"));
        assert!(!text[0].contains("old words"));
        // A folder with no instructions still says the earlier ones are gone.
        let bare = folder(&[]);
        let parts = moved(
            part("claude", from.path()).into_iter().collect(),
            "claude",
            bare.path(),
            from.path(),
        );
        assert_eq!(parts.len(), 1);
        assert!(parts[0].text.as_deref().unwrap().contains("no longer apply"));
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_folder_on_the_way_is_never_followed() {
        let outside = folder(&[("copilot-instructions.md", "outside words")]);
        let dir = folder(&[]);
        std::os::unix::fs::symlink(outside.path(), dir.path().join(".github")).unwrap();
        assert!(part("claude", dir.path()).is_none());
        // A linked folder on the way to the harness's own file is not its own file either.
        let claude = folder(&[("CLAUDE.md", "c")]);
        let dir = folder(&[("AGENTS.md", "a")]);
        std::os::unix::fs::symlink(claude.path(), dir.path().join(".claude")).unwrap();
        assert_eq!(part("claude", dir.path()).unwrap().label, "Folder instructions (AGENTS.md)");
    }

    #[test]
    fn an_empty_file_of_the_harnesses_own_still_counts_as_its_own() {
        let dir = folder(&[("CLAUDE.md", ""), ("AGENTS.md", "a")]);
        assert!(part("claude", dir.path()).is_none());
    }

    #[test]
    fn a_huge_file_is_read_only_up_to_the_cap() {
        let dir = folder(&[]);
        let file = std::fs::File::create(dir.path().join("AGENTS.md")).unwrap();
        file.set_len(1 << 30).unwrap();
        // A sparse 1 GiB file of zeros: read whole, the test would take a gigabyte.
        let got = part("claude", dir.path()).unwrap();
        assert_eq!(got.source_bytes, Some(1 << 30));
        assert!(got.text.unwrap().len() < 2 * MAX_BYTES);
    }

    #[test]
    fn a_claude_code_profile_of_its_own_family_reads_claude_md() {
        let mut cfg = crate::config::Config::default();
        cfg.harnesses.insert(
            "claude-sr2".into(),
            serde_json::from_value(serde_json::json!({
                "kind": "claude-stdio", "argv": ["sr2"], "family": "claude-sr2",
            }))
            .unwrap(),
        );
        let family = crate::context_inventory::family_for_folder(&cfg, "claude-sr2");
        assert_eq!(family, "claude");
        let dir = folder(&[("CLAUDE.md", "c"), ("AGENTS.md", "a")]);
        assert!(part(&family, dir.path()).is_none());
    }

    #[test]
    fn a_fork_into_another_folder_carries_that_folders_instructions() {
        let parent = folder(&[("AGENTS.md", "parent words")]);
        let child = folder(&[("GEMINI.md", "child words")]);
        let parts =
            retarget(part("claude", parent.path()).into_iter().collect(), "claude", child.path());
        assert_eq!(parts.len(), 1);
        assert!(parts[0].text.as_deref().unwrap().contains("child words"));
        let none = retarget(parts, "claude", folder(&[]).path());
        assert!(none.is_empty());
    }

    #[test]
    fn a_long_file_is_cut_on_a_character_boundary() {
        let long = "é".repeat(MAX_BYTES);
        let dir = folder(&[("AGENTS.md", &long)]);
        let text = part("claude", dir.path()).unwrap().text.unwrap();
        assert!(text.contains("[cut: AGENTS.md is"));
        assert!(text.len() < long.len());
    }
}
