//! The ssh carrier under the outbox (`outbox.rs`): a message to `HOST/NAME` whose peer link is
//! down, and whose peer is an `ssh://` machine, goes over a plain ssh login instead of waiting for
//! the link. A daemon that hangs on the far side, or a link stuck reconnecting, leaves ssh itself
//! working more often than not (huge-blue, 2026-11-20: its daemon hung, its peers stayed
//! "reconnecting" and every send to it waited).
//!
//! The carry runs `acpmux --json send --no-wait --prompt-id=ID ... NAME -` on the peer, with the
//! message on stdin (never in the argv or the script), so the far daemon's own outbox takes it.
//! The prompt id is the delivery's: a carry tried again, or a later attempt on the link once it
//! is back, is a resend of the same prompt, which the target runs once and answers again with its
//! first outcome. The ssh destination is the peer record's own (`peer::ssh_target`, checked: never
//! an ssh option), every word the script names is one single-quoted shell word, and the whole
//! login is bounded by [`CARRY_DEADLINE`] (`bounded_child.rs`). The far `acpmux` may be off a
//! non-login PATH: `$HOME/.local/bin/acpmux` is tried first, then `acpmux`.
//!
//! What a carry did decides what the outbox does next ([`Carry`]): taken (the far daemon answered
//! with its delivery id: delivered here, never sent again, on any link), not taken (ssh never got
//! to run it: queued as before, still never sent), or maybe taken (a carry that ran out its time
//! or ended unclear: tried again, by ssh or the link, only as a resend of the same prompt id, and
//! never by the mesh relay, whose message has its own id). Each carry is one info line in the
//! daemon log: its host, session, delivery and outcome.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::hub::Hub;
use crate::hub::outbox::Delivery;

/// How long one ssh carry may take, login included, before it is ended.
pub(super) const CARRY_DEADLINE: Duration = Duration::from_secs(30);

/// The attempt from which a delivery whose link is down goes by ssh: the first one failed on the
/// link and its retry found it down again (about 2 s on the outbox's schedule).
pub(super) const CARRY_FROM_ATTEMPT: u32 = 2;

/// The `--relay` name the far daemon records for a carried message.
const RELAY_NAME: &str = "acpmux-ssh";

/// What one carry did.
#[derive(Debug)]
pub(super) enum Carry {
    /// The far daemon took it: its answer, in the shape the outbox keeps.
    Taken(Value),
    /// ssh never ran it there (no login, no acpmux, a refusal before anything was queued).
    NotTaken(String),
    /// It may have reached the far daemon: only a resend of the same prompt id may follow.
    Maybe(String),
}

/// Where a carry goes: the peer's name, its ssh destination and the session key on it.
#[derive(Debug, PartialEq)]
pub(super) struct Route {
    pub host: String,
    pub destination: String,
    pub key: String,
}

/// The ssh route of `target` while its peer is down: `PEER/KEY` (or a key a down peer's last
/// list named) on an `ssh://` peer. None for a session here, a peer that is connected, a peer
/// that is not an ssh machine, or a key ssh could read as an option.
pub(super) fn route(hub: &Hub, target: &str) -> Option<Route> {
    if hub.resolve(target).is_ok() {
        return None;
    }
    let (peer, key) = match hub.resolve_remote(target) {
        Some((peer, id, _)) => (peer, id),
        None => {
            let (host, key) = target.split_once('/')?;
            (hub.peer_by_name(host)?, key.to_owned())
        }
    };
    if peer.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return None;
    }
    let destination = crate::peer::ssh_target(&peer.url).ok()?.destination;
    plain_key(&key).then(|| Route { host: peer.name.clone(), destination, key })
}

/// A session key ssh may carry: a name or id, never empty, never an option, no control character.
fn plain_key(key: &str) -> bool {
    !key.is_empty() && !key.starts_with('-') && !key.chars().any(char::is_control)
}

/// What a carry sends of a delivery's request: its text, and the flags that keep what it means.
#[derive(Debug, PartialEq)]
pub(super) struct Message {
    pub text: String,
    pub flags: Vec<String>,
}

/// `request` as ssh carries it, or None when it holds what the far CLI cannot take on stdin (an
/// attachment, any block but text): the link or the mesh relay keeps it.
pub(super) fn message(request: &Value, from: Option<&str>, machine: &str) -> Option<Message> {
    let mut texts = Vec::new();
    for block in request.get("prompt").and_then(Value::as_array).into_iter().flatten() {
        match (block.get("type").and_then(Value::as_str), block.get("text").and_then(Value::as_str))
        {
            (Some("text"), Some(text)) => texts.push(text),
            _ => return None,
        }
    }
    if texts.is_empty() {
        return None;
    }
    let mux = request.pointer("/_meta/acpmux");
    let field = |k: &str| mux.and_then(|m| m.get(k));
    let word = |k: &str| field(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    let prompt_id = word("promptId")?;
    let mut flags = vec![format!("--prompt-id={prompt_id}")];
    flags.push(if field("steer") == Some(&json!(true)) { "--steer" } else { "--no-steer" }.into());
    if let Ok(Some(class)) = crate::prompt_class::declared(request) {
        flags.push(format!("--class={}", class.as_str()));
    }
    if let Some(key) = word("supersede") {
        flags.push(format!("--supersede={key}"));
    }
    if let Some(from) = from.filter(|f| !f.trim().is_empty()) {
        flags.push(format!("--from={from}"));
        flags.push(format!("--relay={RELAY_NAME}"));
        flags.push(format!("--relayed-from={machine}/{from}"));
    }
    Some(Message { text: texts.join("\n\n"), flags })
}

/// The script the far login runs: the first acpmux found sends `key` the message on stdin.
pub(super) fn script(key: &str, flags: &[String]) -> String {
    let q = crate::run_elsewhere::shell_quote;
    let mut send = String::from("--json send --no-wait");
    for flag in flags {
        send.push(' ');
        send.push_str(&q(flag));
    }
    send.push(' ');
    send.push_str(&q(key));
    send.push_str(" -");
    format!(
        "for a in \"$HOME/.local/bin/acpmux\" acpmux; do if command -v \"$a\" >/dev/null 2>&1; then exec \"$a\" {send}; fi; done; echo 'acpmux: not found on this machine' >&2; exit 127"
    )
}

/// The sender a carry names: the session this daemon proved sent it, else the name it gave.
fn sender(hub: &Hub, delivery: &Delivery) -> Option<String> {
    delivery.caller.as_deref().map(|id| hub.session_name(id)).or_else(|| {
        delivery
            .request
            .pointer("/_meta/acpmux/fromAgent")
            .and_then(Value::as_str)
            .map(str::to_owned)
    })
}

/// One ssh carry of `delivery`, when it has a route ([`route`]) and a message ssh carries
/// ([`message`]); None otherwise (the outbox goes on as before).
pub(super) async fn carry(hub: &Arc<Hub>, delivery: &Delivery) -> Option<Carry> {
    let route = route(hub, &delivery.target)?;
    let from = sender(hub, delivery);
    let machine = crate::pairing::machine_name();
    let message = message(&delivery.request, from.as_deref(), &machine)?;
    let argv = crate::cli::hosts::ssh_argv(&route.destination, &script(&route.key, &message.flags))
        .ok()?;
    let started = std::time::Instant::now();
    let text = message.text.into_bytes();
    let outcome = tokio::task::spawn_blocking(move || run(argv, text))
        .await
        .unwrap_or_else(|e| Carry::NotTaken(format!("the ssh carry did not run: {e}")));
    let (label, why) = match &outcome {
        Carry::Taken(_) => ("taken", String::new()),
        Carry::NotTaken(why) => ("not_taken", why.clone()),
        Carry::Maybe(why) => ("maybe", why.clone()),
    };
    tracing::info!(
        host = %route.host,
        session = %route.key,
        delivery = %delivery.id,
        outcome = label,
        ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        "ssh carry: {why}"
    );
    Some(match outcome {
        Carry::Taken(mut answer) => {
            if let Some(fields) = answer.as_object_mut() {
                fields.insert("host".into(), json!(route.host));
            }
            Carry::Taken(answer)
        }
        other => other,
    })
}

/// The ssh login itself, bounded by [`CARRY_DEADLINE`], and what it did.
fn run(argv: Vec<String>, text: Vec<u8>) -> Carry {
    let mut cmd = cmux_process::Command::new("ssh");
    cmd.args(argv);
    match crate::cli::owned_child::owned(&mut cmd, Some(text), CARRY_DEADLINE, "the ssh carry") {
        Ok(done) => outcome(
            done.status.code(),
            &String::from_utf8_lossy(&done.stdout),
            &String::from_utf8_lossy(&done.stderr),
        ),
        // ssh never started: nothing went anywhere.
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
            ) =>
        {
            Carry::NotTaken(format!("ssh did not start: {e}"))
        }
        Err(e) => Carry::Maybe(e.to_string()),
    }
}

/// What a finished ssh carry did, from its exit code and output.
pub(super) fn outcome(code: Option<i32>, stdout: &str, stderr: &str) -> Carry {
    let last = stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
    let last = crate::cli::output::short(last, 200);
    match code {
        Some(0) => {
            let answer: Option<Value> = serde_json::from_str(stdout.trim()).ok();
            let id = answer
                .as_ref()
                .and_then(|a| a.get("deliveryId"))
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty());
            let (Some(answer), Some(id)) = (answer.as_ref(), id) else {
                return Carry::Maybe("the far acpmux exited 0 with no delivery id".into());
            };
            let field = |k: &str| answer.get(k).cloned().unwrap_or(Value::Null);
            Carry::Taken(json!({
                "via": "ssh",
                "sshDeliveryId": id,
                "promptId": field("promptId"),
                "sessionId": field("sessionId"),
                "steer": answer.get("steered") == Some(&json!(true)),
                "farStatus": field("status"),
            }))
        }
        // ssh's own failure before the login ran anything: nothing reached the far daemon.
        Some(255) if not_connected(stderr) => Carry::NotTaken(format!("ssh: {last}")),
        // No acpmux there (127), a usage refusal (2) or no such session there (4): the far CLI
        // queued nothing.
        Some(code @ (2 | 4 | 127)) => {
            Carry::NotTaken(format!("the far acpmux exited {code}: {last}"))
        }
        Some(code) => Carry::Maybe(format!("the far side exited {code}: {last}")),
        None => Carry::Maybe("the ssh carry ended by a signal".into()),
    }
}

/// ssh's stderr says it never logged in.
fn not_connected(stderr: &str) -> bool {
    const NEVER: &[&str] = &[
        "Could not resolve hostname",
        "Name or service not known",
        "nodename nor servname",
        "Connection refused",
        "Connection timed out",
        "Operation timed out",
        "No route to host",
        "Network is unreachable",
        "Permission denied",
        "Host key verification failed",
        "connect to host",
    ];
    NEVER.iter().any(|m| stderr.contains(m))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_goes_on_stdin_and_every_word_is_quoted() {
        let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi; rm -rf ~"}],
            "_meta": {"acpmux": {"promptId": "p-1", "steer": true, "class": "question"}}});
        let m = message(&request, Some("co'ord"), "vm-1").unwrap();
        assert_eq!(m.text, "hi; rm -rf ~");
        let s = script("lane x", &m.flags);
        assert!(!s.contains("rm -rf"), "{s}");
        assert!(s.contains("'--prompt-id=p-1'"), "{s}");
        assert!(s.contains("'--steer'"), "{s}");
        assert!(s.contains("'--class=question'"), "{s}");
        assert!(s.contains(r"'--from=co'\''ord'"), "{s}");
        assert!(s.contains(r"'--relayed-from=vm-1/co'\''ord'"), "{s}");
        assert!(s.contains("'lane x' -;"), "{s}");
        assert!(s.starts_with("for a in \"$HOME/.local/bin/acpmux\" acpmux;"), "{s}");
    }

    #[test]
    fn an_attachment_or_no_prompt_id_is_not_carried() {
        let image = json!({"prompt": [{"type": "text", "text": "x"}, {"type": "image", "data": ""}],
            "_meta": {"acpmux": {"promptId": "p"}}});
        assert_eq!(message(&image, None, "m"), None);
        let bare = json!({"prompt": [{"type": "text", "text": "x"}]});
        assert_eq!(message(&bare, None, "m"), None);
    }

    #[test]
    fn a_key_ssh_could_read_as_an_option_is_never_carried() {
        assert!(!plain_key("-oProxyCommand=x"));
        assert!(!plain_key(""));
        assert!(!plain_key("a\nb"));
        assert!(plain_key("lane-1"));
    }

    #[test]
    fn what_the_far_side_said_decides_the_outbox_next_step() {
        let ok = r#"{"deliveryId": "d-9", "promptId": "p", "sessionId": "s", "status": "queued", "steered": false}"#;
        match outcome(Some(0), ok, "") {
            Carry::Taken(v) => {
                assert_eq!(v["sshDeliveryId"], "d-9");
                assert_eq!(v["via"], "ssh");
            }
            other => panic!("{other:?}"),
        }
        assert!(matches!(outcome(Some(0), "not json", ""), Carry::Maybe(_)));
        assert!(matches!(
            outcome(Some(255), "", "ssh: connect to host box port 22: Connection refused"),
            Carry::NotTaken(_)
        ));
        assert!(matches!(
            outcome(Some(255), "", "Connection to box closed by remote host."),
            Carry::Maybe(_)
        ));
        assert!(matches!(outcome(Some(127), "", "acpmux: not found"), Carry::NotTaken(_)));
        assert!(matches!(outcome(Some(4), "", "no session"), Carry::NotTaken(_)));
        assert!(matches!(outcome(Some(1), "", "boom"), Carry::Maybe(_)));
        assert!(matches!(outcome(None, "", ""), Carry::Maybe(_)));
    }
}
