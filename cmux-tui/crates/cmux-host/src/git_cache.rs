//! The machine's git cache (`cmux-git-cache`): on a Cloud machine `cmux host run` starts
//! `cmux host git-cache serve` as the work user and restarts it when it exits, so an agent's
//! plain `git clone https://github.com/...` is served from this machine's mirror.
//!
//! Nothing intercepted an agent's git clone before, so each one went to GitHub.
//!
//! Wiring: `/etc/gitconfig` includes [`INCLUDE`], which only the running proxy writes (and
//! removes when it stops; this supervisor removes it too whenever the proxy is not running).
//! git ignores an include whose file is missing, so a machine without a running proxy reaches
//! GitHub directly, exactly as before. Off: `/etc/cmux/git-cache.disabled` exists, or
//! `CMUX_GIT_CACHE=0` in the unit's environment.
//!
//! cargo: `/.cargo/config.toml` (read by cargo from every working directory, whatever
//! `CARGO_HOME` is) is a link to [`CARGO_CONFIG`], which only the running proxy writes
//! (`cmux_git_cache::crates`: crates.io through this machine's cache). cargo treats a dangling
//! link as no file, so without a running proxy cargo reaches crates.io directly. A machine that
//! already has its own `/.cargo/config.toml` keeps it (no link). Off for cargo alone:
//! `/etc/cmux/crates-cache.disabled`.

use cmux_process::{Command, Stdio};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::proc_roles::privilege::WorkUser;

pub use cmux_git_cache::gitconfig::{DEFAULT_PORT, RUN_INCLUDE as INCLUDE};

pub const DISABLED_FILE: &str = "/etc/cmux/git-cache.disabled";
pub const CACHE_ROOT: &str = "/var/cache/cmux/git-cache";
pub const EDGE: &str = "https://platform.cmux.internal/v1/cloud/git/github.com";
const EDGE_HOST: &str = "platform.cmux.internal:443";
/// The cargo config the proxy writes while it listens, beside the git include (tmpfs).
pub const CARGO_CONFIG: &str = "/run/cmux/git-cache/cargo-config.toml";
pub use cmux_git_cache::crates::ROOT_CARGO_CONFIG;
const STORE_CMUX: &str = "/opt/cmux/current/bin/cmux";

/// The `/etc/gitconfig` stanza that includes the proxy's file.
pub fn include_stanza() -> String {
    format!("[include]\n\tpath = {INCLUDE}\n")
}

/// `/etc/gitconfig` with the stanza, or `None` when it already has it.
pub fn plan_system(current: Option<&str>) -> Option<String> {
    let current = current.unwrap_or("");
    if current.lines().any(|l| l.trim() == format!("path = {INCLUDE}")) {
        return None;
    }
    let mut next = current.to_owned();
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(&include_stanza());
    Some(next)
}

/// The program and leading words that run this binary's `host` verbs.
fn host_argv(self_argv: &[String]) -> Vec<String> {
    if Path::new(STORE_CMUX).is_file() {
        return vec![STORE_CMUX.to_owned(), "host".to_owned()];
    }
    if !self_argv.is_empty() {
        return self_argv.to_vec();
    }
    std::env::current_exe().map(|p| vec![p.to_string_lossy().into_owned()]).unwrap_or_default()
}

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The `serve` arguments for this machine.
pub fn serve_args(host: &[String], tenant: &str, edge: bool) -> Vec<String> {
    let helper = format!(
        "!{} git-cache credential",
        host.iter().map(|w| sh_quote(w)).collect::<Vec<_>>().join(" ")
    );
    let mut args: Vec<String> = host[1..].to_vec();
    args.extend(
        [
            "git-cache",
            "serve",
            "--listen",
            &format!("127.0.0.1:{DEFAULT_PORT}"),
            "--tenant",
            tenant,
            "--cache",
            CACHE_ROOT,
            "--include",
            INCLUDE,
            "--helper",
            &helper,
            "--cargo-config",
            CARGO_CONFIG,
        ]
        .map(str::to_owned),
    );
    if edge {
        args.extend(["--edge".to_owned(), EDGE.to_owned()]);
    }
    args
}

/// Links `/.cargo/config.toml` to the proxy's cargo config, unless the machine has its own file there.
pub fn link_root_cargo_config(root_config: &Path, target: &Path) -> std::io::Result<bool> {
    match std::fs::read_link(root_config) {
        Ok(current) if current == target => return Ok(true),
        Ok(_) => return Ok(false),
        Err(_) if std::fs::symlink_metadata(root_config).is_ok() => return Ok(false),
        Err(_) => {}
    }
    if let Some(dir) = root_config.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::os::unix::fs::symlink(target, root_config)?;
    Ok(true)
}

fn disabled() -> bool {
    Path::new(DISABLED_FILE).exists() || std::env::var("CMUX_GIT_CACHE").is_ok_and(|v| v == "0")
}

fn chown_dir(dir: &Path, user: Option<&WorkUser>) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    if let Some(user) = user {
        std::os::unix::fs::chown(dir, Some(user.uid), Some(user.gid))?;
    }
    Ok(())
}

/// Starts the supervisor thread (root, system root only). Never fatal: any failure leaves the
/// include absent, so git goes to GitHub directly.
pub fn start(self_argv: &[String], tenant: Option<String>, work: Option<WorkUser>) {
    cmux_git_cache::gitconfig::remove_include(Path::new(INCLUDE));
    cmux_git_cache::crates::remove_cargo_config(Path::new(CARGO_CONFIG));
    if disabled() {
        return;
    }
    if let Err(e) = link_root_cargo_config(Path::new(ROOT_CARGO_CONFIG), Path::new(CARGO_CONFIG)) {
        eprintln!("cmux host: git cache: {ROOT_CARGO_CONFIG}: {e}");
    }
    let system = std::fs::read_to_string(crate::github_wiring::SYSTEM_GITCONFIG).ok();
    if let Some(next) = plan_system(system.as_deref())
        && let Err(e) = cmux_git_cache::gitconfig::write_include(
            Path::new(crate::github_wiring::SYSTEM_GITCONFIG),
            &next,
        )
    {
        eprintln!("cmux host: git cache: {}: {e}", crate::github_wiring::SYSTEM_GITCONFIG);
        return;
    }
    let include_dir = Path::new(INCLUDE).parent().map(Path::to_path_buf).unwrap_or_default();
    for dir in [include_dir.as_path(), Path::new(CACHE_ROOT)] {
        if let Err(e) = chown_dir(dir, work.as_ref()) {
            eprintln!("cmux host: git cache: {}: {e}", dir.display());
            return;
        }
    }
    let host = host_argv(self_argv);
    if host.is_empty() {
        return;
    }
    let tenant = tenant.unwrap_or_else(|| "machine".to_owned());
    let spawned = std::thread::Builder::new().name("git-cache".to_owned()).spawn(move || {
        // Resolved in the thread: a slow resolver never delays the agent.
        let edge = std::net::ToSocketAddrs::to_socket_addrs(EDGE_HOST).is_ok();
        supervise(&host[0], &serve_args(&host, &tenant, edge), work.as_ref());
    });
    if let Err(e) = spawned {
        eprintln!("cmux host: git cache: thread: {e}");
    }
}

fn supervise(program: &str, args: &[String], work: Option<&WorkUser>) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        match spawn(program, args, work) {
            Ok(mut child) => {
                let status = child.wait();
                eprintln!("cmux host: git cache exited: {status:?}");
            }
            Err(e) => eprintln!("cmux host: git cache: spawn: {e}"),
        }
        cmux_git_cache::gitconfig::remove_include(Path::new(INCLUDE));
        cmux_git_cache::crates::remove_cargo_config(Path::new(CARGO_CONFIG));
        if disabled() {
            return;
        }
        if started.elapsed() > Duration::from_secs(120) {
            backoff = Duration::from_secs(1);
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(300));
    }
}

/// The proxy under `setpriv`: the work user's ids (no supplementary groups) when there is one,
/// and SIGTERM when cmux host dies (the next start removes its include first). In a session
/// of its own; the `Child` ends it with the supervisor.
fn spawn(
    program: &str,
    args: &[String],
    work: Option<&WorkUser>,
) -> std::io::Result<cmux_process::Child> {
    let mut cmd = Command::new("setpriv");
    if let Some(u) = work {
        cmd.arg(format!("--reuid={}", u.uid))
            .arg(format!("--regid={}", u.gid))
            .arg("--clear-groups")
            .env("HOME", &u.home)
            .current_dir(PathBuf::from(&u.home));
    }
    cmd.arg("--pdeathsig=TERM")
        .arg("--")
        .arg(program)
        .args(args)
        .stdin(Stdio::null())
        .env_remove("NOTIFY_SOCKET")
        .new_session();
    cmd.spawn()
}

#[cfg(test)]
#[path = "git_cache_tests.rs"]
mod tests;
