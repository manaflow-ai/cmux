//! OSC 52 clipboard reads, daemon broker (layer 3 of decision
//! CLIPBOARD-READ-BROKER; deny by default, the user grants each read).
//!
//! A host connection reports each read as a [`HostSignal`] on its frame
//! reader thread, with no polling. The broker asks the single frontend
//! subscribed to that terminal with a `terminal-clipboard-read` event that
//! carries an unguessable request id, and that connection alone answers it
//! once with `terminal-clipboard-reply`. Every other case is refused at once:
//! no subscriber or several, a terminal that already has an open read, a
//! frontend that already holds [`MAX_OPEN_PER_FRONTEND`] reads, or a surface
//! with no public terminal id. Only the frontend user path (the verified cmux
//! app, client kind `frontend`) may subscribe or reply; agents, page relays
//! and the socket get `origin.forbidden`. Clipboard text is never logged or
//! kept: it goes straight to the host connection.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, PoisonError};

use ghostty_vt::{ClipboardLocation, MAX_CLIPBOARD_READ_BYTES};
use serde_json::{Value, json};

use super::{Command, MessageWriter, Mux};
use crate::SurfaceId;
use crate::request_origin::{ORIGIN_FORBIDDEN, RequestOrigin};
use crate::resource::TerminalPublicId;

pub(super) const CAPABILITY: &str = "terminal-clipboard-read-v1";
const MAX_SUBSCRIBED_TERMINALS: usize = 256;
const MAX_SUBSCRIBERS: usize = 16;
const MAX_OPEN_PER_FRONTEND: usize = 16;

/// Answers one host read: `Some(text)` grants it, `None` refuses it. True
/// when the answer reached the host.
pub(crate) type CompleteRead = Box<dyn FnOnce(Option<Vec<u8>>) -> bool + Send>;

/// One read a host asks about.
pub(crate) struct HostRead {
    pub(crate) surface: SurfaceId,
    /// The terminal's public id; a read without one is refused.
    pub(crate) terminal: Option<String>,
    pub(crate) token: u64,
    pub(crate) location: ClipboardLocation,
    pub(crate) complete: CompleteRead,
}

/// What a host connection tells the broker. It runs on that connection's
/// frame reader thread and never blocks on a frontend.
pub(crate) enum HostSignal {
    Request(HostRead),
    /// The host refused the read itself (timeout, terminal end) or its
    /// connection ended: withdraw the question, do not answer it.
    Cancel {
        surface: SurfaceId,
        token: u64,
    },
}

struct Subscriber {
    terminals: HashSet<String>,
    writer: MessageWriter,
}

struct OpenRead {
    client: u64,
    writer: MessageWriter,
    surface: SurfaceId,
    token: u64,
    terminal: String,
    complete: CompleteRead,
}

#[derive(Default)]
struct State {
    subscribers: BTreeMap<u64, Subscriber>,
    open: HashMap<String, OpenRead>,
}

impl State {
    /// The one live frontend subscribed to `terminal`, if exactly one is.
    fn single_subscriber(&self, terminal: &str) -> Option<(u64, MessageWriter)> {
        let mut candidates = self.subscribers.iter().filter(|(_, subscriber)| {
            subscriber.terminals.contains(terminal) && subscriber.writer.is_open()
        });
        let (&client, subscriber) = candidates.next()?;
        // Several frontends see this terminal: the daemon cannot tell which
        // user the program is asking, so it never guesses.
        if candidates.next().is_some() {
            return None;
        }
        Some((client, subscriber.writer.clone()))
    }

    /// Withdraws the open reads `matches` selects from their frontends.
    fn withdraw(&mut self, matches: impl Fn(&OpenRead) -> bool) {
        let ids: Vec<String> =
            self.open.iter().filter(|(_, open)| matches(open)).map(|(id, _)| id.clone()).collect();
        for id in ids {
            if let Some(open) = self.open.remove(&id) {
                let _ = open.writer.send_control(
                    &json!({"event": "terminal-clipboard-read-cancelled", "request_id": id}),
                );
            }
        }
    }
}

/// A poisoned lock still guards whole broker state (no critical section
/// leaves it half changed), so the broker keeps refusing safely.
fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Default)]
pub(crate) struct ClipboardReads(Mutex<State>);

impl ClipboardReads {
    /// One host signal. A refused request is answered before this returns.
    pub(crate) fn handle(&self, signal: HostSignal) {
        match signal {
            HostSignal::Request(read) => {
                if let Some(refused) = self.ask(read) {
                    (refused.complete)(None);
                }
            }
            HostSignal::Cancel { surface, token } => {
                lock(&self.0).withdraw(|open| open.surface == surface && open.token == token);
            }
        }
    }

    /// Puts `read` to its frontend, or hands it back to be refused.
    fn ask(&self, read: HostRead) -> Option<HostRead> {
        let mut state = lock(&self.0);
        // A host keeps one read per terminal open, so a new token from the
        // same surface means the older read is already over.
        state.withdraw(|open| open.surface == read.surface);
        let Some(terminal) = read.terminal.clone() else { return Some(read) };
        if state.open.values().any(|open| open.terminal == terminal) {
            return Some(read);
        }
        let Some((client, writer)) = state.single_subscriber(&terminal) else {
            return Some(read);
        };
        if state.open.values().filter(|open| open.client == client).count() >= MAX_OPEN_PER_FRONTEND
        {
            return Some(read);
        }
        let request_id = crate::workspace_registry::new_uuid_v4();
        let event = json!({
            "event": "terminal-clipboard-read",
            "request_id": request_id,
            "terminal_id": terminal,
            "location": location_name(read.location),
            // Terminal hosts are local to this daemon; a frontend that
            // reached it over a remote or Cloud transport names that host.
            "host": {"kind": "local"},
        });
        if writer.send_control(&event).is_err() {
            return Some(read);
        }
        let HostRead { surface, token, complete, .. } = read;
        state
            .open
            .insert(request_id, OpenRead { client, writer, surface, token, terminal, complete });
        None
    }

    fn subscribe(
        &self,
        client: u64,
        terminals: Vec<String>,
        writer: MessageWriter,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            terminals.len() <= MAX_SUBSCRIBED_TERMINALS,
            "too many clipboard-read terminals"
        );
        for terminal in &terminals {
            TerminalPublicId::parse(terminal.clone())?;
        }
        let mut state = lock(&self.0);
        anyhow::ensure!(
            state.subscribers.len() < MAX_SUBSCRIBERS || state.subscribers.contains_key(&client),
            "too many clipboard-read frontends"
        );
        state
            .subscribers
            .insert(client, Subscriber { terminals: terminals.into_iter().collect(), writer });
        Ok(())
    }

    /// `client`'s answer to `request_id`. Only the connection that got the
    /// event may answer, and only once; `None` text, or text over the cap,
    /// refuses.
    fn reply(&self, client: u64, request_id: &str, text: Option<String>) -> Value {
        let open = {
            let mut state = lock(&self.0);
            match state.open.get(request_id) {
                Some(open) if open.client == client => state.open.remove(request_id),
                _ => None,
            }
        };
        let Some(open) = open else { return json!({"accepted": false, "granted": false}) };
        let text =
            text.map(String::into_bytes).filter(|text| text.len() <= MAX_CLIPBOARD_READ_BYTES);
        let granting = text.is_some();
        let delivered = (open.complete)(text);
        json!({"accepted": true, "granted": granting && delivered})
    }

    /// The connection ended: its subscription goes and its open reads are
    /// refused.
    pub(super) fn disconnect(&self, client: u64) {
        let refused: Vec<CompleteRead> = {
            let mut state = lock(&self.0);
            state.subscribers.remove(&client);
            let ids: Vec<String> = state
                .open
                .iter()
                .filter(|(_, open)| open.client == client)
                .map(|(id, _)| id.clone())
                .collect();
            ids.iter().filter_map(|id| state.open.remove(id)).map(|open| open.complete).collect()
        };
        for complete in refused {
            complete(None);
        }
    }
}

fn location_name(location: ClipboardLocation) -> &'static str {
    match location {
        ClipboardLocation::Standard => "standard",
        ClipboardLocation::Selection => "selection",
        ClipboardLocation::Primary => "primary",
    }
}

#[derive(Debug)]
struct OriginForbidden;

impl std::fmt::Display for OriginForbidden {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("only the verified cmux app's frontend may handle clipboard reads")
    }
}

impl std::error::Error for OriginForbidden {}

/// The `error_code` of a refused clipboard-read command.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<OriginForbidden>().map(|_| ORIGIN_FORBIDDEN.to_string())
}

/// The frontend user path: client kind `frontend` on a connection that
/// derives origin `user` (the verified cmux app; never a page relay).
fn require_frontend_user(mux: &Mux, client: u64) -> anyhow::Result<()> {
    let state = mux.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
    let allowed = state.clients.get(&client).is_some_and(|record| {
        record.kind.as_deref() == Some("frontend") && record.origin.derive() == RequestOrigin::User
    });
    if allowed { Ok(()) } else { Err(OriginForbidden.into()) }
}

/// `terminal-clipboard-subscribe` and `terminal-clipboard-reply`. A
/// forbidden caller changes nothing.
pub(super) fn handle(
    mux: &Mux,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    require_frontend_user(mux, client)?;
    let reads = &mux.control_clients.clipboard_reads;
    match cmd {
        Command::TerminalClipboardSubscribe { terminal_ids } => {
            reads.subscribe(client, terminal_ids, writer.clone())?;
            Ok(json!({"clipboard_read_ready": true}))
        }
        Command::TerminalClipboardReply { request_id, text } => {
            Ok(reads.reply(client, &request_id, text))
        }
        _ => anyhow::bail!("not a clipboard-read command"),
    }
}

#[cfg(all(test, unix))]
#[path = "clipboard_read_tests.rs"]
mod tests;
