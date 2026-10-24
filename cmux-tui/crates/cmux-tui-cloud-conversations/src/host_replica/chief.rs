//! The Home Chief chat stream of the host replica publisher (a450,
//! cmux-prompts logs/iphone-chief-DESIGN.md), split from host_replica.rs for
//! the god-file budget: snapshots only, each the whole bounded copy.

use serde_json::{Value, json};

use super::super::service::CloudWire;
use super::{CHIEF_STREAM_SUFFIX, Driver, MAX_STATE_BYTES, Phase, Use, chief_stream_of, stream_of};

impl Driver {
    /// Publishes the Chief copy as a new snapshot when it changed (or `force`).
    pub(super) fn publish_chief(
        &mut self,
        stream: &str,
        wire: &mut dyn CloudWire,
        force: bool,
    ) -> Result<(), String> {
        let Some(state) = self.source.chief_state() else { return Ok(()) };
        let text = state.to_string();
        if !force && self.chief_last.as_deref() == Some(text.as_str()) {
            return Ok(());
        }
        if text.len() > MAX_STATE_BYTES {
            self.inner.set_phase(
                Phase::Online,
                Some(format!("chief_state_too_large: {} bytes", text.len())),
            );
            return Ok(());
        }
        self.chief_seq += 1;
        let frame = json!({ "t": "publish", "stream": stream, "snapshot": {
            "t": "snapshot", "stream": stream, "seq": self.chief_seq, "state": state, "decided": [] } });
        wire.send(&frame.to_string()).map_err(|error| error.0)?;
        self.chief_last = Some(text);
        Ok(())
    }

    /// Publishes the change of `stream` after a forwarded op; returns its seq.
    pub(super) fn publish_after_op(
        &mut self,
        lease: &Use,
        stream: &str,
        wire: &mut dyn CloudWire,
    ) -> Result<u64, String> {
        // The change flag was cleared for this op: the other stream is checked too.
        let host =
            stream.strip_prefix("host:").and_then(|rest| rest.split('/').next()).unwrap_or("");
        if stream.ends_with(&format!("/{CHIEF_STREAM_SUFFIX}")) {
            self.publish_chief(stream, wire, false)?;
            self.publish(lease, &stream_of(host), wire, false)?;
            return Ok(self.chief_seq);
        }
        self.publish(lease, stream, wire, false)?;
        self.publish_chief(&chief_stream_of(host), wire, false)?;
        Ok(self.inner.lock().published_seq)
    }

    /// A `snapshot.request` for the Chief stream: a reader's pending keys, or the replica's own.
    pub(super) fn chief_snapshot_request(
        &mut self,
        stream: &str,
        wire: &mut dyn CloudWire,
        frame: &Value,
    ) -> Result<(), String> {
        if let Some(to) = frame["to"].as_str() {
            let pending: Vec<&str> = frame["pending"]
                .as_array()
                .map(|keys| keys.iter().filter_map(Value::as_str).take(1000).collect())
                .unwrap_or_default();
            let decided: Vec<Value> = pending
                .iter()
                .filter_map(|key| {
                    self.decided.get(key).map(
                        |a| json!({ "idempotency_key": key, "ok": a.ok, "sequence": a.sequence }),
                    )
                })
                .collect();
            let Some(state) =
                self.chief_last.as_deref().and_then(|t| serde_json::from_str::<Value>(t).ok())
            else {
                return Ok(());
            };
            let answer = json!({ "t": "snapshot", "to": to, "stream": stream, "seq": self.chief_seq,
                        "state": state, "decided": decided });
            return wire.send(&answer.to_string()).map_err(|error| error.0);
        }
        self.publish_chief(stream, wire, true)
    }
}
