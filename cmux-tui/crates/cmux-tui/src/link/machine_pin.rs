//! `cmux link machine pin`: names the cmux-tui build this client pins for a
//! Cloud machine (Linux x86_64), resolved as `cmux link machine update`
//! resolves it (`cmux_remote::pinned_linux_pin`): the manifest beside this
//! executable, else this build's own published commit, else the commit that
//! published its cmux-tui tree. Read-only; nothing is downloaded.
//!
//! The app's legacy machine update (a machine too old for `machine update`)
//! asks for it when its bundle ships no manifest (a DEV build). One JSON
//! line: `{"ok":true,"commit":..,"sha256":..,"target":"x86_64-unknown-linux-musl"}`,
//! or `{"ok":false,"error":..,"error_code":..}` (exit 1; bad usage exits 64).

use serde_json::{Value, json};

const USAGE: &str = "usage: cmux link machine pin";
/// Every Cloud image bakes an x86_64 machine (images/cmux-vm inputs.lock.json).
const CLOUD_ARCH: &str = "x86_64";
const TARGET: &str = "x86_64-unknown-linux-musl";

pub(super) fn run(args: &[String]) -> i32 {
    match args {
        [] => {}
        [flag] if matches!(flag.as_str(), "-h" | "--help" | "help") => {
            println!("{USAGE}");
            return 0;
        }
        _ => {
            eprintln!("{USAGE}");
            return 64;
        }
    }
    let resolved = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())
        .map(|runtime| {
            runtime.block_on(cmux_remote::pinned_linux_pin(
                CLOUD_ARCH,
                cmux_build_identity::BUILD_IDENTITY,
            ))
        });
    let line = match resolved {
        Ok(pinned) => answer(pinned),
        Err(error) => failed("machine_update_failed", &error),
    };
    println!("{line}");
    i32::from(line.get("ok").and_then(Value::as_bool) != Some(true))
}

/// The one JSON line for a resolved (or unresolved) pin.
fn answer(
    pinned: Result<Option<cmux_remote::LinuxPin>, cmux_remote::ssh_bootstrap::BootstrapError>,
) -> Value {
    match pinned {
        Ok(Some(pin)) if is_hex(&pin.sha256, 64) && is_hex(&pin.commit, 40) => {
            json!({"ok": true, "commit": pin.commit, "sha256": pin.sha256, "target": TARGET})
        }
        Ok(Some(_)) => failed("machine_update_payload_rejected", "the pin is malformed"),
        Ok(None) => failed(
            "machine_update_unavailable",
            "this cmux build carries no pinned machine build, and none is published for its commit or cmux-tui tree yet",
        ),
        Err(error) => failed("machine_update_unavailable", &error.to_string()),
    }
}

fn failed(code: &str, error: &str) -> Value {
    json!({"ok": false, "error": error, "error_code": code})
}

/// `length` lowercase hex digits.
fn is_hex(text: &str, length: usize) -> bool {
    text.len() == length && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests;
