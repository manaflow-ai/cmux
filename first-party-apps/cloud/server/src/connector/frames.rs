//! Frame links (`DataPlane::Frames` on the wire): after a user connect that
//! carries the host's open token, the server asks the host with
//! `cmux.terminal.connector.open {kind, target, open_token}`; the host
//! answers `{channel, window_bytes}` and owns the channel id. Each link
//! then has one [`Pump`] between its carrier port (a connection to the
//! link's carrier socket) and the `data`/`credit`/`end` lines on the host
//! channel. Only the serve loop thread touches this state; port results
//! wake the loop, nothing polls.

use super::frame_wire::{frame_from_line, frame_line};
use super::port::{CarrierPort, PortEvent, PortOpener};
use super::pump::Pump;
use crate::link::LinkWake;
use cmux_terminal_iface::{End, FrameBody, Lost};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

/// The host op that opens a frame link.
pub const CONNECTOR_OPEN: &str = "cmux.terminal.connector.open";
/// The host event that ends a frame link from the host side.
pub const CONNECTOR_CLOSE: &str = "cmux.terminal.connector.close";

/// Frame links (open or being opened) at once, the host's own per-app bound.
pub(crate) const MAX_FRAME_LINKS: usize = 64;

/// Longest channel id the host may answer (its target bound).
const MAX_CHANNEL: usize = 256;

struct FrameLink {
    machine: String,
    /// The link generation whose carrier this link reads.
    generation: u64,
    pump: Pump,
    port: Box<dyn CarrierPort>,
    /// A read was asked and its result has not come yet.
    reading: bool,
}

/// The frame links of this server.
pub struct FrameLinks {
    opener: Box<dyn PortOpener>,
    wake: Option<LinkWake>,
    /// Host request id of each `connector.open` that waits, and its machine.
    opening: BTreeMap<u64, String>,
    /// Open links by host channel id.
    links: BTreeMap<String, FrameLink>,
    /// Frame lines for the host, not sent yet.
    lines: Vec<Value>,
    /// `connector.open` requests, sent after `lines`.
    requests: Vec<Value>,
}

impl FrameLinks {
    pub(crate) fn new(opener: Box<dyn PortOpener>) -> Self {
        Self {
            opener,
            wake: None,
            opening: BTreeMap::new(),
            links: BTreeMap::new(),
            lines: Vec::new(),
            requests: Vec::new(),
        }
    }

    pub(crate) fn set_wake(&mut self, wake: LinkWake) {
        self.wake = Some(wake);
    }

    /// Whether a connect of `machine` should ask the host for a frame link:
    /// no live one is open or being opened for it, and the bound has room.
    /// A link whose pump ended (its `end` not sent yet) does not count.
    pub(crate) fn wants_open(&self, machine: &str) -> bool {
        let busy = self.opening.values().any(|m| m == machine)
            || self.links.values().any(|l| l.machine == machine && !l.pump.is_ended());
        !busy && self.opening.len() + self.links.len() < MAX_FRAME_LINKS
    }

    /// Ends the frame links of `machine` that read an older carrier
    /// generation than `generation` (a replaced link whose end did not
    /// come yet).
    pub(crate) fn end_stale(&mut self, machine: &str, generation: u64) {
        for link in self.links.values_mut() {
            if link.machine == machine && link.generation != generation {
                link.pump.close(Lost::new("the link was replaced", true));
            }
        }
    }

    /// The `connector.open` `request` (host request `id`) for `machine`:
    /// it goes out with the frame lines, after the `end` of any link it
    /// replaces.
    pub(crate) fn opening(&mut self, id: u64, machine: &str, request: Value) {
        self.opening.insert(id, machine.to_owned());
        self.requests.push(request);
    }

    /// The machine of the `connector.open` that host request `id` answers.
    pub(crate) fn take_opening(&mut self, id: u64) -> Option<String> {
        self.opening.remove(&id)
    }

    /// The host opened a link for `machine`: `{channel, window_bytes}`.
    /// `carrier`: the socket and generation of the machine's up link (none
    /// when it went down meanwhile; the channel then ends at once).
    pub(crate) fn opened(&mut self, machine: &str, value: &Value, carrier: Option<(&Path, u64)>) {
        let channel = value.get("channel").and_then(Value::as_str).filter(|c| {
            !c.is_empty() && c.len() <= MAX_CHANNEL && !c.chars().any(char::is_control)
        });
        let Some(channel) = channel else {
            eprintln!("cmux-cloud: the host's frame link answer for {machine} has no channel");
            return;
        };
        if self.links.contains_key(channel) {
            // A second open while the link is up answers the same channel.
            return;
        }
        let window = value
            .get("window_bytes")
            .and_then(Value::as_u64)
            .and_then(|w| u32::try_from(w).ok())
            .unwrap_or(0);
        let pump = match Pump::new(window) {
            Ok(pump) => pump,
            Err(error) => return self.end_now(channel, Lost::new(error.to_string(), false)),
        };
        let Some((socket, generation)) = carrier else {
            return self.end_now(channel, Lost::new("the link went down", true));
        };
        match self.opener.open(socket, self.wake.clone()) {
            Ok(port) => {
                let machine = machine.to_owned();
                let link = FrameLink { machine, generation, pump, port, reading: false };
                self.links.insert(channel.to_owned(), link);
            }
            Err(e) => {
                let lost = Lost::new(format!("the link carrier did not open: {e}"), true);
                self.end_now(channel, lost);
            }
        }
    }

    /// The one `end` of a channel that never got a pump.
    fn end_now(&mut self, channel: &str, lost: Lost) {
        self.lines.push(frame_line(channel, &FrameBody::End(End::Lost(lost))));
    }

    /// One frame line from the host. A frame for a channel that is not open
    /// (the host's late frames after an end) is dropped.
    pub(crate) fn receive(&mut self, line: &Value) {
        let frame = match frame_from_line(line) {
            Ok(frame) => frame,
            Err(why) => {
                eprintln!("cmux-cloud: dropped a frame line: {why}");
                return;
            }
        };
        if let Some(link) = self.links.get_mut(&frame.channel) {
            // After the end nothing is accepted; that refusal needs no answer.
            let _ = link.pump.push(frame.body);
        }
    }

    /// `cmux.terminal.connector.close {channel}`: the host ended the link.
    pub(crate) fn host_closed(&mut self, data: &Value) {
        let channel = data.get("channel").and_then(Value::as_str).unwrap_or_default();
        self.close(channel, Lost::new("closed", true));
    }

    /// Ends the link of `channel` with `lost`, if it is open.
    pub(crate) fn close(&mut self, channel: &str, lost: Lost) {
        if let Some(link) = self.links.get_mut(channel) {
            link.pump.close(lost);
        }
    }

    /// Ends every link with `lost`.
    pub(crate) fn close_all(&mut self, lost: &Lost) {
        for link in self.links.values_mut() {
            link.pump.close(lost.clone());
        }
    }

    /// The link of `machine` went down or was revoked: its frame links of
    /// that generation (any, when `generation` is `None`) end.
    pub(crate) fn link_down(&mut self, machine: &str, generation: Option<u64>, lost: &Lost) {
        for link in self.links.values_mut() {
            if link.machine == machine && generation.is_none_or(|g| g == link.generation) {
                link.pump.close(lost.clone());
            }
        }
    }

    /// Moves every link's bytes as far as the credit allows and answers the
    /// frame lines for the host, then the `connector.open` requests; ended
    /// links release their carrier port.
    pub(crate) fn take_lines(&mut self) -> Vec<Value> {
        let mut ended = Vec::new();
        for (channel, link) in &mut self.links {
            drive(link);
            self.lines.extend(link.pump.take_frames().iter().map(|f| frame_line(channel, f)));
            if link.pump.is_ended() {
                ended.push(channel.clone());
            }
        }
        for channel in ended {
            if let Some(mut link) = self.links.remove(&channel) {
                link.port.shutdown();
            }
        }
        let mut lines = std::mem::take(&mut self.lines);
        lines.append(&mut self.requests);
        lines
    }
}

/// Applies a link's port events to its pump, then hands the carrier the
/// host bytes and asks for one read inside the out credit.
fn drive(link: &mut FrameLink) {
    for event in link.port.take_events() {
        let pump = &mut link.pump;
        let refused = match event {
            PortEvent::Read(bytes) => {
                link.reading = false;
                if bytes.is_empty() {
                    pump.carrier_closed(Lost::new("the link carrier closed", true));
                    Ok(())
                } else {
                    pump.from_carrier(bytes)
                }
            }
            PortEvent::Wrote(n) => pump.carrier_wrote(n as u64),
            PortEvent::Closed(why) => {
                pump.carrier_closed(Lost::new(why, true));
                Ok(())
            }
        };
        if let Err(error) = refused
            && !pump.is_ended()
        {
            // A port that broke the pump's rules: end the channel.
            pump.close(Lost::new(error.to_string(), false));
        }
    }
    if link.pump.is_ended() {
        return;
    }
    let bytes = link.pump.take_carrier_bytes();
    if !bytes.is_empty() {
        link.port.write(bytes);
    }
    let budget = link.pump.read_budget();
    if !link.reading && budget > 0 {
        link.port.read(budget);
        link.reading = true;
    }
}
