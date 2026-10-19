//! `mux-echo-lane-v1`: a terminal's keystroke echo travels on the
//! Interactive lane instead of behind other terminals' output on Bulk.
//!
//! Terminal output normally rides the Bulk lane, so the echo of a keystroke
//! in one pane queues behind every byte another pane is flooding: up to the
//! mux upload budget plus the session queue, tens of megabytes. With this
//! feature (the client opts in with the open metadata `mux-echo-lane: v1`),
//! the daemon sends the lines of a surface that had input in the last
//! [`ECHO_WINDOW`] (its output and other events, and replies to requests
//! about it) on the Interactive lane, up to [`ECHO_CREDIT`] bytes per input:
//! the echo, a prompt, a short command's output. A longer burst (a `cat`
//! started from that pane) goes back to Bulk.
//!
//! The receiver writes lines in arrival order, so moving one surface's lines
//! between lanes must never reorder them. The rule that keeps the order:
//! every line that names a surface rides that surface's current lane, and a
//! surface changes lanes only when none of its lines is queued or
//! unacknowledged on the old one. The peer acknowledges a frame only after
//! its session returned the frame to its single reader, which hands frames to
//! the stream in that order, so an acknowledged line is ahead of anything
//! sent after the acknowledgement on any lane. A reply to a request that
//! named a surface belongs to that surface. A line that names no surface (a
//! reply to a request without one, a loopback or agent stream line) stays on
//! Bulk and is a barrier in both directions: no surface moves to Interactive
//! while such a line is in flight, and such a line waits until no surface has
//! a line in flight on Interactive.
//!
//! A surface leaves the Interactive lane without blocking the reader: once
//! its credit or window is used up, its next lines stay on Interactive (up to
//! [`OVERFLOW_MAX`] bytes, about one round trip of output) until its last
//! Interactive line is acknowledged, then move to Bulk. Only an unscoped line
//! (or a surface past the overflow) waits, for about one round trip. While a
//! port forward or an agent stream keeps unscoped lines in flight behind a
//! flood, no surface can move to Interactive and echo rides Bulk as before.
//! Old clients never send the metadata and see no change; an old daemon
//! ignores it.

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_remote_protocol::Lane;
use serde::Deserialize;

use crate::service::ServiceStream;

/// Open metadata key and value a client sends to opt in.
pub(crate) const MUX_ECHO_LANE_METADATA: &str = "mux-echo-lane";
pub(crate) const MUX_ECHO_LANE_V1: &str = "v1";
/// Set to `0` on the client to not opt in (a kill switch and an A/B probe).
pub(crate) const MUX_ECHO_LANE_ENV: &str = "CMUX_REMOTE_MUX_ECHO_LANE";
/// Output this long after a surface's last input counts as its echo.
const ECHO_WINDOW: Duration = Duration::from_millis(500);
/// Output bytes one input lets its surface send on the Interactive lane.
const ECHO_CREDIT: usize = 64 * 1024;
/// Bytes a surface past its credit may still send on Interactive while its
/// earlier Interactive lines are unacknowledged.
const OVERFLOW_MAX: usize = 256 * 1024;
/// Surfaces tracked before idle entries are dropped.
const MAX_TRACKED_SURFACES: usize = 4096;

/// Whether a client opens mux control with the echo-lane opt-in.
pub(crate) fn client_opt_in() -> bool {
    std::env::var(MUX_ECHO_LANE_ENV).map_or(true, |value| value != "0")
}

/// The open metadata a client sends.
pub(crate) fn client_metadata() -> std::collections::BTreeMap<String, String> {
    let mut metadata = std::collections::BTreeMap::new();
    if client_opt_in() {
        metadata.insert(MUX_ECHO_LANE_METADATA.to_owned(), MUX_ECHO_LANE_V1.to_owned());
    }
    metadata
}

/// What a queued line is accounted under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Scope {
    /// Not part of the ordering rule (Control and Interactive replies).
    Untracked,
    /// A Bulk line that names no surface.
    Unscoped,
    Surface(u64),
}

/// Lines of one scope queued for or sent on one lane.
#[derive(Clone, Copy, Default)]
struct Flight {
    queued: usize,
    /// Session sequence of the last frame sent (0: none).
    last_sent: u64,
}

struct SurfaceState {
    lane: Lane,
    flight: Flight,
    input_at: Option<Instant>,
    /// Interactive-lane bytes left from the last input.
    credit: usize,
    /// Bytes sent on Interactive past the credit, waiting to move to Bulk.
    overflow: usize,
}

impl Default for SurfaceState {
    fn default() -> Self {
        Self { lane: Lane::Bulk, flight: Flight::default(), input_at: None, credit: 0, overflow: 0 }
    }
}

#[derive(Default)]
struct State {
    surfaces: HashMap<u64, SurfaceState>,
    unscoped: Flight,
    /// Request id to the surface the request named, until its reply.
    requests: HashMap<u64, u64>,
}

#[derive(Default)]
pub(crate) struct EchoLanes {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
}

#[derive(Deserialize)]
struct Envelope<'a> {
    #[serde(borrow, default)]
    event: Option<Cow<'a, str>>,
    #[serde(default)]
    surface: Option<serde_json::Value>,
    #[serde(default)]
    id: Option<serde_json::Value>,
}

/// What a line still waits for before it may be sent.
enum Pending {
    Nothing,
    Queued,
    Acknowledgement(u64),
}

impl EchoLanes {
    /// The echo lane for a mux control stream whose client opted in, when
    /// its endpoint tracks acknowledgements.
    pub(crate) async fn for_stream(
        stream: &ServiceStream,
        metadata: &std::collections::BTreeMap<String, String>,
    ) -> Option<Self> {
        let opted_in =
            metadata.get(MUX_ECHO_LANE_METADATA).map(String::as_str) == Some(MUX_ECHO_LANE_V1);
        (opted_in && stream.acknowledged(Lane::Bulk).await.is_some()).then(Self::default)
    }

    /// A client request line went to the mux server on `lane`: remember the
    /// surface it named, so its reply (routed here only when it is on Bulk,
    /// the request's lane) is ordered with that surface's lines.
    pub(crate) fn note_request(&self, line: &[u8], lane: Lane) {
        let Ok(envelope) = serde_json::from_slice::<Envelope<'_>>(line) else { return };
        let Some(id) = envelope.id.as_ref().and_then(serde_json::Value::as_u64) else { return };
        let mut state = self.state.lock().unwrap();
        // A reused id never inherits an older request's surface.
        state.requests.remove(&id);
        let Some(surface) = envelope.surface.as_ref().and_then(serde_json::Value::as_u64) else {
            return;
        };
        if lane != Lane::Bulk {
            return;
        }
        if state.requests.len() >= MAX_TRACKED_SURFACES {
            // An unknown reply is a barrier, so forgetting is safe.
            state.requests.clear();
        }
        state.requests.insert(id, surface);
    }

    pub(crate) fn note_input(&self, surface: u64) {
        let mut state = self.state.lock().unwrap();
        let s = state.surfaces.entry(surface).or_default();
        s.input_at = Some(Instant::now());
        s.credit = ECHO_CREDIT;
    }

    /// Chooses the lane for a server line the tracker put on Bulk and
    /// counts it as queued there. May wait (about one round trip) when the
    /// line must leave the Interactive lane.
    pub(crate) async fn route(
        &self,
        stream: &ServiceStream,
        line: &[u8],
        encoded_bytes: usize,
    ) -> (Lane, Scope) {
        let surface = match serde_json::from_slice::<Envelope<'_>>(line) {
            Ok(envelope) => match envelope.surface.as_ref().and_then(serde_json::Value::as_u64) {
                Some(surface) => Some(surface),
                // A reply: the surface of its request, if it named one.
                None if envelope.event.is_none() => envelope
                    .id
                    .as_ref()
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|id| self.state.lock().unwrap().requests.remove(&id)),
                None => None,
            },
            Err(_) => None,
        };
        let Some(surface) = surface else {
            self.wait(stream, None).await;
            let mut state = self.state.lock().unwrap();
            // Every surface that was on Interactive has drained there.
            for s in state.surfaces.values_mut() {
                if s.lane == Lane::Interactive {
                    s.lane = Lane::Bulk;
                    s.flight = Flight::default();
                }
            }
            state.unscoped.queued += 1;
            return (Lane::Bulk, Scope::Unscoped);
        };
        let bulk_acknowledged = stream.acknowledged(Lane::Bulk).await.unwrap_or(0);
        let interactive_acknowledged = stream.acknowledged(Lane::Interactive).await.unwrap_or(0);
        let leave = {
            let mut state = self.state.lock().unwrap();
            if state.surfaces.len() >= MAX_TRACKED_SURFACES
                && !state.surfaces.contains_key(&surface)
            {
                // Keep every entry whose lines are not all delivered: a
                // forgotten surface starts on Bulk with nothing in flight.
                state.surfaces.retain(|_, s| {
                    s.lane == Lane::Interactive
                        || !drained(s.flight, bulk_acknowledged)
                        || s.input_at.is_some_and(|at| at.elapsed() <= ECHO_WINDOW)
                });
            }
            let unscoped = state.unscoped;
            let s = state.surfaces.entry(surface).or_default();
            // Every line of the surface (output, scroll and resize events,
            // replies to requests about it) shares its lane and its credit.
            let echo = encoded_bytes <= s.credit
                && s.input_at.is_some_and(|at| at.elapsed() <= ECHO_WINDOW);
            match (s.lane, echo) {
                (Lane::Bulk, true) => {
                    if drained(s.flight, bulk_acknowledged) && drained(unscoped, bulk_acknowledged)
                    {
                        s.lane = Lane::Interactive;
                        s.flight = Flight::default();
                        s.overflow = 0;
                    }
                    false
                }
                (Lane::Interactive, false) => {
                    if drained(s.flight, interactive_acknowledged) {
                        s.lane = Lane::Bulk;
                        s.flight = Flight::default();
                        false
                    } else if s.overflow + encoded_bytes <= OVERFLOW_MAX {
                        // Stays on Interactive until its lines there are
                        // acknowledged; the reader does not wait.
                        s.overflow += encoded_bytes;
                        false
                    } else {
                        true
                    }
                }
                _ => false,
            }
        };
        if leave {
            self.wait(stream, Some(surface)).await;
            let mut state = self.state.lock().unwrap();
            let s = state.surfaces.entry(surface).or_default();
            s.lane = Lane::Bulk;
            s.flight = Flight::default();
        }
        let mut state = self.state.lock().unwrap();
        let s = state.surfaces.entry(surface).or_default();
        let lane = s.lane;
        s.flight.queued += 1;
        if lane == Lane::Interactive {
            s.credit = s.credit.saturating_sub(encoded_bytes);
        }
        (lane, Scope::Surface(surface))
    }

    /// A line of `scope` is on the wire; `sequence` is its last frame's.
    pub(crate) fn sent(&self, scope: Scope, sequence: u64) {
        {
            let mut state = self.state.lock().unwrap();
            let flight = match scope {
                Scope::Untracked => return,
                Scope::Unscoped => &mut state.unscoped,
                Scope::Surface(surface) => &mut state.surfaces.entry(surface).or_default().flight,
            };
            flight.queued = flight.queued.saturating_sub(1);
            flight.last_sent = flight.last_sent.max(sequence);
        }
        self.changed.notify_waiters();
    }

    /// Waits until `surface` (or, for `None`, every surface) has nothing
    /// queued or unacknowledged on the Interactive lane.
    async fn wait(&self, stream: &ServiceStream, surface: Option<u64>) {
        loop {
            let changed = self.changed.notified();
            let pending = {
                let state = self.state.lock().unwrap();
                let mut pending = Pending::Nothing;
                let on_interactive = state.surfaces.iter().filter(|(id, s)| {
                    s.lane == Lane::Interactive && surface.is_none_or(|wanted| **id == wanted)
                });
                for (_, s) in on_interactive {
                    if s.flight.queued > 0 {
                        pending = Pending::Queued;
                        break;
                    }
                    if s.flight.last_sent > 0 {
                        let needed = match pending {
                            Pending::Acknowledgement(seq) => seq.max(s.flight.last_sent),
                            _ => s.flight.last_sent,
                        };
                        pending = Pending::Acknowledgement(needed);
                    }
                }
                pending
            };
            match pending {
                Pending::Nothing => return,
                Pending::Queued => changed.await,
                Pending::Acknowledgement(sequence) => {
                    if stream.acknowledged(Lane::Interactive).await.unwrap_or(0) >= sequence {
                        return;
                    }
                    if !stream.wait_acknowledged(Lane::Interactive, sequence).await {
                        // Unreachable: the feature is enabled only for
                        // endpoints that track acknowledgements.
                        changed.await;
                    }
                }
            }
        }
    }
}

fn drained(flight: Flight, acknowledged: u64) -> bool {
    flight.queued == 0 && flight.last_sent <= acknowledged
}

/// Unsent bytes the kernel may hold on a CMXR TCP socket. Without a mark
/// the send buffer grows to megabytes of Bulk output, and a frame the lane
/// scheduler sends first (an echo) still waits behind all of it in the
/// kernel; with it the backlog stays in the session's lane queues, where
/// priority applies.
#[cfg(unix)]
pub(crate) const TCP_NOTSENT_LOWAT_BYTES: libc::c_int = 128 * 1024;

/// Sets [`TCP_NOTSENT_LOWAT_BYTES`] on a TCP socket (best effort).
#[cfg(unix)]
pub(crate) fn set_notsent_lowat(socket: &impl std::os::fd::AsRawFd) {
    #[cfg(target_os = "macos")]
    const TCP_NOTSENT_LOWAT: libc::c_int = 0x201;
    #[cfg(target_os = "linux")]
    const TCP_NOTSENT_LOWAT: libc::c_int = libc::TCP_NOTSENT_LOWAT;
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let value = TCP_NOTSENT_LOWAT_BYTES;
        // SAFETY: setsockopt with a valid c_int on a live socket.
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_TCP,
                TCP_NOTSENT_LOWAT,
                (&raw const value).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let _ = socket;
}
