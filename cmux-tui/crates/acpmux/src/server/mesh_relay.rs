//! The daemon's side of the mesh relay (`mesh.rs`): the inbox loop and the delivery of one
//! message.
//!
//! The inbox long-polls the hub (`inbox_wait`), never more often than `min_poll_gap` (a hub that
//! answers at once with nothing is no busy loop), and delivers each message on its own task, at
//! most `max_in_flight` at a time; a message already being delivered is not started again. After
//! a failed call it waits, doubling from `backoff_first` to `backoff_cap`, and logs only the
//! first failure of a run of them and the recovery. It stops when [`MeshRelay`] is stopped or
//! dropped, when the hub is gone (checked before each call), or when the hub refuses the call
//! itself (a bad credential, a request it will never take: retrying cannot help, so it logs that
//! once and the relay stays off until the daemon starts again); deliveries in flight then end
//! unacked, and their leases bring them back.
//!
//! A message is delivered as a send here is (`outbox.rs` `attempt_once`), on a connection of
//! `Origin::Peer`, so a relayed message is held to exactly a peer daemon's rules: it reads no
//! peer of this host, no peer state and no host suggestion. Only a session of this daemon takes
//! it ([`Hub::mesh_target`]); a name this daemon's peers list is refused, never forwarded. Its
//! prompt id is the message id, with `resend`, so a message the hub leases again (a lost ack, a
//! restart) answers with its first run instead of running twice (`hub/prompt_ledger.rs`).

use super::*;
use crate::mesh::{Ack, AckState, Backoff, ControlHook, InMessage, Kind, MeshHub, Mode};
use std::collections::HashSet;
use std::sync::Weak;
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// The inbox loop's timings.
#[derive(Debug, Clone)]
pub struct RelayOptions {
    /// How long one inbox call waits for a message.
    pub inbox_wait: Duration,
    /// The least time between the starts of two inbox calls.
    pub min_poll_gap: Duration,
    pub backoff_first: Duration,
    pub backoff_cap: Duration,
    /// Deliveries running at once; the inbox waits for one to end past it.
    pub max_in_flight: usize,
}

impl Default for RelayOptions {
    fn default() -> Self {
        Self {
            inbox_wait: Duration::from_secs(25),
            min_poll_gap: Duration::from_secs(1),
            backoff_first: Duration::from_secs(1),
            backoff_cap: Duration::from_secs(60),
            max_in_flight: 32,
        }
    }
}

/// The running relay. Dropping it stops it as [`MeshRelay::stop`] does, without waiting.
pub struct MeshRelay {
    stop: watch::Sender<bool>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl MeshRelay {
    pub fn start(
        hub: &Arc<Hub>,
        client: Arc<dyn MeshHub>,
        control: Arc<dyn ControlHook>,
        options: RelayOptions,
    ) -> Self {
        let (stop, stopped) = watch::channel(false);
        let options = Arc::new(options);
        let tasks =
            vec![tokio::spawn(inbox(Arc::downgrade(hub), client, control, options, stopped))];
        Self { stop, tasks }
    }

    /// Whether its loop has ended: stopped, its hub gone, or refused by the mesh hub.
    pub fn is_finished(&self) -> bool {
        self.tasks.iter().all(tokio::task::JoinHandle::is_finished)
    }

    /// Stop it and wait for its loop to end.
    pub async fn stop(mut self) {
        let _ = self.stop.send(true);
        for task in std::mem::take(&mut self.tasks) {
            let _ = task.await;
        }
    }
}

impl Drop for MeshRelay {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

/// Resolves once the relay is stopped or its handle dropped.
async fn stopped(stop: &mut watch::Receiver<bool>) {
    while !*stop.borrow_and_update() {
        if stop.changed().await.is_err() {
            return;
        }
    }
}

async fn inbox(
    hub: Weak<Hub>,
    client: Arc<dyn MeshHub>,
    control: Arc<dyn ControlHook>,
    options: Arc<RelayOptions>,
    mut stop: watch::Receiver<bool>,
) {
    let mut backoff = Backoff::new(options.backoff_first, options.backoff_cap);
    let mut failing = false;
    let mut deliveries = tokio::task::JoinSet::new();
    let in_flight: Arc<StdMutex<HashSet<String>>> = Arc::default();
    loop {
        while deliveries.try_join_next().is_some() {}
        if deliveries.len() >= options.max_in_flight.max(1) {
            tokio::select! {
                _ = deliveries.join_next() => continue,
                () = stopped(&mut stop) => break,
            }
        }
        if hub.strong_count() == 0 {
            break;
        }
        let started = Instant::now();
        // Only as many as it can deliver now: a leased message waits for its ack.
        let room = options.max_in_flight.max(1) - deliveries.len();
        let polled = tokio::select! {
            r = client.inbox(options.inbox_wait, room) => r,
            () = stopped(&mut stop) => break,
        };
        let wait = match polled {
            Ok(messages) => {
                if std::mem::take(&mut failing) {
                    tracing::info!("mesh relay: the hub's inbox answers again");
                }
                backoff.reset();
                for message in messages {
                    if !in_flight.lock_or_recover().insert(message.message_id.clone()) {
                        continue;
                    }
                    let Some(hub) = hub.upgrade() else { return };
                    let (client, control, in_flight) =
                        (client.clone(), control.clone(), in_flight.clone());
                    deliveries.spawn(async move {
                        if let Some(ack) = deliver(&hub, &message, control.as_ref()).await
                            && let Err(e) = client.ack(&message.message_id, &clip(ack)).await
                        {
                            // Its lease brings it back, and that delivery answers with this one.
                            tracing::warn!("mesh relay: ack of {} failed: {e}", message.message_id);
                        }
                        in_flight.lock_or_recover().remove(&message.message_id);
                    });
                }
                options.min_poll_gap.saturating_sub(started.elapsed())
            }
            Err(e) if e.refused => {
                tracing::error!(
                    "mesh relay: the hub refused this daemon's inbox ({e}); the relay is off until the daemon restarts"
                );
                break;
            }
            Err(e) => {
                if !std::mem::replace(&mut failing, true) {
                    tracing::warn!("mesh relay: inbox failed ({e}); retrying with backoff");
                }
                backoff.next_wait()
            }
        };
        if !wait.is_zero() {
            tokio::select! {
                () = tokio::time::sleep(wait) => {}
                () = stopped(&mut stop) => break,
            }
        }
    }
}

/// A connection of the origin a relayed request runs as: a peer daemon's, proven
/// (`ConnAuth::PeerToken`). The control hook sends a start, resume or stop on one.
pub fn relay_connection(hub: &Arc<Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (in_tx, in_rx) = mpsc::channel(16);
    let (out_tx, out_rx) = mpsc::channel(1024);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Peer));
    (in_tx, out_rx)
}

/// The longest ack detail the hub takes, in characters.
const MAX_DETAIL_CHARS: usize = 1000;

fn clip(mut ack: Ack) -> Ack {
    if let Some(detail) = ack.detail.as_mut()
        && detail.chars().count() > MAX_DETAIL_CHARS
    {
        *detail = detail.chars().take(MAX_DETAIL_CHARS).collect();
    }
    ack
}

/// How a relayed message names its sender to the session: `host/name`, one line, within
/// `fromAgent`'s length. Never empty: a message from another machine is never the person's.
fn sender_name(message: &InMessage) -> String {
    let clean = |s: &str| s.chars().filter(|c| !c.is_control()).collect::<String>();
    let field = |f: &Option<String>| clean(f.as_deref().unwrap_or_default().trim());
    let (host, name) = (field(&message.from.host), field(&message.from.name));
    let named = match (host.is_empty(), name.is_empty()) {
        (false, false) => format!("{host}/{name}"),
        (true, false) => name,
        (false, true) => format!("a session on {host}"),
        (true, true) => "a session on another machine".to_owned(),
    };
    named.chars().take(crate::hub::MAX_FROM_AGENT_CHARS).collect::<String>().trim().to_owned()
}

/// Deliver one message: the ack to send, or None to leave it unacked (a target that did not
/// answer in time, or this daemon's own connection failing), so its lease brings it back.
pub async fn deliver(
    hub: &Arc<Hub>,
    message: &InMessage,
    control: &dyn ControlHook,
) -> Option<Ack> {
    match message.kind {
        Kind::Prompt => {}
        Kind::Control => return control.control(hub, message).await,
        Kind::Unknown => return Some(Ack::refused("a message kind this daemon does not know")),
    }
    if message.body.trim().is_empty() {
        return Some(Ack::refused("the message is empty"));
    }
    let session = match hub.mesh_target(&message.to) {
        Ok(session) => session,
        Err(why) => return Some(Ack::refused(why)),
    };
    let prompt_id = message.message_id.as_str();
    let request = json!({
        "sessionId": session.id,
        "prompt": [{"type": "text", "text": message.body}],
        "_meta": {"acpmux": {
            "steer": message.mode == Mode::Now,
            "promptId": prompt_id,
            "resend": true,
            "fromAgent": sender_name(message),
        }},
    });
    use super::outbox::Next;
    match super::outbox::attempt_once(hub, None, request, Origin::Peer).await {
        Ok(_) => Some(Ack::delivered(prompt_id, None)),
        // A paused agent pair holds it in the session's queue: the person's resume runs it.
        Err((why, Next::Held)) => Some(Ack::delivered(prompt_id, Some(format!("held: {why}")))),
        Err((why, Next::Fail)) => Some(Ack {
            state: AckState::Refused,
            prompt_id: Some(prompt_id.to_owned()),
            detail: Some(why),
        }),
        Err((why, Next::Retry)) => {
            tracing::info!(
                "mesh relay: {prompt_id} not delivered yet ({why}); its lease brings it back"
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::{Sender, Target};

    fn from(host: &str, name: &str) -> InMessage {
        InMessage {
            message_id: "m".into(),
            to: Target::default(),
            from: Sender { name: Some(name.into()), host: Some(host.into()), ..Sender::default() },
            body: "x".into(),
            mode: Mode::TurnEnd,
            attempt: 1,
            kind: Kind::Prompt,
            op: None,
        }
    }

    #[test]
    fn a_relayed_message_always_names_a_sender_on_one_line() {
        assert_eq!(sender_name(&from("gcp-codex-lane-3", "lane-a")), "gcp-codex-lane-3/lane-a");
        assert_eq!(sender_name(&from("", "lane-a")), "lane-a");
        assert_eq!(sender_name(&from("vm", "")), "a session on vm");
        assert_eq!(sender_name(&from(" ", "")), "a session on another machine");
        assert_eq!(sender_name(&from("vm\n", "a\u{7}b")), "vm/ab");
        let long = sender_name(&from(&"h".repeat(80), "lane"));
        assert_eq!(long.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
    }

    #[test]
    fn an_ack_detail_is_clipped_to_what_the_hub_takes() {
        let ack = clip(Ack::refused("é".repeat(5000)));
        assert_eq!(ack.detail.unwrap().chars().count(), MAX_DETAIL_CHARS);
        assert_eq!(clip(Ack::refused("short")).detail.as_deref(), Some("short"));
    }
}
