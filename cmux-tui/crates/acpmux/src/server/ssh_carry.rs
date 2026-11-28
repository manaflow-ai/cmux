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

/// The `--relay` name the far daemon records for a carried message: its inbox wakes the chat
/// for it (`prompt_provenance::waited`).
const RELAY_NAME: &str = crate::prompt_provenance::SSH_CARRY_RELAY;

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
pub(super) fn message(request: &Value, from: &Sender, machine: &str) -> Option<Message> {
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
    match from {
        Sender::Named(from) => {
            flags.push(format!("--from={from}"));
            flags.push(format!("--relay={RELAY_NAME}"));
            flags.push(format!("--relayed-from={machine}/{from}"));
        }
        // No name to give, and still not the person's: the relay record alone names this
        // machine, so the far daemon records another agent's message (`cli/run/standard.rs`
        // names a relayed send with no `--from` by where it came from).
        Sender::Program => {
            flags.push(format!("--relay={RELAY_NAME}"));
            flags.push(format!("--relayed-from={machine}"));
        }
        Sender::Person => {}
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

/// Who a carry says sent a delivery. The far CLI runs under a plain ssh login, which declares a
/// terminal and holds no caller token: a carry that says nothing is recorded there as the far
/// machine's owner typing at a terminal (`server/requests/prompt_sender.rs` `owner_terminal`).
/// So only the person's own send says nothing.
///
/// Leo, 2026-11-22, on a lane's messages drawn in his chat as his own bubbles, "you · via CLI on
/// cosmic-gray": "these shouldn't have been shown like that." The lane's send had proved no
/// session to its own daemon, the carry named no one for it, and the far record read
/// `origin: {actor: "person", verified: true}`.
#[derive(Debug, PartialEq)]
pub(super) enum Sender {
    /// A session or a name: the one this daemon proved, else the one the send gave.
    Named(String),
    /// A program that is not the person and has no name here: a send that declared no terminal
    /// or claimed a harness, a relay or a route (`Delivery::not_terminal`, `SENDER_CLAIMS`).
    Program,
    /// The person's own send, carried as the far machine's owner's terminal send.
    Person,
}

/// The `_meta.acpmux` fields that make a send a program's and never the owner's terminal's, as
/// `prompt_sender.rs` `claims_a_sender` reads them on a direct send.
const SENDER_CLAIMS: &[&str] = &[
    crate::prompt_provenance::FROM_HARNESS,
    crate::sender_harness::META_KEY,
    crate::prompt_provenance::FROM_RELAY,
    "via",
];

/// Who a carry of `delivery` names, with `name_of` this daemon's name for a session id: the
/// session it proved, the name the send gave, the session it named without proof (still an
/// agent's, by the name this daemon has for it), a program with no name, or the person.
pub(super) fn sender(delivery: &Delivery, name_of: impl Fn(&str) -> String) -> Sender {
    let mux = delivery.request.pointer("/_meta/acpmux");
    let said = |key: &str| mux.and_then(|m| m.get(key)).filter(|v| !v.is_null());
    let named = |name: String| Some(name).filter(|n| !n.trim().is_empty()).map(Sender::Named);
    let from_agent = || said("fromAgent").and_then(Value::as_str).map(str::to_owned);
    delivery
        .caller
        .as_deref()
        .and_then(|id| named(name_of(id)))
        .or_else(|| from_agent().and_then(named))
        .or_else(|| delivery.unproven_caller.as_deref().and_then(|id| named(name_of(id))))
        .unwrap_or_else(|| {
            let program = delivery.caller.is_some()
                || delivery.unproven_caller.is_some()
                || delivery.not_terminal
                || said("fromAgent").is_some()
                || SENDER_CLAIMS.iter().any(|key| said(key).is_some());
            if program { Sender::Program } else { Sender::Person }
        })
}

/// One ssh carry of `delivery`, when it has a route ([`route`]) and a message ssh carries
/// ([`message`]); None otherwise (the outbox goes on as before).
pub(super) async fn carry(hub: &Arc<Hub>, delivery: &Delivery) -> Option<Carry> {
    carry_by(hub, delivery, run).await
}

/// [`carry`], with `login` as the ssh login itself ([`run`]; a test's stand-in counts them).
async fn carry_by(
    hub: &Arc<Hub>,
    delivery: &Delivery,
    login: fn(Vec<String>, Vec<u8>) -> Carry,
) -> Option<Carry> {
    let route = route(hub, &delivery.target)?;
    // One host whose ssh login refuses is tried once per cool-down for all its deliveries, not
    // once per delivery per retry (each a process spawn, a daemon.log line and outbox writes).
    let cooldown =
        || hub.ssh_carry_cooldown.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if cooldown().cooling(&route.host, std::time::Instant::now()) {
        return None;
    }
    // The joined machine name reads the local machine record.
    let machine = crate::qos::off_worker(crate::pairing::machine_name);
    // A peer named as this machine is this daemon: ssh to it is a login to ourselves, which
    // (gcp lane VM, 2026-11-24) failed its publickey on every retry of 416 deliveries.
    if route.host == machine {
        return None;
    }
    let from = sender(delivery, |id| hub.session_name(id));
    let message = message(&delivery.request, &from, &machine)?;
    let argv = crate::cli::hosts::ssh_argv(&route.destination, &script(&route.key, &message.flags))
        .ok()?;
    let started = std::time::Instant::now();
    let text = message.text.into_bytes();
    let outcome = tokio::task::spawn_blocking(move || login(argv, text))
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
    cooldown().record(
        &route.host,
        matches!(outcome, Carry::NotTaken(_)),
        std::time::Instant::now(),
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

/// The first wait after a host's carry was not taken; each further refusal doubles it up to
/// [`COOLDOWN_MAX`]. A carry that reached the host (taken or maybe) clears it.
const COOLDOWN_FIRST: Duration = Duration::from_secs(60);
const COOLDOWN_MAX: Duration = Duration::from_secs(15 * 60);

/// Per host: until when no carry goes to it, and the wait last used. Each hub holds its own
/// (`Hub::ssh_carry_cooldown`).
#[derive(Default)]
pub(crate) struct Cooldown(std::collections::HashMap<String, (std::time::Instant, Duration)>);

impl Cooldown {
    fn cooling(&self, host: &str, now: std::time::Instant) -> bool {
        self.0.get(host).is_some_and(|(until, _)| now < *until)
    }

    fn record(&mut self, host: &str, refused: bool, now: std::time::Instant) {
        if !refused {
            self.0.remove(host);
            return;
        }
        let wait = self
            .0
            .get(host)
            .map_or(COOLDOWN_FIRST, |(_, last)| last.saturating_mul(2).min(COOLDOWN_MAX));
        self.0.insert(host.to_owned(), (now.checked_add(wait).unwrap_or(now), wait));
    }
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
        // A relay ProxyCommand (ProxyUseFdpass) reached none of the machine's routes: no login.
        "proxy dialer did not pass back a connection",
    ];
    NEVER.iter().any(|m| stderr.contains(m))
}

#[cfg(test)]
#[path = "ssh_carry_tests.rs"]
mod tests;
