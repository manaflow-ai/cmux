//! Part of `Hub`; see `hub/mod.rs`. The tap that logs one session's wire
//! traffic into its event log.

use super::*;

impl Hub {
    /// Make sure a live child process exists for the session. Spawns, runs
    /// `initialize`, and either creates or loads the agent session.
    /// The tap that logs one session's wire traffic (and the agent host
    /// entry each record logs, `hostSeq`).
    pub(super) fn session_tap(self: &Arc<Self>, session: &Arc<Session>) -> crate::agent::Tap {
        let tap_session = session.clone();
        let tap_hub = self.clone();
        Arc::new(move |dir: Direction, msg: &Message, host_seq: Option<u64>| -> bool {
            let (d, kind) = match (dir, msg) {
                // Agent host stderr and exit entries: logged here, in entry
                // order, before the entry is acknowledged.
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_STDERR =>
                {
                    let text = params.as_ref().and_then(|p| p.get("text")).cloned();
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            "stderr",
                            json!({"text": text}),
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_EXIT =>
                {
                    let code = params.as_ref().and_then(|p| p.get("code")).cloned();
                    let intentional =
                        matches!(tap_session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            json!({"code": code}),
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params }) => {
                    let mut kind = method.clone();
                    if method.starts_with("claude.") {
                        // Raw stream-json line; translated messages follow.
                        return tap_hub
                            .append_logged(
                                &tap_session,
                                "in",
                                &kind,
                                params.clone().unwrap_or(Value::Null),
                                host_seq,
                            )
                            .1;
                    }
                    if method == crate::rpc::method::SESSION_UPDATE {
                        if let Some(su) = params
                            .as_ref()
                            .and_then(|p| p.get("update"))
                            .and_then(|u| u.get("sessionUpdate"))
                            .and_then(Value::as_str)
                        {
                            kind = su.to_owned();
                        }
                        if tap_session.loading.load(Ordering::SeqCst) {
                            kind.push_str(".replay");
                        }
                    }
                    ("in", kind)
                }
                (Direction::In, Message::Request { method, .. }) => ("in", method.clone()),
                (Direction::In, Message::Response { .. }) => ("in", "response".to_owned()),
                (Direction::Out, Message::Request { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Notification { method, params })
                    if method == "claude.stdin" =>
                {
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "out",
                            "claude.stdin",
                            params.clone().unwrap_or(Value::Null),
                            host_seq,
                        )
                        .1;
                }
                (Direction::Out, Message::Notification { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Response { .. }) => ("out", "response".to_owned()),
            };
            // Live agent updates (not a session/load replay) also feed the
            // stream watcher, which may record `message_superseded` first.
            let live_update = d == "in"
                && !kind.ends_with(".replay")
                && msg.method() == Some(crate::rpc::method::SESSION_UPDATE);
            if live_update {
                tap_hub.before_agent_update(&tap_session, msg.params());
            }
            let (rec, logged) =
                tap_hub.append_logged(&tap_session, d, &kind, msg.to_value(), host_seq);
            if live_update {
                tap_hub.after_agent_update(&tap_session, &rec);
            }
            logged
        })
    }
}
