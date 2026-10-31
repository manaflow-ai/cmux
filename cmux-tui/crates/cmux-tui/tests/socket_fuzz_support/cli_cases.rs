//! The CLI's own catalogue of command lines (`safe_operation_cases` in
//! src/cli/command/cases.rs, one line per safe catalog operation), read from
//! its source, and a runner for one `cmux-tui` command line with a deadline.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};
use std::time::Duration;

use wait_timeout::ChildExt;

use super::daemon::{Daemon, scaled};
use super::generate::Context;

const CASES_RS: &str = include_str!("../../src/cli/command/cases.rs");
const CASES_GIT_RS: &str = include_str!("../../src/cli/command/cases/git.rs");

/// (argv, operation). A constant becomes its value; a variable (an id the
/// caller picks) becomes `$<name>`.
pub fn cli_cases() -> Vec<(Vec<String>, String)> {
    let mut out = Vec::new();
    for source in [CASES_RS, CASES_GIT_RS] {
        let constants = constants(source);
        let tokens = rust_tokens(source);
        let mut i = 0;
        while i + 4 < tokens.len() {
            // `(vec![<literal or name>, ...], "<operation>")`
            let opens_case = tokens[i] == "(" && tokens[i + 1] == "vec" && tokens[i + 2] == "!";
            if !opens_case || tokens[i + 4] == "(" {
                i += 1;
                continue;
            }
            let mut j = i + 4;
            let mut argv = Vec::new();
            while j < tokens.len() && tokens[j] != "]" {
                let token = &tokens[j];
                if let Some(text) = token.strip_prefix('\u{1}') {
                    argv.push(text.to_string());
                } else if token != "," && token != "&" {
                    argv.push(constants.get(token).cloned().unwrap_or_else(|| format!("${token}")));
                }
                j += 1;
            }
            if let Some(op) = tokens.get(j + 2).and_then(|t| t.strip_prefix('\u{1}')) {
                out.push((argv, op.to_string()));
            }
            i = j;
        }
    }
    out
}

fn constants(source: &str) -> BTreeMap<String, String> {
    source
        .lines()
        .filter_map(|line| line.trim().strip_prefix("const "))
        .filter_map(|rest| rest.split_once(": &str = \""))
        .map(|(name, value)| (name.to_string(), value.trim_end_matches("\";").to_string()))
        .collect()
}

/// A small Rust tokenizer: string literals (plain and raw) come back marked
/// with `\u{1}`, identifiers and punctuation as themselves; comments dropped.
fn rust_tokens(source: &str) -> Vec<String> {
    let chars: Vec<char> = source.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
        } else if c == 'r' && matches!(next, Some('#') | Some('"')) {
            i = raw_string(&chars, i, &mut tokens);
            continue;
        } else if c == '"' {
            i = plain_string(&chars, i, &mut tokens);
        } else if c.is_alphanumeric() || c == '_' {
            let start = i;
            while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            tokens.push(chars[start..i].iter().collect());
            continue;
        } else if !c.is_whitespace() {
            tokens.push(c.to_string());
        }
        i += 1;
    }
    tokens
}

/// `r#"..."#` at `start`; returns the index after it.
fn raw_string(chars: &[char], start: usize, tokens: &mut Vec<String>) -> usize {
    let mut j = start + 1;
    let mut hashes = 0;
    while chars.get(j) == Some(&'#') {
        hashes += 1;
        j += 1;
    }
    j += 1; // the opening quote
    let body = j;
    loop {
        if j >= chars.len() {
            break;
        }
        if chars[j] == '"' && (1..=hashes).all(|k| chars.get(j + k) == Some(&'#')) {
            break;
        }
        j += 1;
    }
    tokens.push(format!("\u{1}{}", chars[body..j.min(chars.len())].iter().collect::<String>()));
    j + 1 + hashes
}

/// `"..."` at `start`; returns the index of the closing quote.
fn plain_string(chars: &[char], start: usize, tokens: &mut Vec<String>) -> usize {
    let mut text = String::new();
    let mut i = start + 1;
    while i < chars.len() && chars[i] != '"' {
        if chars[i] == '\\' {
            i += 1;
            match chars.get(i) {
                Some('n') => text.push('\n'),
                Some('t') => text.push('\t'),
                Some(other) => text.push(*other),
                None => {}
            }
        } else {
            text.push(chars[i]);
        }
        i += 1;
    }
    tokens.push(format!("\u{1}{text}"));
    i
}

const ID_KINDS: &[(&str, &str)] = &[
    ("ws_", "workspace"),
    ("screen_", "screen"),
    ("pane_", "pane"),
    ("tab_", "tab"),
    ("term_", "terminal"),
    ("browser_", "browser"),
    ("client_", "client"),
];

/// The session's real ids in place of placeholders; every program, folder
/// and URL made safe (a program after `--` becomes the sink).
pub fn localize(argv: &[String], ctx: &Context) -> Vec<String> {
    let mut out = Vec::new();
    for (index, arg) in argv.iter().enumerate() {
        if arg == "--" {
            out.extend(["--", "/bin/sh", "-c", "exec cat > /dev/null"].map(String::from));
            break;
        }
        let previous = index.checked_sub(1).map(|i| argv[i].as_str()).unwrap_or("");
        let value = match previous {
            "--cwd" | "--path" => ctx.dir.clone(),
            "--url" => "https://example.invalid/".to_string(),
            _ => real_id(arg, ctx),
        };
        out.push(value);
    }
    out
}

fn real_id(arg: &str, ctx: &Context) -> String {
    let kind =
        ID_KINDS.iter().find(|(prefix, _)| arg.starts_with(prefix)).map(|(_, kind)| *kind).or_else(
            || arg.strip_prefix('$').filter(|name| ID_KINDS.iter().any(|(_, kind)| kind == name)),
        );
    match kind.and_then(|kind| ctx.ids.get(kind)).and_then(|ids| ids.first()) {
        Some(id) => id.clone(),
        None if arg.starts_with('$') => "current".to_string(),
        None => arg.to_string(),
    }
}

pub struct CliOutcome {
    pub code: Option<i32>,
    pub stderr: String,
    pub timed_out: bool,
}

pub fn run_cli(daemon: &Daemon, argv: &[String], deadline: Duration) -> CliOutcome {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--socket")
        .arg(&daemon.socket)
        .args(argv)
        .current_dir(&daemon.dir)
        .env("HOME", &daemon.dir)
        .env("PATH", "/usr/bin:/bin")
        .env("CMUX_TUI_CONFIG", daemon.dir.join("config.json"))
        .env("CMUX_TUI_STATE_DIR", daemon.dir.join("cmux-tui/sessions"))
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_TAG")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut pipe = child.stderr.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut pipe, &mut text);
        text
    });
    let waited = child.wait_timeout(scaled(deadline)).unwrap();
    let timed_out = waited.is_none();
    if timed_out {
        let _ = child.kill();
    }
    let status = waited.or_else(|| child.wait().ok());
    CliOutcome {
        code: status.and_then(|s| s.code()),
        stderr: reader.join().unwrap_or_default(),
        timed_out,
    }
}
