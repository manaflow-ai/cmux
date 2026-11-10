//! The GitHub broker's `clone` action (`github_broker.rs`): a chat on a machine the person added
//! clones a repository into a new folder under its own folder, with a credential its Mac lends
//! for that one clone. The sandboxed agent of a remote chain may never write `.git`
//! (`hub/remote_sandbox.rs`), so it cannot clone itself; the machine's daemon, outside the
//! sandbox, runs git for it, the same way for a chat that asks over the unix socket.
//!
//! - The Mac checks the request as it checks every action (`serve_owner`: the peer's
//!   `githubBroker`, `validate`, the deadline). It never lends its keyring login, which is the
//!   person's whole GitHub: only a token the cmux GitHub App mints for that one repository with
//!   read access to its contents (`github_app_token::clone_token`), and only while the cmux
//!   sign-in it was minted with is still lent. With no sign-in lent there is none, and the clone
//!   runs without one (a public repository).
//! - The token goes to the machine in the Mac's answer (`cloneToken`), over the peer link, and
//!   the machine's daemon takes it out of the answer before anything else reads it
//!   ([`take_lent`]): it is not in the reply the agent gets, the session's
//!   `github_broker_action` row or a log. It lives in this daemon's memory (wiped on drop) until
//!   it is written once into a pipe that only the git credential helper of that one clone reads
//!   (fd 3, [`run`]): never in argv, an environment variable, `.git/config` or any file. The
//!   helper answers only for the one host it was made for, git follows no redirect, and the
//!   person's own credential helpers, global and system config are not used, so nothing stores
//!   it. A clone whose `.git/config` holds it all the same is removed.
//! - `DIR` is a new folder name: one plain name (no `/`, no `..`, no leading `.` or `-`), that
//!   nothing in the chat's folder has (a file, a folder or a link, [`check_target`]).
//! - git never runs in the chat's folder (Codex review on #40513: git removes its own failed
//!   clone through its working folder, so what the agent wrote or moved there while git ran
//!   went with it). It clones into a new private folder (0700, `mkdtemp`) under the daemon's
//!   state folder, `clone-staging` in `config::home()`, which no sandbox lets the agent write
//!   (`hub/remote_sandbox.rs`: the session folder, its temporary folders and Claude Code's own).
//!   git runs inside that folder by its open handle. The finished clone, its `.git/config`
//!   checked for the token first, moves to `DIR` in one rename through both folders' handles
//!   that never replaces anything (`RENAME_NOREPLACE` on Linux, `RENAME_EXCL` on macOS): a name
//!   the agent took since the check is refused and keeps what it holds. A failed clone is
//!   removed in the staging folder only, through its handle ([`remove_failed`]); the chat's
//!   folder is never touched. The staging folder must be on the chat folder's file system,
//!   since nothing is copied; a chat folder on another one (a `/tmp` on its own disk) is refused
//!   with that reason.
//! - git runs with `--template=` and `core.hooksPath=/dev/null` (no hook or template runs),
//!   https only (`protocol.allow=never`), no submodules, a bounded time and bounded output, and
//!   an empty home of its own in the staging folder (Codex review round 4, F1): libcurl reads
//!   `~/.netrc`, so the daemon's own HOME would send the machine's credentials, not the lent one.
//! - The checkout leaves out every path the remote sandbox forbids the agent to write
//!   (`github_clone_checkout.rs`, Codex review round 4, F2): a clone is written outside the
//!   sandbox, and a later session outside it would read those paths (agent instructions,
//!   Claude Code and editor settings, hooks, `.envrc`). The reply names them.

use crate::github_broker::{GithubAction, GithubActionParams};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

/// The key of the Mac's answer that carries a clone's credential.
pub const LENT_KEY: &str = "cloneToken";
/// How long one clone may run.
pub const CLONE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10 * 60);
const DIR_MAX: usize = 100;
/// Where clones come from.
const GITHUB: &str = "https://github.com";

/// Where one daemon clones from and stages its clones (module docs): GitHub and `clone-staging`
/// in the daemon's state folder. A test's hub is given another through
/// `Hub::set_github_clone_origin`, never through anything a caller or the environment sets.
#[derive(Debug, Clone, Default)]
pub struct CloneOrigin {
    /// `http://127.0.0.1:PORT`, a test's git stand-in; GitHub when `None`.
    loopback: Option<String>,
    /// The folder clones are staged in; `clone-staging` in `config::home()` when `None`.
    staging: Option<PathBuf>,
}

impl CloneOrigin {
    /// A test's origin: its loopback git stand-in at `base` (`http://127.0.0.1:PORT`, else
    /// `None`) and its staging folder `staging` (absolute, else `None`).
    pub fn loopback(base: &str, staging: PathBuf) -> Option<Self> {
        let port = base.strip_prefix("http://127.0.0.1:")?;
        if port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) || !staging.is_absolute() {
            return None;
        }
        Some(Self { loopback: Some(base.to_owned()), staging: Some(staging) })
    }

    fn base(&self) -> &str {
        self.loopback.as_deref().unwrap_or(GITHUB)
    }

    /// Where clones are staged (module docs).
    fn staging(&self) -> PathBuf {
        self.staging.clone().unwrap_or_else(|| crate::config::home().join("clone-staging"))
    }
}

/// The folder a clone makes: `dir`, else the repository's name.
pub fn dir_name(r: &GithubActionParams) -> String {
    match &r.dir {
        Some(dir) => dir.clone(),
        None => {
            let name = r.repo.split_once('/').map_or(r.repo.as_str(), |(_, n)| n);
            name.strip_suffix(".git").unwrap_or(name).to_owned()
        }
    }
}

/// Whether `name` is one new plain folder name (module docs); the reason when it is not.
pub fn valid_dir(name: &str) -> Result<(), &'static str> {
    if name.is_empty() || name.len() > DIR_MAX {
        return Err("must be 1..100 characters");
    }
    if name.starts_with('.') || name.starts_with('-') {
        return Err("must not start with . or -");
    }
    if !name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        return Err("must be one folder name of letters, digits, '.', '_' or '-' (no path)");
    }
    Ok(())
}

fn exists_error(name: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{name} already exists in this chat's folder: a clone goes into a new folder (give another DIR)"
    ))
    .with_data(json!({"reason": "github.clone_exists"}))
}

/// The clone's new folder under `cwd`: refused when its name is not one plain name or anything
/// is there already (a link too, which is not followed).
pub fn check_target(cwd: &Path, r: &GithubActionParams) -> Result<PathBuf, RpcError> {
    let name = dir_name(r);
    valid_dir(&name).map_err(|why| RpcError::invalid_params(format!("dir {why}")))?;
    let target = cwd.join(&name);
    if std::fs::symlink_metadata(&target).is_ok() {
        return Err(exists_error(&name));
    }
    Ok(target)
}

/// The Mac's answer with the clone credential taken out, and the credential.
pub fn take_lent(mut v: Value) -> (Value, Option<Zeroizing<String>>) {
    let lent = v
        .as_object_mut()
        .and_then(|o| o.remove(LENT_KEY))
        .and_then(|t| match t {
            Value::String(s) => Some(Zeroizing::new(s)),
            _ => None,
        })
        .filter(|t| !t.is_empty());
    (v, lent)
}

/// The Mac's side of a clone `validate` accepted (module docs): the credential it lends, if any.
pub async fn serve_owner(
    peer: &str,
    r: &GithubActionParams,
    app: Option<&crate::github_app_token::AppLease>,
) -> Result<Value, RpcError> {
    let (source, lent) = crate::github_app_token::clone_token(r, app).await;
    let session = r.session_id.as_deref().unwrap_or("-");
    let status = if lent.is_ok() { "allowed" } else { "failed" };
    let row = crate::github_broker::audit_payload(r, status, lent.as_ref().err(), source);
    tracing::info!(peer, session, "github broker: {row}");
    let lent = lent.map_err(|e| crate::github_broker::with_source(e, source))?;
    let mut answer =
        json!({"action": GithubAction::Clone, "repo": r.repo, "output": "", "source": source});
    if let (Some(token), Some(o)) = (lent, answer.as_object_mut()) {
        o.insert(LENT_KEY.into(), Value::String(token.to_string()));
    }
    Ok(answer)
}

/// `text` with `token` and every other GitHub token cut out.
fn clean(text: &[u8], token: Option<&str>) -> String {
    let mut text = String::from_utf8_lossy(text).into_owned();
    if let Some(t) = token.filter(|t| !t.is_empty()) {
        text = text.replace(t, "[redacted]");
    }
    let text = crate::github_broker::redact_github_tokens(&text);
    let mut text = text.trim().to_owned();
    if text.len() > 4096 {
        let mut end = 4096;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
        text.push('…');
    }
    text
}

/// The machine's side: clone `r.repo` into its new folder under `cwd` with the credential the
/// Mac lent, if any (module docs). Nothing is made in `cwd` unless the clone succeeds.
pub async fn run(
    cwd: &Path,
    r: &GithubActionParams,
    lent: Option<Zeroizing<String>>,
    source: Option<&str>,
    origin: &CloneOrigin,
) -> Result<Value, RpcError> {
    let target = check_target(cwd, r)?;
    let name = dir_name(r);
    let out = clone_into(origin, &target, &r.repo, lent.as_ref().map(|t| t.as_str())).await?;
    #[cfg(unix)]
    let left_out = checkout::left_out_line(&out);
    #[cfg(not(unix))]
    let left_out = String::new();
    Ok(json!({
        "action": GithubAction::Clone,
        "repo": r.repo,
        "dir": name,
        "path": target,
        "leftOut": out,
        "output": format!("Cloned {} into {}\n{left_out}", r.repo, name),
        "source": source,
    }))
}

#[cfg(not(unix))]
async fn clone_into(
    _: &CloneOrigin,
    _: &Path,
    _: &str,
    _: Option<&str>,
) -> Result<Vec<String>, RpcError> {
    Err(RpcError::internal("repo clone runs on macOS and Linux only"))
}

/// The env git runs with: none of the daemon's own but what reaching GitHub needs, and nothing
/// that reads the person's home, global or system config or asks a person.
#[cfg(unix)]
fn git_env(git: &mut tokio::process::Command, home: &Path) {
    git.env_clear();
    // An empty home of its own (Codex review round 4, F1): libcurl reads `~/.netrc`, so the
    // daemon's HOME would lend git the machine's own credentials.
    git.env("HOME", home).env("XDG_CONFIG_HOME", home);
    for key in [
        "PATH",
        "TMPDIR",
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
        "NO_PROXY",
        "no_proxy",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    ] {
        if let Some(v) = std::env::var_os(key) {
            git.env(key, v);
        }
    }
    git.env("LANG", "C")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GCM_INTERACTIVE", "never")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null");
}

/// The credential helper of one clone: for `get` on `host`, what fd 3 holds; nothing for any
/// other host or operation (`store`, `erase`).
fn helper(host: &str) -> String {
    format!(
        "!f() {{ [ \"$1\" = get ] || exit 0; h=; while IFS= read -r l; do case \"$l\" in host=*) h=\"${{l#host=}}\";; esac; done; [ \"$h\" = '{host}' ] && cat <&3; exit 0; }}; f"
    )
}

/// The folder under the staging folder git clones into, moved to `DIR` when it is done.
#[cfg(unix)]
const STAGED: &std::ffi::CStr = c"clone";

/// Opens folder `path` without following a link at its last part.
#[cfg(unix)]
fn open_dir(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
}

/// A new private staging folder for one clone (module docs).
#[cfg(unix)]
fn make_stage(root: &Path) -> Result<PathBuf, RpcError> {
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::DirBuilderExt as _;
    let failed = |e: &dyn std::fmt::Display| {
        RpcError::internal(format!("could not make a staging folder in {}: {e}", root.display()))
    };
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(root).map_err(|e| failed(&e))?;
    if !std::fs::symlink_metadata(root).is_ok_and(|m| m.is_dir()) {
        return Err(failed(&"it is not a folder"));
    }
    let template = std::ffi::CString::new(root.join("clone-XXXXXX").as_os_str().as_bytes())
        .map_err(|e| failed(&e))?;
    let mut template = template.into_bytes_with_nul();
    // SAFETY: `template` is a NUL-terminated buffer that mkdtemp rewrites in place.
    if unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) }.is_null() {
        return Err(failed(&std::io::Error::last_os_error()));
    }
    template.pop();
    Ok(PathBuf::from(std::ffi::OsStr::from_bytes(&template)))
}

#[cfg(unix)]
async fn clone_into(
    origin: &CloneOrigin,
    target: &Path,
    repo: &str,
    token: Option<&str>,
) -> Result<Vec<String>, RpcError> {
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let chat = target.parent().unwrap_or(Path::new("/"));
    let parent = open_dir(chat)
        .map_err(|e| RpcError::internal(format!("could not open the chat's folder: {e}")))?;
    let root = origin.staging();
    let stage = make_stage(&root)?;
    let staged = stage.join(STAGED.to_str().unwrap_or("clone"));
    let done = clone_staged(origin, &stage, &staged, &parent, &name, repo, token).await;
    // The daemon's own folder: empty now, whether the clone moved out or was removed.
    if let Err(e) = std::fs::remove_dir(&stage) {
        tracing::warn!(stage = %stage.display(), "github clone: the staging folder stays: {e}");
    }
    done
}

/// The clone in `staged` (under `stage`), then its move to `name` in the chat's folder
/// (`parent`); what is left in `staged` is removed when either fails.
#[cfg(unix)]
async fn clone_staged(
    origin: &CloneOrigin,
    stage: &Path,
    staged: &Path,
    parent: &std::fs::File,
    name: &str,
    repo: &str,
    token: Option<&str>,
) -> Result<Vec<String>, RpcError> {
    use std::os::unix::fs::MetadataExt as _;
    let opened =
        |e: std::io::Error| RpcError::internal(format!("could not open the staging folder: {e}"));
    let stage_dir = open_dir(stage).map_err(opened)?;
    let chat_dev = parent.metadata().map_err(opened)?.dev();
    if stage_dir.metadata().map_err(opened)?.dev() != chat_dev {
        return Err(other_disk(&origin.staging()));
    }
    std::fs::create_dir(staged).map_err(opened)?;
    let dir = open_dir(staged).map_err(opened)?;
    // git's home: new and empty, in the daemon's private staging folder.
    let home = stage.join("home");
    std::fs::create_dir(&home).map_err(opened)?;
    let cloned = clone_in(origin, &dir, staged, &home, repo, token).await;
    let _ = std::fs::remove_dir_all(&home);
    let done = cloned.and_then(|out| place(origin, &stage_dir, parent, name).map(|()| out));
    if done.is_err() {
        remove_failed(&dir, staged);
    }
    done
}

#[cfg(unix)]
fn other_disk(staging: &Path) -> RpcError {
    RpcError::invalid_params(format!(
        "this chat's folder is on another file system than acpmux's state folder ({}), where a clone is made out of the agent's reach and then moved in; clone from a chat whose folder is on that file system",
        staging.display()
    ))
    .with_data(json!({"reason": "github.clone_other_disk"}))
}

/// Moves the finished clone (`STAGED` in `stage`) to `name` in `parent`, never replacing what is
/// there (module docs).
#[cfg(unix)]
fn place(
    origin: &CloneOrigin,
    stage: &std::fs::File,
    parent: &std::fs::File,
    name: &str,
) -> Result<(), RpcError> {
    use std::os::fd::AsRawFd as _;
    let to = std::ffi::CString::new(name).map_err(|_| exists_error(name))?;
    // SAFETY: both handles are open folders; both names are C strings.
    #[cfg(target_os = "linux")]
    let moved = unsafe {
        libc::renameat2(
            stage.as_raw_fd(),
            STAGED.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    // SAFETY: as above.
    #[cfg(target_vendor = "apple")]
    let moved = unsafe {
        libc::renameatx_np(
            stage.as_raw_fd(),
            STAGED.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
    let moved: libc::c_int = {
        let _ = (stage, parent, to);
        return Err(RpcError::internal("repo clone runs on macOS and Linux only"));
    };
    if moved == 0 {
        return Ok(());
    }
    let e = std::io::Error::last_os_error();
    Err(match e.raw_os_error() {
        Some(libc::EEXIST) => exists_error(name),
        Some(libc::EXDEV) => other_disk(&origin.staging()),
        _ => RpcError::internal(format!("could not move the clone to {name}: {e}")),
    })
}

/// Removes what a failed clone left in the folder it made (`dir`, opened at `target`), through
/// that open folder and never through the name `target`: had the folder been renamed and
/// another put at its name (Codex review F1 on #40513), nothing of that one is touched. It is
/// the staging folder's now, out of the agent's reach; the walk holds regardless. Every entry is removed relative to its own parent's handle, without following a
/// link, and only on the folder's own file system. A `.git` below the top folder is never one
/// the clone made (no submodules, and the agent may not write `.git` at all), so one found there
/// was moved in and is left whole, with the folders above it. The emptied top folder goes only
/// while `target` still names it; one that moved stays, empty.
#[cfg(unix)]
pub(crate) fn remove_failed(dir: &std::fs::File, target: &Path) {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::fs::MetadataExt as _;
    let Ok(top) = dir.metadata() else { return };
    if let Err(e) = clear_at(dir.as_raw_fd(), top.dev(), 0) {
        let folder = target.display();
        tracing::warn!(%folder, "github clone: a failed clone was not all removed: {e}");
        return;
    }
    let same = std::fs::symlink_metadata(target)
        .is_ok_and(|m| m.is_dir() && m.dev() == top.dev() && m.ino() == top.ino());
    if same {
        // rmdir removes only an empty folder, so a swap after this check loses nothing.
        let _ = std::fs::remove_dir(target);
    }
}

/// How deep [`clear_at`] goes; a deeper tree is left.
#[cfg(unix)]
const CLEAR_DEPTH: usize = 64;

/// Removes every entry of the folder open at `fd` (module docs, [`remove_failed`]).
#[cfg(unix)]
fn clear_at(fd: std::os::fd::RawFd, dev: u64, depth: usize) -> std::io::Result<()> {
    use std::ffi::CStr;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    let last = std::io::Error::last_os_error;
    if depth > CLEAR_DEPTH {
        return Err(std::io::Error::other("too deep"));
    }
    // The entries' names, read through a copy of the handle (closedir closes the copy).
    let mut names = Vec::new();
    // SAFETY: `fd` is an open folder for the whole call; the copy is owned by `dirp` and closed
    // with it; `readdir`'s entry is read before the next call.
    unsafe {
        let copy = libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0);
        if copy < 0 {
            return Err(last());
        }
        let dirp = libc::fdopendir(copy);
        if dirp.is_null() {
            let e = last();
            libc::close(copy);
            return Err(e);
        }
        libc::rewinddir(dirp);
        loop {
            let entry = libc::readdir(dirp);
            if entry.is_null() {
                break;
            }
            let name = CStr::from_ptr((*entry).d_name.as_ptr()).to_owned();
            if name.as_bytes() != b"." && name.as_bytes() != b".." {
                names.push(name);
            }
        }
        libc::closedir(dirp);
    }
    let mut result = Ok(());
    for name in names {
        let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: `name` is a C string; `st` is written by fstatat when it returns 0.
        if unsafe { libc::fstatat(fd, name.as_ptr(), st.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) }
            != 0
        {
            result = Err(last());
            continue;
        }
        // SAFETY: fstatat returned 0.
        let st = unsafe { st.assume_init() };
        if (st.st_mode & libc::S_IFMT) != libc::S_IFDIR {
            // SAFETY: `name` is a C string; flag 0 unlinks the entry itself, never a link's target.
            if unsafe { libc::unlinkat(fd, name.as_ptr(), 0) } != 0 {
                result = Err(last());
            }
            continue;
        }
        #[allow(clippy::unnecessary_cast)] // dev_t is u64 on Linux, i32 on macOS
        let entry_dev = st.st_dev as u64;
        if (depth > 0 && name.as_bytes() == b".git") || entry_dev != dev {
            result = Err(std::io::Error::other("a folder the clone did not make is left"));
            continue;
        }
        // SAFETY: `name` is a C string; O_NOFOLLOW refuses a link swapped in since fstatat.
        let sub = unsafe {
            libc::openat(
                fd,
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if sub < 0 {
            result = Err(last());
            continue;
        }
        // SAFETY: `sub` was just opened and is owned here.
        let sub = unsafe { OwnedFd::from_raw_fd(sub) };
        let cleared = clear_at(sub.as_raw_fd(), dev, depth + 1);
        drop(sub);
        if cleared.is_err() {
            result = cleared;
            continue;
        }
        // SAFETY: `name` is a C string; AT_REMOVEDIR removes only an empty folder.
        if unsafe { libc::unlinkat(fd, name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
            result = Err(last());
        }
    }
    result
}

/// The bytes of `.git/config` in the folder open at `dir`, read through it without following a
/// link; empty when there is none.
#[cfg(unix)]
fn config_at(dir: &std::fs::File) -> Vec<u8> {
    use std::io::Read as _;
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: literal C strings; each fd opened here is owned by the File made from it.
    unsafe {
        let git = libc::openat(dir.as_raw_fd(), c".git".as_ptr(), flags | libc::O_DIRECTORY);
        if git < 0 {
            return Vec::new();
        }
        let git = std::fs::File::from_raw_fd(git);
        let config = libc::openat(git.as_raw_fd(), c"config".as_ptr(), flags);
        if config < 0 {
            return Vec::new();
        }
        let mut bytes = Vec::new();
        let _ = std::fs::File::from_raw_fd(config).take(1 << 20).read_to_end(&mut bytes);
        bytes
    }
}

/// The most a git of a clone may print on stdout (a listing of the repository's paths).
#[cfg(unix)]
const OUT_MAX: u64 = 64 << 20;

/// A git run inside the folder open at `dir_fd`, with `home` as its home (`git_env`), the
/// options every git of a clone runs with, and `pipe_fd` (the credential) as its fd 3.
#[cfg(unix)]
fn git_at(
    base: &str,
    home: &Path,
    dir_fd: std::os::fd::RawFd,
    pipe_fd: Option<std::os::fd::RawFd>,
) -> tokio::process::Command {
    let mut git = tokio::process::Command::new("git");
    git_env(&mut git, home);
    git.args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "credential.helper=", "-c", "credential.interactive=false"])
        .args(["-c", "http.followRedirects=false", "-c", "protocol.allow=never"])
        .args(["-c", "protocol.https.allow=always"]);
    if base != GITHUB {
        // A test's loopback stand-in (`CloneOrigin::loopback`).
        git.args(["-c", "protocol.http.allow=always"]);
    }
    // SAFETY: only async-signal-safe calls (fchdir, dup2, fcntl) between fork and exec.
    unsafe {
        git.pre_exec(move || {
            if libc::fchdir(dir_fd) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if let Some(fd) = pipe_fd {
                if fd == 3 {
                    // dup2 onto itself keeps close-on-exec: clear it instead.
                    if libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                } else if libc::dup2(fd, 3) != 3 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    git.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    git
}

/// Runs `git` to its end by `deadline`: what it printed on stdout, or why it failed (`what` it
/// could not do, its error output with `token` cut out). `pipe` is closed here once git holds it.
#[cfg(unix)]
async fn finish(
    mut git: tokio::process::Command,
    pipe: Option<std::io::PipeReader>,
    deadline: tokio::time::Instant,
    what: &str,
    token: Option<&str>,
) -> Result<Vec<u8>, RpcError> {
    use tokio::io::AsyncReadExt as _;
    let mut child =
        git.spawn().map_err(|e| RpcError::internal(format!("could not start git: {e}")))?;
    drop(pipe);
    let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
    let run = async {
        let out = async {
            let mut kept = Vec::new();
            if let Some(mut pipe) = stdout {
                let _ = (&mut pipe).take(OUT_MAX + 1).read_to_end(&mut kept).await;
                let _ = tokio::io::copy(&mut pipe, &mut tokio::io::sink()).await;
            }
            kept
        };
        let err = async {
            let mut kept = Vec::new();
            if let Some(mut pipe) = stderr {
                let _ = (&mut pipe).take(64 * 1024).read_to_end(&mut kept).await;
                let _ = tokio::io::copy(&mut pipe, &mut tokio::io::sink()).await;
            }
            kept
        };
        let (out, err, status) = tokio::join!(out, err, child.wait());
        status.map(|s| (s, out, err))
    };
    let Ok(ran) = tokio::time::timeout_at(deadline, run).await else {
        // Stopped and waited for, so it writes nothing while its folder is removed.
        let _ = child.kill().await;
        return Err(RpcError::internal(format!(
            "git did not finish within {}s",
            CLONE_TIMEOUT.as_secs()
        )));
    };
    let (status, out, err) = ran.map_err(|e| RpcError::internal(format!("lost git: {e}")))?;
    if !status.success() {
        return Err(RpcError::new(-32041, format!("git could not {what}: {}", clean(&err, token)))
            .with_data(json!({"reason": "github.command_failed"})));
    }
    if out.len() as u64 > OUT_MAX {
        return Err(RpcError::internal(format!("git could not {what}: its output is too long")));
    }
    Ok(out)
}

/// Clones `repo` into the folder open at `dir` (`staged`), with `home` as git's home, and
/// checks out all but what the sandbox forbids (`checkout.rs`): the paths left out.
#[cfg(unix)]
async fn clone_in(
    origin: &CloneOrigin,
    dir: &std::fs::File,
    staged: &Path,
    home: &Path,
    repo: &str,
    token: Option<&str>,
) -> Result<Vec<String>, RpcError> {
    use std::io::Write as _;
    use std::os::fd::AsRawFd as _;
    let deadline = tokio::time::Instant::now() + CLONE_TIMEOUT;
    let base = origin.base();
    let host = base.split_once("://").map_or(base, |(_, h)| h).to_owned();
    let url = format!("{base}/{repo}.git");
    let dir_fd = dir.as_raw_fd();
    // The token goes into a pipe only the helper reads (fd 3 in git and its children).
    let pipe = match token {
        Some(token) => {
            let (reader, mut writer) = std::io::pipe()
                .map_err(|e| RpcError::internal(format!("could not make a pipe: {e}")))?;
            let answer = Zeroizing::new(format!("username=x-access-token\npassword={token}\n"));
            writer.write_all(answer.as_bytes()).map_err(|e| {
                RpcError::internal(format!("could not hand git its credential: {e}"))
            })?;
            drop(writer);
            Some(reader)
        }
        None => None,
    };
    let mut git = git_at(base, home, dir_fd, pipe.as_ref().map(|p| p.as_raw_fd()));
    if pipe.is_some() {
        git.arg("-c").arg(format!("credential.helper={}", helper(&host)));
    }
    git.args(["clone", "--template=", "--no-checkout", "--no-recurse-submodules", "--quiet"])
        .args(["--", &url, "."]);
    finish(git, pipe, deadline, &format!("clone {repo}"), token).await?;
    // What git wrote stays in this one folder; a config that kept the token is not left.
    if let Some(token) = token.filter(|t| !t.is_empty()) {
        let config = config_at(dir);
        if config.windows(token.len()).any(|w| w == token.as_bytes()) {
            return Err(RpcError::internal("the clone kept its credential; it was removed"));
        }
    }
    // The checkout: everything but what the sandbox forbids (`checkout.rs`).
    let mut ls = git_at(base, home, dir_fd, None);
    ls.args(["ls-tree", "-r", "-z", "--name-only", "HEAD"]);
    let Ok(listing) = finish(ls, None, deadline, "list the repository", None).await else {
        // An empty repository has no HEAD, and nothing to check out.
        return Ok(Vec::new());
    };
    let out: Vec<&[u8]> =
        listing.split(|&b| b == 0).filter(|p| !p.is_empty() && checkout::kept_out(p)).collect();
    if !out.is_empty() {
        let patterns = checkout::sparse_patterns(&out).ok_or_else(|| {
            RpcError::invalid_params(
                "the repository has a path a chat may not write whose name holds a line break; it was not cloned",
            )
        })?;
        let failed = |e: std::io::Error| {
            RpcError::internal(format!("could not set up the clone's checkout: {e}"))
        };
        let info = staged.join(".git").join("info");
        std::fs::create_dir_all(&info).map_err(failed)?;
        std::fs::write(info.join("sparse-checkout"), patterns).map_err(failed)?;
        for (key, value) in [("core.sparseCheckout", "true"), ("core.sparseCheckoutCone", "false")]
        {
            let mut set = git_at(base, home, dir_fd, None);
            set.args(["config", key, value]);
            finish(set, None, deadline, "set up the checkout", None).await?;
        }
    }
    let mut read = git_at(base, home, dir_fd, None);
    read.args(["read-tree", "-m", "-u", "HEAD"]);
    finish(read, None, deadline, "check out the clone", None).await?;
    if let Some(path) = checkout::first_left_in(staged)? {
        return Err(RpcError::internal(format!(
            "the checkout holds {path}, which a chat on this machine may not write; the clone was removed"
        )));
    }
    Ok(out.iter().map(|p| String::from_utf8_lossy(p).into_owned()).collect())
}

#[cfg(unix)]
#[path = "github_clone_checkout.rs"]
mod checkout;

#[cfg(test)]
#[path = "github_clone_tests.rs"]
mod tests;
