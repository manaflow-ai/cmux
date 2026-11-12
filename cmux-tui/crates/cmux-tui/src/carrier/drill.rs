//! The fault drill ([`run_drill`]): a turn's events over a session's
//! carriers, the kill of the first carrier after the fault's event count,
//! the resume on the next one from the last acpmux seq the client had, and
//! the [`Drill`] record the probe's judge reads.
// The turn's event source over the carriers lands with plan slice S1 (the
// Cloud dial on the route runner); until then only the tests drive the drill.
#![cfg_attr(
    not(test),
    allow(dead_code, reason = "the event source over the carriers lands with plan slice S1")
)]

use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::time::Instant;

use super::fault::{DrillError, FaultPlan, FaultSpec, Route};

/// One event of the turn, as the machine's acpmux numbered it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TurnEvent {
    pub seq: u64,
    /// The turn's last event.
    pub last: bool,
}

/// The turn's events over one carrier.
#[async_trait]
pub(crate) trait EventStream: Send {
    /// The next event; `None` when the stream ended, `Err` when it broke.
    async fn next(&mut self) -> Option<Result<TurnEvent, String>>;
    /// Kills the carrier under this stream (the fault).
    async fn kill(self: Box<Self>);
}

/// Opens the turn's event stream on a carrier.
#[async_trait]
pub(crate) trait EventRoutes: Send {
    /// The stream on carrier `index` of the plan (`route`), with every event
    /// after `after_seq` (acpmux's `afterSeq`; `None`: from the turn's start).
    async fn open(
        &mut self,
        index: usize,
        route: Route,
        after_seq: Option<u64>,
    ) -> Result<Box<dyn EventStream>, String>;
}

/// The drill record, in the shape the probe's judge reads.
#[derive(Debug)]
pub(crate) struct Drill {
    spec: FaultSpec,
    capabilities: Value,
    began: Instant,
    /// No stamp is earlier than this: every time is on one clock and in
    /// arrival order, and the kill is strictly after the event before it.
    floor: u64,
    kill: Option<Value>,
    events: Vec<Value>,
    resumes: Vec<Value>,
}

impl Drill {
    pub(crate) fn new(spec: FaultSpec, capabilities: Value) -> Self {
        Self {
            spec,
            capabilities,
            began: Instant::now(),
            floor: 0,
            kill: None,
            events: Vec::new(),
            resumes: Vec::new(),
        }
    }

    fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.began.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn stamp(&mut self) -> u64 {
        self.floor = self.floor.max(self.elapsed_ms());
        self.floor
    }

    fn event(&mut self, route: Route, event: TurnEvent) {
        let at = self.stamp();
        let mut row = json!({"seq": event.seq, "route": route.name(), "at_ms": at});
        if event.last
            && let Some(object) = row.as_object_mut()
        {
            object.insert("final".into(), json!(true));
        }
        self.events.push(row);
    }

    fn killed(&mut self, route: Route) {
        // Strictly after the last event, so the judge reads that event as
        // the relay's, before the kill.
        let at = self.elapsed_ms().max(self.floor.saturating_add(1));
        self.floor = at;
        self.kill = Some(json!({"route": route.name(), "at_ms": at}));
    }

    fn opened(
        &mut self,
        route: Route,
        phase: &str,
        outcome: Result<(), &str>,
        from_seq: Option<u64>,
        took: Duration,
    ) {
        let ms = u64::try_from(took.as_millis()).unwrap_or(u64::MAX);
        let mut row = json!({"route": route.name(), "phase": phase, "ms": ms,
                             "outcome": outcome.err().unwrap_or("ok")});
        if let (Some(from), Some(object)) = (from_seq, row.as_object_mut()) {
            object.insert("from_seq".into(), json!(from));
        }
        self.resumes.push(row);
    }

    /// `{capabilities, fault, kill, events, resumes}`.
    pub(crate) fn json(&self) -> Value {
        let capabilities = json!({
            "routes": self.capabilities.get("routes").cloned().unwrap_or_else(|| json!([])),
            "faults": self.capabilities.get("faults").cloned().unwrap_or_else(|| json!([])),
        });
        json!({
            "capabilities": capabilities,
            "fault": self.spec.json(),
            "kill": self.kill.clone().unwrap_or(Value::Null),
            "events": self.events,
            "resumes": self.resumes,
        })
    }

    fn fail(&self, code: &'static str, message: impl Into<String>) -> DrillError {
        DrillError { code, message: message.into(), record: self.json() }
    }
}

/// Runs one drill by `deadline`: the turn's events from carrier 0, the kill
/// of that carrier after `after_events` events, then the next carrier from
/// the last seq the client had, until the turn's last event. `Ok` is the
/// record of a turn that ended; any other end is a typed [`DrillError`]
/// with the record so far, never a hang.
pub(crate) async fn run_drill(
    plan: &FaultPlan,
    routes: &mut dyn EventRoutes,
    capabilities: Value,
    deadline: Instant,
) -> Result<Value, DrillError> {
    let mut drill = Drill::new(plan.spec, capabilities);
    let ended = tokio::time::timeout_at(deadline, drive(plan, routes, &mut drill)).await;
    match ended {
        Ok(Ok(())) => Ok(drill.json()),
        Ok(Err((code, message))) => Err(drill.fail(code, message)),
        Err(_) => Err(drill.fail(
            "carrier_fault.timeout",
            "the drill did not reach the turn's last event before the deadline",
        )),
    }
}

async fn drive(
    plan: &FaultPlan,
    routes: &mut dyn EventRoutes,
    drill: &mut Drill,
) -> Result<(), (&'static str, String)> {
    let mut index = 0;
    let mut route =
        plan.candidates.first().copied().ok_or(("carrier_fault.no_route", String::new()))?;
    let opened = Instant::now();
    let mut stream = match routes.open(index, route, None).await {
        Ok(stream) => stream,
        Err(why) => {
            drill.opened(route, "connect", Err("error"), None, opened.elapsed());
            return Err(("carrier_fault.connect_failed", why));
        }
    };
    drill.opened(route, "connect", Ok(()), None, opened.elapsed());
    let (mut delivered, mut last_seq, mut killed) = (0_u32, None::<u64>, false);
    loop {
        let event = match stream.next().await {
            Some(Ok(event)) => event,
            Some(Err(why)) => return Err(("carrier_fault.stream_failed", why)),
            None => {
                return Err((
                    "carrier_fault.stream_ended",
                    format!("the {} stream ended before the turn's last event", route.name()),
                ));
            }
        };
        // A replayed event the client already has is not delivered twice.
        if last_seq.is_some_and(|last| event.seq <= last) {
            continue;
        }
        drill.event(route, event);
        last_seq = Some(event.seq);
        delivered = delivered.saturating_add(1);
        if event.last {
            return Ok(());
        }
        if killed || delivered < plan.spec.after_events {
            continue;
        }
        killed = true;
        stream.kill().await;
        drill.killed(route);
        index = index.saturating_add(1);
        let Some(next) = plan.candidates.get(index).copied() else {
            return Err((
                "carrier_fault.no_other_route",
                "no carrier was left after the kill".into(),
            ));
        };
        route = next;
        let from = last_seq.map_or(1, |seq| seq.saturating_add(1));
        let opened = Instant::now();
        stream = match routes.open(index, route, last_seq).await {
            Ok(stream) => stream,
            Err(why) => {
                drill.opened(route, "resume", Err("error"), Some(from), opened.elapsed());
                return Err(("carrier_fault.resume_failed", why));
            }
        };
        drill.opened(route, "resume", Ok(()), Some(from), opened.elapsed());
    }
}
