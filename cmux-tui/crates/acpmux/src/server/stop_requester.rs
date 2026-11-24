//! Who asked for a stop (`_acpmux/kill`): the client, its origin, its unix peer pid and that
//! process's command line, the session it runs in and, for a stop a peer forwarded, who asked
//! the peer. The hub logs it and puts it on the chat's `stopped` and closing `status` records
//! (`hub/stop_requester.rs`).
//!
//! Lane agents died mid-task in waves across lane VMs (2026-11-24, hq#22914: 204 exit-143s in
//! 6 h, 137 shaped like stop requests) and no host said who stopped them: the stop path logged
//! nothing of its requester, and a stop a peer forwarded came in as the peer link alone.
//!
//! Provenance only, never a proof: what a peer says of its own client is that peer's word, kept
//! under `forwardedFor`, and a client's own claim is dropped at the forwarding daemon.

use super::{Conn, Origin};
use serde_json::{Value, json};

/// The `_meta.acpmux` key a forwarding daemon names its own requester under.
pub(super) const KEY: &str = "stopRequester";

/// The longest command line kept, in bytes.
const CMDLINE_CAP: usize = 300;

/// Who on `conn` asked for this stop, with the forwarding daemon's word for a peer's request.
pub(super) fn of(conn: &Conn, params: &Value) -> Value {
    let caller = conn.stats_caller();
    let mut by = json!({
        "client": caller.client,
        "origin": caller.origin,
        "conn": conn.id,
    });
    if let Some(pid) = caller.pid {
        by["pid"] = json!(pid);
        if let Some(cmd) = cmdline(pid) {
            by["cmd"] = json!(cmd);
        }
        if let Some(ppid) = parent_of(pid) {
            by["ppid"] = json!(ppid);
            if let Some(cmd) = cmdline(ppid) {
                by["parentCmd"] = json!(cmd);
            }
        }
    }
    if let Some(session) = caller.session {
        by["session"] = json!(session);
        by["sessionProven"] = json!(caller.proven);
    }
    if conn.origin == Origin::Peer
        && let Some(theirs) =
            params.pointer(&format!("/_meta/acpmux/{KEY}")).filter(|v| v.is_object())
    {
        by["forwardedFor"] = theirs.clone();
    }
    by
}

/// Names this daemon's requester on a stop it forwards to a peer: this machine and [`of`] its
/// connection, in place of anything the client put there.
pub(super) fn stamp(conn: &Conn, params: &Value, forwarded: &mut Value) {
    let mut by = of(conn, params);
    by["host"] = json!(crate::pairing::machine_name());
    if let Some(mux) = forwarded.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(KEY);
    }
    crate::hub::merge_mux_meta(forwarded, json!({KEY: by}));
}

/// The process's command line, its arguments joined by spaces and cut at [`CMDLINE_CAP`].
#[cfg(target_os = "linux")]
fn cmdline(pid: u32) -> Option<String> {
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let text = raw
        .split(|b| *b == 0)
        .filter(|part| !part.is_empty())
        .map(String::from_utf8_lossy)
        .collect::<Vec<_>>()
        .join(" ");
    (!text.is_empty()).then(|| cut(text))
}

#[cfg(not(target_os = "linux"))]
fn cmdline(_pid: u32) -> Option<String> {
    None
}

/// The process's parent pid, from `/proc/PID/stat` (the field after the parenthesised name).
#[cfg(target_os = "linux")]
fn parent_of(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(not(target_os = "linux"))]
fn parent_of(_pid: u32) -> Option<u32> {
    None
}

fn cut(mut text: String) -> String {
    if text.len() > CMDLINE_CAP {
        let mut end = CMDLINE_CAP;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_command_line_is_cut_at_a_character() {
        let text = format!("{}é", "a".repeat(CMDLINE_CAP - 1));
        let cut = cut(text);
        assert!(cut.len() <= CMDLINE_CAP);
        assert!(cut.chars().all(|c| c == 'a'));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn this_process_reads_its_own_command_line_and_parent() {
        let pid = std::process::id();
        assert!(cmdline(pid).is_some_and(|c| !c.is_empty()));
        assert_eq!(parent_of(pid), Some(std::os::unix::process::parent_id()));
    }
}
