//! Transient guest OS-opener requests. URLs never enter the session journal or
//! notification ledger. A live frontend explicitly subscribes to its terminal
//! projections, claims each request, then acknowledges actual browser delivery.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{MessageWriter, Mux, Response, send_response};
use crate::resource::TerminalPublicId;

const CLAIM_DEADLINE: Duration = Duration::from_secs(5);
const FILE_PREVIEW_DELIVERY_DEADLINE: Duration = Duration::from_secs(45);
const CAPACITY: usize = 16;

struct Subscriber {
    terminals: HashSet<String>,
    writer: MessageWriter,
}

struct Pending {
    client: u64,
    kind: OpenKind,
    claim_deadline: Instant,
    delivery_deadline: Option<Instant>,
    claimed: bool,
    claim_reply: mpsc::SyncSender<Instant>,
    reply: mpsc::SyncSender<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum OpenKind {
    Url,
    FilePreview,
}

impl OpenKind {
    fn delivery_deadline(self) -> Duration {
        match self {
            Self::Url => CLAIM_DEADLINE,
            Self::FilePreview => FILE_PREVIEW_DELIVERY_DEADLINE,
        }
    }

    fn worker_name(self) -> &'static str {
        match self {
            Self::Url => "mux-url-open",
            Self::FilePreview => "mux-file-preview-open",
        }
    }
}

pub(super) enum OpenEvent<'a> {
    Url { url: &'a str },
    FilePreview { path: &'a str, line: Option<u64> },
}

impl OpenEvent<'_> {
    fn kind(&self) -> OpenKind {
        match self {
            Self::Url { .. } => OpenKind::Url,
            Self::FilePreview { .. } => OpenKind::FilePreview,
        }
    }

    fn send(&self, writer: &MessageWriter, id: &str, terminal: &str) -> std::io::Result<()> {
        match self {
            Self::Url { url } => writer.send_url_open(id, terminal, url),
            Self::FilePreview { path, line } => {
                writer.send_file_preview_open(id, terminal, path, *line)
            }
        }
    }
}

#[derive(Default)]
struct State {
    subscribers: BTreeMap<u64, Subscriber>,
    pending: HashMap<String, Pending>,
}

#[derive(Default)]
pub(super) struct URLRequests(Mutex<State>);

impl URLRequests {
    pub(super) fn subscribe(
        &self,
        client: u64,
        terminals: Vec<String>,
        writer: MessageWriter,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(terminals.len() <= 256, "too many URL opener terminals");
        for terminal in &terminals {
            TerminalPublicId::parse(terminal.clone())?;
        }
        let mut state = self.0.lock().unwrap();
        anyhow::ensure!(
            state.subscribers.len() < CAPACITY || state.subscribers.contains_key(&client),
            "too many URL opener clients"
        );
        state
            .subscribers
            .insert(client, Subscriber { terminals: terminals.into_iter().collect(), writer });
        Ok(())
    }

    fn prepare(
        &self,
        terminal: &str,
        event: OpenEvent<'_>,
    ) -> Option<(String, mpsc::Receiver<Instant>, mpsc::Receiver<bool>)> {
        let (id, writer, claim_receiver, receiver) = {
            let mut state = self.0.lock().unwrap();
            if state.pending.len() >= CAPACITY {
                return None;
            }
            let mut candidates = state.subscribers.iter().filter(|(_, subscriber)| {
                subscriber.terminals.contains(terminal) && subscriber.writer.is_open()
            });
            let (&client, subscriber) = candidates.next()?;
            // A shared terminal has no reliable physical-Mac origin. Never
            // send its authentication URL to an arbitrary other frontend.
            if candidates.next().is_some() {
                return None;
            }
            let writer = subscriber.writer.clone();
            // An unguessable capability lets a frontend acknowledge on another
            // connection through the same authenticated mux tunnel.
            let id = crate::workspace_registry::new_uuid_v4();
            let (claim_sender, claim_receiver) = mpsc::sync_channel(1);
            let (sender, receiver) = mpsc::sync_channel(1);
            let kind = event.kind();
            let now = Instant::now();
            state.pending.insert(
                id.clone(),
                Pending {
                    client,
                    kind,
                    claim_deadline: now + CLAIM_DEADLINE,
                    delivery_deadline: None,
                    claimed: false,
                    claim_reply: claim_sender,
                    reply: sender,
                },
            );
            (id, writer, claim_receiver, receiver)
        };
        let sent = event.send(&writer, &id, terminal);
        if sent.is_err() {
            self.cancel(&id);
            return None;
        }
        Some((id, claim_receiver, receiver))
    }

    /// A buffered event cannot open a stale auth URL after its caller timed out.
    pub(super) fn claim(&self, id: &str, kind: OpenKind) -> bool {
        let mut state = self.0.lock().unwrap();
        let Some(pending) = state.pending.get_mut(id) else {
            return false;
        };
        if pending.kind != kind || pending.claimed || Instant::now() >= pending.claim_deadline {
            return false;
        }
        let delivery_deadline = match kind {
            OpenKind::Url => pending.claim_deadline,
            OpenKind::FilePreview => Instant::now() + kind.delivery_deadline(),
        };
        if pending.claim_reply.try_send(delivery_deadline).is_err() {
            return false;
        }
        pending.claimed = true;
        pending.delivery_deadline = Some(delivery_deadline);
        true
    }

    pub(super) fn complete(&self, id: &str, kind: OpenKind, opened: bool) -> bool {
        let mut state = self.0.lock().unwrap();
        let Some(pending) = state.pending.get(id) else {
            return false;
        };
        if pending.kind != kind
            || !pending.claimed
            || pending.delivery_deadline.is_none_or(|deadline| Instant::now() >= deadline)
        {
            return false;
        }
        let pending = state.pending.remove(id).unwrap();
        pending.reply.try_send(opened).is_ok()
    }

    fn cancel(&self, id: &str) {
        self.0.lock().unwrap().pending.remove(id);
    }

    pub(super) fn disconnect(&self, client: u64) {
        let mut state = self.0.lock().unwrap();
        state.subscribers.remove(&client);
        state.pending.retain(|_, pending| pending.client != client);
    }
}

fn validate_url(raw: &str) -> bool {
    raw.len() <= 16_384
        && !raw.chars().any(|c| c.is_control() || c.is_whitespace())
        && url::Url::parse(raw)
            .is_ok_and(|url| matches!(url.scheme(), "http" | "https") && url.host_str().is_some())
}

fn validate_file_preview(path: &str, line: Option<u64>) -> bool {
    path.len() <= 16_384
        && std::path::Path::new(path).is_absolute()
        && !path.chars().any(char::is_control)
        && line.is_none_or(|line| line >= 1)
}

/// Only this bounded wait leaves the normal command dispatcher; ack/claim and
/// disconnect are independent control messages and never wait on the opener.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    terminal: String,
    event: OpenEvent<'_>,
    writer: &MessageWriter,
) -> bool {
    let terminal_id = TerminalPublicId::parse(terminal.clone()).ok();
    let kind = event.kind();
    let valid_event = match &event {
        OpenEvent::Url { url } => validate_url(url),
        OpenEvent::FilePreview { path, line } => validate_file_preview(path, *line),
    };
    let valid = mux.control_clients.is_unix(client)
        && valid_event
        && terminal_id.as_ref().and_then(|id| mux.resource_surface_for_terminal(id)).is_some();
    let pending = valid.then(|| mux.control_clients.url_opens.prepare(&terminal, event)).flatten();
    let Some((request_id, claim_receiver, receiver)) = pending else {
        return respond(writer, id, false);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let cleanup_id = request_id.clone();
    let spawned = std::thread::Builder::new().name(kind.worker_name().into()).spawn(move || {
        let opened = claim_receiver
            .recv_timeout(CLAIM_DEADLINE)
            .ok()
            .and_then(|deadline| {
                receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())).ok()
            })
            .unwrap_or(false);
        worker_mux.control_clients.url_opens.cancel(&request_id);
        respond(&worker_writer, worker_id, opened);
    });
    if spawned.is_err() {
        mux.control_clients.url_opens.cancel(&cleanup_id);
        return respond(writer, id, false);
    }
    true
}

fn respond(writer: &MessageWriter, id: Option<Value>, opened: bool) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(json!({"opened": opened})),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::super::tests::captured_writer;
    use super::*;

    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

    #[test]
    fn url_open_has_no_headless_or_wrong_terminal_queue() {
        let broker = URLRequests::default();
        assert!(
            broker
                .prepare(TERMINAL, OpenEvent::Url { url: "https://github.com/login/device" })
                .is_none()
        );
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        assert!(
            broker.prepare("term_other", OpenEvent::Url { url: "https://example.com" }).is_none()
        );
    }

    #[test]
    fn url_open_requires_claim_and_actual_delivery_ack() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let (id, _claim_receiver, receiver) = broker
            .prepare(TERMINAL, OpenEvent::Url { url: "https://example.com/?code=abc" })
            .unwrap();
        assert!(!broker.complete(&id, OpenKind::Url, true));
        assert!(broker.claim(&id, OpenKind::Url));
        assert!(!broker.claim(&id, OpenKind::Url));
        assert!(broker.complete(&id, OpenKind::Url, true));
        assert!(receiver.recv().unwrap());
        assert!(!broker.claim(&id, OpenKind::Url));
    }

    #[test]
    fn url_open_does_not_guess_between_frontends() {
        let broker = URLRequests::default();
        let (first, _) = captured_writer();
        let (second, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], first).unwrap();
        broker.subscribe(2, vec![TERMINAL.into()], second).unwrap();
        assert!(broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).is_none());
        broker.disconnect(2);
        assert!(broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).is_some());
    }

    #[test]
    fn url_open_disconnect_deadline_and_capacity_are_bounded() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let mut requests = Vec::new();
        for _ in 0..CAPACITY {
            requests.push(
                broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).unwrap(),
            );
        }
        assert!(broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).is_none());
        broker.0.lock().unwrap().pending.get_mut(&requests[0].0).unwrap().claim_deadline =
            Instant::now();
        assert!(!broker.claim(&requests[0].0, OpenKind::Url));
        broker.disconnect(1);
        for (_, _, receiver) in requests {
            assert!(receiver.recv().is_err());
        }
        assert!(broker.0.lock().unwrap().pending.is_empty());
    }

    #[test]
    fn url_claim_keeps_the_prepare_deadline_for_delivery() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let (id, _claim_receiver, _) =
            broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).unwrap();
        let claim_deadline = broker.0.lock().unwrap().pending[&id].claim_deadline;

        assert!(broker.claim(&id, OpenKind::Url));

        let pending = broker.0.lock().unwrap();
        assert_eq!(pending.pending[&id].delivery_deadline, Some(claim_deadline));
    }

    #[test]
    fn file_preview_capacity_is_bounded_without_waiting_for_claim_deadlines() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        for _ in 0..CAPACITY {
            assert!(
                broker
                    .prepare(TERMINAL, OpenEvent::FilePreview { path: "/srv/notes.md", line: None })
                    .is_some()
            );
        }
        assert!(
            broker
                .prepare(TERMINAL, OpenEvent::FilePreview { path: "/srv/notes.md", line: None })
                .is_none()
        );
    }

    #[test]
    fn url_open_validates_without_rewriting_auth_url_bytes() {
        assert!(validate_url("HTTPS://github.com/login/device?state=AbC%2F%2b#fragment"));
        for url in [
            "file:///tmp/file",
            "javascript:alert(1)",
            "https://",
            "https://foo/\ncommand",
            "https://foo/a b",
        ] {
            assert!(!validate_url(url));
        }
        assert!(!validate_url(&format!("https://example.com/{}", "a".repeat(16_384))));
    }

    #[test]
    fn file_preview_requires_an_absolute_bounded_safe_path_and_positive_line() {
        assert!(validate_file_preview("/srv/notes.md", Some(12)));
        for (path, line) in
            [("notes.md", None), ("/srv/notes\n.md", None), ("/srv/notes.md", Some(0))]
        {
            assert!(!validate_file_preview(path, line));
        }
        assert!(!validate_file_preview(&format!("/{}", "a".repeat(16_384)), None));
    }

    #[test]
    fn file_preview_claims_fast_but_allows_a_longer_delivery_window() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let (id, _claim_receiver, _) = broker
            .prepare(TERMINAL, OpenEvent::FilePreview { path: "/srv/notes.md", line: None })
            .unwrap();
        let pending = broker.0.lock().unwrap();
        let request = pending.pending.get(&id).unwrap();
        assert_eq!(request.kind, OpenKind::FilePreview);
        assert!(request.delivery_deadline.is_none());
        drop(pending);
        assert!(broker.claim(&id, OpenKind::FilePreview));
        let pending = broker.0.lock().unwrap();
        let request = pending.pending.get(&id).unwrap();
        assert!(request.delivery_deadline.is_some());
        assert_eq!(OpenKind::FilePreview.delivery_deadline(), Duration::from_secs(45));
        assert_eq!(OpenKind::Url.delivery_deadline(), Duration::from_secs(5));
    }

    #[test]
    fn claims_and_results_must_match_the_pending_request_kind() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let (url_id, _claim_receiver, _reply_receiver) =
            broker.prepare(TERMINAL, OpenEvent::Url { url: "https://example.com" }).unwrap();
        assert!(!broker.claim(&url_id, OpenKind::FilePreview));
        assert!(broker.claim(&url_id, OpenKind::Url));
        assert!(!broker.complete(&url_id, OpenKind::FilePreview, true));
        assert!(broker.complete(&url_id, OpenKind::Url, true));
    }
}
