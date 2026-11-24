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
//! A chat handed to a cmux terminal (`release_to_watch.rs`, `acpmux resume-here`) is bridged by
//! that terminal, whatever `agents.desktopBridge.enabled` says, while Write to a chat a terminal
//! runs (`agents.chats.terminalChatWritable`, off by default) is on (Leo, 2026-11-14: "this is
//! obviously what we need", on the chat writable in both directions while the terminal drives the
//! session; 2026-11-15: "these are opt-in settings"). Off, that chat is a View Only watch. The daemon
//! recorded the terminal's process (`Watching::terminal`: `resume-here` becomes the harness, same
//! pid); a prompt goes to the Claude Code session registered under that pid for this conversation
//! (its inbox, opened with the peer key), or to the Codex thread a running Codex holds (its
//! queue). The harness takes it as its terminal takes a typed prompt: mid-turn it waits for the
//! turn's end. A harness with no inbox (Claude Code's cross-session messaging off) refuses the
//! send with `bridge.no_inbox`, never as View Only; once the terminal's process is gone the chat
//! is a watch as any other.
//!
//! A chat whose app no longer runs it falls through to the refusal: Take Over runs it here. A
//! chat its session registered by name (`acpmux register`, `register.rs`) is that name's address
//! instead: while its app is not running it, a prompt is refused as `bridge.not_running`, which
//! the outbox tries again (`acpmux send --no-wait` keeps it queued, `--status` says so) until the
//! session runs again and registers, or the outbox's day runs out. A conversation that runs, but
//! not in the process that registered (Claude Code restarted: its new token is in its own shell
//! only), is refused as `bridge.registration_stale`, and one two live processes claim as
//! `bridge.registration_contested`: both retried the same way, both naming what ends them, and
//! the chat's row says it too (`bridge.unreachable`, STUCK in `acpmux ls`) until a delivery goes or
//! the session registers again. acpmux never binds the new process itself: the registration's
//! proof is the session echoing a code delivered with its own token (`register.rs`), and the
//! daemon has no token of the new process to deliver one with.
//! Deliveries are kept in memory (the newest 256 answered ones too, so a resend is not delivered
//! again). After a daemon restart, a delivered line the watch had not shown yet shows only its
//! answer, as any other session's peer message does. A prompt id is delivered at most once per
//! session for good: the session's log records each delivery (`bridge_delivered`), and a resend of
//! a recorded id the memory no longer holds (a restart, or past the kept 256) is answered as a
//! duplicate without reaching the app. A peer's outbox resends an open delivery on every link
//! (`open_delivery.rs`), so without this each restart put the same message in the app again.

use super::{Hub, PromptOptions, Session};

/// A bridged chat the account's rate limit stopped holds what is sent to it until the reset.
#[path = "bridge_hold.rs"]
pub(super) mod hold;
use crate::claude_peers::Unreached;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
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
    /// What the chat shows as the prompt: the person's words, without a context block.
    pub(super) text: String,
    /// The text as the app got it (context blocks and the reply hint too): what a Codex rollout
    /// line shows.
    wire: String,
    /// The watch showed its line (known by its text, which another line may repeat).
    shown: bool,
    /// Typed into the terminal (`terminal_input.rs`): its line is the person's, known by its text.
    typed: bool,
    order: u64,
    turn: watch::Sender<Outcome>,
    /// The prompts a rate-limit hold folded into this delivery (`bridge_hold.rs`): each one's
    /// kept delivery answers with this one's turn.
    riders: Vec<String>,
}

#[derive(Default)]
struct Deliveries {
    by_uuid: HashMap<String, Pending>,
    next: u64,
}

static PENDING: LazyLock<Mutex<Deliveries>> = LazyLock::new(Default::default);

/// Prompt ids recorded in each session's journal as delivered (`bridge_delivered`). The
/// in-memory registry above handles live resends; this set closes the restart/eviction gap.
static DELIVERED: LazyLock<Mutex<HashMap<String, HashSet<String>>>> =
    LazyLock::new(Default::default);

fn delivered_ids() -> std::sync::MutexGuard<'static, HashMap<String, HashSet<String>>> {
    DELIVERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

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
        typed: bool,
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
            typed,
            order: self.next,
            turn,
            riders: Vec::new(),
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

/// What the watch took from the delivery registry while it read one batch: given back
/// (`unclaim`) when the journal refused the batch, so the batch read again finds the same
/// deliveries unshown and shows them, never skipping a prompt.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Claim {
    /// The delivery with this uuid was shown.
    Shown(String),
}

/// Gives back what a refused batch claimed (`Claim`).
pub(super) fn unclaim(claims: &[Claim]) {
    let mut all = deliveries();
    for Claim::Shown(uuid) in claims {
        if let Some(p) = all.by_uuid.get_mut(uuid) {
            p.shown = false;
        }
    }
}

/// A delivery the watch shows now: (uuid, prompt id, text as sent).
pub(super) type ShownDelivery = (String, String, String);

fn show(uuid: &str, p: &mut Pending) -> ShownDelivery {
    p.shown = true;
    (uuid.to_owned(), p.prompt_id.clone(), p.text.clone())
}

/// The delivery a transcript line with `uuid` in `session_id` shows, if acpmux sent it and the
/// watch has not shown it yet, marked shown: Claude Code may write it twice (the attachment that
/// takes it into a running turn, then its line), and it shows once.
pub(super) fn delivered(session_id: &str, uuid: &str) -> Option<ShownDelivery> {
    let mut all = deliveries();
    let p = all
        .by_uuid
        .get_mut(uuid)
        .filter(|p| p.session_id == session_id && !p.shown && p.turn.borrow().is_none())?;
    Some(show(uuid, p))
}

/// The oldest unanswered delivery into `session_id` whose text as the app got it is exactly
/// `text`, among those `pick` admits.
fn oldest_with<'a>(
    all: &'a mut Deliveries,
    session_id: &str,
    text: &str,
    pick: impl Fn(&Pending) -> bool,
) -> Option<(&'a String, &'a mut Pending)> {
    let text = text.trim();
    all.by_uuid
        .iter_mut()
        .filter(|(_, p)| {
            p.session_id == session_id
                && p.turn.borrow().is_none()
                && !p.wire.trim().is_empty()
                && p.wire.trim() == text
                && pick(p)
        })
        .min_by_key(|(_, p)| p.order)
}

/// Whether a queue line with `text` may be a delivery's: an unanswered, unshown delivery into
/// `session_id` has exactly that text. Claude Code's `enqueue` line carries the text alone, so such
/// a line is told from a prompt typed in the terminal with the same text only when it runs (its
/// attachment's `source_uuid` and origin, or its line's uuid): it shows then, never at once, so
/// neither is lost nor shown twice. A prompt that only contains a delivery's text is not one.
pub(super) fn may_be_delivery(session_id: &str, text: &str) -> bool {
    let mut all = deliveries();
    oldest_with(&mut all, session_id, text, |p| !p.shown).is_some()
}

/// The delivery a running turn took in by its text when its attachment names no uuid acpmux sent
/// but says it did not come from the person (`origin.kind` other than `human`): the oldest unshown
/// delivery with exactly that text, marked shown.
pub(super) fn delivered_queued(session_id: &str, text: &str) -> Option<ShownDelivery> {
    let mut all = deliveries();
    let (uuid, p) = oldest_with(&mut all, session_id, text, |p| !p.shown)?;
    let uuid = uuid.clone();
    Some(show(&uuid, p))
}

/// The app took a queued prompt with `text` back (edited or cancelled in the terminal) that was a
/// delivery's: the oldest unshown one with exactly that text ends with why, so its sender hears at
/// once instead of waiting for a turn that never comes. True when one did.
pub(super) fn taken_back(session_id: &str, text: &str) -> bool {
    let mut all = deliveries();
    let Some((_, p)) = oldest_with(&mut all, session_id, text, |p| !p.shown) else { return false };
    p.shown = true;
    p.turn.send_replace(Some(Err("taken back in the terminal before it ran".to_owned())));
    true
}

/// The delivery a Codex rollout's prompt `text` in `session_id` shows: the oldest one acpmux
/// sent with that text the watch has not shown yet, marked shown.
pub(super) fn delivered_text(session_id: &str, text: &str) -> Option<ShownDelivery> {
    let mut all = deliveries();
    let (uuid, p) = oldest_with(&mut all, session_id, text, |p| !p.shown)?;
    let uuid = uuid.clone();
    Some(show(&uuid, p))
}

/// The delivery a prompt line the person's terminal wrote shows, when acpmux typed it there
/// (`terminal_input.rs`, a harness with no inbox): the oldest unshown typed delivery with exactly
/// that text, marked shown. Only a typed one: an inbox delivery's line names its uuid.
pub(super) fn delivered_typed(session_id: &str, text: &str) -> Option<ShownDelivery> {
    let mut all = deliveries();
    let (uuid, p) = oldest_with(&mut all, session_id, text, |p| !p.shown && p.typed)?;
    let uuid = uuid.clone();
    Some(show(&uuid, p))
}

/// The turn outcome of delivery `prompt_id`, for tests.
#[cfg(test)]
pub(super) fn delivery_turn(session_id: &str, prompt_id: &str) -> Option<watch::Receiver<Outcome>> {
    deliveries().of_prompt(session_id, prompt_id).map(|(_, p)| p.turn.subscribe())
}

/// A delivery for tests that drive the watch alone: `uuid` into `session_id` as `prompt_id`.
#[cfg(test)]
pub(super) fn test_delivery(session_id: &str, prompt_id: &str, uuid: &str, text: &str) {
    let _ = deliveries().claim(uuid.to_owned(), session_id, prompt_id, text, text, false);
}

/// Delivery `uuid` will never reach its app (`why`): its call and any resend answer so.
pub(super) fn fail_delivery(uuid: &str, why: &str) {
    if let Some(p) = deliveries().by_uuid.remove(uuid) {
        p.turn.send_replace(Some(Err(why.to_owned())));
    }
}

/// [`fail_delivery`], answering the prompt id of the delivery that failed (none when it was gone).
pub(super) fn fail_delivery_of(uuid: &str, why: &str) -> Option<String> {
    let p = deliveries().by_uuid.remove(uuid)?;
    p.turn.send_replace(Some(Err(why.to_owned())));
    Some(p.prompt_id)
}

/// The watch ended the turn of `prompt_id`: its call (and any resend's) answers with `turn_id`.
pub(super) fn answered(session_id: &str, prompt_id: &str, turn_id: &str) {
    let all = deliveries();
    let Some((_, p)) = all.of_prompt(session_id, prompt_id) else { return };
    p.turn.send_replace(Some(Ok(turn_id.to_owned())));
    // The prompts a rate-limit hold folded into this one went in the same turn.
    for rider in &p.riders {
        if let Some((_, r)) = all.of_prompt(session_id, rider) {
            r.turn.send_replace(Some(Ok(turn_id.to_owned())));
        }
    }
}

/// The outcome `rx` gets, once the watch shows its turn or its delivery fails, within [`ANSWER_WAIT`].
async fn turn_of(mut rx: watch::Receiver<Outcome>) -> Outcome {
    let wait = rx.wait_for(Option::is_some);
    tokio::time::timeout(ANSWER_WAIT, wait).await.ok()?.ok()?.clone()
}

/// A prompt as the app takes it: its text (text blocks, and each file as a mention or its
/// contents) and its images (media type, base64), as a chat send carries them.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Content {
    pub(super) text: String,
    pub(super) images: Vec<(String, String)>,
}

/// The prompt `blocks` as the app takes them, or why one cannot reach it.
/// - text: as typed;
/// - a file (`resource_link`): `@path` for a local file, the harness's own mention, else a link;
/// - a file's contents (`resource` with text): a `<context ref>` block, as an ACP adapter sends it;
/// - an image, or a resource holding one: an image.
pub(super) fn content_of(blocks: &[Value]) -> Result<Content, String> {
    let mut texts = Vec::new();
    let mut images = Vec::new();
    let s = |b: &Value, k: &str| b.get(k).and_then(Value::as_str).map(str::to_owned);
    for b in blocks {
        match b.get("type").and_then(Value::as_str) {
            Some("text") => texts.extend(s(b, "text")),
            Some("image") => match (s(b, "mimeType"), s(b, "data")) {
                (Some(mime), Some(data)) => images.push((mime, data)),
                _ => return Err("an image without its data".to_owned()),
            },
            Some("resource_link") => {
                let uri = s(b, "uri").ok_or("a file without its address")?;
                let name = s(b, "name").unwrap_or_else(|| uri.clone());
                texts.push(match uri.strip_prefix("file://") {
                    Some(path) => format!("@{path}"),
                    None => format!("[{name}]({uri})"),
                });
            }
            Some("resource") => {
                let r = b.get("resource").ok_or("a file without its contents")?;
                let uri = s(r, "uri").unwrap_or_default();
                match (s(r, "text"), s(r, "blob"), s(r, "mimeType")) {
                    (Some(text), _, _) => {
                        texts.push(format!("<context ref=\"{uri}\">\n{text}\n</context>"));
                    }
                    (None, Some(blob), Some(mime)) if mime.starts_with("image/") => {
                        images.push((mime, blob));
                    }
                    _ => {
                        return Err(format!(
                            "{uri} is neither text nor an image, so the app cannot read it"
                        ));
                    }
                }
            }
            other => {
                return Err(format!("a {} block", other.unwrap_or("untyped")));
            }
        }
    }
    let text = texts.join("\n\n");
    if text.trim().is_empty() && images.is_empty() {
        return Err("an empty prompt".to_owned());
    }
    Ok(Content { text, images })
}

/// What the chat shows of a prompt: its content as the app takes it ([`content_of`]) but the
/// context blocks (`prompt_context::is_context`, a note for the agent such as the `@` tools' or the
/// workspace one), which the app still gets. A transcript never shows a context.
fn visible_text(blocks: &[Value]) -> Option<String> {
    let shown: Vec<Value> =
        blocks.iter().filter(|b| !crate::prompt_context::is_context(b)).cloned().collect();
    content_of(&shown).ok().map(|content| content.text)
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

    /// Delivers `wire` and `images` as message `uuid` from `sender`.
    async fn deliver(
        &self,
        wire: &str,
        images: &[(String, String)],
        uuid: &str,
        sender: &str,
    ) -> Result<(), String> {
        match self {
            Target::Claude { config, peer, token } => {
                let from = crate::claude_peers::from_address(sender);
                let content = claude_content(wire, images);
                crate::claude_peers::deliver(config, peer, content, uuid, &from, token.as_deref())
                    .await
            }
            Target::Codex { home, thread } => {
                crate::codex_desktop::deliver(home, &thread.id, wire, images, uuid).await.map(drop)
            }
        }
    }
}

/// A Claude Code inbox message's content: the text alone, or with images its content blocks
/// (stream-json's `image` block, base64).
pub(super) fn claude_content(wire: &str, images: &[(String, String)]) -> Value {
    if images.is_empty() {
        return json!(wire);
    }
    let text = (!wire.is_empty()).then(|| json!({"type": "text", "text": wire}));
    let images = images.iter().map(|(mime, data)| {
        json!({"type": "image", "source": {"type": "base64", "media_type": mime, "data": data}})
    });
    Value::Array(text.into_iter().chain(images).collect())
}

impl Hub {
    /// Where a watched chat the bridge listed goes (`desktop_bridge.rs`, `register.rs`): the app's
    /// session, when the setting or the session's own registration lets it through.
    async fn listed_target(
        &self,
        session: &Session,
        family: String,
        agent_session_id: String,
        registered: bool,
    ) -> Result<Target, Option<Unreached>> {
        let homes = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let acpmux_home = crate::config::home();
        let chat_id = session.id.clone();
        tokio::task::spawn_blocking(move || -> Result<Target, Option<Unreached>> {
            // A chat its session registered is bridged whatever the setting says: the session
            // asked for it from its own shell (`register.rs`).
            if !registered && !crate::claude_peers::enabled() {
                return Err(None);
            }
            // A chat nobody registered: the app's own record must name an entrypoint (Claude
            // Code) or originator (Codex) the setting lists, since a tag alone is anyone's to
            // set. A registered chat never goes by an entrypoint (anyone's to write): only by the
            // process its registration recorded, below.
            let listed = crate::claude_peers::listed_entrypoints();
            if family == "codex" {
                // Only Claude Code sessions register (`register.rs`).
                if registered {
                    return Err(None);
                }
                let thread = crate::codex_desktop::find(&homes.codex, &agent_session_id, &listed)
                    .ok_or(None)?;
                return Ok(Target::Codex { home: homes.codex, thread });
            }
            let by_setting = |p: &crate::claude_peers::Peer| {
                crate::claude_peers::enabled()
                    && p.entrypoint.as_ref().is_some_and(|e| listed.contains(e))
            };
            if registered {
                // A registered chat opens only with the token its session handed over, into the
                // process that registration recorded (pid, inbox, start), while it is its
                // conversation's only live claimant. A restarted session's new process has none
                // until it registers again, so the send waits (`bridge.registration_stale`), never
                // opening with the undocumented peer key, with the bridge setting on or off.
                let live = crate::claude_peers::live(&homes.claude);
                let found =
                    live.iter().filter(|p| p.session_id == agent_session_id).find_map(|p| {
                        let started = crate::claude_peers::started_at(&homes.claude, p.pid);
                        let token =
                            crate::claude_peers::token_for(&acpmux_home, &chat_id, p, started)?;
                        crate::claude_peers::sole_claimant(p, &live).then(|| (p.clone(), token))
                    });
                let Some((peer, token)) = found else {
                    return Err(Some(crate::claude_peers::unreached(&agent_session_id, &live)));
                };
                return Ok(Target::Claude { config: homes.claude, peer, token: Some(token) });
            }
            let peer = crate::claude_peers::find(&homes.claude, &agent_session_id)
                .filter(by_setting)
                .ok_or(None)?;
            let token = None;
            Ok(Target::Claude { config: homes.claude, peer, token })
        })
        .await
        .unwrap_or(Err(None))
    }

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
        // A chat handed to a cmux terminal (`release_to_watch.rs`) goes into that terminal's
        // harness, bound by its process: the daemon's own record, never a tag.
        // Only while Write to a chat a terminal runs is on (`release_to_watch.rs`); off, the
        // binding is let go of, and a chat that still had one is read-only meanwhile.
        let terminal = watching.terminal.clone().filter(|_| self.terminal_chat_writable());
        // The terminal's harness asks its permissions in that terminal, under the person's own
        // settings there, not through acpmux: the remote floor (the asking-mode table, D13) cannot
        // hold, so a paired device (Web control) never sends into it. The Mac and the terminal do.
        if terminal.is_some() && opts.control == crate::hub::Control::Web {
            return Some(Err(terminal_remote_refused(&family)));
        }
        // Only a chat the bridge listed (`desktop_bridge.rs`) takes prompts; any other watched
        // chat stays read-only, whatever runs its conversation.
        if terminal.is_none() && session.meta().tags.get("bridge").is_none_or(|t| t.value != family)
        {
            return None;
        }
        let registered = terminal.is_none() && super::register::is_registered(session);
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
            // The live registry is bounded and is lost on restart. The journal is durable, so a
            // prompt id recorded there is still a duplicate and must never reach the harness.
            if self.delivered_before(session, &id).await {
                if let Some(f) = opts.on_accepted.take() {
                    f(json!({"sessionId": session.id, "promptId": id, "duplicate": true}));
                }
                let mut reply = reply(&id, None, None);
                if let Some(meta) =
                    reply.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
                {
                    meta.insert("duplicate".to_owned(), json!(true));
                }
                return Some(Ok(reply));
            }
        }
        // Attachments reach a terminal's harness only (Write to a chat a terminal runs); a chat the
        // desktop bridge listed takes text alone, as before.
        let to_terminal = terminal.is_some();
        let target = match terminal {
            Some(driver) => match terminal_target(&family, &agent_session_id, driver.clone()).await
            {
                TerminalTarget::Ready(target) => Some(Route::Inbox(target)),
                // The terminal's harness ended: a watch as any other (Take Over runs it here).
                TerminalTarget::Gone => {
                    self.terminal_ended(session, &driver).await;
                    None
                }
                // Typed into its cmux terminal instead (`terminal_input.rs`): Claude Code reads
                // a paste and Return as the person's own prompt.
                TerminalTarget::NoInbox(_) if family == "claude" && driver.input.is_some() => {
                    Some(Route::Typed(driver))
                }
                TerminalTarget::NoInbox(why) => return Some(Err(no_inbox(&why))),
            },
            None => {
                let found = self
                    .listed_target(session, family.clone(), agent_session_id.clone(), registered)
                    .await;
                if registered {
                    self.note_unreached(session, found.as_ref().err().and_then(Option::as_ref));
                }
                match found {
                    Ok(target) => Some(Route::Inbox(target)),
                    Err(why) => {
                        // A registered name keeps its address while its app does not reach it: a
                        // send the outbox carries (here, or a peer's forwarded) waits and is tried
                        // again, instead of failing as a read-only chat's would, and says why. A
                        // person's own prompt still gets the read-only refusal, with Take Over.
                        let name = session.read_meta(|m| m.name.clone());
                        return (registered && retried_client(client))
                            .then(|| Err(unreached_error(&name, why.as_ref())));
                    }
                }
            }
        };
        let Some(target) = target else {
            // A registered name keeps its address while its app is closed: a send the outbox
            // carries (here, or a peer's forwarded) waits and is tried again, instead of failing
            // as a read-only chat's would. A person's own prompt still gets the read-only
            // refusal, with Take Over.
            return (registered && retried_client(client))
                .then(|| Err(not_running(&session.meta().name)));
        };
        let text_only =
            blocks.iter().all(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                && blocks.iter().any(|b| {
                    b.get("text").and_then(Value::as_str).is_some_and(|t| !t.trim().is_empty())
                });
        if !to_terminal && !text_only {
            return Some(Err(RpcError::invalid_params(
                "only text reaches a session another app runs: send it without attachments, or take the chat over",
            )));
        }
        let content = match content_of(blocks) {
            Ok(content) => content,
            Err(why) => {
                return Some(Err(RpcError::invalid_params(format!(
                    "{why} cannot reach a session another app runs: send it without it, or take the chat over"
                ))));
            }
        };
        if matches!(target, Route::Typed(_)) && !content.images.is_empty() {
            return Some(Err(no_inbox(
                "an image reaches the terminal's Claude Code only through its inbox (its cross-session messaging is off); paste it in the terminal",
            )));
        }
        // The app reads every block (`delivery`), the chat's transcript (`delivered`,
        // `user_message`) only the person's own (`text`).
        let delivery = content.text.clone();
        let text = visible_text(blocks).unwrap_or_else(|| delivery.clone());
        let prompt_id = opts.prompt_id.clone().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let uuid = uuid::Uuid::now_v7().to_string();
        // The chat shows the prompt as sent (`delivered`); the app also reads how to answer.
        let harness = sender_harness(opts);
        let unverified =
            opts.provenance.as_ref().and_then(|p| p.get("kind")).and_then(Value::as_str)
                == Some("unverified");
        let claude = matches!(target, Route::Inbox(Target::Claude { .. }));
        let name = reply_name(opts);
        let routable = name.as_deref().is_some_and(|n| self.reply_routable(n));
        // A program's claimed name is all it has: no given name beside it.
        let given = crate::prompt_provenance::display_name_of(opts.provenance.as_ref())
            .filter(|_| !unverified)
            .map(str::to_owned);
        let wire = with_reply_hint(
            &delivery,
            name.as_deref(),
            given.as_deref(),
            harness.as_deref(),
            unverified,
            claude,
            routable,
        );
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
        let sender = opts.agent.clone().unwrap_or_else(|| "person".to_owned());
        // The app's last turn stopped on the account's rate limit: kept until the reset, then
        // sent with the others the hold kept as one message (`bridge_hold.rs`). The hold resumes
        // through the inbox, so a prompt typed into a terminal with none is never parked.
        let parked = match target {
            Route::Inbox(_) => hold::park(&session.id, &prompt_id, &text, &wire, &sender),
            Route::Typed(_) => None,
        };
        match parked {
            Some(Ok((rx, until))) => {
                if let Some(f) = opts.on_accepted.take() {
                    f(
                        json!({"sessionId": session.id, "promptId": prompt_id, "queued": true, "state": "held", "bridged": true, "rateLimitedUntil": until}),
                    );
                }
                return Some(hold::held_answer(&session.id, &prompt_id, rx, until).await);
            }
            Some(Err(rx)) => return Some(resent(session, &prompt_id, rx, opts).await),
            None => {}
        }
        // Claimed under one lock: two sends of one id never both go.
        let typed = matches!(target, Route::Typed(_));
        let claimed =
            deliveries().claim(uuid.clone(), &session.id, &prompt_id, &text, &wire, typed);
        let rx = match claimed {
            Ok(rx) => rx,
            Err(rx) => return Some(resent(session, &prompt_id, rx, opts).await),
        };
        let target = match target {
            Route::Inbox(target) => target,
            Route::Typed(driver) => {
                let typed = self.type_into(session, &driver, &agent_session_id, &uuid, &wire).await;
                if let Err(e) = typed {
                    let gone = deliveries().by_uuid.remove(&uuid);
                    if let Some(p) = gone {
                        p.turn.send_replace(Some(Err(e.clone())));
                    }
                    return Some(Err(undelivered(&e)));
                }
                let details = json!({"pid": driver.pid, "typed": true});
                let mut record = json!({"promptId": prompt_id, "uuid": uuid});
                if let (Some(record), Some(more)) = (record.as_object_mut(), details.as_object()) {
                    record.extend(more.clone());
                }
                self.append(session, "mux", "bridge_delivered", record);
                if let Some(ids) = delivered_ids().get_mut(&session.id) {
                    ids.insert(prompt_id.clone());
                }
                if let Some(f) = opts.on_accepted.take() {
                    f(
                        json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "state": "delivered", "bridged": true}),
                    );
                }
                return Some(answer(&prompt_id, turn_of(rx).await, Some(&details)));
            }
        };
        if let Err(e) = target.deliver(&wire, &content.images, &uuid, &sender).await {
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
        // Added only to a set the log was already read into: a set made here would hide the log's
        // earlier deliveries from `delivered_before`.
        if let Some(ids) = delivered_ids().get_mut(&session.id) {
            ids.insert(prompt_id.clone());
        }
        if let Some(f) = opts.on_accepted.take() {
            f(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "state": "delivered", "bridged": true}),
            );
        }
        Some(answer(&prompt_id, turn_of(rx).await, Some(&details)))
    }

    /// Whether `acpmux send NAME` can deliver to `name`, so a reply hint may name it: a
    /// qualified `HOST/NAME` (as relays and peers stamp a session) goes to that host; a bare
    /// name only when it names a session here or on a peer now (in memory, no network). A
    /// program's label (`merge-audit`) or a relay's bare machine name (`lane-vm-2`)
    /// names none, and `acpmux send` to it fails with `no_session`.
    pub(super) fn reply_routable(&self, name: &str) -> bool {
        let name = name.trim();
        if let Some((host, rest)) = name.split_once('/') {
            return !host.is_empty() && !rest.is_empty();
        }
        !name.is_empty() && (self.resolve(name).is_ok() || self.resolve_remote(name).is_some())
    }

    /// Where a prompt to bridged chat `session` goes now: its app's inbox or thread, while that
    /// app runs the conversation (and, for a registered chat, the process its registration
    /// recorded); otherwise why not, when a registered chat's conversation runs where its
    /// registration does not reach ([`Unreached`]), else `None`.
    async fn bridge_target(
        self: &Arc<Self>,
        session: &Session,
    ) -> Result<Target, Option<Unreached>> {
        let watching = session.meta().watching.ok_or(None)?;
        let agent_session_id = session.meta().agent_session_id.ok_or(None)?;
        // A chat handed to a cmux terminal goes into that terminal's harness while Write to a
        // chat a terminal runs is on (`bridged_prompt`).
        if let Some(driver) = watching.terminal.clone().filter(|_| self.terminal_chat_writable()) {
            return match terminal_target(&watching.family, &agent_session_id, driver).await {
                TerminalTarget::Ready(target) => Ok(target),
                TerminalTarget::Gone | TerminalTarget::NoInbox(_) => Err(None),
            };
        }
        let registered = super::register::is_registered(session);
        self.listed_target(session, watching.family, agent_session_id, registered).await
    }

    /// Whether `session`'s log records `prompt_id` as delivered. The first ask of a session reads
    /// its log's `bridge_delivered` records (headers only, off the async threads); later ones
    /// read the set that read made.
    async fn delivered_before(self: &Arc<Self>, session: &Session, prompt_id: &str) -> bool {
        if let Some(ids) = delivered_ids().get(&session.id) {
            return ids.contains(prompt_id);
        }
        let hub = Arc::clone(self);
        let id = session.id.clone();
        let read = tokio::task::spawn_blocking(move || {
            let mut ids = HashSet::new();
            let scanned = hub.store.scan_heads(&id, &mut |head| {
                if head.dir == "mux" && head.kind == "bridge_delivered" {
                    let rec = head.record();
                    let prompt = rec.as_ref().and_then(|r| r.msg.get("promptId")?.as_str());
                    if let Some(prompt) = prompt {
                        ids.insert(prompt.to_owned());
                    }
                }
                true
            });
            scanned.ok().map(|()| ids)
        })
        .await
        .ok()
        .flatten();
        let Some(ids) = read else { return false };
        let mut all = delivered_ids();
        let known = all.entry(session.id.clone()).or_default();
        known.extend(ids);
        known.contains(prompt_id)
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
///
/// Claude Code (`claude`) puts its own text around every message that reaches it this way:
/// "Another Claude session sent a message:" before it, and after it a paragraph saying a peer is
/// not the user and cannot grant permissions. Nothing turns those off, and its terminal shows
/// them on every message. So a Claude Code session gets the sender and how to answer as one line
/// and nothing after the text (Leo, 2026-11-14, ask-c810e83a38: "it sends so much s*** each
/// time. can it not?"). The line keeps "not the person": a sender's name may be only what it
/// claimed, and Claude Code's note calls a peer "very likely working on their behalf".
///
/// The answer command is printed only for a sender `acpmux send` can deliver to (`routable`,
/// `Hub::reply_routable`). Another (a program's label, a relay's bare machine name) gets no
/// command, since it would fail with `no_session`, but says nothing reads a reply (Leo,
/// 2026-11-21: "it's our product bug or smth those need to get fixed").
fn with_reply_hint(
    text: &str,
    agent: Option<&str>,
    given: Option<&str>,
    harness: Option<&str>,
    unverified: bool,
    claude: bool,
    routable: bool,
) -> String {
    let Some(agent) = agent.map(str::trim).filter(|a| !a.is_empty()) else {
        return text.to_owned();
    };
    let quoted = agent.replace('\'', "'\\''");
    let provenance = harness.map(|h| json!({crate::prompt_provenance::FROM_HARNESS: h}));
    // Named as people call it, its HOST/NAME (what a reply goes to) beside it.
    let label = crate::prompt_provenance::display_label(given, agent);
    let who = super::prompt_attribution::with_harness(&label, provenance.as_ref());
    let line = if unverified {
        super::prompt_attribution::unverified_line(Some(&who))
    } else {
        super::prompt_attribution::agent_line(&who)
    };
    if !routable {
        let no_inbox = format!(
            "{agent} has no inbox acpmux can deliver to, so nothing reads a reply: act on it yourself, or tell whoever coordinates you"
        );
        if claude {
            let line = line.trim_end_matches(':');
            return format!("{line}. {no_inbox}:\n{text}");
        }
        return format!("{line}\n{text}\n\n[{no_inbox}.]");
    }
    if claude {
        let line = line.trim_end_matches(':');
        return format!(
            "{line}. Answer with `acpmux send '{quoted}' '<your reply>'`, not SendMessage:\n{text}"
        );
    }
    format!(
        "{line}\n{text}\n\n[Answer {agent} with `acpmux send '{quoted}' '<your reply>'` in your shell; your own messaging tools cannot reach it.]"
    )
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

/// The tag that says, on a registered chat's row, why its daemon cannot reach it
/// (`registration stale: ...`, `registration contested: ...`); `acpmux ls` shows the part before
/// the colon in STUCK. Set and cleared by the daemon at each delivery attempt and registration.
pub(crate) const UNREACHABLE_TAG: &str = "bridge.unreachable";

/// What the row and the refusal say of `why` for the chat named `name`; None for a closed app,
/// which needs nothing from anyone.
fn unreached_text(name: &str, why: &Unreached) -> Option<(&'static str, String)> {
    match why {
        Unreached::NotRunning => None,
        Unreached::Restarted { pid } => Some((
            "bridge.registration_stale",
            format!(
                "registration stale: Claude Code restarted (now process {pid}), and the new process handed acpmux no token; run `acpmux register {name}` in that chat"
            ),
        )),
        Unreached::Contested { pids } => {
            let pids = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(", ");
            Some((
                "bridge.registration_contested",
                format!(
                    "registration contested: live processes {pids} all claim the conversation, so acpmux delivers to none; close all but one, then run `acpmux register {name}` in it"
                ),
            ))
        }
    }
}

/// A registered chat's delivery found no process to take it: retried by the outbox
/// (`server/outbox.rs` `next`), saying why.
fn unreached_error(name: &str, why: Option<&Unreached>) -> RpcError {
    let Some((reason, text)) = why.and_then(|w| unreached_text(name, w)) else {
        return not_running(name);
    };
    RpcError::new(
        -32000,
        format!("{reason}: {name} is unreachable, {text}; the message waits and is tried again"),
    )
    .with_data(json!({"reason": reason, "retryable": true}))
}

impl Hub {
    /// Whether registered chat `session`'s row says it is unreachable ([`UNREACHABLE_TAG`]:
    /// registration stale or contested) until it registers again. The mesh relay parks a message
    /// to it on this (`server/mesh_relay_park.rs`).
    pub(crate) fn bridge_unreached(&self, session: &Session) -> bool {
        session.read_meta(|m| m.tags.contains_key(UNREACHABLE_TAG))
    }

    /// Puts why registered chat `session` is unreachable on its row ([`UNREACHABLE_TAG`]), or
    /// takes it off when it is reachable or merely closed. Written only on a change: the outbox
    /// asks again on every retry.
    fn note_unreached(&self, session: &Session, why: Option<&Unreached>) {
        let (name, current) = session
            .read_meta(|m| (m.name.clone(), m.tags.get(UNREACHABLE_TAG).map(|t| t.value.clone())));
        let text = why.and_then(|w| unreached_text(&name, w)).map(|(_, text)| text);
        if text == current {
            return;
        }
        match text {
            Some(text) => {
                let mut set = serde_json::Map::new();
                set.insert(UNREACHABLE_TAG.to_owned(), json!(text));
                self.set_tags(session, Some(&set), &[], None);
            }
            None => self.set_tags(session, None, &[UNREACHABLE_TAG.to_owned()], None),
        }
    }
}

/// A paired device's prompt to a chat a cmux terminal drives (`remote.terminal_session`).
fn terminal_remote_refused(family: &str) -> RpcError {
    RpcError::new(
        -32000,
        "This chat's agent runs in a terminal on the Mac and asks for permission there: send from the Mac, or type it in that terminal.",
    )
    .with_data(json!({"reason": "remote.terminal_session", "harness": family}))
}

/// A chat's terminal runs its harness, which takes no message from acpmux now (`why`): the
/// person types it in the terminal. Never View Only: the next send tries again.
fn no_inbox(why: &str) -> RpcError {
    RpcError::new(-32000, format!("bridge.no_inbox: {why}; type it in the terminal for now"))
        .with_data(json!({"reason": "bridge.no_inbox", "retryable": true}))
}

/// How a bridged prompt reaches its app: its inbox or queue, or typed into its cmux terminal.
enum Route {
    Inbox(Target),
    Typed(crate::store::TerminalDriver),
}

/// Where a terminal-driven chat's prompt goes ([`terminal_target`]).
enum TerminalTarget {
    Ready(Target),
    /// The terminal's process ended (or another took its pid).
    Gone,
    /// It runs, but takes nothing from acpmux now: why.
    NoInbox(String),
}

/// How long a send waits for the terminal's Claude Code to register its session after
/// `acpmux resume-here` started it (it registers within a second or two of its start).
// timeout: a terminal Claude Code registers within a second or two of its start; past 10 s the send answers bridge.no_inbox, which the person can retry.
const REGISTER_WAIT: Duration = Duration::from_secs(10);

/// The harness the terminal `driver` runs, by its process: the Claude Code session registered
/// under that very pid (`resume-here` became it, `exec`) for this conversation, the only one that
/// claims it, with an inbox (Claude Code's cross-session messaging); or the Codex thread a running
/// Codex holds, whose queue (`thread/queue/add`) the terminal's Codex reads. A send right after the
/// hand-off waits up to [`REGISTER_WAIT`] for the Claude Code session to register.
async fn terminal_target(
    family: &str,
    agent_session_id: &str,
    driver: crate::store::TerminalDriver,
) -> TerminalTarget {
    let deadline = tokio::time::Instant::now() + REGISTER_WAIT;
    loop {
        let (fam, sid, d) = (family.to_owned(), agent_session_id.to_owned(), driver.clone());
        let found = tokio::task::spawn_blocking(move || terminal_target_now(&fam, &sid, &d))
            .await
            .unwrap_or(TerminalTarget::Gone);
        match found {
            TerminalTarget::NoInbox(why)
                if why == NOT_REGISTERED && tokio::time::Instant::now() < deadline =>
            {
                // poll: the registry has no event to wait on; bounded by REGISTER_WAIT, only
                // between a hand-off and its harness's start.
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            other => return other,
        }
    }
}

const NOT_REGISTERED: &str =
    "Claude Code in this chat's terminal has not opened the conversation (yet)";

fn terminal_target_now(
    family: &str,
    agent_session_id: &str,
    d: &crate::store::TerminalDriver,
) -> TerminalTarget {
    if !crate::adopt_live::registered_runs(d.pid, d.started) {
        return TerminalTarget::Gone;
    }
    if family == "codex" {
        return match crate::codex_desktop::find_held(&d.store, agent_session_id) {
            Some(thread) => TerminalTarget::Ready(Target::Codex { home: d.store.clone(), thread }),
            None => TerminalTarget::NoInbox(
                "Codex in this chat's terminal does not hold the conversation open".to_owned(),
            ),
        };
    }
    let live = crate::claude_peers::live(&d.store);
    let Some(peer) = live.iter().find(|p| p.pid == d.pid && p.session_id == agent_session_id)
    else {
        return TerminalTarget::NoInbox(NOT_REGISTERED.to_owned());
    };
    if !crate::claude_peers::sole_claimant(peer, &live) {
        return TerminalTarget::NoInbox(
            "another Claude Code also claims this conversation".to_owned(),
        );
    }
    if peer.socket.is_none() {
        return TerminalTarget::NoInbox(
            "Claude Code in this chat's terminal takes no messages from other sessions (its cross-session messaging is off)"
                .to_owned(),
        );
    }
    TerminalTarget::Ready(Target::Claude {
        config: d.store.clone(),
        peer: peer.clone(),
        token: None,
    })
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
fn forget_delivered_ids(session_id: &str) {
    delivered_ids().remove(session_id);
}

#[cfg(test)]
#[path = "bridge_tests.rs"]
mod tests;
