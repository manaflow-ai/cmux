//! The user's login-shell environment. A Finder- or Dock-launched app gets
//! launchd's minimal `PATH`, and every PTY inherits the daemon's, so the app
//! captures `$SHELL -l -i -c 'env -0'` once ([`capture_plan`], then
//! [`parse`]) and remembers the allowlisted part for the next launch
//! ([`store_encode`], [`store_decode`]).

use crate::Env;
use crate::terminal_env::filter;
use serde::{Deserialize, Serialize};

/// Printed before `env -0` so rc-file chatter on stdout is skipped.
pub const MARKER: &str = "__CMUX_NEXT_LOGIN_ENV__";
/// The store file's version.
pub const STORE_VERSION: u32 = 1;

/// The capture's process: the shell, its arguments and its seed environment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapturePlan {
    pub shell: String,
    pub arguments: Vec<String>,
    pub environment: Env,
}

/// The capture for `shell` (none: the base's `SHELL`, then the user's
/// account shell, then zsh). `HOME`, `USER` and `LOGNAME` must be right for
/// rc files; the rest comes from the shell.
pub fn capture_plan(shell: Option<&str>, base: &Env, user_shell: Option<&str>) -> CapturePlan {
    let shell = shell
        .map(str::to_string)
        .or_else(|| base.get("SHELL").filter(|s| !s.is_empty()).cloned())
        .or_else(|| user_shell.filter(|s| !s.is_empty()).map(str::to_string))
        .unwrap_or_else(|| "/bin/zsh".into());
    let mut seed = Env::new();
    for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] {
        if let Some(value) = base.get(key) {
            seed.insert(key.into(), value.clone());
        }
    }
    seed.insert("SHELL".into(), shell.clone());
    seed.insert("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into());
    let script = format!("printf '\\n{MARKER}\\n'; /usr/bin/env -0");
    CapturePlan {
        shell,
        arguments: vec!["-l".into(), "-i".into(), "-c".into(), script],
        environment: seed,
    }
}

/// Parses `<noise>\n<marker>\n` followed by NUL-separated `KEY=value`; none
/// without the marker or with no entry. An entry that is not UTF-8 or has no
/// `=` is skipped.
pub fn parse(output: &[u8]) -> Option<Env> {
    let marker = format!("\n{MARKER}\n");
    let start = find(output, marker.as_bytes())?.checked_add(marker.len())?;
    let (_, entries) = output.split_at_checked(start)?;
    let mut env = Env::new();
    for entry in entries.split(|b| *b == 0).filter(|e| !e.is_empty()) {
        let Ok(text) = std::str::from_utf8(entry) else { continue };
        let Some((key, value)) = text.split_once('=') else { continue };
        env.insert(key.into(), value.into());
    }
    (!env.is_empty()).then_some(env)
}

/// A capture the app keeps: the shell exited 0 and the output has `PATH`.
pub fn accept(status: i32, output: &[u8]) -> Option<Env> {
    if status != 0 {
        return None;
    }
    parse(output).filter(|env| env.contains_key("PATH"))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[derive(Serialize, Deserialize)]
struct Record {
    version: u32,
    environment: Env,
}

/// The store file's bytes for `env`: only the allowlist (never a
/// credential); none without `PATH`.
pub fn store_encode(env: &Env) -> Option<String> {
    let environment = filter(env);
    if !environment.contains_key("PATH") {
        return None;
    }
    serde_json::to_string(&Record { version: STORE_VERSION, environment }).ok()
}

/// The remembered environment in the store file's bytes; none when it is
/// another version, unreadable, or has no `PATH`.
pub fn store_decode(data: &str) -> Option<Env> {
    let record: Record = serde_json::from_str(data).ok()?;
    if record.version != STORE_VERSION {
        return None;
    }
    let environment = filter(&record.environment);
    environment.contains_key("PATH").then_some(environment)
}
