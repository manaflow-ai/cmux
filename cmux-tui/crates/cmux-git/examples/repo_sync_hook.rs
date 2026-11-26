//! The repository-sync gate alone, as a Claude Code PreToolUse hook command: it waits as
//! `cmux-tui-hook` does ([`cmux_git::native_hook::wait`]) without the session journal, so
//! a real chat can be timed on a checkout that is still filling (the `git_seed` dogfood,
//! `cmux-tui-core` `tests/dogfood.rs`). With `CMUX_HOOK_LOG` set it appends one line per
//! tool call: the wall time in ms, the tool, and `ran` or `denied`.

use std::io::{Read, Write};

fn main() {
    let mut payload = String::new();
    let _ = std::io::stdin().read_to_string(&mut payload);
    let native: serde_json::Value = serde_json::from_str(&payload).unwrap_or_default();
    let result =
        cmux_git::native_hook::wait("claude", "PreToolUse", &native, cmux_git::native_hook::WAIT);
    if let Some(log) = std::env::var_os("CMUX_HOOK_LOG") {
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_millis());
        let tool = native.get("tool_name").and_then(serde_json::Value::as_str).unwrap_or("");
        let outcome = if result.is_ok() { "ran" } else { "denied" };
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log) {
            let _ = writeln!(file, "{millis} {tool} {outcome}");
        }
    }
    if let Err(error) = result {
        println!("{}", cmux_git::native_hook::denial(&error.to_string()));
    }
}
