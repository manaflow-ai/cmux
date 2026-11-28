//! `offer-link-to-phone`: a web link a program in a terminal asks a browser for (`gh auth
//! login`'s "Press Enter to open github.com in your browser", `open URL`) opens on the phone
//! that drives that terminal, not on the Mac.
//!
//! Leo, 2026-11-14: "I tried to open up a link on the terminal on iOS. And a direct open link
//! one. It opened in Alma on Mac".
//!
//! A cmux terminal's `BROWSER` and its `open` / `xdg-open` shims ask the Mac app
//! (`browser.open_link`), which asks this daemon first. The daemon owns the terminals and the
//! phone's connections, so it decides here. The link goes to a phone when all of these hold:
//!
//! - the terminal's most recent input came from a phone's connection (`send` or `send-key` of
//!   a remote device, its attach channel or its input lane), no more than [`INPUT_WINDOW`]
//!   ago: a key the Mac's own view sends later takes the terminal back;
//! - a connection of that same phone (the same `device_id`, which the phone's splice stamps on
//!   every `set-client-info`) is attached to the terminal, is open, and declared
//!   [`CAPABILITY`]: a phone app that cannot open it never gets the event;
//! - the address is public ([`cmux_local_url::side::LinkSide::Phone`]): a dev server, a LAN
//!   or tailnet host only the Mac reaches stays on the Mac, as a tapped link does (#43056).
//!
//! That connection gets one [`EVENT`] control line, and the reply is `{offered:true}`. Anything
//! else answers `{offered:false}` and changes nothing: the Mac app opens the link as it always
//! did. The URL is never logged or journaled.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_local_url::side::{LinkSide, link_side};
use serde_json::{Value, json};

use super::{MessageWriter, Mux};
use crate::SurfaceId;
use crate::panic_free::RecoverPoison;
use crate::resource::TerminalPublicId;

/// How long after a phone's last key into a terminal a link its program opens still goes to
/// that phone. A sign-in flow (`gh auth login`: a few questions, then Enter) opens its page
/// within seconds of the last key; two minutes also covers a slow build that opens a page
/// when it is done, and is short enough that a phone the person put down an hour ago does
/// not take a link the person opens at the Mac.
pub(super) const INPUT_WINDOW: Duration = Duration::from_secs(120);

/// The phone's attach channel declares it in `set-client-info`: it opens a pushed link.
pub(super) const CAPABILITY: &str = "phone-open-link-v1";

/// The control event the phone gets: `{event, terminal_id, url}`.
pub(super) const EVENT: &str = "phone-open-link";

/// Terminals kept at most: past it the inputs older than the window go, then the oldest.
const CAPACITY: usize = 4096;

/// The last connection that typed into each terminal, and when.
#[derive(Default)]
pub(super) struct LastInputs(Mutex<HashMap<SurfaceId, (u64, Instant)>>);

impl LastInputs {
    /// A key (`send`, `send-key`) from `client` reached `surface`.
    pub(super) fn note(&self, surface: SurfaceId, client: u64) {
        self.note_at(surface, client, Instant::now());
    }

    fn note_at(&self, surface: SurfaceId, client: u64, now: Instant) {
        let mut inputs = self.0.lock().recover_poison();
        if inputs.len() >= CAPACITY && !inputs.contains_key(&surface) {
            inputs.retain(|_, (_, at)| now.saturating_duration_since(*at) <= INPUT_WINDOW);
            if inputs.len() >= CAPACITY
                && let Some(oldest) =
                    inputs.iter().min_by_key(|(_, (_, at))| *at).map(|(surface, _)| *surface)
            {
                inputs.remove(&oldest);
            }
        }
        inputs.insert(surface, (client, now));
    }

    pub(super) fn last(&self, surface: SurfaceId) -> Option<(u64, Instant)> {
        self.0.lock().recover_poison().get(&surface).copied()
    }

    /// A connection left: its keys no longer say who drives a terminal.
    pub(super) fn disconnect(&self, client: u64) {
        self.0.lock().recover_poison().retain(|_, (typed, _)| *typed != client);
    }
}

/// What the decision reads about one connection of this daemon.
#[derive(Clone, Debug, Default)]
pub(super) struct Connection {
    pub(super) client: u64,
    /// A phone's spliced lane (`set-client-info remote:true`).
    pub(super) remote_device: bool,
    pub(super) device_id: Option<String>,
    /// It declared [`CAPABILITY`].
    pub(super) opens_links: bool,
    /// It is attached to the terminal the link came from.
    pub(super) attached: bool,
    pub(super) open: bool,
}

/// The connection of the phone that drives the terminal, which should open `url`, or `None`
/// (the Mac opens it, as before). `last_input` is the terminal's last key and when it came.
pub(super) fn phone_for(
    url: &str,
    last_input: Option<(u64, Instant)>,
    now: Instant,
    connections: &[Connection],
) -> Option<u64> {
    if link_side(url) != LinkSide::Phone {
        return None;
    }
    let (typed, at) = last_input?;
    if now.saturating_duration_since(at) > INPUT_WINDOW {
        return None;
    }
    let typist = connections.iter().find(|connection| connection.client == typed)?;
    let device = typist.device_id.as_deref().filter(|_| typist.remote_device)?;
    connections
        .iter()
        .filter(|connection| {
            connection.remote_device
                && connection.device_id.as_deref() == Some(device)
                && connection.opens_links
                && connection.attached
                && connection.open
        })
        // The connection that typed when it is the attach channel, else the newest one.
        .max_by_key(|connection| (connection.client == typed, connection.client))
        .map(|connection| connection.client)
}

/// `offer-link-to-phone {terminal_id, url}` from the Mac app's own connection.
pub(super) fn offer(mux: &Mux, client: u64, terminal_id: &str, url: &str) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client)
            && !super::incognito_remote::is_remote_device(mux, client),
        "offer-link-to-phone is only for this Mac's own app"
    );
    anyhow::ensure!(
        super::url_open::validate_url(url),
        "offer-link-to-phone needs url, an absolute http or https URL"
    );
    let terminal = TerminalPublicId::parse(terminal_id.to_owned())?;
    let Some(surface) = mux.resource_surface_for_terminal(&terminal) else {
        return Ok(json!({"offered": false}));
    };
    let last_input = mux.control_clients.last_inputs.last(surface);
    let (connections, writers) = mux.control_clients.link_connections(surface);
    let Some(phone) = phone_for(url, last_input, Instant::now(), &connections) else {
        return Ok(json!({"offered": false}));
    };
    let Some(writer) = writers.get(&phone) else { return Ok(json!({"offered": false})) };
    let offered = send_event(writer, terminal_id, url).is_ok();
    Ok(json!({"offered": offered}))
}

impl super::ClientRegistry {
    /// Every connection as [`phone_for`] reads it for a link from `surface`, with the writers.
    /// One registry lock, taken only when a program opens a link, never on a key.
    pub(super) fn link_connections(
        &self,
        surface: SurfaceId,
    ) -> (Vec<Connection>, HashMap<u64, MessageWriter>) {
        let state = self.state.lock().recover_poison();
        let mut connections = Vec::with_capacity(state.clients.len());
        let mut writers = HashMap::new();
        for (&client, record) in &state.clients {
            let attached = record.attached.contains_key(&surface);
            let opens_links = record.capabilities.contains(CAPABILITY);
            if record.remote_device && attached && opens_links {
                writers.insert(client, record.writer.clone());
            }
            connections.push(Connection {
                client,
                remote_device: record.remote_device,
                device_id: record.identity.device_id.clone(),
                opens_links,
                attached,
                open: record.writer.is_open(),
            });
        }
        (connections, writers)
    }
}

fn send_event(writer: &MessageWriter, terminal_id: &str, url: &str) -> std::io::Result<()> {
    writer.send_control(&json!({"event": EVENT, "terminal_id": terminal_id, "url": url}))
}

#[cfg(test)]
#[path = "phone_link_tests.rs"]
mod tests;
