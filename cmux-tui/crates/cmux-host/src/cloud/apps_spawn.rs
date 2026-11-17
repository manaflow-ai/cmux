//! Published app versions (`cmux app publish`, the `cmux-apps` crate) run as the unprivileged
//! `cmux-app` user, started by this root agent, never by the publisher: the publisher's own
//! processes are in group `cmux` and hold its credentials, and a shared app must reach neither
//! (the agent socket serves `github_token` and `apps.call`).
//!
//! - `{"apps.spawn": {slug, version, versionDir, subdir, cmd, setup, port, env}}`: copies the
//!   staged `versionDir/src.tar` (a directory of the asking user's, `.../apps/<slug>/v<n>`) into
//!   `/var/lib/cmux-apps/<uid>/<slug>/v<n>`, owned by `cmux-app`, and starts `cmd` there in a
//!   session of its own as `cmux-app`, with exactly `PATH`, `LANG`, `TZ` and the app's
//!   `service.env` literals from `env`, plus `HOME` (the run directory) and `PORT`. `setup`,
//!   when given, runs first in the same process, bounded. Its output goes to `app.log`, opened
//!   here with `O_NOFOLLOW`. Answers `{pid, startTime, runDir, log, user}`.
//! - `{"apps.status": {slug, version}}` and `{"apps.stop": {slug, version}}`: whether that
//!   version's process still runs, and ending its process group. A pid counts only while its
//!   start time (`/proc/<pid>/stat` field 22) is the one recorded at spawn, so a reused pid is
//!   never taken for the app or signalled.
//!
//! Each ask is the asking user's own: run directories are kept per uid (the socket's peer
//! credentials), so no user starts, sees or stops another's versions. The agent refuses, with
//! no fallback, when it can't create or switch to `cmux-app`.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};

use super::github::refusal;

pub const SPAWN_KEY: &str = "apps.spawn";
pub const STATUS_KEY: &str = "apps.status";
pub const STOP_KEY: &str = "apps.stop";
/// The account every published app runs as. It is never in group `cmux`.
pub const APP_USER: &str = "cmux-app";
/// The group whose members reach the agent socket.
pub const AGENT_GROUP: &str = "cmux";
/// Where the agent keeps the run directories (root-owned, `0711` down to each version).
pub const RUN_ROOT: &str = "/var/lib/cmux-apps";
/// A setup command's bound.
pub const SETUP_LIMIT: Duration = Duration::from_secs(600);
const EXTRACT_LIMIT: Duration = Duration::from_secs(120);
/// `setpriv` (util-linux), by path: the asker's `PATH` never picks it.
const SETPRIV: &str = "/usr/bin/setpriv";
const USERADD_LIMIT: Duration = Duration::from_secs(30);
/// The variables an asker may set; `HOME` and `PORT` are the agent's.
const RESERVED: [&str; 2] = ["HOME", "PORT"];
const MAX_ENV: usize = 64;
const MAX_TEXT: usize = 16 * 1024;
/// The exit status of a start whose setup failed.
pub const SETUP_FAILED: i32 = 97;

/// Started app processes, kept so their exit is reaped.
static CHILDREN: Mutex<Vec<Child>> = Mutex::new(Vec::new());

/// One checked `apps.spawn`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnAsk {
    pub slug: String,
    pub version: u32,
    pub version_dir: PathBuf,
    /// The app's directory in the source tree, relative (`""` for its top).
    pub subdir: String,
    pub cmd: String,
    pub setup: Option<String>,
    pub port: u16,
    pub env: Vec<(String, String)>,
    /// A restart (rollback) runs the tree this version first started from; a fresh start
    /// unpacks the staged archive over any old tree.
    pub restart: bool,
}

/// One checked `apps.status` or `apps.stop`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VersionAsk {
    pub slug: String,
    pub version: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppsRun {
    Spawn(SpawnAsk),
    Status(VersionAsk),
    Stop(VersionAsk),
}

/// Where an agent finds the process table and keeps run directories (under its root).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunPaths {
    pub proc_root: PathBuf,
    pub run_root: PathBuf,
}

/// The app account.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppUser {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
}

/// Finds or makes the app account, and proves it can't reach the agent socket.
pub trait AppUsers {
    fn ensure(&self) -> Result<AppUser, String>;
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn version_of(value: &Value) -> Result<VersionAsk, String> {
    let slug = text(value, "slug").unwrap_or_default();
    if !cmux_apps::slug::is_slug(&slug) {
        return Err("apps: slug must be an app slug".to_owned());
    }
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .filter(|n| *n > 0)
        .ok_or_else(|| "apps: version must be a version number".to_owned())?;
    Ok(VersionAsk { slug, version })
}

/// A plain relative path: no `..`, no root, no `.` tricks.
fn plain_relative(path: &str) -> bool {
    path.len() <= 1024 && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

/// Variables the dynamic loader or libc reads to load code or data from a path: an app may
/// set none of them (glibc's unsecure list, and every `LD_*`).
const LOADER: [&str; 10] = [
    "GCONV_PATH",
    "GETCONF_DIR",
    "GLIBC_TUNABLES",
    "HOSTALIASES",
    "LOCALDOMAIN",
    "LOCPATH",
    "NIS_PATH",
    "NLSPATH",
    "RESOLV_HOST_CONF",
    "RES_OPTIONS",
];

/// A variable name an app may get: `[A-Za-z_][A-Za-z0-9_]*`, not `HOME` or `PORT`, and no
/// loader variable (`LD_*`, `MALLOC_*`, [`LOADER`]).
pub fn env_key_allowed(key: &str) -> bool {
    unimplemented!("red: env_key_allowed")
}

/// The `apps.spawn` object of a socket line, checked.
pub fn check_spawn(value: &Value) -> Result<SpawnAsk, String> {
    let VersionAsk { slug, version } = version_of(value)?;
    let version_dir = PathBuf::from(text(value, "versionDir").unwrap_or_default());
    if !version_dir.is_absolute() {
        return Err("apps.spawn: versionDir must be an absolute path".to_owned());
    }
    let subdir = text(value, "subdir").unwrap_or_default();
    if !subdir.is_empty() && !plain_relative(&subdir) {
        return Err("apps.spawn: subdir must be a plain relative path".to_owned());
    }
    let cmd = text(value, "cmd").unwrap_or_default();
    if cmd.trim().is_empty() || cmd.len() > MAX_TEXT || cmd.contains('\0') {
        return Err("apps.spawn: cmd must be a command".to_owned());
    }
    let setup = text(value, "setup").filter(|s| !s.trim().is_empty());
    if setup.as_ref().is_some_and(|s| s.len() > MAX_TEXT || s.contains('\0')) {
        return Err("apps.spawn: setup must be a command".to_owned());
    }
    let port = value
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .filter(|p| *p >= 1024)
        .ok_or_else(|| "apps.spawn: port must be from 1024 to 65535".to_owned())?;
    let mut env = vec![];
    if let Some(map) = value.get("env").and_then(Value::as_object) {
        if map.len() > MAX_ENV {
            return Err(format!("apps.spawn: at most {MAX_ENV} variables"));
        }
        for (key, value) in map {
            let Some(value) = value.as_str() else {
                return Err(format!("apps.spawn: {key} must be a string"));
            };
            if !env_key_allowed(key) || value.contains('\0') || value.len() > MAX_TEXT {
                return Err(format!(
                    "apps.spawn: {key} can't be set (HOME and PORT are the agent's; loader variables are refused)"
                ));
            }
            env.push((key.clone(), value.to_owned()));
        }
    }
    let restart = value.get("restart").and_then(Value::as_bool).unwrap_or(false);
    Ok(SpawnAsk { slug, version, version_dir, subdir, cmd, setup, port, env, restart })
}

/// The ask of an `apps.spawn`, `apps.status` or `apps.stop` line.
pub fn check_run(key: &str, value: &Value) -> Result<AppsRun, String> {
    match key {
        SPAWN_KEY => check_spawn(value).map(AppsRun::Spawn),
        STATUS_KEY => version_of(value).map(AppsRun::Status),
        _ => version_of(value).map(AppsRun::Stop),
    }
}

/// The app process's whole environment: the asker's allowed variables, `HOME` and `PORT`.
pub fn spawn_env(asked: &[(String, String)], home: &Path, port: u16) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> =
        asked.iter().filter(|(k, _)| env_key_allowed(k)).cloned().collect();
    env.push(("HOME".to_owned(), home.display().to_string()));
    env.push(("PORT".to_owned(), port.to_string()));
    env.sort();
    env
}

/// Whether an account with `groups` (its own and supplementary) is kept off the agent socket.
pub fn isolated(user: &AppUser, groups: &[u32], agent_gid: Option<u32>, asker: u32) -> bool {
    user.uid != 0 && user.uid != asker && agent_gid.is_none_or(|gid| !groups.contains(&gid))
}

/// The staged directory of the asker's version: `.../apps/<slug>/v<n>`, not a symlink, and the
/// asker's own; then its `src.tar`, opened without following a link, a regular file of theirs.
pub fn staged_archive(ask: &SpawnAsk, asker: u32) -> Result<File, String> {
    unimplemented!("red: staged_archive")
}

/// Clears `O_NONBLOCK` on a regular file opened with it.
fn blocking(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd as _;
    let fd = file.as_raw_fd();
    // SAFETY: fcntl on an open descriptor this function borrows.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    // SAFETY: as above, setting flags read from the same descriptor.
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// `path` for appending, refusing a symbolic link or a second hard link, then owned by `uid`.
pub fn open_log(path: &Path, uid: u32, gid: u32) -> Result<File, String> {
    unimplemented!("red: open_log")
}

/// `/proc/<pid>/stat`: its state letter and start time (field 22, clock ticks after boot).
pub fn stat_of(proc_root: &Path, pid: u32) -> Option<(char, u64)> {
    let text = fs::read_to_string(proc_root.join(pid.to_string()).join("stat")).ok()?;
    let (_, rest) = text.rsplit_once(')')?;
    let mut fields = rest.split_whitespace();
    let state = fields.next()?.chars().next()?;
    // Fields 4 to 21 lie between the state (3) and the start time (22).
    let start = fields.nth(18)?.parse().ok()?;
    Some((state, start))
}

/// Whether `pid` is still the process started at `start_time` as `uid`, and not a zombie.
pub fn still_running(proc_root: &Path, pid: u32, start_time: u64, uid: u32) -> bool {
    let owner = fs::metadata(proc_root.join(pid.to_string())).map(|m| m.uid()).ok();
    matches!(stat_of(proc_root, pid), Some((state, start)) if start == start_time && state != 'Z')
        && owner == Some(uid)
}

fn dir_at(path: &Path, mode: u32) -> io::Result<()> {
    match fs::DirBuilder::new().mode(mode).create(path) {
        Err(e) if e.kind() != io::ErrorKind::AlreadyExists => Err(e),
        _ => {
            let meta = fs::symlink_metadata(path)?;
            if meta.is_dir() {
                Ok(())
            } else {
                Err(io::Error::other(format!("{} is not a directory", path.display())))
            }
        }
    }
}

/// `<run root>/<uid>/<slug>`: root-owned, traversable, not listable.
fn slug_dir(paths: &RunPaths, asker: u32, slug: &str) -> Result<PathBuf, String> {
    let at = |p: &Path| dir_at(p, 0o711).map_err(|e| format!("{}: {e}", p.display()));
    at(&paths.run_root)?;
    let user = paths.run_root.join(asker.to_string());
    at(&user)?;
    let slug_dir = user.join(slug);
    at(&slug_dir)?;
    Ok(slug_dir)
}

fn record_file(paths: &RunPaths, asker: u32, ask: &VersionAsk) -> PathBuf {
    paths
        .run_root
        .join(asker.to_string())
        .join(&ask.slug)
        .join(format!("v{}.run.json", ask.version))
}

/// The only variable root's exec of `setpriv` gets.
const ROOT_PATH: &str = "/usr/bin:/bin";

/// `setpriv`'s arguments up to its `--`: `user`'s uid and gid, no other group, no new privileges.
fn drop_args(user: &AppUser) -> Vec<String> {
    vec![
        format!("--reuid={}", user.uid),
        format!("--regid={}", user.gid),
        "--clear-groups".to_owned(),
        "--no-new-privs".to_owned(),
        "--".to_owned(),
    ]
}

/// `setpriv` to `user`, then `program`, run by root with only [`ROOT_PATH`] from `/`.
fn as_user(user: &AppUser, program: &str) -> Command {
    let mut command = Command::new(SETPRIV);
    command.args(drop_args(user)).arg(program).env_clear().env("PATH", ROOT_PATH).current_dir("/");
    command
}

/// What root executes to start a version: `setpriv` with an empty environment (only
/// [`ROOT_PATH`]) from `/`; after the drop, `env -i` sets exactly the app's variables, and the
/// shell changes into `src/<subdir>` as the app user before the setup and the command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartPlan {
    pub program: String,
    pub args: Vec<String>,
    pub root_env: Vec<(String, String)>,
    pub root_dir: PathBuf,
}

pub fn start_plan(user: &AppUser, ask: &SpawnAsk, run: &Path) -> StartPlan {
    unimplemented!("red: start_plan")
}

/// Whether a start runs the tree already unpacked: only a restart, and only when one exists.
pub fn keeps_tree(restart: bool, exists: bool) -> bool {
    unimplemented!("red: keeps_tree")
}

fn wait_bounded(mut child: Child, limit: Duration, what: &str) -> Result<(), String> {
    match child.wait_timeout(limit) {
        Ok(Some(status)) if status.success() => Ok(()),
        Ok(Some(status)) => Err(format!("{what} exited with {status}")),
        Ok(None) => {
            let _ = child.kill();
            Err(format!("{what} ran past {} s", limit.as_secs()))
        }
        Err(e) => Err(format!("{what}: {e}")),
    }
}

/// The run directory of the version, its source unpacked from the asker's archive as `user`.
fn run_dir(
    paths: &RunPaths,
    asker: u32,
    ask: &SpawnAsk,
    user: &AppUser,
) -> Result<PathBuf, String> {
    let slug_dir = slug_dir(paths, asker, &ask.slug)?;
    let run = slug_dir.join(format!("v{}", ask.version));
    dir_at(&run, 0o755).map_err(|e| format!("{}: {e}", run.display()))?;
    let meta = fs::symlink_metadata(&run).map_err(|e| format!("{}: {e}", run.display()))?;
    if meta.uid() != user.uid {
        std::os::unix::fs::lchown(&run, Some(user.uid), Some(user.gid))
            .map_err(|e| format!("{}: {e}", run.display()))?;
    }
    let src = run.join("src");
    if keeps_tree(ask.restart, fs::symlink_metadata(&src).is_ok_and(|m| m.is_dir())) {
        return Ok(run);
    }
    let archive = staged_archive(ask, asker)?;
    // As the app user, in its run directory: unpack beside the tree, and only a whole unpack
    // replaces it; a failed one is removed and leaves the old tree as it was.
    let mut extract = as_user(user, "/bin/sh");
    extract
        .arg("-c")
        .arg(
            "cd -- \"$1\" || exit 1; rm -rf -- src.new src.old; mkdir -- src.new || exit 1; \
             if tar -x -f - -C src.new --no-same-owner; then \
               if [ -e src ]; then mv -- src src.old || exit 1; fi; \
               mv -- src.new src && rm -rf -- src.old; \
             else rm -rf -- src.new; exit 1; fi",
        )
        .arg("cmux-app-extract")
        .arg(&run)
        .stdin(Stdio::from(archive))
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let child = extract.spawn().map_err(|e| format!("tar: {e}"))?;
    wait_bounded(child, EXTRACT_LIMIT, "unpacking the version's source")?;
    Ok(run)
}

fn reap() {
    if let Ok(mut children) = CHILDREN.lock() {
        children.retain_mut(|child| matches!(child.try_wait(), Ok(None)));
    }
}

fn spawn(
    paths: &RunPaths,
    asker: u32,
    ask: &SpawnAsk,
    users: &dyn AppUsers,
) -> Result<Value, String> {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        return Err(format!(
            "this machine's agent does not run as root, so it can't start apps as {APP_USER}"
        ));
    }
    let user = users.ensure()?;
    if user.uid == asker {
        return Err(format!("{} is the asking user; an app must run as another", user.name));
    }
    let run = run_dir(paths, asker, ask, &user)?;
    let log_path = run.join("app.log");
    let log = open_log(&log_path, user.uid, user.gid)?;
    let err = log.try_clone().map_err(|e| format!("{}: {e}", log_path.display()))?;
    let plan = start_plan(&user, ask, &run);
    let mut command = Command::new(&plan.program);
    command
        .args(&plan.args)
        .env_clear()
        .envs(plan.root_env.iter().map(|(k, v)| (k, v)))
        .current_dir(&plan.root_dir)
        .new_session()
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(err));
    let mut child = command.spawn().map_err(|e| format!("starting `{}`: {e}", ask.cmd))?;
    child.detach("a published app version outlives the publish that asked for it");
    let pid = child.id();
    if let Ok(mut children) = CHILDREN.lock() {
        children.push(child);
    }
    let start_time = stat_of(&paths.proc_root, pid).map(|(_, start)| start).unwrap_or_default();
    let version = VersionAsk { slug: ask.slug.clone(), version: ask.version };
    let record = json!({"pid": pid, "startTime": start_time, "uid": user.uid});
    let file = record_file(paths, asker, &version);
    fs::write(&file, record.to_string()).map_err(|e| format!("{}: {e}", file.display()))?;
    Ok(json!({
        "ok": true,
        "pid": pid,
        "startTime": start_time,
        "runDir": run.display().to_string(),
        "log": log_path.display().to_string(),
        "user": user.name,
    }))
}

/// The recorded process of the asker's version, while it still runs.
fn running(paths: &RunPaths, asker: u32, ask: &VersionAsk) -> Option<u32> {
    let record: Value =
        serde_json::from_slice(&fs::read(record_file(paths, asker, ask)).ok()?).ok()?;
    let pid = record.get("pid").and_then(Value::as_u64).and_then(|p| u32::try_from(p).ok())?;
    let start = record.get("startTime").and_then(Value::as_u64)?;
    let uid = record.get("uid").and_then(Value::as_u64).and_then(|u| u32::try_from(u).ok())?;
    still_running(&paths.proc_root, pid, start, uid).then_some(pid)
}

/// The reply for an `apps.*` run ask from `peer_uid`.
pub fn answer(
    paths: &RunPaths,
    ask: Result<AppsRun, String>,
    peer_uid: Option<u32>,
    users: &dyn AppUsers,
) -> Value {
    reap();
    let ask = match ask {
        Ok(ask) => ask,
        Err(why) => return refusal("request.invalid", &why),
    };
    let Some(asker) = peer_uid else {
        return refusal("request.invalid", "apps: the asking user is unknown");
    };
    match ask {
        AppsRun::Spawn(ask) => {
            spawn(paths, asker, &ask, users).unwrap_or_else(|e| refusal("app.spawn", &e))
        }
        AppsRun::Status(ask) => {
            let pid = running(paths, asker, &ask);
            json!({"ok": true, "alive": pid.is_some(), "pid": pid})
        }
        AppsRun::Stop(ask) => {
            let pid = running(paths, asker, &ask);
            if let Some(pid) = pid.and_then(|p| i32::try_from(p).ok()) {
                // SAFETY: kill has no memory preconditions; the group is the app's session,
                // proven by its recorded start time.
                unsafe { libc::kill(-pid, libc::SIGTERM) };
            }
            json!({"ok": true, "stopped": pid.is_some()})
        }
    }
}

/// [`AppUsers`] on this machine: `getpwnam`, else `useradd --system`, and the account's
/// groups checked against the agent socket's.
pub struct SystemUsers;

fn lookup(name: &str) -> Option<AppUser> {
    let cname = std::ffi::CString::new(name).ok()?;
    // SAFETY: getpwnam takes a NUL-terminated name; the entry is read before any other call.
    let entry = unsafe { libc::getpwnam(cname.as_ptr()) };
    if entry.is_null() {
        return None;
    }
    // SAFETY: a non-null entry points to a valid passwd record.
    let (uid, gid) = unsafe { ((*entry).pw_uid, (*entry).pw_gid) };
    Some(AppUser { name: name.to_owned(), uid, gid })
}

fn group_id(name: &str) -> Option<u32> {
    let cname = std::ffi::CString::new(name).ok()?;
    // SAFETY: getgrnam takes a NUL-terminated name; the entry is read at once.
    let entry = unsafe { libc::getgrnam(cname.as_ptr()) };
    // SAFETY: a non-null entry points to a valid group record.
    (!entry.is_null()).then(|| unsafe { (*entry).gr_gid })
}

#[cfg(target_os = "linux")]
fn groups_of(user: &AppUser) -> Result<Vec<u32>, String> {
    let cname = std::ffi::CString::new(user.name.as_str()).map_err(|e| e.to_string())?;
    let mut groups = vec![0 as libc::gid_t; 64];
    let mut count = libc::c_int::try_from(groups.len()).unwrap_or(64);
    // SAFETY: getgrouplist writes at most `count` gids into `groups`.
    let rc = unsafe {
        libc::getgrouplist(cname.as_ptr(), user.gid, groups.as_mut_ptr(), &raw mut count)
    };
    if rc < 0 {
        return Err(format!("{} is in more than 64 groups", user.name));
    }
    groups.truncate(usize::try_from(count).unwrap_or(0));
    Ok(groups)
}

#[cfg(not(target_os = "linux"))]
fn groups_of(user: &AppUser) -> Result<Vec<u32>, String> {
    Err(format!("{}: app users are a Linux Cloud machine's", user.name))
}

impl AppUsers for SystemUsers {
    fn ensure(&self) -> Result<AppUser, String> {
        let user = match lookup(APP_USER) {
            Some(user) => user,
            None => {
                let mut add = Command::new("useradd");
                add.args([
                    "--system",
                    "--no-create-home",
                    "--shell",
                    "/usr/sbin/nologin",
                    APP_USER,
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
                let child = add.spawn().map_err(|e| format!("useradd {APP_USER}: {e}"))?;
                wait_bounded(child, USERADD_LIMIT, "useradd")?;
                lookup(APP_USER).ok_or_else(|| format!("useradd made no {APP_USER} account"))?
            }
        };
        let groups = groups_of(&user)?;
        // Root is refused here; `spawn` refuses the asking user's own uid.
        if !isolated(&user, &groups, group_id(AGENT_GROUP), u32::MAX) {
            return Err(format!(
                "{APP_USER} (uid {}) is root or in group {AGENT_GROUP}, so an app could reach this agent; refused",
                user.uid
            ));
        }
        Ok(user)
    }
}
