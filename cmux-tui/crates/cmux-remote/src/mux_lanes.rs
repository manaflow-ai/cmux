use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use cmux_remote_protocol::Lane;
use serde::Deserialize;
use sha2::{Digest, Sha256};

const MAX_TRACKED_REQUESTS: usize = 4096;

#[derive(Default)]
pub(crate) struct MuxLaneTracker {
    state: Mutex<MuxLaneState>,
}

#[derive(Default)]
struct MuxLaneState {
    requests: HashMap<MuxId, TrackedResponse>,
    order: VecDeque<(MuxId, u64)>,
    next_token: u64,
}

#[derive(Clone, Copy)]
struct TrackedResponse {
    disposition: ResponseDisposition,
    token: u64,
}

#[derive(Clone, Copy)]
enum ResponseDisposition {
    Forward(Lane),
    Suppress,
}

// Keep the reply table bounded in bytes as well as entries: a peer's string
// id can be as large as its request line. Hash the decoded string, so escaped
// and literal spellings match, while numbers keep their allocation-free path.
#[derive(Clone, Copy, Eq, Hash, PartialEq)]
enum MuxId {
    Number(u64),
    Negative(i64),
    Text([u8; 32]),
}

impl<'de> Deserialize<'de> for MuxId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct IdVisitor;

        impl serde::de::Visitor<'_> for IdVisitor {
            type Value = MuxId;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an integer or string mux request id")
            }

            fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<MuxId, E> {
                Ok(MuxId::Number(value))
            }

            fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<MuxId, E> {
                Ok(match u64::try_from(value) {
                    Ok(value) => MuxId::Number(value),
                    Err(_) => MuxId::Negative(value),
                })
            }

            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<MuxId, E> {
                Ok(MuxId::Text(Sha256::digest(value.as_bytes()).into()))
            }
        }

        deserializer.deserialize_any(IdVisitor)
    }
}

struct MuxName<'a>(Cow<'a, str>);

impl MuxName<'_> {
    fn as_str(&self) -> &str {
        self.0.as_ref()
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for MuxName<'a> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct MuxNameVisitor<'a>(std::marker::PhantomData<&'a ()>);

        impl<'de: 'a, 'a> serde::de::Visitor<'de> for MuxNameVisitor<'a> {
            type Value = MuxName<'a>;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a mux protocol name")
            }

            fn visit_borrowed_str<E>(self, value: &'de str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Borrowed(value)))
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Owned(value.to_owned())))
            }

            fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Owned(value)))
            }
        }

        deserializer.deserialize_str(MuxNameVisitor(std::marker::PhantomData))
    }
}

#[derive(Deserialize)]
struct MuxEnvelope<'a> {
    id: Option<MuxId>,
    #[serde(borrow)]
    cmd: Option<MuxName<'a>>,
    #[serde(borrow)]
    event: Option<MuxName<'a>>,
    #[serde(borrow)]
    scope: Option<MuxName<'a>>,
    #[serde(borrow)]
    mode: Option<MuxName<'a>>,
    #[serde(borrow)]
    op: Option<MuxName<'a>>,
}

fn parse_envelope(line: &[u8]) -> Result<MuxEnvelope<'_>, serde_json::Error> {
    serde_json::from_slice(line)
}

impl MuxLaneTracker {
    pub(crate) fn observe_request(&self, line: &[u8], lane: Lane) {
        let Ok(envelope) = parse_envelope(line) else { return };
        if let Some(id) = envelope.id {
            self.track(id, ResponseDisposition::Forward(lane));
        }
    }

    pub(crate) fn suppress_response(&self, id: u64) {
        self.track(MuxId::Number(id), ResponseDisposition::Suppress);
    }

    pub(crate) fn classify_server_line(&self, line: &[u8]) -> Option<Lane> {
        let Ok(envelope) = parse_envelope(line) else {
            return Some(Lane::Control);
        };
        if let Some(event) = envelope.event.as_ref().map(MuxName::as_str) {
            return Some(match event {
                // A snapshot viewer's READY and history pages (`snapshot`) and
                // its idle drift check (`digest`) are cut at one generation
                // and offset of the same byte stream as `output`. On another
                // lane, output tagged with the new generation can overtake its
                // READY, pass the app's generation check, and then be wiped
                // when the READY lands: bytes printed just after a reconnect
                // vanish. One ordered lane keeps the cut and the bytes after
                // it in host order.
                "snapshot" | "digest" => Lane::Bulk,
                "output" | "vt-state" | "render-state" | "render-delta" | "frame"
                | "browser-state" | "resized" | "colors-changed" | "scroll-changed"
                | "detached" => Lane::Bulk,
                // Forwarded loopback bytes and their stream lifecycle stay in
                // one ordered lane, away from keystrokes and control replies.
                name if name.starts_with("loopback-") => Lane::Bulk,
                // Agent session records and the attachment's close follow
                // the attach reply in one ordered lane (they can be large).
                name if name.starts_with("agent-session-") => Lane::Bulk,
                "overflow" if envelope.scope.as_ref().map(MuxName::as_str) == Some("surface") => {
                    Lane::Bulk
                }
                _ => Lane::Control,
            });
        }
        match envelope
            .id
            .and_then(|id| {
                self.state.lock().unwrap_or_else(PoisonError::into_inner).requests.remove(&id)
            })
            .map(|tracked| tracked.disposition)
        {
            Some(ResponseDisposition::Forward(lane)) => Some(lane),
            Some(ResponseDisposition::Suppress) => None,
            None => Some(Lane::Control),
        }
    }

    fn track(&self, id: MuxId, disposition: ResponseDisposition) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.next_token == u64::MAX {
            state.requests.clear();
            state.order.clear();
            state.next_token = 0;
        }
        state.next_token += 1;
        let token = state.next_token;
        state.requests.insert(id, TrackedResponse { disposition, token });
        state.order.push_back((id, token));

        while state.order.len() > MAX_TRACKED_REQUESTS {
            let Some((old_id, old_token)) = state.order.pop_front() else { break };
            if state.requests.get(&old_id).is_some_and(|tracked| tracked.token == old_token) {
                state.requests.remove(&old_id);
            }
        }
    }
}

pub(crate) fn classify_client_line(line: &[u8]) -> Lane {
    let Ok(envelope) = parse_envelope(line) else { return Lane::Control };
    match envelope.cmd.as_ref().map(MuxName::as_str) {
        Some("paste-image") if envelope.op.as_ref().map(MuxName::as_str) == Some("commit") => {
            Lane::Interactive
        }
        // Image transactions acknowledge every chunk before commit, so they can
        // use bulk backpressure without delaying interactive keys or reordering paste.
        Some("attach-surface" | "read-screen" | "read-scrollback" | "vt-state" | "paste-image") => {
            Lane::Bulk
        }
        Some("copy") if envelope.mode.as_ref().map(MuxName::as_str) == Some("scrollback") => {
            Lane::Bulk
        }
        // `loopback-forward-v1`: open, data, credit and close of one stream
        // must stay ordered, and forwarded bytes must never queue ahead of
        // PTY input, so every loopback command uses the bulk lane.
        Some(name) if name.starts_with("loopback-") => Lane::Bulk,
        // `agent-session-attach-v1`: the attach reply, the replay pages and
        // the live records of one attachment stay in one ordered lane, so a
        // record never overtakes the reply it follows.
        Some(name) if name.starts_with("agent-session-") => Lane::Bulk,
        // `agent-transfer-v1`: bundle pages of up to 4 MiB never queue ahead
        // of PTY input.
        Some(name) if name.starts_with("agent-transfer-") => Lane::Bulk,
        // Read-only lookups never wait behind PTY input or a slow mutation
        // commit; a stalled Interactive lane must not make a live terminal
        // look missing to the client resolving it.
        Some(
            "identify" | "ping" | "list-clients" | "list-workspaces" | "export-layout" | "wait-for"
            | "ids" | "list-agents" | "pane-neighbor" | "process-info" | "terminal-ports"
            | "terminal-resources" | "subscribe" | "resolve-terminal",
        ) => Lane::Control,
        // A projection's dial (`projection-v1`): its line, then its manifest and the Mac's
        // answers as non-JSON lines, which go on the control lane; the line goes with them so
        // the manifest never overtakes it.
        Some("projection.serve") => Lane::Control,
        // Mutations default to one ordered lane with compact PTY input. This
        // keeps a later close, move, focus, resize, or configuration change
        // from overtaking input already accepted from the local mux client.
        Some(_) => Lane::Interactive,
        None => Lane::Control,
    }
}

#[cfg(test)]
#[path = "mux_lanes_tests.rs"]
mod tests;
