//! Which harness or app an `acpmux send` came from (`_meta.acpmux.senderHarness`): Claude Code
//! (in Claude desktop, a terminal or the SDK), Codex, or the MCP client that started acpmux's MCP
//! server (an assistant agent, Duet). Leo, 2026-11-07: "Actually, could it possibly detect that
//! you sent it as the Claude Code desktop? If you're just using like a shell to do it directly,
//! then I guess not, right?"
//!
//! Provenance, never proof. The sender reports it from its own environment, which anything can
//! set, so it is kept as `claimed` with `selfReported: true` and never names the sender: it never
//! makes a prompt another agent's message, verified or not, nor the person's (`fromAgent`, the
//! caller token and `messageSender` do that, `prompt_provenance.rs`). Where the daemon can look,
//! it walks the process chain from the unix socket's peer pid (`SO_PEERCRED` on Linux,
//! `LOCAL_PEERPID` on macOS) and records what it found beside the claim as `checked`, so a reader
//! sees whether the two agree. The daemon writes both as one `sender_claim` record keyed by the
//! prompt id, next to the prompt and outside it: the prompt's own record and its routing do not
//! change.
//!
//! The environment markers are the ones each harness sets for the commands its tools run, read on
//! a real session: Claude Code `CLAUDECODE=1`, `CLAUDE_CODE_ENTRYPOINT` (`claude-desktop`, `cli`,
//! `sdk-cli`, `sdk-ts`, ...), `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_HOST_SESSION_ID` (Claude
//! desktop's `local_…` id), `CLAUDE_CODE_DESKTOP_APP_VERSION`, `CLAUDE_PID`; Codex
//! `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, `CODEX_VERSION`; and the cross-harness `AI_AGENT`
//! (`claude-code_2-1-310_agent`). A Codex run started from a Claude Code shell inherits Claude's
//! markers too: the process chain decides which harness is nearer, and Codex wins without one.

use serde_json::{Map, Value, json};

/// The key a send carries the claim under, in `_meta.acpmux`.
pub const META_KEY: &str = "senderHarness";
/// The mux record the daemon writes it as: `{promptId, claimed?, checked?}`.
pub const RECORD_KIND: &str = "sender_claim";
/// Longest field, in characters.
pub const MAX_FIELD_CHARS: usize = 128;
/// Most parents walked from a pid.
const MAX_HOPS: usize = 32;

/// The string fields a claim may carry; anything else is dropped.
const FIELDS: &[&str] = &[
    "harness",
    "entrypoint",
    "sessionId",
    "hostSessionId",
    "appVersion",
    "version",
    "app",
    "source",
];
/// How a claim was found.
const SOURCES: &[&str] = &["env", "process", "mcp"];

/// Harness binaries known by name in a process chain, and the harness each is.
const HARNESS_BINARIES: &[(&str, &str)] = &[
    ("claude", "claude-code"),
    ("codex", "codex"),
    ("gemini", "gemini"),
    ("opencode", "opencode"),
];

/// Terminals and editors: a shell under one is the person's own, so the app alone claims nothing.
const TERMINAL_APPS: &[&str] = &[
    "Terminal",
    "iTerm",
    "iTerm2",
    "Ghostty",
    "WezTerm",
    "Alacritty",
    "kitty",
    "Warp",
    "Hyper",
    "Zed",
    "Visual Studio Code",
    "Cursor",
];

/// One process as `ps` lists it: its pid, its parent and its executable (a full path on macOS,
/// the command name on Linux).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub exe: String,
}

/// What a process chain shows: the nearest harness binary and the nearest app bundle above it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Chain {
    pub harness: Option<(String, u32)>,
    /// The bundle's name (`Claude.app`) and path.
    pub app: Option<(String, String)>,
    /// The file name of the first tool an app only ships that the walk went past (`Python`, for
    /// Xcode's python): no app's own code ([`app_bundle`]), yet a program, so a send under it is a
    /// tool's and never the person's plain shell ([`from_chain`]).
    pub shipped: Option<String>,
}

/// The claim this process makes, from its environment and, when that is silent or names two
/// harnesses, its own process chain. `None` in an acpmux session (its caller token proves it) and
/// when nothing names a harness.
pub fn of_this_process() -> Option<Value> {
    let env = |key: &str| std::env::var(key).ok();
    detect(&env, || chain(lookup, std::process::id()))
}

/// [`of_send`] for this process.
pub fn of_this_send(named: Option<String>) -> (Option<String>, Option<Value>) {
    let env = |key: &str| std::env::var(key).ok();
    of_send(named, &env, crate::host_pressure::host_name, || chain(lookup, std::process::id()))
}

/// What an `acpmux send` names: its sender (`cli::sender::implicit` when `named` is none) and the
/// claim it carries. A sender named on purpose (`--from`, `ACPMUX_FROM`, a notice, a relay) speaks
/// for itself and carries none; one the harness shell named carries its harness's claim, so the
/// receiver can say where it came from and whether acpmux confirmed it.
pub fn of_send(
    named: Option<String>,
    env: &impl Fn(&str) -> Option<String>,
    host: impl FnOnce() -> String,
    walk: impl FnOnce() -> Chain,
) -> (Option<String>, Option<Value>) {
    let on_purpose =
        named.is_some() || env(crate::cli::sender::FROM_ENV).is_some_and(|v| !v.trim().is_empty());
    let claim = if on_purpose { None } else { detect(env, walk) };
    (named.or_else(|| crate::cli::sender::implicit(env, host)), claim)
}

/// [`of_this_process`] over `env`, with `walk` read only when needed.
pub fn detect(
    env: &impl Fn(&str) -> Option<String>,
    walk: impl FnOnce() -> Chain,
) -> Option<Value> {
    if in_session(env) {
        return None;
    }
    let mut walk = once(walk);
    of_env(env, &mut walk).or_else(|| ai_agent(env)).or_else(|| from_chain(&walk()))
}

/// In an acpmux session, whose caller token proves where a send came from.
fn in_session(env: &impl Fn(&str) -> Option<String>) -> bool {
    let set = |key: &str| env(key).is_some_and(|v| !v.trim().is_empty());
    set("ACPMUX_SESSION_ID") && set(crate::hub::person::CALLER_TOKEN_ENV)
}

/// Claude Code's or Codex's markers. With both (a Codex run from a Claude shell inherits
/// `CLAUDECODE`), the harness nearer in the process chain, else Codex.
fn of_env(
    env: &impl Fn(&str) -> Option<String>,
    walk: &mut impl FnMut() -> Chain,
) -> Option<Value> {
    match (claude_code(env), codex(env)) {
        (Some(claude), Some(codex)) => {
            let nearer = walk().harness.map(|(h, _)| h);
            Some(if nearer.as_deref() == Some("claude-code") { claude } else { codex })
        }
        (Some(found), None) | (None, Some(found)) => Some(found),
        (None, None) => None,
    }
}

/// `walk`, read at most once.
fn once(walk: impl FnOnce() -> Chain) -> impl FnMut() -> Chain {
    let mut walk = Some(walk);
    move || walk.take().map(|walk| walk()).unwrap_or_default()
}

/// Claude Code's own markers: `CLAUDECODE=1` or an entrypoint.
pub fn claude_code(env: &impl Fn(&str) -> Option<String>) -> Option<Value> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let entrypoint = set("CLAUDE_CODE_ENTRYPOINT");
    if set("CLAUDECODE").as_deref() != Some("1") && entrypoint.is_none() {
        return None;
    }
    let mut claim = Map::new();
    claim.insert("harness".into(), json!("claude-code"));
    claim.insert("source".into(), json!("env"));
    for (field, key) in [
        ("entrypoint", "CLAUDE_CODE_ENTRYPOINT"),
        ("sessionId", "CLAUDE_CODE_SESSION_ID"),
        ("hostSessionId", "CLAUDE_CODE_HOST_SESSION_ID"),
        ("appVersion", "CLAUDE_CODE_DESKTOP_APP_VERSION"),
    ] {
        if let Some(value) = set(key) {
            claim.insert(field.into(), json!(value));
        }
    }
    if let Some(pid) = set("CLAUDE_PID").and_then(|p| p.parse::<u32>().ok()) {
        claim.insert("pid".into(), json!(pid));
    }
    Some(Value::Object(claim))
}

/// Codex's markers: the thread it runs a tool for.
pub fn codex(env: &impl Fn(&str) -> Option<String>) -> Option<Value> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let thread = set("CODEX_THREAD_ID").or_else(|| set("CODEX_SESSION_ID"))?;
    let mut claim = json!({"harness": "codex", "source": "env", "sessionId": thread});
    if let Some(version) = set("CODEX_VERSION") {
        put(&mut claim, "version", json!(version));
    }
    Some(claim)
}

/// The cross-harness `AI_AGENT` mark (`<harness>_<version>_agent`), for a harness with no markers
/// of its own here.
pub fn ai_agent(env: &impl Fn(&str) -> Option<String>) -> Option<Value> {
    let mark = env("AI_AGENT")?;
    let mark = mark.trim();
    let mut parts = mark.split('_');
    let harness = parts.next().filter(|h| !h.is_empty())?;
    let version = parts.next().filter(|v| !v.is_empty()).map(|v| v.replace('-', "."));
    let mut claim = json!({"harness": harness, "source": "env"});
    if let Some(version) = version {
        put(&mut claim, "version", json!(version));
    }
    Some(claim)
}

/// A claim from a process chain: a known harness binary, an app bundle that is not a terminal (a
/// shell under a terminal is the person's), or else a tool an app ships that the walk went past.
pub fn from_chain(chain: &Chain) -> Option<Value> {
    let app = chain.app.as_ref().map(|(name, _)| name.as_str());
    let mut claim = match &chain.harness {
        Some((harness, pid)) => json!({"harness": harness, "pid": pid}),
        None => match app.filter(|a| !is_terminal(a)) {
            Some(app) => json!({"harness": app.trim_end_matches(".app")}),
            // A tool an app ships (Xcode's python) is named by its own file, not the app: still a
            // program's send, as when the walk stopped at the app that ships it.
            None => json!({"harness": chain.shipped.as_deref()?}),
        },
    };
    put(&mut claim, "source", json!("process"));
    if let Some(app) = app {
        put(&mut claim, "app", json!(app));
    }
    Some(claim)
}

/// The claim of the MCP client that started this MCP server, from its `initialize`
/// `clientInfo {name, version}` (an assistant agent, Duet, Claude desktop).
pub fn from_mcp_client(client_info: &Value) -> Option<Value> {
    let name = client_info.get("name")?.as_str()?.trim();
    if name.is_empty() {
        return None;
    }
    let mut claim = json!({"harness": name, "source": "mcp"});
    if let Some(version) = client_info.get("version").and_then(Value::as_str) {
        put(&mut claim, "version", json!(version));
    }
    Some(claim)
}

static MCP_CLIENT: std::sync::OnceLock<Value> = std::sync::OnceLock::new();

/// Keep the `clientInfo` of this MCP server's `initialize`: one client per server process.
pub fn note_mcp_client(params: &Value) {
    if let Some(info) = params.get("clientInfo").filter(|i| i.is_object()) {
        let _ = MCP_CLIENT.set(info.clone());
    }
}

/// The claim an MCP tool's send makes: the environment's, else the MCP client's.
pub fn of_this_mcp_server() -> Option<Value> {
    let env = |key: &str| std::env::var(key).ok();
    of_mcp(&env, || chain(lookup, std::process::id()), MCP_CLIENT.get())
}

/// [`of_this_mcp_server`] over `env`, with `walk` read only when needed.
pub fn of_mcp(
    env: &impl Fn(&str) -> Option<String>,
    walk: impl FnOnce() -> Chain,
    client: Option<&Value>,
) -> Option<Value> {
    if in_session(env) {
        return None;
    }
    of_env(env, &mut once(walk)).or_else(|| client.and_then(from_mcp_client))
}

/// A claim as the daemon keeps it: the known fields, each one line of at most
/// [`MAX_FIELD_CHARS`], with `selfReported: true`. `None` when it names no harness.
pub fn sanitized(claim: &Value) -> Option<Value> {
    let claim = claim.as_object()?;
    let mut kept = Map::new();
    for field in FIELDS {
        let Some(value) = claim.get(*field).and_then(Value::as_str).map(str::trim) else {
            continue;
        };
        if value.is_empty()
            || value.chars().count() > MAX_FIELD_CHARS
            || value.chars().any(char::is_control)
        {
            continue;
        }
        kept.insert((*field).into(), json!(value));
    }
    if let Some(pid) =
        claim.get("pid").and_then(Value::as_u64).filter(|p| *p <= u64::from(u32::MAX))
    {
        kept.insert("pid".into(), json!(pid));
    }
    if kept.get("source").and_then(Value::as_str).is_some_and(|s| !SOURCES.contains(&s)) {
        kept.remove("source");
    }
    kept.contains_key("harness").then(|| {
        kept.insert("selfReported".into(), Value::Bool(true));
        Value::Object(kept)
    })
}

/// What the daemon found walking from the socket peer's pid, as recorded beside a claim:
/// `{harness?, harnessPid?, app?, signedBy?, peerPid}`. `None` when the chain shows neither.
pub fn checked(
    chain: &Chain,
    peer_pid: u32,
    signer: impl Fn(&str) -> Option<String>,
) -> Option<Value> {
    if chain.harness.is_none() && chain.app.is_none() {
        return None;
    }
    let mut found = json!({"peerPid": peer_pid});
    if let Some((harness, pid)) = &chain.harness {
        put(&mut found, "harness", json!(harness));
        put(&mut found, "harnessPid", json!(pid));
    }
    if let Some((name, path)) = &chain.app {
        put(&mut found, "app", json!(name));
        if let Some(signer) = signer(path) {
            put(&mut found, "signedBy", json!(signer));
        }
    }
    Some(found)
}

/// `value[key] = field` on a JSON object, without indexing (a no-op on anything else).
fn put(value: &mut Value, key: &str, field: Value) {
    if let Some(map) = value.as_object_mut() {
        map.insert(key.into(), field);
    }
}

/// The `sender_claim` record for a prompt, or `None` with nothing to say.
pub fn record(prompt_id: &str, claimed: Option<Value>, checked: Option<Value>) -> Option<Value> {
    if claimed.is_none() && checked.is_none() {
        return None;
    }
    let mut record = json!({"promptId": prompt_id});
    if let Some(claimed) = claimed {
        put(&mut record, "claimed", claimed);
    }
    if let Some(checked) = checked {
        put(&mut record, "checked", checked);
    }
    Some(record)
}

/// A prompt's acceptance callback that also writes its `sender_claim` with `write`, once the
/// prompt is kept (queued, started or steered in): a duplicate, a withdrawn one or an inbox resend
/// (`resent`) writes nothing, and a refused prompt never calls its acceptance, so no claim names a
/// prompt the chat does not hold, nor rewrites one it holds.
pub fn on_kept(
    claim: Value,
    write: impl FnOnce(Value) + Send + 'static,
    next: Option<Box<dyn FnOnce(Value) + Send>>,
) -> Option<Box<dyn FnOnce(Value) + Send>> {
    Some(Box::new(move |accepted: Value| {
        let said = |key: &str| accepted.get(key).and_then(Value::as_bool) == Some(true);
        if !said("duplicate") && !said("withdrawn") && !said("resent") {
            write(claim);
        }
        if let Some(next) = next {
            next(accepted);
        }
    }))
}

/// What the daemon knows of a connection's other end, for [`check_trust`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SocketPeer {
    /// No peer pid: a WebSocket, a Windows pipe, an in-process caller. Never trusted.
    #[default]
    Unknown,
    /// The unix socket peer's pid, read at accept.
    Pid(u32),
    /// The daemon's own outbox delivering a send it kept (`server/outbox.rs`), the one local
    /// connection whose [`CHECKED_KEY`] is the daemon's own.
    Outbox,
}

/// For a `session/prompt` or `send_queue`: the pid to walk from, and whether the
/// [`CHECKED_KEY`] it carries is the daemon's own (`carried`). Fails closed: a local connection
/// with no peer pid that is not the outbox (a Windows pipe, any in-process bridge) is checked by
/// nothing and its [`CHECKED_KEY`] is dropped, as a Web client's is.
pub fn check_trust(peer: SocketPeer, local: bool, peer_token: bool) -> (Option<u32>, bool) {
    match peer {
        SocketPeer::Outbox => (None, true),
        SocketPeer::Pid(pid) if local => (Some(pid), false),
        _ => (None, !local && peer_token),
    }
}

/// Where the daemon carries what it found (`checked`) in `_meta.acpmux`, from the request path to
/// the prompt's record, through the outbox and a peer link. Never taken from a client: see
/// [`stamp_checked`].
pub const CHECKED_KEY: &str = "senderHarnessChecked";

/// The daemon's first look at a send carrying a claim, before the outbox keeps it or a peer gets
/// it: what the unix socket peer's process chain shows goes in [`CHECKED_KEY`]. `carried` is a
/// connection whose [`CHECKED_KEY`] is the daemon's own ([`check_trust`]); from any other, one it
/// sent is dropped. Reads the chain (and runs
/// `codesign` on macOS) only for a send carrying a claim, off the async workers.
pub async fn stamp_checked(prompt: &mut Value, peer_pid: Option<u32>, carried: bool) {
    let Some(mux) = prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) else {
        return;
    };
    if !carried {
        mux.remove(CHECKED_KEY);
    }
    let (Some(pid), true) = (peer_pid, mux.contains_key(META_KEY)) else { return };
    let found = tokio::task::spawn_blocking(move || checked(&chain(lookup, pid), pid, signer))
        .await
        .ok()
        .flatten();
    if let (Some(found), Some(mux)) =
        (found, prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut))
    {
        mux.insert(CHECKED_KEY.into(), found);
    }
}

/// The `sender_claim` record a prompt's params make: the claim, sanitized, and what the daemon
/// checked ([`stamp_checked`]). `None` with no claim, or with no prompt id to key it by.
pub fn recorded(params: &Value, prompt_id: Option<&str>) -> Option<Value> {
    let mux = params.pointer("/_meta/acpmux")?;
    let claimed = sanitized(mux.get(META_KEY)?)?;
    let checked = mux.get(CHECKED_KEY).filter(|c| c.is_object()).map(checked_fields);
    record(prompt_id.filter(|id| !id.is_empty())?, Some(claimed), checked)
}

/// A carried `checked`, with only the fields [`checked`] writes.
fn checked_fields(found: &Value) -> Value {
    let mut kept = Map::new();
    for field in ["harness", "app", "signedBy"] {
        if let Some(value) = found.get(field).and_then(Value::as_str) {
            kept.insert(
                field.into(),
                json!(value.chars().take(MAX_FIELD_CHARS).collect::<String>()),
            );
        }
    }
    for field in ["peerPid", "harnessPid"] {
        if let Some(pid) = found.get(field).and_then(Value::as_u64) {
            kept.insert(field.into(), json!(pid));
        }
    }
    Value::Object(kept)
}

/// Walk up from `pid`, one parent at a time: the first harness binary, and the first app bundle
/// at or above it. `lookup` reads one pid; nothing lists processes.
pub fn chain(lookup: impl Fn(u32) -> Option<Proc>, pid: u32) -> Chain {
    let mut found = Chain::default();
    let mut at = pid;
    for _ in 0..MAX_HOPS {
        let Some(p) = lookup(at) else { break };
        let name = p.exe.rsplit('/').next().unwrap_or(p.exe.as_str());
        // acpmux itself may be the copy an app ships (cmux.app's): that bundle is not the sender.
        // The first process is acpmux by construction, whatever the kernel names its file
        // (cmux.app's bin/acpmux resolves to bin/cmux).
        if found.app.is_none() && p.pid != pid && name != "acpmux" {
            found.app = app_bundle(&p.exe);
            if found.app.is_none() && found.shipped.is_none() && p.exe.contains(".app/") {
                found.shipped = Some(name.to_owned());
            }
        }
        if found.harness.is_none() {
            found.harness = HARNESS_BINARIES
                .iter()
                .find(|(binary, _)| *binary == name)
                .map(|(_, harness)| ((*harness).to_owned(), p.pid));
        }
        if found.app.is_some() || p.ppid <= 1 || p.ppid == p.pid {
            break;
        }
        at = p.ppid;
    }
    found
}

/// `pid` and its parents, nearest first, at most [`MAX_HOPS`]: what the kernel says of the
/// socket peer's ancestry, read one pid at a time (`hub/desktop_bridge.rs` binds a desktop chat's
/// send by it). Empty where no process can be read.
pub fn ancestors(pid: u32) -> Vec<u32> {
    ancestors_in(lookup, pid)
}

fn ancestors_in(lookup: impl Fn(u32) -> Option<Proc>, pid: u32) -> Vec<u32> {
    let mut found = Vec::new();
    let mut at = pid;
    for _ in 0..MAX_HOPS {
        let Some(p) = lookup(at) else { break };
        found.push(p.pid);
        if p.ppid <= 1 || p.ppid == p.pid {
            break;
        }
        at = p.ppid;
    }
    found
}

/// The parent of `pid`, read for that pid alone (`sender_program.rs` walks the same chain).
pub(crate) fn parent(pid: u32) -> Option<u32> {
    lookup(pid).map(|p| p.ppid)
}

/// Where an app bundle keeps its own code: its main executable, its frameworks and helper apps
/// (Claude.app's `Contents/Frameworks/Claude Helper.app`), its helpers, XPC services and login
/// items.
const OWN_CODE: &[&str] = &[
    "Contents/MacOS/",
    "Contents/Frameworks/",
    "Contents/Helpers/",
    "Contents/XPCServices/",
    "Contents/Library/LoginItems/",
];

/// The app bundle an executable is the code of: the outermost `.app` in its path, when the
/// executable is that app's own code ([`OWN_CODE`]), with its name and path. A tool an app only
/// ships is not that app, nor is any bundle inside it: Xcode's
/// `Contents/Developer/.../Python.app/Contents/MacOS/Python` (which ran our outbox relay and drew as
/// "Xcode", Leo, 2026-11-11: "what's up with this?"), its git and clang, anything under
/// `Contents/Resources/` or `Contents/SharedSupport/`; the walk goes on past it.
fn app_bundle(exe: &str) -> Option<(String, String)> {
    let end = exe.find(".app/")? + ".app".len();
    let (path, inside) = (exe.get(..end)?, exe.get(end + 1..)?);
    let name = path.rsplit('/').next()?;
    (name.len() > ".app".len() && OWN_CODE.iter().any(|dir| inside.starts_with(dir)))
        .then(|| (name.to_owned(), path.to_owned()))
}

fn is_terminal(app: &str) -> bool {
    let name = app.trim_end_matches(".app");
    TERMINAL_APPS.contains(&name) || name.starts_with("cmux")
}

/// One process, read for its pid alone (Linux `/proc/<pid>/stat`: its command name and parent).
#[cfg(target_os = "linux")]
fn lookup(pid: u32) -> Option<Proc> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat_proc(pid, &stat)
}

/// `pid (comm) state ppid ...`; comm may hold spaces and parens.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn stat_proc(pid: u32, stat: &str) -> Option<Proc> {
    let (head, rest) = stat.rsplit_once(')')?;
    let comm = head.split_once('(')?.1;
    let ppid = rest.split_whitespace().nth(1)?.parse().ok()?;
    Some(Proc { pid, ppid, exe: comm.to_owned() })
}

/// One process, read for its pid alone (macOS `proc_pidinfo` for its parent, `proc_pidpath` for
/// its executable).
#[cfg(target_os = "macos")]
fn lookup(pid: u32) -> Option<Proc> {
    let id = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(std::mem::size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: the buffer is `size` bytes of a `proc_bsdinfo`, which the kernel fills for this flavor.
    let n = unsafe {
        libc::proc_pidinfo(id, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if n != size {
        return None;
    }
    // SAFETY: the kernel wrote all `size` bytes (a short answer is refused above).
    let info = unsafe { info.assume_init() };
    let mut path = [0u8; 4096];
    // SAFETY: `path` is 4096 writable bytes.
    let len = unsafe { libc::proc_pidpath(id, path.as_mut_ptr().cast(), 4096) };
    let len = usize::try_from(len).ok().filter(|l| (1..=path.len()).contains(l))?;
    let exe = String::from_utf8_lossy(path.get(..len)?).into_owned();
    Some(Proc { pid, ppid: info.pbi_ppid, exe })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn lookup(_pid: u32) -> Option<Proc> {
    None
}

/// Who signed an app bundle (`codesign`'s first `Authority=`), macOS only.
fn signer(path: &str) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    static SIGNERS: std::sync::OnceLock<Signers> = std::sync::OnceLock::new();
    SIGNERS.get_or_init(Signers::default).signer(path, run_codesign)
}

/// `codesign -dv` on one bundle: what it writes to stderr, empty when it cannot run.
fn run_codesign(path: &str) -> String {
    std::process::Command::new("codesign")
        .args(["-dv", "--verbose=2", path])
        .output()
        .map(|out| String::from_utf8_lossy(&out.stderr).into_owned())
        .unwrap_or_default()
}

/// Who signed each app bundle the daemon has looked at, kept while the bundle's files are the
/// same. A send from an agent inside an app (cmux.app, Claude.app) walks to that app every time,
/// and `codesign -dv` costs about 15 ms; reading what it reads costs a few `stat`s.
#[derive(Default)]
struct Signers {
    known: std::sync::Mutex<std::collections::HashMap<String, (BundleFiles, Option<String>)>>,
}

/// At most this many bundles are kept; past it the cache starts again empty.
const MAX_SIGNERS: usize = 64;

impl Signers {
    /// Who signed the bundle at `path`, by `run` (`codesign -dv`'s stderr), run again only when
    /// the bundle's files changed since the last answer for `path`. A path whose files cannot
    /// be read is asked each time and never kept.
    fn signer(&self, path: &str, run: impl FnOnce(&str) -> String) -> Option<String> {
        let Some(files) = BundleFiles::read(path) else {
            return parse_signer(&run(path));
        };
        if let Some((seen, signer)) = self.known().get(path)
            && *seen == files
        {
            return signer.clone();
        }
        // codesign runs with no lock held: two sends from one new bundle may both run it.
        let signer = parse_signer(&run(path));
        let mut known = self.known();
        if known.len() >= MAX_SIGNERS && !known.contains_key(path) {
            known.clear();
        }
        known.insert(path.to_owned(), (files, signer.clone()));
        signer
    }

    fn known(
        &self,
    ) -> std::sync::MutexGuard<'_, std::collections::HashMap<String, (BundleFiles, Option<String>)>>
    {
        self.known.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// What `codesign -dv` reads of a bundle, as the file system describes it: the bundle folder,
/// `Contents/Info.plist`, `Contents/_CodeSignature/CodeResources` and every entry of
/// `Contents/MacOS` (identity, size, change time). An update, a re-sign or a replaced bundle
/// changes at least one. Provenance only (see the module notes): a writer that keeps all of
/// these the same could just as well sign the bundle itself.
#[derive(Debug, PartialEq, Eq)]
struct BundleFiles(Vec<(String, FileStamp)>);

#[derive(Debug, PartialEq, Eq)]
struct FileStamp {
    dev: u64,
    ino: u64,
    len: u64,
    modified: Option<std::time::SystemTime>,
    changed: (i64, i64),
}

impl BundleFiles {
    fn read(path: &str) -> Option<Self> {
        let root = std::path::Path::new(path);
        let mut files = vec![(String::new(), FileStamp::of(root)?)];
        for part in ["Contents/Info.plist", "Contents/_CodeSignature/CodeResources"] {
            if let Some(stamp) = FileStamp::of(&root.join(part)) {
                files.push((part.to_owned(), stamp));
            }
        }
        let macos = root.join("Contents/MacOS");
        if let Some(stamp) = FileStamp::of(&macos) {
            files.push(("Contents/MacOS".to_owned(), stamp));
        }
        let mut executables: Vec<(String, FileStamp)> = std::fs::read_dir(&macos)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                Some((format!("Contents/MacOS/{name}"), FileStamp::of(&entry.path())?))
            })
            .collect();
        executables.sort_by(|a, b| a.0.cmp(&b.0));
        files.extend(executables);
        Some(Self(files))
    }
}

impl FileStamp {
    fn of(path: &std::path::Path) -> Option<Self> {
        let meta = std::fs::metadata(path).ok()?;
        #[cfg(unix)]
        let (dev, ino, changed) = {
            use std::os::unix::fs::MetadataExt;
            (meta.dev(), meta.ino(), (meta.ctime(), meta.ctime_nsec()))
        };
        // App bundles and codesign are macOS only; elsewhere the length and mtime are the stamp.
        #[cfg(not(unix))]
        let (dev, ino, changed) = (0, 0, (0, 0));
        Some(Self { dev, ino, len: meta.len(), modified: meta.modified().ok(), changed })
    }
}

fn parse_signer(codesign: &str) -> Option<String> {
    codesign
        .lines()
        .find_map(|l| l.strip_prefix("Authority="))
        .map(|a| a.trim().chars().take(MAX_FIELD_CHARS).collect())
}

#[cfg(test)]
#[path = "sender_harness_tests.rs"]
mod tests;
