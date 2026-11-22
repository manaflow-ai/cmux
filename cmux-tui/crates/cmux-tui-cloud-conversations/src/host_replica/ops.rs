//! Forwarded ops and the off switch of the host replica publisher
//! (split from host_replica.rs for the god-file budget).

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::Ordering;
use std::time::Instant;

use serde_json::{Map, Value, json};

use super::super::service::{CloudWire, WireRecv};
use super::{DECIDED_KEYS, Driver, Ended, MAX_KEY_CHARS, Phase, Use};
use cmux_json::JsonSet as _;

/// One decided forwarded op: its answer frames without `to`.
#[derive(Clone)]
pub(super) struct Answer {
    pub(super) ok: bool,
    pub(super) sequence: u64,
    frames: Vec<Value>,
}

#[derive(Default)]
pub(super) struct Decided {
    order: VecDeque<String>,
    answers: HashMap<String, Answer>,
}

impl Decided {
    pub(super) fn get(&self, key: &str) -> Option<&Answer> {
        self.answers.get(key)
    }

    fn put(&mut self, key: String, answer: Answer) {
        if self.answers.insert(key.clone(), answer).is_none() {
            self.order.push_back(key);
        }
        while self.order.len() > DECIDED_KEYS {
            if let Some(old) = self.order.pop_front() {
                self.answers.remove(&old);
            }
        }
    }
}

impl Driver {
    pub(super) fn on_op(
        &mut self,
        lease: &Use,
        stream: &str,
        wire: &mut dyn CloudWire,
        frame: &Value,
    ) -> Result<(), String> {
        let Some(to) = frame["to"].as_str() else { return Ok(()) };
        let key = frame["idempotency_key"].as_str().unwrap_or("");
        let send = |wire: &mut dyn CloudWire, frames: &[Value]| -> Result<(), String> {
            for f in frames {
                let mut f = f.clone();
                f.set("to", json!(to));
                wire.send(&f.to_string()).map_err(|error| error.0)?;
            }
            Ok(())
        };
        if key.is_empty() || key.len() > MAX_KEY_CHARS {
            // Answered (so the reader does not wait) and never recorded.
            let tx = self.inner.tx();
            return send(
                wire,
                &[
                    json!({ "t": "reject", "tx": tx, "stream": stream, "idempotency_key": key, "code": "validation.invalid",
                            "message": format!("idempotency_key must be 1-{MAX_KEY_CHARS} characters"), "retryable": false, "replayed": false }),
                    json!({ "t": "request-settled", "tx": tx, "idempotency_key": key, "stream": stream, "sequence": 0, "ok": false }),
                ],
            );
        }
        if let Some(answer) = self.decided.get(key) {
            let mut frames = answer.frames.clone();
            for f in &mut frames {
                if f["t"] == "result" || f["t"] == "reject" {
                    f["replayed"] = json!(true);
                }
            }
            return send(wire, &frames);
        }
        let tx = self.inner.tx();
        let refuse = |code: &str, message: String, retryable: bool| Answer {
            ok: false,
            sequence: 0,
            frames: vec![
                json!({ "t": "reject", "tx": tx, "stream": stream, "idempotency_key": key, "code": code,
                        "message": message, "retryable": retryable, "replayed": false }),
                json!({ "t": "request-settled", "tx": tx, "idempotency_key": key, "stream": stream, "sequence": 0, "ok": false }),
            ],
        };
        let principal_user = frame["principal"]["user"].as_str().unwrap_or("");
        let answer = if frame["stream"].as_str() != Some(stream) {
            refuse("validation.invalid", "not a stream of this host".into(), false)
        } else if principal_user != lease.user || !frame["principal"]["agent"].is_null() {
            // HostDO admits only the owner; the host checks again.
            refuse("auth.forbidden", "only the host's owner may change it".into(), false)
        } else {
            let op = frame["op"].as_str().unwrap_or("");
            let params = frame.get("params").cloned().unwrap_or_else(|| Value::Object(Map::new()));
            match self.source.apply(op, &params, key, principal_user) {
                Ok(value) => {
                    // The change is published before the answer, so the settle names its seq.
                    self.inner.changed.store(false, Ordering::Release);
                    let sequence = self.publish_after_op(lease, stream, wire)?;
                    Answer {
                        ok: true,
                        sequence,
                        frames: vec![
                            json!({ "t": "result", "tx": tx, "idempotency_key": key, "value": value,
                                    "revision": sequence.to_string(), "replayed": false }),
                            json!({ "t": "request-settled", "tx": tx, "idempotency_key": key, "stream": stream, "sequence": sequence, "ok": true }),
                        ],
                    }
                }
                Err(refusal) => refuse(&refusal.code, refusal.message, refusal.retryable),
            }
        };
        let retryable_refusal = answer.frames[0]["retryable"] == true;
        send(wire, &answer.frames)?;
        // A retryable refusal decides nothing: the same key may run later.
        if !retryable_refusal {
            self.decided.put(key.to_string(), answer);
        }
        Ok(())
    }

    /// The off switch: `replica.purge`, wait for `replica.purged`, drop the lease.
    pub(super) fn purge(&mut self, lease: &Use, wire: &mut dyn CloudWire) -> Ended {
        self.inner.set_phase(Phase::Purging, None);
        if let Err(error) = wire.send(&json!({ "t": "replica.purge" }).to_string()) {
            return Ended::Dropped(error.0);
        }
        let deadline = Instant::now() + self.inner.options.purge_timeout;
        while Instant::now() < deadline {
            match wire.recv(self.inner.options.poll) {
                WireRecv::Text(text) => {
                    let frame = serde_json::from_str::<Value>(&text).unwrap_or(Value::Null);
                    if frame["t"] == "replica.purged" {
                        let mut state = self.inner.lock();
                        if state.lease.as_ref().map(|l| l.generation) == Some(lease.generation) {
                            state.lease = None;
                        }
                        state.purge = false;
                        state.host = None;
                        // The seq stays: it never goes back in this daemon.
                        state.published_seq = 0;
                        state.phase = Phase::Off;
                        self.last_state = None;
                        return Ended::Purged;
                    }
                    if frame["t"] == "op"
                        && let Some(to) = frame["to"].as_str()
                    {
                        // An op that arrives while the replica turns off is not run.
                        let key = frame["idempotency_key"].as_str().unwrap_or("");
                        let stream = frame["stream"].as_str().unwrap_or("");
                        let tx = self.inner.tx();
                        for f in [
                            json!({ "t": "reject", "to": to, "tx": tx, "stream": stream, "idempotency_key": key, "code": "owner_unreachable",
                                    "message": "the host is turning the replica off", "retryable": true, "replayed": false }),
                            json!({ "t": "request-settled", "to": to, "tx": tx, "idempotency_key": key, "stream": stream, "sequence": 0, "ok": false }),
                        ] {
                            if let Err(error) = wire.send(&f.to_string()) {
                                return Ended::Dropped(error.0);
                            }
                        }
                    }
                }
                WireRecv::Idle => {}
                WireRecv::Closed { code } => return self.closed(lease, code),
            }
        }
        Ended::Dropped("replica.purge was not confirmed".into())
    }
}
