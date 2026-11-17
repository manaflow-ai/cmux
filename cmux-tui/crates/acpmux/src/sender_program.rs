//! Which program sent a prompt no proof attributes (`prompt_provenance::unverified`), as the
//! daemon sees it from the unix socket's peer pid. Leo, 2026-11-11: "generally the "unverified
//! sender" things should be more verified".
//!
//! Nearly every unverified prompt is a fleet tool's (a reconciler, an autoland, an ask
//! forwarder): a script that runs `acpmux send` with no session's caller token, so the chat read
//! "Unverified sender" with nothing to say who. The daemon need not take the tool's word: it walks
//! the peer pid's parents, one pid at a time as `sender_harness.rs` does and with its readers, and names the nearest
//! program that ran the send: a script's file (`python3 /…/tools/next-autoland`), or a plain
//! executable. It skips acpmux itself, shells and interpreters running inline code (`bash -c`,
//! an interactive shell) and wrappers (`env`, `timeout`, ...). It names nothing when it reaches
//! an agent harness first (its own claim says that, `sender_harness.rs`) or a login boundary
//! (`sshd`, `tmux`, a terminal, `launchd`): a person's shell is no program.
//!
//! The daemon writes it as [`KEY`] in `_meta.acpmux`, before the outbox keeps the send or a peer
//! gets it, so a peer daemon's own check reaches the receiver; one a client wrote is dropped,
//! as `sender_harness::CHECKED_KEY` is. The receiving daemon puts it on the `unverified`
//! provenance as `program: {name, path?, host?}` ([`PROVENANCE_KEY`]); `host` is the checking
//! daemon's own machine, never the send's `cliHost` claim. It says which program, as this
//! machine's kernel reports it; it proves no agent or person and grants nothing.

use serde_json::{Map, Value, json};

/// Where the daemon carries the program it found in `_meta.acpmux`. Never taken from a client.
pub const KEY: &str = "senderProgramChecked";
/// The field of an `unverified` provenance that names the program: `{name, path?}`.
pub const PROVENANCE_KEY: &str = "program";
/// Longest program name, in characters (`prompt_provenance::MAX_NAME_CHARS`).
const MAX_NAME_CHARS: usize = crate::prompt_provenance::MAX_NAME_CHARS;
/// Longest program path, in bytes.
const MAX_PATH_BYTES: usize = crate::prompt_provenance::MAX_FIELD_BYTES;
/// Most parents walked from a pid.
const MAX_HOPS: usize = 32;

/// One process with its arguments: its pid, its parent and its argv (`argv[0]` the executable
/// as it was run).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcArgs {
    pub pid: u32,
    pub ppid: u32,
    pub argv: Vec<String>,
}

/// acpmux itself: the CLI that made the connection, never the sender.
const SELF: &[&str] = &["acpmux", "cmux", "cmux-tui"];
/// Shells and interpreters: the sender is the script they run, never they.
const INTERPRETERS: &[&str] = &[
    "sh",
    "bash",
    "zsh",
    "dash",
    "fish",
    "ksh",
    "node",
    "ruby",
    "perl",
    "bun",
    "deno",
    "osascript",
];
/// The shells among [`INTERPRETERS`].
const SHELLS: &[&str] = &["sh", "bash", "zsh", "dash", "fish", "ksh"];
/// Commands that run another and are not the sender.
const WRAPPERS: &[&str] = &[
    "env",
    "timeout",
    "gtimeout",
    "nice",
    "nohup",
    "xargs",
    "flock",
    "caffeinate",
    "time",
    "stdbuf",
    "uv",
    "uvx",
    "npx",
    "bunx",
];
/// Where a person's or an agent's session starts: no program sent past one.
const BOUNDARIES: &[&str] = &[
    "sshd",
    "sshd-session",
    "login",
    "tmux",
    "tmux: server",
    "screen",
    "su",
    "sudo",
    "launchd",
    "systemd",
    "init",
    "cron",
    "crond",
    "mosh-server",
    "claude",
    "codex",
    "gemini",
    "opencode",
];

/// The program that sent from `pid`, nearest first: `{name, path?}`. `lookup` reads one pid.
pub fn find(lookup: impl Fn(u32) -> Option<ProcArgs>, pid: u32) -> Option<Value> {
    let mut at = pid;
    for _ in 0..MAX_HOPS {
        let p = lookup(at)?;
        match program_of(&p.argv) {
            Step::Found(name, path) => return found(&name, path.as_deref()),
            Step::Stop => return None,
            Step::Up => {}
        }
        if p.ppid <= 1 || p.ppid == p.pid {
            return None;
        }
        at = p.ppid;
    }
    None
}

enum Step {
    Found(String, Option<String>),
    Up,
    Stop,
}

fn base(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// `python3`, `python3.12`, `Python`: a Python interpreter.
fn python(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.strip_prefix("python").is_some_and(|v| v.chars().all(|c| c.is_ascii_digit() || c == '.'))
}

fn program_of(argv: &[String]) -> Step {
    let Some(first) = argv.first() else { return Step::Up };
    // A process that retitled itself (`sshd-session: cmux@pts/0`): the word before its colon.
    let first = first.split_once(": ").map_or(first.as_str(), |(head, _)| head);
    // A login shell's argv[0] is `-zsh`.
    let name = base(first).trim_start_matches('-');
    if name.is_empty() || SELF.contains(&name) || WRAPPERS.contains(&name) {
        return Step::Up;
    }
    if BOUNDARIES.contains(&name) || name.ends_with(".app") || first.contains(".app/") {
        return Step::Stop;
    }
    if !INTERPRETERS.contains(&name) && !python(name) {
        return Step::Found(name.to_owned(), first.starts_with('/').then(|| first.to_owned()));
    }
    // The script an interpreter runs: its first argument that is no option. Inline code (`-c`;
    // `-e` for all but a shell, whose `-e` is errexit) or none (an interactive shell) names
    // nothing here; its parent may.
    let shell = SHELLS.contains(&name);
    let mut args = argv.iter().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-c" | "-" => return Step::Up,
            // `bash -lc CODE`, `sh -ec CODE`: a cluster of a shell's short options with `c` in it.
            cluster if shell && short_cluster(cluster, 'c') => return Step::Up,
            // `perl -E CODE`, `perl -le CODE`, `node -pe CODE`.
            cluster if !shell && (short_cluster(cluster, 'e') || short_cluster(cluster, 'E')) => {
                return Step::Up;
            }
            "-p" | "--eval" | "--print" if !shell => return Step::Up,
            // `bash -o pipefail script`: the option's value is no script.
            "-o" | "-O" | "+o" if shell => {
                args.next();
            }
            // `python3 -m tools.next_autoland`: the module.
            "-m" if python(name) => {
                return match args.next() {
                    Some(module) => Step::Found(module.clone(), None),
                    None => Step::Up,
                };
            }
            arg if arg.starts_with('-') => {}
            script => {
                let path = script.starts_with('/').then(|| script.to_owned());
                return Step::Found(base(script).to_owned(), path);
            }
        }
    }
    Step::Up
}

/// `-lc`, `-euc`: one `-` and letters, `flag` among them.
fn short_cluster(arg: &str, flag: char) -> bool {
    arg.strip_prefix('-').is_some_and(|rest| {
        !rest.starts_with('-')
            && rest.contains(flag)
            && rest.chars().all(|c| c.is_ascii_alphabetic())
    })
}

/// `{name, path?}` for a well-formed name, else nothing; a path that does not fit is left out.
fn found(name: &str, path: Option<&str>) -> Option<Value> {
    let name = name.trim();
    if !one_line(name) || name.chars().count() > MAX_NAME_CHARS {
        return None;
    }
    let mut out = Map::new();
    out.insert("name".into(), json!(name));
    if let Some(path) = path.filter(|p| one_line(p) && p.len() <= MAX_PATH_BYTES) {
        out.insert("path".into(), json!(path));
    }
    Some(Value::Object(out))
}

fn one_line(value: &str) -> bool {
    !value.is_empty()
        && !value.chars().any(|c| {
            c.is_control()
                || (c.is_whitespace() && c != ' ')
                || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
                    | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
        })
}

/// A carried program, with only the fields [`find`] and [`stamp`] write and each still well formed.
pub fn sanitized(value: &Value) -> Option<Value> {
    let name = value.get("name").and_then(Value::as_str)?;
    let mut out = found(name, value.get("path").and_then(Value::as_str))?;
    if let (Some(host), Some(fields)) =
        (value.get("host").and_then(Value::as_str).and_then(host_label), out.as_object_mut())
    {
        fields.insert("host".into(), json!(host));
    }
    Some(out)
}

/// A host name as the program's record keeps it: its first label (`cosmic-gray` of
/// `cosmic-gray.local`), letters, digits, `-` and `_`, at most 64 characters.
fn host_label(host: &str) -> Option<&str> {
    let label = host.split('.').next()?.trim();
    (!label.is_empty()
        && label.len() <= 64
        && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
    .then_some(label)
}

/// The daemon's look at a send's program, beside `sender_harness::stamp_checked`: `peer_pid` is
/// the unix socket peer's (`None` when nothing local can be walked), `carried` a connection whose
/// [`KEY`] is the daemon's own (`sender_harness::check_trust`); from any other, one it sent is
/// dropped. `unproven` is a connection that proved no session: a proven one is never unverified,
/// so its chain is not read.
pub async fn stamp(prompt: &mut Value, peer_pid: Option<u32>, carried: bool, unproven: bool) {
    if !carried
        && let Some(mux) = prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
    {
        mux.remove(KEY);
    }
    let (Some(pid), true) = (peer_pid, unproven) else { return };
    let Some(program) = tokio::task::spawn_blocking(move || {
        find(lookup, pid).map(|mut program| {
            // The machine whose kernel was read: this daemon's own name, never the send's
            // `cliHost` claim, so a peer's receiver can say where the program ran.
            let host = crate::host_pressure::host_name();
            if let (Some(host), Some(fields)) = (host_label(&host), program.as_object_mut()) {
                fields.insert("host".into(), json!(host));
            }
            program
        })
    })
    .await
    .ok()
    .flatten() else {
        return;
    };
    let Some(fields) = prompt.as_object_mut() else { return };
    let meta = fields.entry("_meta").or_insert_with(|| json!({}));
    let Some(meta) = meta.as_object_mut() else { return };
    let mux = meta.entry("acpmux").or_insert_with(|| json!({}));
    if let Some(mux) = mux.as_object_mut() {
        mux.insert(KEY.into(), program);
    }
}

/// The program a send's params carry ([`stamp`]), checked again, for its `unverified` provenance.
pub fn of_params(params: &Value) -> Option<Value> {
    params.pointer("/_meta/acpmux").and_then(|m| m.get(KEY)).and_then(sanitized)
}

/// `provenance` (an `unverified` one) with the program `params` carry, when there is one.
pub fn on_unverified(mut provenance: Value, params: &Value) -> Value {
    if let (Some(program), Some(fields)) = (of_params(params), provenance.as_object_mut()) {
        fields.insert(PROVENANCE_KEY.into(), program);
    }
    provenance
}

/// One process and its argv, read for its pid alone with the readers acpmux already has: its
/// parent from `sender_harness.rs`, its exact argv from `agent_host/tree.rs`. Nothing lists
/// processes.
#[cfg(unix)]
fn lookup(pid: u32) -> Option<ProcArgs> {
    let ppid = crate::sender_harness::parent(pid)?;
    let argv = crate::agent_host::tree::argv(pid)?;
    Some(ProcArgs { pid, ppid, argv })
}

#[cfg(not(unix))]
fn lookup(_pid: u32) -> Option<ProcArgs> {
    None
}

#[cfg(test)]
#[path = "sender_program_tests.rs"]
mod tests;
