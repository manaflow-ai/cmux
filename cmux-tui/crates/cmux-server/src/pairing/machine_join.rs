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

fn run(args: &[&str], stdin: Option<&str>) -> Result<Value, &'static str> {
    let mut child = Command::new(acpmux())
        .args(args)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "server.pair.machine_join_no_acpmux")?;
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
    if status.success() { Ok(value) } else { Err("server.pair.machine_join_refused") }
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
        .is_some_and(|status| status["revoked"] == true || status["cloned"] == true);
    let mut args = vec!["host", "join", "--hub", hub, "--json"];
    // acpmux's own name rule (1 to 63 bytes); a longer one takes acpmux's default, the host name.
    if !name.is_empty() && name.len() <= 63 {
        args.extend(["--name", name]);
    }
    if revoked {
        args.push("--replace");
    }
    match run(&args, Some(join.token())) {
        Ok(value) => {
            let mut out = json!({"state":"joined"});
            for (from, to) in [
                ("machineId", "machine_id"),
                ("teamId", "team"),
                ("alreadyJoined", "already_joined"),
            ] {
                if let Some(v) = value.get(from).filter(|v| v.is_string() || v.is_boolean()) {
                    out[to] = v.clone();
                }
            }
            out
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
    fn the_token_never_shows_in_debug() {
        let token = format!("cmj_{}", "s".repeat(43));
        let join = MachineJoin::for_tests(&token, 7);
        assert!(join.well_formed());
        assert!(!format!("{join:?}").contains(&token));
        assert!(!MachineJoin::for_tests("cmj_short", 7).well_formed());
        assert!(!MachineJoin::for_tests(&format!("cmm_{}", "a".repeat(43)), 7).well_formed());
    }
}
