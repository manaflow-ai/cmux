//! A prompt to a watched Claude Code or Codex chat whose app still runs it, delivered into that
//! app's session (`claude_peers.rs`, `codex_desktop.rs`) instead of refused as `watch.read_only`.
//!
//! With `agents.desktopBridge.enabled`, `prompt_with` hands a watched bridged chat's prompt here.
//! When the conversation's own Claude Code is registered and live, the prompt goes to its inbox
//! as a message with a fresh `uuid`, and is accepted at once. The app runs it as a turn and writes
//! it to the transcript with that uuid; the watch (`watch.rs`) shows that line as this prompt,
//! under this prompt's id, and its answer as the turn's answer. A Codex thread a running Codex
//! holds gets it through its app-server's queue (`thread/queue/add`); its rollout keeps no id of
//! ours on the prompt line, so the watch knows the delivery by its exact text, the oldest one not
//! shown yet first. The prompt's call answers when
//! the watch ends that turn, so a person's send and an agent's `--wait` read the answer as from
//! any turn. Nothing is started and nothing is written to the transcript by acpmux.
//!
//! A chat whose app no longer runs it falls through to the refusal: Take Over runs it here. A
//! chat its session registered by name (`acpmux register`, `register.rs`) is that name's address
//! instead: while its app is not running it, a prompt is refused as `bridge.not_running`, which
//! the outbox tries again (`acpmux send --no-wait` keeps it queued, `--status` says so) until the
//! session runs again and registers, or the outbox's day runs out.
//! Deliveries are kept in memory (the newest 256 answered ones too, so a resend is not delivered
//! again). After a daemon restart, a delivered line the watch had not shown yet shows only its
//! answer, as any other session's peer message does.

use super::{Hub, PromptOptions, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::watch;

/// Longest a delivered prompt's call waits for the app to end its turn. It is answered then
/// with `answered: false`; the turn still shows when it ends.
const ANSWER_WAIT: Duration = Duration::from_secs(30 * 60);

/// Most deliveries kept; past it the oldest answered ones go. A resend of a prompt id that went
/// still finds its answer while it is kept.
const KEPT: usize = 256;

/// How a delivery ended: the turn the watch showed it as, or why the app's inbox did not take it.
type Outcome = Option<Result<String, String>>;

/// A delivery, by the uuid it was sent with: waiting for its transcript line and turn until
/// `turn` holds its [`Outcome`], then kept (when it went) so a resend is not delivered again.
pub(super) struct Pending {
    pub(super) session_id: String,
    pub(super) prompt_id: String,
    pub(super) text: String,
    /// The text as the app got it (with the reply hint): what a Codex rollout line shows.
    wire: String,
    /// The watch showed its line (known by its text, which another line may repeat).
    shown: bool,
    order: u64,
    turn: watch::Sender<Outcome>,
}

#[derive(Default)]
struct Deliveries {
    by_uuid: HashMap<String, Pending>,
    next: u64,
}

static PENDING: LazyLock<Mutex<Deliveries>> = LazyLock::new(Default::default);

fn deliveries() -> std::sync::MutexGuard<'static, Deliveries> {
    PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Deliveries {
    /// The delivery of `prompt_id`, claimed under one lock: a new one (`Ok`) to send as `uuid`, or
    /// the one a resend of the same id finds (`Err`), whose turn it answers with.
    fn claim(
        &mut self,
        uuid: String,
        session_id: &str,
        prompt_id: &str,
        text: &str,
        wire: &str,
    ) -> Result<watch::Receiver<Outcome>, watch::Receiver<Outcome>> {
        if let Some((_, p)) = self.of_prompt(session_id, prompt_id) {
            return Err(p.turn.subscribe());
        }
        let (turn, rx) = watch::channel(None);
        self.next = self.next.saturating_add(1);
        let pending = Pending {
            session_id: session_id.to_owned(),
            prompt_id: prompt_id.to_owned(),
            text: text.to_owned(),
            wire: wire.to_owned(),
            shown: false,
            order: self.next,
            turn,
        };
        self.by_uuid.insert(uuid, pending);
        while self.by_uuid.len() > KEPT {
            let oldest = self
                .by_uuid
                .iter()
                .filter(|(_, p)| p.turn.borrow().is_some())
                .min_by_key(|(_, p)| p.order)
                .map(|(k, _)| k.clone());
            let Some(oldest) = oldest else { break };
            self.by_uuid.remove(&oldest);
        }
        Ok(rx)
    }

    fn of_prompt(&self, session_id: &str, prompt_id: &str) -> Option<(&String, &Pending)> {
        self.by_uuid.iter().find(|(_, p)| p.session_id == session_id && p.prompt_id == prompt_id)
    }
}

/// The delivery a transcript line with `uuid` in `session_id` shows, if acpmux sent it and the
/// watch has not shown it yet.
pub(super) fn delivered(session_id: &str, uuid: &str) -> Option<(String, String)> {
    deliveries()
        .by_uuid
        .get(uuid)
        .filter(|p| p.session_id == session_id && p.turn.borrow().is_none())
        .map(|p| (p.prompt_id.clone(), p.text.clone()))
}

/// The delivery a Codex rollout's prompt `text` in `session_id` shows: the oldest one acpmux
/// sent with that text the watch has not shown yet, marked shown.
pub(super) fn delivered_text(session_id: &str, text: &str) -> Option<(String, String)> {
    let text = text.trim();
    let mut all = deliveries();
    let p = all
        .by_uuid
        .values_mut()
        .filter(|p| {
            p.session_id == session_id
                && !p.shown
                && p.turn.borrow().is_none()
                && p.wire.trim() == text
        })
        .min_by_key(|p| p.order)?;
    p.shown = true;
    Some((p.prompt_id.clone(), p.text.clone()))
}

/// The watch ended the turn of `prompt_id`: its call (and any resend's) answers with `turn_id`.
pub(super) fn answered(session_id: &str, prompt_id: &str, turn_id: &str) {
    if let Some((_, p)) = deliveries().of_prompt(session_id, prompt_id) {
        p.turn.send_replace(Some(Ok(turn_id.to_owned())));
    }
}

/// The outcome `rx` gets, once the watch shows its turn or its delivery fails, within [`ANSWER_WAIT`].
async fn turn_of(mut rx: watch::Receiver<Outcome>) -> Outcome {
    let wait = rx.wait_for(Option::is_some);
    tokio::time::timeout(ANSWER_WAIT, wait).await.ok()?.ok()?.clone()
}

/// The text of a prompt's content blocks, when they are all text: an image or a file would not
/// reach the app (its inbox takes text), so such a prompt is refused rather than cut.
fn text_of(blocks: &[Value]) -> Option<String> {
    blocks
        .iter()
        .map(|b| match b.get("type").and_then(Value::as_str) {
            Some("text") => b.get("text").and_then(Value::as_str),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()
        .map(|texts| texts.join("\n\n"))
        .filter(|text| !text.trim().is_empty())
}

/// Where a bridged chat's prompt goes: the Claude Code session's inbox, or the Codex thread's
/// queue.
enum Target {
    Claude { config: PathBuf, peer: crate::claude_peers::Peer, token: Option<String> },
    Codex { home: PathBuf, thread: crate::codex_desktop::Thread },
}

impl Target {
    /// What the delivery record and the prompt's answer say of the app.
    fn details(&self) -> Value {
        match self {
            Target::Claude { peer, token, .. } => json!({
                "pid": peer.pid,
                "entrypoint": peer.entrypoint,
                "token": if token.is_some() { "registered" } else { "peer-key" },
            }),
            Target::Codex { thread, .. } => {
                json!({"thread": thread.id, "originator": thread.originator})
            }
        }
    }

    /// Delivers `wire` as message `uuid` from `sender`.
    async fn deliver(&self, wire: &str, uuid: &str, sender: &str) -> Result<(), String> {
        match self {
            Target::Claude { config, peer, token } => {
                let from = crate::claude_peers::from_address(sender);
                crate::claude_peers::deliver(config, peer, wire, uuid, &from, token.as_deref())
                    .await
            }
            Target::Codex { home, thread } => {
                crate::codex_desktop::deliver(home, &thread.id, wire, uuid).await.map(drop)
            }
        }
    }
}

impl Hub {
    /// `Some` answer when `session` is a watched bridged chat this prompt was delivered into;
    /// `None` leaves the prompt to the usual path (which refuses it while watched).
    pub(super) async fn bridged_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        opts: &mut PromptOptions,
    ) -> Option<Result<Value, RpcError>> {
        let watching = session.meta().watching?;
        let family = watching.family.clone();
        if family != "claude" && family != "codex" {
            return None;
        }
        let agent_session_id = session.meta().agent_session_id?;
        // Only a chat the bridge listed (`desktop_bridge.rs`) takes prompts; any other watched
        // chat stays read-only, whatever runs its conversation.
        if session.meta().tags.get("bridge").is_none_or(|t| t.value != family) {
            return None;
        }
        let registered = super::register::is_registered(session);
        // A prompt that waits for the owner's approval (a shared chat's guest, `author.rs`) is
        // never delivered: the app would run it before anyone approved it. It goes the usual way,
        // which refuses it while the chat is watched, until the bridge holds prompts for approval.
        if crate::author::awaits_owner(opts.provenance.as_ref()) {
            return None;
        }
        // A resend of a prompt id that went answers with its turn, whether or not the app still runs.
        if let Some(id) = opts.prompt_id.clone() {
            let kept = deliveries().of_prompt(&session.id, &id).map(|(_, p)| p.turn.subscribe());
            if let Some(rx) = kept {
                return Some(resent(session, &id, rx, opts).await);
            }
        }
        let homes = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let acpmux_home = crate::config::home();
        let chat_id = session.id.clone();
        let target = tokio::task::spawn_blocking(move || {
            // A chat its session registered is bridged whatever the setting says: the session
            // asked for it from its own shell (`register.rs`).
            if !registered && !crate::claude_peers::enabled() {
                return None;
            }
            // A chat nobody registered: the app's own record must name an entrypoint (Claude
            // Code) or originator (Codex) the setting lists, since a tag alone is anyone's to
            // set. A registered chat never goes by an entrypoint (anyone's to write): only by the
            // process its registration recorded, below.
            let listed = crate::claude_peers::listed_entrypoints();
            if family == "codex" {
                // Only Claude Code sessions register (`register.rs`).
                if registered {
                    return None;
                }
                let thread = crate::codex_desktop::find(&homes.codex, &agent_session_id, &listed)?;
                return Some(Target::Codex { home: homes.codex, thread });
            }
            let by_setting = |p: &crate::claude_peers::Peer| {
                crate::claude_peers::enabled()
                    && p.entrypoint.as_ref().is_some_and(|e| listed.contains(e))
            };
            if registered {
                // A registered chat opens only with the token its session handed over, into the
                // process that registration recorded (pid, inbox, start), while it is its
                // conversation's only live claimant. A restarted session's new process has none
                // until it registers again, so the send waits (`bridge.not_running`), never
                // opening with the undocumented peer key, with the bridge setting on or off.
                let live = crate::claude_peers::live(&homes.claude);
                let (peer, token) =
                    live.iter().filter(|p| p.session_id == agent_session_id).find_map(|p| {
                        let started = crate::claude_peers::started_at(&homes.claude, p.pid);
                        let token =
                            crate::claude_peers::token_for(&acpmux_home, &chat_id, p, started)?;
                        crate::claude_peers::sole_claimant(p, &live).then(|| (p.clone(), token))
                    })?;
                return Some(Target::Claude { config: homes.claude, peer, token: Some(token) });
            }
            let peer =
                crate::claude_peers::find(&homes.claude, &agent_session_id).filter(by_setting)?;
            let token = None;
            Some(Target::Claude { config: homes.claude, peer, token })
        })
        .await
        .ok()
        .flatten();
        let Some(target) = target else {
            // A registered name keeps its address while its app is closed: a send the outbox
            // carries (here, or a peer's forwarded) waits and is tried again, instead of failing
            // as a read-only chat's would. A person's own prompt still gets the read-only
            // refusal, with Take Over.
            return (registered && retried_client(client))
                .then(|| Err(not_running(&session.meta().name)));
        };
        let Some(text) = text_of(blocks) else {
            return Some(Err(RpcError::invalid_params(
                "only text reaches a session another app runs: send it without attachments, or take the chat over",
            )));
        };
        let prompt_id = opts.prompt_id.clone().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let uuid = uuid::Uuid::now_v7().to_string();
        // The chat shows the prompt as sent (`delivered`); the app also reads how to answer.
        let harness = sender_harness(opts);
        let unverified =
            opts.provenance.as_ref().and_then(|p| p.get("kind")).and_then(Value::as_str)
                == Some("unverified");
        let wire =
            with_reply_hint(&text, reply_name(opts).as_deref(), harness.as_deref(), unverified);
        // The gate every prompt passes again at dispatch (`web_control.rs` `check_dispatch`): the
        // chat's mode, policy, device authorization or folder trust may have changed since the
        // request's own check, and a refused prompt never reaches the app.
        let checked = self
            .check_dispatch(
                session,
                opts.control,
                opts.cloud_mobile,
                opts.trust_gate,
                opts.full_access_device.as_deref(),
                &prompt_id,
                &uuid,
                "bridge",
            )
            .await;
        if let Err(e) = checked {
            return Some(Err(e));
        }
        // Claimed under one lock: two sends of one id never both go.
        let claimed = deliveries().claim(uuid.clone(), &session.id, &prompt_id, &text, &wire);
        let rx = match claimed {
            Ok(rx) => rx,
            Err(rx) => return Some(resent(session, &prompt_id, rx, opts).await),
        };
        let sender = opts.agent.clone().unwrap_or_else(|| "person".to_owned());
        if let Err(e) = target.deliver(&wire, &uuid, &sender).await {
            // A resend waiting on this delivery fails with it, and a later one delivers again.
            let gone = deliveries().by_uuid.remove(&uuid);
            if let Some(p) = gone {
                p.turn.send_replace(Some(Err(e.clone())));
            }
            return Some(Err(undelivered(&e)));
        }
        let details = target.details();
        let mut record = json!({"promptId": prompt_id, "uuid": uuid});
        if let (Some(record), Some(more)) = (record.as_object_mut(), details.as_object()) {
            record.extend(more.clone());
        }
        self.append(session, "mux", "bridge_delivered", record);
        if let Some(f) = opts.on_accepted.take() {
            f(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "state": "delivered", "bridged": true}),
            );
        }
        Some(answer(&prompt_id, turn_of(rx).await, Some(&details)))
    }
}

/// `text` as the app reads it: an agent's message opens with the line every harness reads ahead
/// of another agent's message (`prompt_attribution::agent_line`: its name, and its harness when
/// the daemon bound one) and ends with how to answer that agent. Claude Code's own messaging
/// cannot reach an `acpmux:` address, and its `acpmux send` from the app's shell is bound to this
/// chat (`desktop_bridge.rs`), so the answer lands in the sender's inbox under the chat's name.
/// The person's prompt goes as typed.
/// A sender acpmux could not bind (`unverified`) reads as the program it claims to be, as on the
/// ACP path (`prompt_attribution::unverified_line`).
fn with_reply_hint(
    text: &str,
    agent: Option<&str>,
    harness: Option<&str>,
    unverified: bool,
) -> String {
    match agent.map(str::trim).filter(|a| !a.is_empty()) {
        Some(agent) => {
            let quoted = agent.replace('\'', "'\\''");
            let provenance = harness.map(|h| json!({crate::prompt_provenance::FROM_HARNESS: h}));
            let who = super::prompt_attribution::with_harness(agent, provenance.as_ref());
            let line = if unverified {
                super::prompt_attribution::unverified_line(Some(&who))
            } else {
                super::prompt_attribution::agent_line(&who)
            };
            format!(
                "{line}\n{text}\n\n[Answer {agent} with `acpmux send '{quoted}' '<your reply>'` in your shell; your own messaging tools cannot reach it.]"
            )
        }
        None => text.to_owned(),
    }
}

/// The sender's harness the daemon bound on the prompt's provenance (`fromHarness`).
fn sender_harness(opts: &PromptOptions) -> Option<String> {
    opts.provenance
        .as_ref()?
        .get(crate::prompt_provenance::FROM_HARNESS)?
        .as_str()
        .map(str::to_owned)
}

/// Who the app's answer goes to: the chat a verified session message came from (a caller token's
/// session, or a desktop chat's bridged one), by the name `acpmux send` finds it by; else the
/// label the sender gave. A bridged desktop chat's own label (`Claude Code desktop on <host> ·
/// <id>`) names no session, so an answer to it would go nowhere.
fn reply_name(opts: &PromptOptions) -> Option<String> {
    let verified = opts.provenance.as_ref().filter(|p| {
        p.get("kind").and_then(Value::as_str) == Some("session_message")
            && p.get(crate::prompt_provenance::VERIFIED).and_then(Value::as_bool) == Some(true)
    });
    verified
        .and_then(|p| p.get("fromName").and_then(Value::as_str))
        .filter(|n| !n.trim().is_empty())
        .map(str::to_owned)
        .or_else(|| opts.agent.clone())
}

/// A client whose refused prompt is tried again: this daemon's outbox, or a peer daemon
/// forwarding its outbox's send (`hub/prompt_line.rs` names the same prefixes).
fn retried_client(client: &str) -> bool {
    ["acpmux-outbox#", "acpmux-peer#"].iter().any(|p| client.starts_with(p))
}

/// A registered chat's app is not running it now: tried again (`server/outbox.rs` `next`).
fn not_running(name: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "bridge.not_running: {name}'s app is not running it now; the message waits and is tried again"
        ),
    )
    .with_data(json!({"reason": "bridge.not_running", "retryable": true}))
}

fn undelivered(e: &str) -> RpcError {
    RpcError::new(-32000, format!("bridge.undelivered: {e}"))
        .with_data(json!({"reason": "bridge.undelivered"}))
}

fn answer(prompt_id: &str, outcome: Outcome, app: Option<&Value>) -> Result<Value, RpcError> {
    match outcome {
        Some(Err(e)) => Err(undelivered(&e)),
        Some(Ok(turn_id)) => Ok(reply(prompt_id, Some(&turn_id), app)),
        None => Ok(reply(prompt_id, None, app)),
    }
}

/// A resend's answer: accepted as a duplicate, then the first delivery's turn.
async fn resent(
    session: &Session,
    prompt_id: &str,
    rx: watch::Receiver<Outcome>,
    opts: &mut PromptOptions,
) -> Result<Value, RpcError> {
    if let Some(f) = opts.on_accepted.take() {
        f(json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true}));
    }
    let mut answer = answer(prompt_id, turn_of(rx).await, None);
    let meta = answer.as_mut().ok().and_then(|v| v.pointer_mut("/_meta/acpmux"));
    if let Some(meta) = meta.and_then(Value::as_object_mut) {
        meta.insert("duplicate".to_owned(), json!(true));
    }
    answer
}

/// `app`: what the delivery says of the app ([`Target::details`]); a resend's names none.
fn reply(prompt_id: &str, turn_id: Option<&str>, app: Option<&Value>) -> Value {
    let bridged = app.cloned();
    json!({
        "stopReason": "end_turn",
        "_meta": {"acpmux": {
            "promptId": prompt_id,
            "turnId": turn_id,
            "answered": turn_id.is_some(),
            "bridged": bridged.unwrap_or(json!(true)),
        }},
    })
}

#[cfg(test)]
#[path = "bridge_tests.rs"]
mod tests;
