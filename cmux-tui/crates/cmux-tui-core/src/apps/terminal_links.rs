//! The relay side of connector links for the supervisor: each link the
//! registry opens gets its local socket ([`RelaySet`]); every end stops the
//! relay; clients learn sockets from `apps-terminal-links` and the
//! `apps-terminal-link` event. Frames from a relay go to the app's current
//! server process. No socket path goes to an app.

use std::sync::Arc;

use serde_json::{Value, json};

use super::supervisor::{Out, Supervisor};
use crate::terminal_backend::relay::{ClientGone, Emit};
use crate::terminal_backend::{End, LinkAnswer, LinkEvent, LinkRegistry, RelaySet, wire};

/// The supervisor's terminal state: connector links and their relays.
#[derive(Default)]
pub(crate) struct Terminals {
    pub links: Arc<LinkRegistry>,
    pub relays: RelaySet,
}

impl Supervisor {
    /// Starts the relay of a link `cmux.terminal.connector.open` answered,
    /// unless it already runs (the same link answered again).
    pub(super) fn start_link_relay(&self, app: &str, answer: &LinkAnswer) {
        let channel = &answer.channel;
        if self.terminals.relays.socket(channel).is_some() {
            return;
        }
        let Some(dir) = self.config.state_dir.as_ref().map(|d| d.join("tl")) else {
            self.log_terminal(app, "warn", format!("terminal link {channel}: no state directory"));
            return;
        };
        let emit: Emit = {
            let (me, app) = (self.me.clone(), app.to_owned());
            Arc::new(move |frame| {
                if let Some(me) = me.upgrade() {
                    me.send_to_server(&app, &wire::frame_to_json(&frame));
                }
            })
        };
        let gone: ClientGone = {
            let me = self.me.clone();
            Arc::new(move |channel| {
                if let Some(me) = me.upgrade() {
                    let _ = me.close_terminal_link(channel);
                }
            })
        };
        let links = &self.terminals.links;
        match self.terminals.relays.start(&dir, links, channel, emit, gone) {
            Ok(socket) => {
                let Some((id, target)) = links.link(channel) else {
                    // The link ended while the relay started.
                    self.terminals.relays.stop(channel);
                    return;
                };
                self.emit(vec![Out::Broadcast(json!({
                    "event": "apps-terminal-link", "channel": channel, "app": app,
                    "id": id.as_str(), "target": target, "state": "open", "socket": socket,
                }))]);
            }
            Err(error) => {
                self.log_terminal(app, "warn", format!("terminal link {channel}: {error}"));
            }
        }
    }

    /// One line to `app`'s running server, if any.
    fn send_to_server(&self, app: &str, value: &Value) {
        let inner = self.inner.lock().unwrap();
        if let Some(server) = inner.servers.get(app) {
            let mut line = value.to_string().into_bytes();
            line.push(b'\n');
            server.process.send(line);
        }
    }

    /// A link ended: its relay stops; answers the client event.
    pub(super) fn link_ended(&self, event: &LinkEvent) -> Out {
        self.terminals.relays.stop(&event.channel);
        let end = match &event.end {
            End::Lost(lost) => {
                json!({ "lost": { "reason": lost.reason, "retryable": lost.retryable } })
            }
            End::Exit(exit) => json!({ "exit": { "code": exit.code, "signal": exit.signal } }),
        };
        Out::Broadcast(json!({
            "event": "apps-terminal-link", "channel": event.channel, "app": event.app,
            "state": "ended", "end": end,
        }))
    }

    /// `apps-terminal-links`: every open link and its socket.
    pub(crate) fn terminal_links_list(&self) -> Value {
        let links: Vec<Value> = self
            .terminals
            .links
            .list()
            .into_iter()
            .map(|(channel, app, id, target)| {
                let socket = self.terminals.relays.socket(&channel);
                json!({ "channel": channel, "app": app, "id": id.as_str(), "target": target, "socket": socket })
            })
            .collect();
        json!({ "links": links })
    }
}
