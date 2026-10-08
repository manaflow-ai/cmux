//! `cmux host team-ssh …`:
//! - `apply [--root DIR]`: a `team_vm.ssh_ca` value on stdin; writes the
//!   KRL, CA keys and state, then ends revoked sessions. Exit 4 = refused.
//! - `principals <user> [--root DIR]`: sshd `AuthorizedPrincipalsCommand`;
//!   prints nothing unless trust is fresh.
//! - `session-open [--root DIR]`: pam_exec hook (open_session records the
//!   certificate session, close_session removes it). Exit 1 refuses the
//!   session, so a certificate session is never left unrecorded.
//! - `reap [--root DIR]`: one reaper pass.

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
        "cmux host team-ssh: {msg}\nusage: cmux host team-ssh apply|principals <user>|session-open|reap [--root DIR]"
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
        ["principals", user] => {
            let out = store::principals(&paths, user, now());
            if out.is_empty() {
                eprintln!("cmux host team-ssh: no principals for {user} (trust missing or stale)");
            }
            print!("{out}");
            0
        }
        ["session-open"] => session_verb(&paths),
        ["reap"] => reap_verb(&paths),
        _ => usage("unknown arguments"),
    }
}

fn apply_verb(paths: &Paths) -> u8 {
    let mut text = String::new();
    if let Err(e) = std::io::stdin().take(MAX_SNAPSHOT_BYTES).read_to_string(&mut text) {
        eprintln!("cmux host team-ssh apply: stdin: {e}");
        return 2;
    }
    let snapshot: trust::Snapshot = match serde_json::from_str(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cmux host team-ssh apply: snapshot: {e}");
            return 2;
        }
    };
    let applied = match store::apply(paths, &snapshot, now()) {
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
            "ended": reaped.0,
            "errors": reaped.1,
        })
    );
    if reaped.1.is_empty() { 0 } else { 1 }
}

#[cfg(target_os = "linux")]
fn reap_pass(paths: &Paths) -> (Vec<u32>, Vec<String>) {
    let host = super::linux_host::LinuxHost::new(paths.at(super::SESSIONS_DIR));
    let out = super::sessions::reap(paths, &host);
    (out.ended, out.errors)
}

#[cfg(not(target_os = "linux"))]
fn reap_pass(_paths: &Paths) -> (Vec<u32>, Vec<String>) {
    (Vec::new(), Vec::new())
}

fn reap_verb(paths: &Paths) -> u8 {
    let (ended, errors) = reap_pass(paths);
    println!("{}", serde_json::json!({ "ended": ended, "errors": errors }));
    if errors.is_empty() { 0 } else { 1 }
}

#[cfg(target_os = "linux")]
fn session_verb(paths: &Paths) -> u8 {
    use super::sessions::{SessionRecord, forget, save};
    let var = |k: &str| std::env::var(k).ok();
    // SAFETY: getppid has no preconditions.
    let parent = unsafe { libc::getppid() } as u32;
    match var("PAM_TYPE").as_deref() {
        Some("open_session") => {}
        Some("close_session") => return u8::from(forget(paths, parent).is_err()),
        _ => return 0,
    }
    let certs = match super::cert::session_certs(&var("SSH_AUTH_INFO_0").unwrap_or_default()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cmux host team-ssh session-open: {e}");
            return 1;
        }
    };
    if certs.is_empty() {
        return 0;
    }
    let host = super::linux_host::LinuxHost::new(paths.at(super::SESSIONS_DIR));
    use super::sessions::Host;
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
