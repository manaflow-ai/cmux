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
    // One carry per host at a time: while one login to a host runs, the others are not carried
    // (None: the outbox keeps them for its next try). A down link otherwise turned its whole
    // outbox into that many 30 s ssh logins (and their ProxyCommand hops) at once.
    let _in_flight = InFlight::begin(hub, &route.host, std::time::Instant::now())?;
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
    cooldown().record(&route.host, cools(&outcome), std::time::Instant::now());
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

/// The first wait after a host's carry was not taken (or timed out); each further one doubles it
/// up to [`COOLDOWN_MAX`]. A carry that reached the host and answered clears it.
const COOLDOWN_FIRST: Duration = Duration::from_secs(60);
const COOLDOWN_MAX: Duration = Duration::from_secs(15 * 60);

/// The text of a carry that ran into [`CARRY_DEADLINE`]: `owned_child::owned`'s timeout for
/// [`run`]'s "the ssh carry".
const TIMED_OUT: &str = "the ssh carry timed out";

/// A carry whose outcome cools its host down: refused, or a login that hung (its deadline, or
/// ssh's own keep-alive giving up). A hung host is as unreachable as a refusing one, and each
/// try of it holds an ssh login (and its hops) for the whole deadline.
fn cools(outcome: &Carry) -> bool {
    match outcome {
        Carry::NotTaken(_) => true,
        Carry::Maybe(why) => why.starts_with(TIMED_OUT) || why.contains("Timeout, server"),
        Carry::Taken(_) => false,
    }
}

/// Per host: until when no carry goes to it and the wait last used, and the hosts a carry is
/// logging in to now. Each hub holds its own (`Hub::ssh_carry_cooldown`).
#[derive(Default)]
pub(crate) struct Cooldown {
    waits: std::collections::HashMap<String, (std::time::Instant, Duration)>,
    in_flight: std::collections::HashSet<String>,
}

impl Cooldown {
    fn cooling(&self, host: &str, now: std::time::Instant) -> bool {
        self.waits.get(host).is_some_and(|(until, _)| now < *until)
    }

    /// Takes `host`'s one carry slot: false while it cools down or another carry holds it.
    fn begin(&mut self, host: &str, now: std::time::Instant) -> bool {
        !self.cooling(host, now) && self.in_flight.insert(host.to_owned())
    }

    fn end(&mut self, host: &str) {
        self.in_flight.remove(host);
    }

    fn record(&mut self, host: &str, refused: bool, now: std::time::Instant) {
        if !refused {
            self.waits.remove(host);
            return;
        }
        let wait = self
            .waits
            .get(host)
            .map_or(COOLDOWN_FIRST, |(_, last)| last.saturating_mul(2).min(COOLDOWN_MAX));
        self.waits.insert(host.to_owned(), (now.checked_add(wait).unwrap_or(now), wait));
    }
}

/// A host's one carry slot ([`Cooldown::begin`]), given back on drop: also when the carry's
/// future is dropped mid-login, so a cancelled carry never holds its host forever.
struct InFlight<'a> {
    hub: &'a Hub,
    host: String,
}

impl<'a> InFlight<'a> {
    fn begin(hub: &'a Hub, host: &str, now: std::time::Instant) -> Option<Self> {
        let mut cool =
            hub.ssh_carry_cooldown.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        cool.begin(host, now).then(|| Self { hub, host: host.to_owned() })
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.hub
            .ssh_carry_cooldown
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .end(&self.host);
    }
}

/// The ssh login itself, bounded by [`CARRY_DEADLINE`], and what it did.
fn run(argv: Vec<String>, text: Vec<u8>) -> Carry {
    // In its own low-weight scope, with its ProxyCommand hops (`agent_host/scope.rs`).
    let (program, lead) = crate::agent_host::scope::low_weight(std::ffi::OsStr::new("ssh"));
    let mut cmd = cmux_process::Command::new(program);
    cmd.args(lead).args(argv);
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
        // `systemd-run` could not make the ssh's scope (`scope::low_weight`): no ssh ran.
        Some(_) if stderr.contains("Failed to start transient scope unit") => {
            Carry::NotTaken(format!("systemd-run: {last}"))
        }
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
mod tests {
    /// Duress harness: 416 queued deliveries to one host whose ssh login refuses, each retried
    /// every 2 s for an hour (the herd a link flap woke). Carries that spawn ssh: one per
    /// cool-down step, not one per delivery per retry.
    #[test]
    fn a_refusing_host_gets_one_carry_per_cool_down_not_one_per_delivery() {
        let start = std::time::Instant::now();
        let mut cool = super::Cooldown::default();
        let mut spawned = 0u32;
        for tick in 0..1800u64 {
            let now = start + std::time::Duration::from_secs(tick * 2);
            for _ in 0..416 {
                if !cool.cooling("h", now) {
                    spawned += 1;
                    cool.record("h", true, now);
                }
            }
        }
        eprintln!("ssh carries in 1 h for 416 deliveries: {spawned} (was {})", 1800 * 416);
        // At 0, 60, 180, 420, 900, 1800 and 2700 s (waits 60, 120, 240, 480, then 900): 7.
        assert_eq!(spawned, 7);
        // Another host is not held back by this one; a carry that reached a host clears it.
        assert!(!cool.cooling("other", start));
        let late = start + std::time::Duration::from_secs(3600);
        cool.record("h", false, late);
        assert!(!cool.cooling("h", late));
    }

    use super::*;

    /// Review of #53719, F2: `carry` itself skips the ssh login while the host cools down. 416
    /// deliveries to one refusing ssh host: one login, the rest not carried; another hub's own
    /// cool-down is its own, so it logs in once too.
    #[tokio::test]
    async fn carry_skips_a_cooling_host_and_each_hub_has_its_own_cool_down() {
        static LOGINS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        fn refused(_: Vec<String>, _: Vec<u8>) -> Carry {
            LOGINS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Carry::NotTaken("ssh: connect to host box port 22: Connection refused".into())
        }
        let hub = || {
            let mut config = crate::config::Config::default();
            config.store.mode = crate::config::StoreMode::Memory;
            let store =
                crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
            let hub = Hub::new(config, store);
            let row = json!({"sessionId": "s-lane", "name": "lane", "status": "idle",
                             "turnCount": 1, "updatedAt": 5});
            hub.seed_down_peer_at("carry-cool-box", "ssh://carry-cool-box", vec![row]);
            hub
        };
        let mut d = delivery(json!({"promptId": "p"}));
        d.target = "carry-cool-box/lane".into();
        let (one, two) = (hub(), hub());
        assert!(route(&one, &d.target).is_some(), "no ssh route to the down peer");
        let mut carried = 0;
        for _ in 0..416 {
            carried += u32::from(carry_by(&one, &d, refused).await.is_some());
        }
        assert_eq!((carried, LOGINS.load(std::sync::atomic::Ordering::SeqCst)), (1, 1));
        assert!(carry_by(&two, &d, refused).await.is_some(), "another hub's cool-down held it");
        assert_eq!(LOGINS.load(std::sync::atomic::Ordering::SeqCst), 2);
        // A carry that reached the host clears its cool-down for the next one.
        one.ssh_carry_cooldown.lock().unwrap().record(
            "carry-cool-box",
            false,
            std::time::Instant::now(),
        );
        assert!(carry_by(&one, &d, refused).await.is_some());
        assert_eq!(LOGINS.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    /// The hop storm of 2026-11-28 (a shared Linux host): a down link's outbox woke its whole
    /// queue at once and each delivery became its own 30 s ssh login (each with its ProxyCommand
    /// hop), about 300 at once. 64 deliveries to one host whose login hangs, all at once: one
    /// login runs, the rest are not carried (the outbox keeps them), and the timeout cools the
    /// host down so the next try logs in to nothing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn one_carry_per_host_at_a_time_and_a_hung_login_cools_the_host() {
        use std::sync::atomic::{AtomicU32, Ordering::SeqCst};
        static NOW: AtomicU32 = AtomicU32::new(0);
        static PEAK: AtomicU32 = AtomicU32::new(0);
        static LOGINS: AtomicU32 = AtomicU32::new(0);
        fn hangs(_: Vec<String>, _: Vec<u8>) -> Carry {
            LOGINS.fetch_add(1, SeqCst);
            PEAK.fetch_max(NOW.fetch_add(1, SeqCst) + 1, SeqCst);
            std::thread::sleep(Duration::from_millis(300));
            NOW.fetch_sub(1, SeqCst);
            Carry::Maybe(format!("{TIMED_OUT} after 30 s"))
        }
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let row = json!({"sessionId": "s-lane", "name": "lane", "status": "idle",
                         "turnCount": 1, "updatedAt": 5});
        hub.seed_down_peer_at("carry-storm-box", "ssh://carry-storm-box", vec![row]);
        const DELIVERIES: u32 = 64;
        let start = std::sync::Arc::new(tokio::sync::Barrier::new(DELIVERIES as usize));
        let mut all = tokio::task::JoinSet::new();
        for _ in 0..DELIVERIES {
            let (hub, start) = (hub.clone(), start.clone());
            all.spawn(async move {
                let mut d = delivery(json!({"promptId": "p"}));
                d.target = "carry-storm-box/lane".into();
                start.wait().await;
                carry_by(&hub, &d, hangs).await.is_some()
            });
        }
        let mut carried = 0;
        while let Some(done) = all.join_next().await {
            carried += u32::from(done.unwrap());
        }
        let (peak, logins) = (PEAK.load(SeqCst), LOGINS.load(SeqCst));
        eprintln!(
            "{DELIVERIES} deliveries to one hung host: {logins} ssh logins, {peak} at once, {carried} carried"
        );
        assert_eq!((peak, logins, carried), (1, 1, 1));
        // The slot came back, and the timeout cools the host: the next try logs in to nothing.
        let mut d = delivery(json!({"promptId": "p"}));
        d.target = "carry-storm-box/lane".into();
        assert!(carry_by(&hub, &d, hangs).await.is_none());
        assert_eq!(LOGINS.load(SeqCst), 1);
        assert!(hub.ssh_carry_cooldown.lock().unwrap().in_flight.is_empty());
    }

    #[test]
    fn a_hosts_slot_is_its_own_and_only_a_refusal_or_a_hang_cools_it() {
        let now = std::time::Instant::now();
        let mut cool = Cooldown::default();
        assert!(cool.begin("a", now));
        assert!(!cool.begin("a", now), "a second carry to a host in flight");
        assert!(cool.begin("b", now), "another host held back by this one");
        cool.end("a");
        assert!(cool.begin("a", now));
        assert!(cools(&Carry::NotTaken("ssh: Connection refused".into())));
        assert!(cools(&Carry::Maybe(format!("{TIMED_OUT} after 30 s"))));
        assert!(cools(&Carry::Maybe("Timeout, server box not responding.".into())));
        assert!(!cools(&Carry::Maybe("the far side exited 1: boom".into())));
        assert!(!cools(&Carry::Taken(json!({}))));
    }

    #[test]
    fn the_message_goes_on_stdin_and_every_word_is_quoted() {
        let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi; rm -rf ~"}],
            "_meta": {"acpmux": {"promptId": "p-1", "steer": true, "class": "question"}}});
        let m = message(&request, &Sender::Named("co'ord".into()), "vm-1").unwrap();
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
        assert_eq!(message(&image, &Sender::Person, "m"), None);
        let bare = json!({"prompt": [{"type": "text", "text": "x"}]});
        assert_eq!(message(&bare, &Sender::Person, "m"), None);
    }

    /// A delivery with `mux` as its request's `_meta.acpmux`.
    fn delivery(mux: Value) -> Delivery {
        let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi"}],
            "_meta": {"acpmux": mux}});
        serde_json::from_value(json!({"id": "d-1", "target": "box/lane", "request": request,
            "state": "queued", "createdAt": 0, "updatedAt": 0}))
        .unwrap()
    }

    /// Only the person's own send is carried with no sender: every other one names its sender
    /// or, with no name to give, this machine as its relay, so the far daemon never records an
    /// agent's message as its owner's terminal send.
    #[test]
    fn only_the_persons_own_send_is_carried_with_no_sender() {
        let name_of = |id: &str| format!("name-of-{id}");
        let flags = |d: &Delivery| message(&d.request, &sender(d, name_of), "vm-1").unwrap().flags;
        let relayed = |flags: &[String]| flags.iter().any(|f| f.starts_with("--relay="));

        let person = delivery(json!({"promptId": "p"}));
        assert_eq!(sender(&person, name_of), Sender::Person);
        assert!(!relayed(&flags(&person)), "{:?}", flags(&person));

        let mut proven = delivery(json!({"promptId": "p"}));
        proven.caller = Some("s1".into());
        assert_eq!(sender(&proven, name_of), Sender::Named("name-of-s1".into()));

        // The case of 2026-11-22: a stale caller token, so the session is named and unproven.
        let mut unproven = delivery(json!({"promptId": "p"}));
        unproven.unproven_caller = Some("s2".into());
        assert_eq!(sender(&unproven, name_of), Sender::Named("name-of-s2".into()));
        let f = flags(&unproven);
        assert!(f.contains(&"--from=name-of-s2".to_owned()), "{f:?}");
        assert!(f.contains(&"--relayed-from=vm-1/name-of-s2".to_owned()), "{f:?}");

        // An agent's shell that declared no terminal and named no one.
        let mut no_terminal = delivery(json!({"promptId": "p"}));
        no_terminal.not_terminal = true;
        assert_eq!(sender(&no_terminal, name_of), Sender::Program);
        let f = flags(&no_terminal);
        assert!(f.contains(&"--relay=acpmux-ssh".to_owned()), "{f:?}");
        assert!(f.contains(&"--relayed-from=vm-1".to_owned()), "{f:?}");
        assert!(!f.iter().any(|flag| flag.starts_with("--from=")), "{f:?}");

        // Each claim that makes a direct send a program's does the same for a carried one.
        for key in ["fromHarness", "senderHarness", "fromRelay", "via"] {
            let claimed = delivery(json!({"promptId": "p", key: {"harness": "claude-code"}}));
            assert_eq!(sender(&claimed, name_of), Sender::Program, "{key}");
            assert!(relayed(&flags(&claimed)), "{key}");
        }
        let named = delivery(json!({"promptId": "p", "fromAgent": "vm-9/lane", "via": "x"}));
        assert_eq!(sender(&named, name_of), Sender::Named("vm-9/lane".into()));
        // A blank name is no name, and still not the person's.
        let blank = delivery(json!({"promptId": "p", "fromAgent": "  "}));
        assert_eq!(sender(&blank, name_of), Sender::Program);
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
        // A parked machine behind a relay ProxyCommand: ssh never logged in, so the message is
        // still unsent and the mesh relay may carry it (not a maybe-taken that rules it out).
        assert!(matches!(
            outcome(
                Some(255),
                "",
                "mm_receive_fd: recvmsg: expected received 1 got 0\nproxy dialer did not pass back a connection"
            ),
            Carry::NotTaken(_)
        ));
        assert!(matches!(outcome(Some(127), "", "acpmux: not found"), Carry::NotTaken(_)));
        assert!(matches!(
            outcome(Some(1), "", "Failed to start transient scope unit: Connection timed out"),
            Carry::NotTaken(_)
        ));
        assert!(matches!(outcome(Some(4), "", "no session"), Carry::NotTaken(_)));
        assert!(matches!(outcome(Some(1), "", "boom"), Carry::Maybe(_)));
        assert!(matches!(outcome(None, "", ""), Carry::Maybe(_)));
    }
}
