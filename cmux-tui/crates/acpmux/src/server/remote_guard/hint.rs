//! A peer's refusal of a `session/new` this daemon forwarded (`acpmux new --host HOST`) says
//! what works instead: `data.try` is a command to copy, and the message ends with it (Leo,
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

use crate::no_panic::JsonExt;
use crate::rpc::RpcError;
use serde_json::{Value, json};

/// Why a remote `session/new` was refused, in `data.reason`: the daemon that forwarded it
/// turns each into a command that works (below).
pub(crate) const POLICY_REFUSED: &str = "remote.policy_refused";
pub(crate) const MODE_REFUSED: &str = "remote.mode_refused";
pub(crate) const CWD_MISSING: &str = "remote.cwd_missing";
pub(crate) const CWD_OUTSIDE_ROOTS: &str = "remote.cwd_outside_roots";

/// `remote_guard::check_inner`. A refused remote `session/new` (`remote.*`) says how this
/// daemon served the caller (`data.servedAs`: `peer` or `remote`), for the forwarding
/// daemon's hint.
pub(in crate::server) async fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: crate::server::Origin,
    auth: crate::server::ConnAuth,
    device: Option<&str>,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    let peer = super::control_of(origin, auth, params) == crate::hub::Control::Peer;
    let mut result = super::check_inner(hub, origin, auth, device, m, params).await;
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
    peer.request(method, p).await.map_err(|e| explain(peer, params, e))
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
    let (command, why) = match suggest(&Start::of(params), reason, found) {
        Hint::Here(start) => (start.command(Some(&peer.name)), String::new()),
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
                on_host(ssh.as_deref(), &start.on_host_command()),
                format!("{served}: run it on {} itself{then}", peer.name),
            )
        }
    };
    let message = format!("{}{why}; instead: {command}", e.message);
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

/// `inner` as run on the peer's machine: through ssh to `dest` (an `ssh://` peer's checked
/// destination, after `--` so it is never read as an option), else as it is, for that machine.
fn on_host(dest: Option<&str>, inner: &str) -> String {
    match dest {
        Some(dest) => format!("ssh -- {} {}", quote(dest), quote(inner)),
        None => inner.to_owned(),
    }
}

/// The refusal's reason, from its data or, from a peer on an older build, its message.
fn reason_of(e: &RpcError) -> Option<&'static str> {
    let named = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    let known = [POLICY_REFUSED, MODE_REFUSED, CWD_MISSING, CWD_OUTSIDE_ROOTS];
    if let Some(r) = named {
        return known.into_iter().find(|k| *k == r);
    }
    let m = e.message.as_str();
    if m.starts_with("a permission policy other than ask or deny-all is accepted only") {
        Some(POLICY_REFUSED)
    } else if m.starts_with("a mode at session start is accepted only") {
        Some(MODE_REFUSED)
    } else if m.starts_with("cwd is refused: from a WebSocket connection it must be") {
        Some(CWD_MISSING)
    } else if m.starts_with("cwd is refused: a remote WebSocket connection may use only") {
        Some(CWD_OUTSIDE_ROOTS)
    } else {
        None
    }
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

    /// `acpmux new [--host HOST] ... -d`, each value quoted for a POSIX shell.
    fn command(&self, host: Option<&str>) -> String {
        let mut words = vec!["acpmux".to_owned(), "new".to_owned()];
        let flags = [
            ("--host", host.map(str::to_owned)),
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
    /// `acpmux new --host HOST ...` from here.
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
mod tests {
    use super::*;

    fn start() -> Start {
        Start::of(&json!({
            "cwd": "/home/cmux/hb-acpmux/x",
            "_meta": {"acpmux": {"harness": "codex", "model": "gpt-6", "name": "lane", "policy": "approve-all", "mode": "auto"}}
        }))
    }

    #[test]
    fn a_start_is_spelled_as_the_flags_that_make_it() {
        assert_eq!(
            start().command(Some("gcp-1")),
            "acpmux new --host gcp-1 -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all --mode auto -d"
        );
        let odd = Start { cwd: Some("/tmp/a b/it's".into()), ..Start::default() };
        assert_eq!(odd.command(None), r"acpmux new --cwd '/tmp/a b/it'\''s' -d");
    }

    fn peer(try_cwd: Option<&str>) -> Found<'_> {
        Found { served: Some("peer"), try_cwd, cause: None }
    }

    #[test]
    fn each_refusal_suggests_a_start_the_peer_takes() {
        let s = start();
        // From a peer that serves us as a peer: the folder it checked, or none; never a mode.
        let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(Some("/home/cmux/Projects/x")))
        else {
            panic!()
        };
        assert_eq!(next.cwd.as_deref(), Some("/home/cmux/Projects/x"));
        assert_eq!(next.mode, None);
        let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(None)) else { panic!() };
        assert_eq!(next.cwd, None);
        let Hint::Here(next) = suggest(&s, MODE_REFUSED, peer(None)) else { panic!() };
        assert_eq!((next.mode, next.policy.as_deref()), (None, Some("approve-all")));
        // A policy it refused, or anything from a peer that serves us as Web: on the host,
        // its folder made first, with no mode.
        assert!(matches!(suggest(&s, POLICY_REFUSED, peer(None)), Hint::OnHost(_)));
        let web = |cause| Found { served: Some("remote"), cause, ..Found::default() };
        let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(Some("missing"))) else { panic!() };
        assert_eq!(
            next.on_host_command(),
            "mkdir -p /home/cmux/hb-acpmux/x && acpmux new -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all -d"
        );
        // A path no `mkdir -p` makes (a file, a link) is left out.
        for cause in [Some("unusable"), None] {
            let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(cause)) else { panic!() };
            assert_eq!(next.cwd, None, "{cause:?}");
        }
        // An older peer checked the mode before the folder: on the host, in the shell's folder.
        for reason in [MODE_REFUSED, POLICY_REFUSED, CWD_OUTSIDE_ROOTS] {
            let Hint::OnHost(next) = suggest(&s, reason, Found::default()) else { panic!() };
            assert_eq!((next.cwd, next.mode), (None, None), "{reason}");
        }
    }

    #[test]
    fn a_start_on_the_host_goes_through_ssh_only_for_an_ssh_peer() {
        let inner = "mkdir -p /x && acpmux new -d";
        assert_eq!(
            on_host(Some("leo@huge-blue"), inner),
            "ssh -- leo@huge-blue 'mkdir -p /x && acpmux new -d'"
        );
        assert_eq!(on_host(None, inner), inner);
    }

    #[test]
    fn an_older_peers_refusal_is_known_by_its_message() {
        let e = |m: &str| RpcError::invalid_params(m);
        assert_eq!(
            reason_of(&e(
                "a mode at session start is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
            )),
            Some(MODE_REFUSED)
        );
        assert_eq!(
            reason_of(&e(
                "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
            )),
            Some(CWD_OUTSIDE_ROOTS)
        );
        assert_eq!(reason_of(&e("no peer \"x\"")), None);
        let other = e("x").with_data(json!({"reason": "trust.remote"}));
        assert_eq!(reason_of(&other), None);
    }
}
