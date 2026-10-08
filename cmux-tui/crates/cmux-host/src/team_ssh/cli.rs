//! `cmux host team-ssh …`:
//! - `apply [--root DIR]`: a `team_vm.ssh_ca` value on stdin; writes the
//!   KRL, CA keys and state, then ends revoked sessions. Exit 4 = refused.
//! - `accounts-apply [--root DIR]`: a `team_vm.accounts` value on stdin;
//!   creates the members' users and principals files, removes the
//!   principals of members who left, then runs the reaper (Linux only).
//! - `principals <user> [--root DIR]`: sshd `AuthorizedPrincipalsCommand`;
//!   prints nothing unless trust is fresh.
//! - `session-open [--root DIR]`: pam_exec hook (open_session records the
//!   certificate session, close_session removes it). Exit 1 refuses the
//!   session, so a certificate session is never left unrecorded, and a
//!   session with no logind session (nothing would scope its processes) is
//!   refused.
//! - `reap [--root DIR]`: one reaper pass (revoked sessions, then the team
//!   users' lingering and user managers).

use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

use super::{store, trust};
use crate::config::Paths;

const MAX_SNAPSHOT_BYTES: u64 = 8 * 1024 * 1024;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn split_root(args: &[String]) -> Result<(Paths, Vec<String>), String> {
    let mut paths = Paths::new("/");
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--root" {
            paths = Paths::new(it.next().ok_or("--root needs a value")?);
        } else {
            rest.push(arg.clone());
        }
    }
    Ok((paths, rest))
}

fn usage(msg: &str) -> u8 {
    eprintln!(
        "cmux host team-ssh: {msg}\nusage: cmux host team-ssh apply|accounts-apply|principals <user>|session-open|reap|sync [--once] [--root DIR]"
    );
    2
}

/// Entry for `cmux host team-ssh <args>`.
pub fn run(args: &[String]) -> u8 {
    let (paths, rest) = match split_root(args) {
        Ok(v) => v,
        Err(e) => return usage(&e),
    };
    match rest.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["apply"] => apply_verb(&paths),
        ["accounts-apply"] => accounts_verb(&paths),
        ["principals", user] => {
            let out = store::principals(&paths, user, now());
            if out.is_empty() {
                eprintln!("cmux host team-ssh: no principals for {user} (trust missing or stale)");
            }
            print!("{out}");
            0
        }
        ["session-open"] => session_verb(&paths),
        ["sync"] => sync_verb(&paths, false),
        ["sync", "--once"] => sync_verb(&paths, true),
        ["reap"] => reap_verb(&paths),
        _ => usage("unknown arguments"),
    }
}

#[cfg(target_os = "linux")]
fn sync_verb(paths: &Paths, once: bool) -> u8 {
    super::sync::run(paths, once)
}

#[cfg(not(target_os = "linux"))]
fn sync_verb(_paths: &Paths, _once: bool) -> u8 {
    eprintln!("cmux host team-ssh sync: Linux only");
    4
}

fn read_stdin(verb: &str) -> Option<String> {
    let mut text = String::new();
    match std::io::stdin().take(MAX_SNAPSHOT_BYTES).read_to_string(&mut text) {
        Ok(_) => Some(text),
        Err(e) => {
            eprintln!("cmux host team-ssh {verb}: stdin: {e}");
            None
        }
    }
}

#[cfg(target_os = "linux")]
fn accounts_verb(paths: &Paths) -> u8 {
    let Some(text) = read_stdin("accounts-apply") else { return 2 };
    let wanted = match serde_json::from_str(&text)
        .map_err(|e| e.to_string())
        .and_then(|view| super::accounts::verify(&view))
    {
        Ok(w) => w,
        Err(e) => {
            eprintln!("cmux host team-ssh accounts-apply: refused: {e}");
            return 4;
        }
    };
    let done = super::accounts::reconcile(
        paths,
        &wanted,
        &super::accounts_linux::LinuxAccounts::default(),
    );
    let reaped = reap_pass(paths);
    println!(
        "{}",
        serde_json::json!({
            "created": done.created,
            "written": done.written,
            "removed": done.removed,
            "refused": done.refused,
            "ended": reaped.ended,
            "errors": done.errors.iter().chain(&reaped.errors).collect::<Vec<_>>(),
        })
    );
    if done.errors.is_empty() && reaped.errors.is_empty() { 0 } else { 1 }
}

#[cfg(not(target_os = "linux"))]
fn accounts_verb(_paths: &Paths) -> u8 {
    eprintln!("cmux host team-ssh accounts-apply: Linux only");
    4
}

fn apply_verb(paths: &Paths) -> u8 {
    let Some(text) = read_stdin("apply") else { return 2 };
    let snapshot: trust::Snapshot = match serde_json::from_str(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cmux host team-ssh apply: snapshot: {e}");
            return 2;
        }
    };
    let applied = match store::apply(paths, &snapshot, now(), &store::ssh_keygen_check) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("cmux host team-ssh apply: refused: {e}");
            return 4;
        }
    };
    let reaped = reap_pass(paths);
    println!(
        "{}",
        serde_json::json!({
            "krl_version": applied.state.krl_version,
            "generation": applied.state.generation,
            "krl_changed": applied.krl_changed,
            "ended": reaped.ended,
            "linger_off": reaped.linger_off,
            "managers_stopped": reaped.managers_stopped,
            "errors": reaped.errors,
        })
    );
    if reaped.errors.is_empty() { 0 } else { 1 }
}

#[cfg(target_os = "linux")]
fn reap_pass(paths: &Paths) -> super::sessions::Reaped {
    let host = super::linux_host::LinuxHost::new(paths.at(super::SESSIONS_DIR));
    super::sessions::reap(paths, &host)
}

#[cfg(not(target_os = "linux"))]
fn reap_pass(_paths: &Paths) -> super::sessions::Reaped {
    super::sessions::Reaped::default()
}

fn reap_verb(paths: &Paths) -> u8 {
    let reaped = reap_pass(paths);
    println!(
        "{}",
        serde_json::json!({
            "ended": reaped.ended,
            "linger_off": reaped.linger_off,
            "managers_stopped": reaped.managers_stopped,
            "errors": reaped.errors,
        })
    );
    if reaped.errors.is_empty() { 0 } else { 1 }
}

#[cfg(target_os = "linux")]
fn session_verb(paths: &Paths) -> u8 {
    use super::sessions::{SessionRecord, forget, save};
    let var = |k: &str| std::env::var(k).ok();
    use super::sessions::Host;
    // SAFETY: getppid has no preconditions.
    let parent = unsafe { libc::getppid() } as u32;
    let host = super::linux_host::LinuxHost::new(paths.at(super::SESSIONS_DIR));
    match var("PAM_TYPE").as_deref() {
        Some("open_session") => {}
        Some("close_session") => {
            return match host.start_time(parent) {
                Some(start) => u8::from(forget(paths, parent, start).is_err()),
                None => 0,
            };
        }
        _ => return 0,
    }
    let auth_info = var("SSH_AUTH_INFO_0").unwrap_or_default();
    let certs = match super::cert::required_session_certs(&auth_info) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cmux host team-ssh session-open: {e}");
            return 1;
        }
    };
    let (Some(start), Some(comm)) = (host.start_time(parent), host.comm(parent)) else {
        eprintln!("cmux host team-ssh session-open: parent {parent} is gone");
        return 1;
    };
    if !comm.starts_with("sshd") {
        eprintln!("cmux host team-ssh session-open: parent is {comm}, not sshd");
        return 1;
    }
    let user = var("PAM_USER").unwrap_or_default();
    let record = SessionRecord::new(parent, start, &user, &certs, var("XDG_SESSION_ID"));
    // Only a logind session scopes every process of the session, so only
    // then can a revocation end them all (pam_systemd is `optional` and
    // opens none when sshd already runs inside a session).
    let Some(id) = record.logind_session.as_deref() else {
        eprintln!("cmux host team-ssh session-open: no logind session (pam_systemd), refused");
        return 1;
    };
    if host.session_leader(id) != Some(parent) {
        eprintln!(
            "cmux host team-ssh session-open: logind session {id} is not led by sshd {parent}, refused"
        );
        return 1;
    }
    match save(paths, &record) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux host team-ssh session-open: {e}");
            1
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn session_verb(_paths: &Paths) -> u8 {
    eprintln!("cmux host team-ssh session-open: Linux only");
    4
}
