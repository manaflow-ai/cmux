//! A peer's refusal of a `session/new` this daemon forwarded (`acpmux new --host HOST`) says
//! what works instead: `data.try` is a command to copy, and the message names it between a
//! first and a last line that both say `refused by HOST` (`refused_by`) (Leo,
//! 2026-10-24: "we improve the instructions and the error messages and the hints"). The
//! peer's rules (`remote_guard.rs`) stay as they are; only the way out is named:
//!
//! - from a peer that serves this daemon as a remote Web client (`data.servedAs`), or a
//!   policy that skips asking: the same start on HOST itself, where its own unix socket
//!   accepts it (`ssh -- DEST '...'` for an `ssh://` peer; else the command with
//!   `data.runOn: HOST`), with its folder made first;
//! - from a peer that serves it as a peer, a folder outside its roots: the same start in the
//!   folder the peer checked (`data.tryCwd`), else with no folder (a scratch folder there).
//!
//! A mode is never taken at a remote start, nor by HOST's own CLI (not the person), so no
//! suggestion keeps one: the session starts in the harness's asking mode. The peer judges a
//! new session's folder before its policy and mode, so one refusal covers every field. A peer
//! on an older build names no `reason` (its message is read instead) and judged the mode
//! before the folder: its way out is HOST's own CLI in the shell's own folder.

use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// Why a remote `session/new` was refused, in `data.reason`: the daemon that forwarded it
/// turns each into a command that works (below).
pub(crate) const POLICY_REFUSED: &str = "remote.policy_refused";
pub(crate) const MODE_REFUSED: &str = "remote.mode_refused";
pub(crate) const CWD_MISSING: &str = "remote.cwd_missing";
pub(crate) const CWD_OUTSIDE_ROOTS: &str = "remote.cwd_outside_roots";

/// `remote_guard::check_inner`. A refused remote `session/new` (`remote.*`) says how this
/// daemon served the caller (`data.servedAs`: `peer` or `remote`), for the forwarding
/// daemon's hint. `policy_proved`: the request is a policy raise the person proved
/// (`hub/person/policy_grant.rs`).
pub(in crate::server) async fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: crate::server::Origin,
    auth: crate::server::ConnAuth,
    device: Option<&str>,
    m: &str,
    params: &mut Value,
    policy_proved: bool,
) -> Result<(), RpcError> {
    let peer = super::control_of(origin, auth, params) == crate::hub::Control::Peer;
    let mut result = super::check_inner(hub, origin, auth, device, m, params, policy_proved).await;
    if m == crate::rpc::method::SESSION_NEW
        && origin.web_class()
        && let Err(e) = &mut result
        && let Some(Value::Object(data)) = &mut e.data
        && data.get("reason").and_then(Value::as_str).is_some_and(|r| r.starts_with("remote."))
    {
        data.insert("servedAs".into(), Value::from(if peer { "peer" } else { "remote" }));
    }
    result
}

/// `peer`'s answer to the `session/new` `p` this daemon forwarded for `params`, a refusal
/// explained.
pub(in crate::server) async fn new_on(
    peer: &crate::peer::Peer,
    params: &Value,
    p: Value,
) -> Result<Value, RpcError> {
    let method = crate::rpc::method::SESSION_NEW;
    let web = via_web(&p);
    // Creation is interactive (New Tab and composer), unlike a prompt's unbounded turn, but
    // this hazard bound outlasts the peer's own pooled-start envelope: the peer answers a slow
    // valid start, or fails it itself, before this ends. A peer that stays connected and never
    // answers is the remaining real hazard; dropping the request removes its pending reply.
    // timeout: a remote handler that never answers needs a finite forwarding fallback, while a
    // live start remains well beyond the old local 90-second budget.
    // Match `peer::send_request`: the forwarded request must outlive both the
    // generic peer budget and the peer's pooled-start hazard envelope.
    // The start as sent, for a refusal of full access (`try_asking`).
    let asked = p.clone();
    let timings = peer.timings();
    let budget = timings.request.max(timings.start);
    let start_timeout = || {
        RpcError::internal(format!(
            "session/new on peer {} did not answer within {} seconds; the session may still start there. Check that host's sessions before retrying",
            peer.name, budget.as_secs()
        ))
        .with_data(json!({"reason": "peer_start_timeout", "host": peer.name}))
    };
    let result =
        tokio::time::timeout(budget, peer.request(method, p)).await.map_err(|_| start_timeout())?;
    // `Peer::send_request` gives session/new this same budget, and a timeout polls its inner
    // future first, so the request's own deadline usually ends it first: that is the same
    // start timeout, said the same way.
    if let Err(e) = &result
        && e.data.is_none()
        && is_request_timeout(&peer.name, &e.message)
    {
        return Err(start_timeout());
    }
    result.map_err(|e| {
        // Full access refused: the way out is asking there, not this start on HOST (`explain`).
        let e = crate::hub::full_access_children::refused_by(&peer.name, &asked, e);
        if e.data.as_ref().is_some_and(|d| d.get("fullAccessRefusedBy").is_some()) {
            return try_asking(&peer.name, params, e);
        }
        let (build, served_peer) =
            (peer.remote_build(), peer.served_as().as_deref() == Some("peer"));
        update_first(&e, &peer.name, build.as_deref(), served_peer && !web, params)
            .unwrap_or_else(|| explain(peer, params, e))
    })
}

/// Whether `message` is `Peer::send_request`'s own deadline (`peer NAME timed out after Ns`).
fn is_request_timeout(peer: &str, message: &str) -> bool {
    message
        .strip_prefix("peer ")
        .and_then(|rest| rest.strip_prefix(peer))
        .is_some_and(|rest| rest.starts_with(" timed out after "))
}

/// Whether this daemon forwarded `p` for a Web client (`mark_forwarded`'s `via: web`): the
/// peer runs such a start under Web rules on any build, so no update gives it a scratch folder.
fn via_web(p: &Value) -> bool {
    p.pointer("/_meta/acpmux/via").and_then(Value::as_str) == Some("web")
}

/// `e`, with `data.host`, `data.try` (and `data.runOn` when it runs on HOST) and the command
/// at the end of its message, when it is one of the refusals above; any other error unchanged.
fn explain(peer: &crate::peer::Peer, params: &Value, e: RpcError) -> RpcError {
    let Some(reason) = reason_of(&e) else { return e };
    let data = e.data.as_ref();
    // `peer` or `remote`; an older peer does not say.
    let served = data.and_then(|d| d.get("servedAs")).and_then(Value::as_str);
    // A folder inside its roots the peer checked for this start (`peer_folder::outside_told`).
    let try_cwd = data.and_then(|d| d.get("tryCwd")).and_then(Value::as_str);
    let ssh = crate::peer::ssh_target(&peer.url).ok().map(|t| t.destination);
    let mut run_on = None;
    // `missing` (mkdir -p makes it) or `unusable`; an older peer does not say.
    let cause = data.and_then(|d| d.get("cause")).and_then(Value::as_str);
    let found = Found { served, try_cwd, cause };
    let (command, why) = match suggest(&Start::of(params), &reason, found) {
        Hint::Here(start) => {
            (command(params, &start, Some(&peer.name), false).render(None), String::new())
        }
        Hint::OnHost(start) => {
            let then = start
                .name
                .as_ref()
                .map(|n| format!(", then reach it from here as {}/{n}", peer.name))
                .unwrap_or_default();
            let served = if served == Some("remote") {
                format!(" ({} serves this daemon as a remote client, not as a peer)", peer.name)
            } else {
                String::new()
            };
            if ssh.is_none() {
                run_on = Some(peer.name.clone());
            }
            (
                command(params, &start, None, true).render(ssh.as_deref()),
                format!("{served}: run it on {} itself{then}", peer.name),
            )
        }
    };
    let message = refused_by(&peer.name, &format!("{}{why}", e.message), &command);
    let mut data = match e.data {
        Some(Value::Object(o)) => Value::Object(o),
        _ => json!({}),
    };
    data.set("reason", json!(reason));
    data.set("host", json!(peer.name));
    data.set("try", json!(command));
    if let Some(host) = run_on {
        data.set("runOn", json!(host));
    }
    RpcError::new(e.code, message).with_data(data)
}

/// `e`, a refusal of full access by `host` (`hub/full_access_children.rs` `refused_by`, which
/// sets `data.fullAccessRefusedBy`), with `data.try` the same start there asking
/// (`--policy ask`), also at the end of its message, as its message says; any other error
/// unchanged.
fn try_asking(host: &str, params: &Value, mut e: RpcError) -> RpcError {
    let Some(data) = e.data.as_mut().filter(|d| d.get("fullAccessRefusedBy").is_some()) else {
        return e;
    };
    let mut p = params.clone();
    crate::hub::merge_mux_meta(&mut p, json!({"policy": "ask"}));
    if let Some(argv) = p.pointer_mut("/_meta/acpmux/argv").and_then(Value::as_array_mut) {
        let mut words: Vec<String> =
            argv.iter().filter_map(Value::as_str).map(str::to_owned).collect();
        if !change_option(&mut words, "--policy", Some("ask")) {
            // After the subcommand (the first word that is no global switch, such as `--json`),
            // before any prompt words: acpmux takes `--policy` only as a `new` option.
            let sub = words.iter().position(|w| !w.starts_with('-')).unwrap_or(words.len());
            words.insert((sub + 1).min(words.len()), "--policy=ask".to_owned());
        }
        *argv = words.into_iter().map(Value::String).collect();
    }
    let start = Start { mode: None, ..Start::of(&p) };
    let command = command(&p, &start, Some(host), false).render(None);
    data.set("try", json!(command));
    e.message = refused_by(host, &e.message, &command);
    e
}

/// A forwarded start's refusal by `host`, as its message reads: `refused by HOST: REASON` on the
/// first line, then the command that works, then the refusal again, so a caller that reads only
/// the first line or only the last (`| tail -1`) still sees nothing started. A command with a
/// prompt file spans lines (`Retry::render`), which is why the last line says it once more.
fn refused_by(host: &str, reason: &str, command: &str) -> String {
    format!(
        "refused by {host}: {reason}; nothing was started. Instead:\n{command}\nrefused by {host}: nothing was started; the command above runs it"
    )
}

/// A start with no folder that `peer_name` refused as outside its roots, from a peer of
/// another build that serves this daemon as a peer (`served_peer`: its handshake, for a start
/// this daemon did not forward for a Web client) but names no
/// `servedAs` in the refusal: one older than the peer scratch folder (#24442), which treats
/// an absent folder as the home folder. Its way out is updating it once no session there is
/// mid-turn (`--if-idle`), then the same command;
/// the peer's own folder rule is unchanged. None for any other refusal.
fn update_first(
    e: &RpcError,
    peer_name: &str,
    build: Option<&str>,
    served_peer: bool,
    params: &Value,
) -> Option<RpcError> {
    let named_folder = params.get("cwd").is_some_and(|c| !c.is_null());
    let served = e.data.as_ref().and_then(|d| d.get("servedAs")).is_some();
    if !served_peer || named_folder || served || build == Some(crate::hub::build()) {
        return None;
    }
    if reason_of(e).as_deref() != Some(CWD_OUTSIDE_ROOTS) {
        return None;
    }
    // `--if-idle`: the update never restarts the peer under a session mid-turn there.
    let update = format!("acpmux machine update {peer_name} --if-idle");
    let then = command(params, &Start::of(params), Some(peer_name), false).render(None);
    let message = format!(
        "{}: {peer_name} runs acpmux build {} (this daemon: {}), from before a start with no folder runs in a scratch folder there; run `{update}`, then `{then}`",
        e.message,
        build.unwrap_or("unknown"),
        crate::hub::build()
    );
    Some(RpcError::new(e.code, message).with_data(json!({
        "reason": "peer_version_skew",
        "refused": CWD_OUTSIDE_ROOTS,
        "host": peer_name,
        "try": update,
        "then": then,
    })))
}

/// `inner` as run on the peer's machine: through ssh to `dest` (an `ssh://` peer's checked
/// destination, after `--` so it is never read as an option), else as it is, for that machine.
fn on_host(dest: Option<&str>, inner: &str) -> String {
    match dest {
        Some(dest) => format!("ssh -- {} {}", quote(dest), quote(inner)),
        None => inner.to_owned(),
    }
}

/// The refusal's reason, from its data or, from a peer on an older build, its message.
fn reason_of(e: &RpcError) -> Option<String> {
    let named = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    if let Some(r) = named
        && r.starts_with("remote.")
    {
        return Some(r.to_owned());
    }
    let m = e.message.as_str();
    if m.starts_with("a permission policy other than ask or deny-all is accepted only") {
        Some(POLICY_REFUSED.to_owned())
    } else if m.starts_with("a mode at session start is accepted only") {
        Some(MODE_REFUSED.to_owned())
    } else if m.starts_with("cwd is refused: from a WebSocket connection it must be") {
        Some(CWD_MISSING.to_owned())
    } else if m.starts_with("cwd is refused: a remote WebSocket connection may use only") {
        Some(CWD_OUTSIDE_ROOTS.to_owned())
    } else {
        None
    }
}

/// A command and optional prompt-file input, rendered together only at the outer shell.
struct Retry {
    command: String,
    input: Option<String>,
}

impl Retry {
    fn render(&self, ssh: Option<&str>) -> String {
        let command = on_host(ssh, &self.command);
        match &self.input {
            // Keep file text outside ssh's command argument: accepted files can be 1 MiB,
            // larger than exec's per-argument limit. The shell's printf streams it over stdin.
            Some(text) => format!("printf %s {} | ({command})", quote(text)),
            None => command,
        }
    }
}

/// Build a refusal's runnable command from the original CLI argv when available. The CLI
/// adds this metadata before forwarding a request, so prompts and launcher flags survive intact.
fn command(params: &Value, start: &Start, host: Option<&str>, on_host: bool) -> Retry {
    let Some(mut words) = params
        .pointer("/_meta/acpmux/argv")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>())
    else {
        return Retry {
            command: if on_host { start.on_host_command() } else { start.command(host) },
            input: None,
        };
    };
    if on_host {
        change_option(&mut words, "--machine", None);
    } else if let Some(host) = host {
        // Pin an automatic placement to the peer that actually refused this start.
        change_option(&mut words, "--machine", Some(host));
    }
    change_option(&mut words, "--mode", None);
    // `suggest` already selected the usable folder (or the scratch-folder fallback).
    change_option(&mut words, "--cwd", start.cwd.as_deref());
    let prompt_file = params.pointer("/_meta/acpmux/promptFileText").and_then(Value::as_str);
    let input = prompt_file
        .filter(|_| change_option(&mut words, "--prompt-file", Some("/dev/stdin")))
        .map(str::to_owned);
    let rendered = words.iter().map(|w| quote(w)).collect::<Vec<_>>();
    let inner = format!("acpmux {}", rendered.join(" "));
    let command = if on_host && let Some(cwd) = start.cwd.as_deref() {
        format!("mkdir -p {} && {inner}", quote(cwd))
    } else {
        inner
    };
    Retry { command, input }
}

/// Change only actual options, never another option's value or prompt words after `--`.
/// Read value-taking flags from clap's grammar so future launcher options are preserved too.
fn change_option(words: &mut Vec<String>, option: &str, value: Option<&str>) -> bool {
    use clap::Args;
    // Only creation flags take values here (the global flags are switches). Building the
    // whole CLI grammar inside the request handler exhausts a debug worker's 2 MiB stack.
    let new = crate::cli::command::NewArgs::augment_args(clap::Command::new("new"));
    let args: Vec<_> = new.get_arguments().collect();
    // A long flag by its name or a hidden alias (`--host` is `--machine`'s), so either spelling
    // is read with its value and counts as the same option.
    let arg_of = |name: &str| {
        args.iter().copied().find(|a| {
            a.get_long() == Some(name) || a.get_all_aliases().is_some_and(|all| all.contains(&name))
        })
    };
    let wanted = option.trim_start_matches('-');
    let wanted_id = arg_of(wanted).map(|a| a.get_id().clone());
    let mut i = 0;
    while let Some(word) = words.get(i) {
        if word == "--" {
            break;
        }
        if let Some(long) = word.strip_prefix("--") {
            let (name, inline) = long.split_once('=').map_or((long, false), |(k, _)| (k, true));
            let arg = arg_of(name);
            let takes = arg.is_some_and(|a| a.get_action().takes_values());
            let end = (i + if takes && !inline { 2 } else { 1 }).min(words.len());
            if name == wanted
                || (wanted_id.is_some() && arg.map(|a| a.get_id()) == wanted_id.as_ref())
            {
                let replacement = value.map(|v| format!("{option}={v}"));
                words.splice(i..end, replacement);
                return true;
            }
            i = end;
        } else if let Some(shorts) = word.strip_prefix('-').filter(|s| !s.is_empty()) {
            let mut separate_value = false;
            for (offset, short) in shorts.char_indices() {
                if args
                    .iter()
                    .any(|a| a.get_short() == Some(short) && a.get_action().takes_values())
                {
                    separate_value = offset + short.len_utf8() == shorts.len();
                    break;
                }
            }
            i += if separate_value { 2 } else { 1 };
        } else {
            i += 1;
        }
    }
    false
}

/// What the caller asked to start, as `acpmux new` flags.
#[derive(Clone, Debug, Default, PartialEq)]
struct Start {
    preset: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    name: Option<String>,
    cwd: Option<String>,
    policy: Option<String>,
    mode: Option<String>,
}

impl Start {
    fn of(params: &Value) -> Start {
        let meta = params.pointer("/_meta/acpmux");
        let pick = |key: &str| {
            meta.and_then(|m| m.get(key))
                .or_else(|| params.get(key))
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        };
        let model = match (pick("harness"), pick("model")) {
            (Some(h), Some(m)) => Some(format!("{h}/{m}")),
            (h, m) => h.or(m),
        };
        let mode = crate::web_modes::MODE_FIELDS.iter().find_map(|f| pick(f));
        Start {
            preset: pick("preset"),
            model,
            effort: pick("effort"),
            name: pick("name"),
            cwd: params.get("cwd").and_then(Value::as_str).map(str::to_owned),
            policy: pick("policy"),
            mode,
        }
    }

    /// `acpmux new [--machine MACHINE] ... -d`, each value quoted for a POSIX shell.
    fn command(&self, host: Option<&str>) -> String {
        let mut words = vec!["acpmux".to_owned(), "new".to_owned()];
        let flags = [
            ("--machine", host.map(str::to_owned)),
            ("--preset", self.preset.clone()),
            ("-m", self.model.clone()),
            ("-e", self.effort.clone()),
            ("-n", self.name.clone()),
            ("--cwd", self.cwd.clone()),
            ("--policy", self.policy.clone()),
            ("--mode", self.mode.clone()),
        ];
        for (flag, value) in flags {
            if let Some(value) = value {
                words.push(flag.to_owned());
                words.push(quote(&value));
            }
        }
        words.push("-d".to_owned());
        words.join(" ")
    }

    /// `command` for HOST's own shell, its folder made first.
    fn on_host_command(&self) -> String {
        let new = self.command(None);
        match &self.cwd {
            Some(cwd) => format!("mkdir -p {} && {new}", quote(cwd)),
            None => new,
        }
    }
}

#[derive(Debug, PartialEq)]
enum Hint {
    /// `acpmux new --machine MACHINE ...` from here.
    Here(Start),
    /// The start on HOST itself.
    OnHost(Start),
}

/// What the refusal says besides its reason.
#[derive(Clone, Copy, Default)]
struct Found<'a> {
    served: Option<&'a str>,
    try_cwd: Option<&'a str>,
    cause: Option<&'a str>,
}

/// The start that works after `reason`. A peer that serves this daemon as a remote Web
/// client takes only its own roots (which it does not name) and asking policies, so the
/// way out there is HOST's own CLI, in the folder asked for unless the peer did not say
/// `mkdir -p` makes it (then in the shell's own). From a peer that serves it as a peer, a
/// folder outside its roots becomes the one it checked, else none (a scratch folder). A mode
/// is dropped either way.
fn suggest(start: &Start, reason: &str, found: Found) -> Hint {
    let Found { served, try_cwd, cause } = found;
    let mut next = Start { mode: None, ..start.clone() };
    match (served, reason) {
        (None, _) => {
            next.cwd = None;
            Hint::OnHost(next)
        }
        (Some("peer"), CWD_OUTSIDE_ROOTS | CWD_MISSING | MODE_REFUSED) => {
            if reason != MODE_REFUSED {
                next.cwd = try_cwd.filter(|_| reason == CWD_OUTSIDE_ROOTS).map(str::to_owned);
            }
            Hint::Here(next)
        }
        _ => {
            if reason == CWD_MISSING && cause != Some("missing") {
                next.cwd = None;
            }
            Hint::OnHost(next)
        }
    }
}

/// `text` as one POSIX shell word: unchanged when it holds only characters no shell reads
/// specially, else in single quotes.
fn quote(text: &str) -> String {
    let plain = !text.is_empty()
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-./=:@%+,".contains(&b));
    if plain { text.to_owned() } else { format!("'{}'", text.replace('\'', r"'\''")) }
}

#[cfg(test)]
mod tests;
