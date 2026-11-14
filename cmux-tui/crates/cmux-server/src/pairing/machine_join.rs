//! The paired box's machine credential. Leo, 2026-11-05: "I don't want to deal
//! with SSH keys. I just want the app to handle the thing for me." An approval
//! pushes a single-use join token minted for the approver (the backend's
//! pair-machine-join.ts) with the result; this box redeems it exactly as a
//! pasted join line does: `acpmux host join` with the token on stdin, never in
//! argv. So a box paired with a code and one joined with `cmux machine add`
//! end in the same `cmm_` machine record (`~/.acpmux/machine-credential.json`
//! and `meshRelay` in its config), listed by `cmux machine list` and revoked by
//! `cmux machine revoke` or `acpmux machine leave`.
//!
//! The pairing stands whatever happens here: a join that fails is reported in
//! the result's `machine` field, with a code and no secret.

use std::io::{Read as _, Write as _};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use cmux_server_core::pairing::enrollment::MachineJoin;
use serde_json::{Value, json};

/// The cmux platform that redeems the API's join tokens: each API's own.
pub fn platform_for(api: &str) -> Option<&'static str> {
    use cmux_cloud_environment as e;
    match api.trim_end_matches('/') {
        a if a == e::PRODUCTION_API => Some(e::PRODUCTION_PLATFORM),
        a if a == e::STAGING_API => Some(e::STAGING_PLATFORM),
        a if a == e::DEVELOPMENT_API => Some(e::DEVELOPMENT_PLATFORM),
        _ => None,
    }
}

/// acpmux next to this binary (one install ships both), else on PATH.
fn acpmux() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("acpmux")))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("acpmux"))
}

/// What the result's `machine` field says when nothing could be joined.
pub fn failed(code: &str) -> Value {
    json!({"state":"failed","code":code})
}

const JOIN_DEADLINE: Duration = Duration::from_secs(90);

/// The start of the line `acpmux host join` prints on stderr when it leaves the box without its
/// update timer (`acpmux/src/cli/run/extra.rs`); the rest of the line says why.
const TIMER_NOTE: &str = "acpmux update timer: ";

/// The most stderr read from one acpmux call.
const STDERR_MAX: u64 = 16 * 1024;

/// What one acpmux call answered: its JSON on stdout and its stderr.
struct Answer {
    value: Value,
    stderr: String,
}

fn run(args: &[&str], stdin: Option<&str>) -> Result<Answer, &'static str> {
    let mut child = Command::new(acpmux())
        .args(args)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| "server.pair.machine_join_no_acpmux")?;
    // Read while the child runs, so a full pipe never holds it; bounded, the rest drained.
    let stderr = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut text = Vec::new();
            let _ = pipe.by_ref().take(STDERR_MAX).read_to_end(&mut text);
            let _ = std::io::copy(&mut pipe, &mut std::io::sink());
            String::from_utf8_lossy(&text).into_owned()
        })
    });
    if let Some(text) = stdin {
        let mut pipe = child.stdin.take().ok_or("server.pair.machine_join_failed")?;
        let written = pipe.write_all(text.as_bytes()).and_then(|()| pipe.write_all(b"\n"));
        drop(pipe);
        if written.is_err() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("server.pair.machine_join_failed");
        }
    }
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < JOIN_DEADLINE => {
                std::thread::sleep(Duration::from_millis(50));
            }
            _ => {
                // Our own child only.
                let _ = child.kill();
                let _ = child.wait();
                return Err("server.pair.machine_join_timeout");
            }
        }
    };
    let mut out = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.by_ref().take(64 * 1024).read_to_end(&mut out);
    }
    let value: Value = serde_json::from_slice(&out).unwrap_or(Value::Null);
    let stderr = stderr.and_then(|reader| reader.join().ok()).unwrap_or_default();
    if status.success() {
        Ok(Answer { value, stderr })
    } else {
        Err("server.pair.machine_join_refused")
    }
}

/// Why the join left the box without its update timer, from acpmux's stderr: the last
/// [`TIMER_NOTE`] line, one line of at most 300 bytes with no secret-shaped text.
fn timer_note(stderr: &str) -> Option<String> {
    let note = stderr.lines().rev().find_map(|line| line.trim().strip_prefix(TIMER_NOTE))?.trim();
    let clean = !note.is_empty()
        && note.len() <= 300
        && !note.contains("cmj_")
        && !note.contains("cmm_")
        && !note.chars().any(char::is_control);
    clean.then(|| format!("acpmux-update.timer: {note}"))
}

/// Redeems `join` with acpmux for the platform of `api`, as `name`. A machine
/// whose earlier credential was revoked rejoins with `--replace`, as join.sh
/// does; a live one stays as it is.
pub fn redeem(join: &MachineJoin, api: &str, name: &str) -> Value {
    let Some(hub) = platform_for(api) else {
        return failed("server.pair.machine_join_unknown_api");
    };
    let revoked = run(&["host", "join", "--status", "--hub", hub, "--json"], None)
        .ok()
        .map(|answer| answer.value)
        .is_some_and(|status| {
            ["revoked", "cloned"]
                .iter()
                .any(|k| status.get(k).and_then(Value::as_bool) == Some(true))
        });
    let mut args = vec!["host", "join", "--hub", hub, "--json"];
    // acpmux's own name rule (1 to 63 bytes); a longer one takes acpmux's default, the host name.
    if !name.is_empty() && name.len() <= 63 {
        args.extend(["--name", name]);
    }
    if revoked {
        args.push("--replace");
    }
    match run(&args, Some(join.token())) {
        Ok(Answer { value, stderr }) => {
            let mut out = serde_json::Map::new();
            out.insert("state".into(), "joined".into());
            // Joined, but not keeping itself on the newest build: the person sees why.
            if let Some(note) = timer_note(&stderr) {
                out.insert("note".into(), note.into());
            }
            for (from, to) in [
                ("machineId", "machine_id"),
                ("teamId", "team"),
                ("alreadyJoined", "already_joined"),
            ] {
                if let Some(v) = value.get(from).filter(|v| v.is_string() || v.is_boolean()) {
                    out.insert(to.into(), v.clone());
                }
            }
            Value::Object(out)
        }
        Err(code) => failed(code),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_api_joins_its_own_platform_and_an_unknown_api_none() {
        use cmux_cloud_environment as e;
        assert_eq!(platform_for(e::PRODUCTION_API), Some(e::PRODUCTION_PLATFORM));
        assert_eq!(platform_for(&format!("{}/", e::STAGING_API)), Some(e::STAGING_PLATFORM));
        assert_eq!(platform_for(e::DEVELOPMENT_API), Some(e::DEVELOPMENT_PLATFORM));
        assert_eq!(platform_for("https://example.com"), None);
        assert_eq!(
            redeem(
                &MachineJoin::for_tests(&format!("cmj_{}", "a".repeat(43)), 1),
                "https://example.com",
                "box"
            ),
            failed("server.pair.machine_join_unknown_api")
        );
    }

    #[test]
    fn a_join_without_its_update_timer_says_why_and_nothing_else() {
        let stderr = "Existing Computer Use helpers may remain ungated until they exit\n\
            acpmux update timer: XDG_CONFIG_HOME is set, so systemd reads user units from there\n";
        assert_eq!(
            timer_note(stderr).as_deref(),
            Some(
                "acpmux-update.timer: XDG_CONFIG_HOME is set, so systemd reads user units from there"
            )
        );
        // Other stderr is no note; nor is a secret-shaped or overlong one.
        assert_eq!(timer_note("Existing Computer Use helpers may remain ungated\n"), None);
        assert_eq!(timer_note(""), None);
        assert_eq!(timer_note("acpmux update timer: cmm_secret\n"), None);
        assert_eq!(timer_note(&format!("acpmux update timer: {}\n", "x".repeat(400))), None);
    }

    #[test]
    fn the_token_never_shows_in_debug() {
        let token = format!("cmj_{}", "s".repeat(43));
        let join = MachineJoin::for_tests(&token, 7);
        assert!(join.well_formed());
        assert!(!format!("{join:?}").contains(&token));
        assert!(!MachineJoin::for_tests("cmj_short", 7).well_formed());
        assert!(!MachineJoin::for_tests(&format!("cmm_{}", "a".repeat(43)), 7).well_formed());
    }
}
