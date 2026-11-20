//! Automatic work uses a bounded, priority-ordered admission queue after outages. Fresh
//! user prompts do not use it. A durable pause holds automatic work across daemon restarts.
use super::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use tokio::time::{Duration, Instant};

const WIDTH: usize = 4;
const SPACING: Duration = Duration::from_secs(1);
const WAIT_LIMIT: Duration = Duration::from_secs(3600);

pub(super) struct Admission {
    state: StdMutex<State>,
    path: Option<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub(super) enum Binding {
    Authority { id: String },
    Member { peer: String, id: String },
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Durable {
    paused: Option<String>,
    #[serde(default)]
    binding: Option<Binding>,
    #[serde(default)]
    reservations: BTreeSet<String>,
}

struct State {
    durable: Durable,
    sequence: u64,
    waiting: BTreeMap<(u8, u64), Arc<Notify>>,
    active: usize,
    next: Instant,
}

impl Admission {
    pub(super) fn open(home: Option<&std::path::Path>) -> Self {
        let path = home.map(|h| h.join("resume-admission.json"));
        let durable = path
            .as_ref()
            .map(|p| match std::fs::read(p) {
                Ok(bytes) => serde_json::from_slice::<Durable>(&bytes)
                    .or_else(|_| {
                        // Upgrade the first version's pause-only file without releasing its hold.
                        serde_json::from_slice::<Option<String>>(&bytes)
                            .map(|paused| Durable { paused, ..Default::default() })
                    })
                    .unwrap_or_else(|e| Durable {
                        paused: Some(format!("resume admission state is unreadable: {e}")),
                        ..Default::default()
                    }),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Durable::default(),
                Err(e) => Durable {
                    paused: Some(format!("resume admission state is unreadable: {e}")),
                    ..Default::default()
                },
            })
            .unwrap_or_default();
        let active = durable.reservations.len();
        let next =
            Instant::now() + if durable.binding.is_some() { SPACING } else { Duration::ZERO };
        Self {
            path,
            state: StdMutex::new(State {
                durable,
                sequence: 0,
                waiting: BTreeMap::new(),
                active,
                next,
            }),
        }
    }

    pub(crate) fn pause(&self, reason: Option<&str>) -> Result<(), RpcError> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = state.durable.clone();
        next.paused = reason.map(str::to_owned);
        self.persist(&next)?;
        state.durable = next;
        wake_first(&state);
        Ok(())
    }

    fn persist(&self, next: &Durable) -> Result<(), RpcError> {
        if let Some(path) = &self.path {
            let bytes = serde_json::to_vec(next).map_err(|e| RpcError::internal(e.to_string()))?;
            crate::config::write_atomic(path, &bytes)
                .map_err(|e| RpcError::internal(e.to_string()))?;
        }
        Ok(())
    }

    pub(super) fn binding(&self) -> Option<Binding> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).durable.binding.clone()
    }

    pub(super) fn bind(&self, binding: Binding) -> Result<(), RpcError> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = &state.durable.binding {
            return if old == &binding {
                Ok(())
            } else {
                Err(RpcError::invalid_params(
                    "fleet authority is already pinned; rebinding is refused",
                ))
            };
        }
        if state.active != 0 || !state.waiting.is_empty() {
            return Err(RpcError::invalid_params(
                "pause and drain local recovery before fleet binding",
            ));
        }
        let mut next = state.durable.clone();
        next.binding = Some(binding);
        // Enrolling an authority never releases work. Only its explicit fleet-resume does.
        next.paused = Some("fleet enrollment: verify every member before release".into());
        self.persist(&next)?;
        state.durable = next;
        Ok(())
    }

    pub(super) fn authority_status(&self, expected: Option<&str>) -> Result<Value, RpcError> {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let Some(Binding::Authority { id }) = &state.durable.binding else {
            return Err(RpcError::invalid_params("this daemon is not a fleet admission authority"));
        };
        if expected.is_some_and(|expected| expected != id) {
            return Err(RpcError::invalid_params(
                "fleet authority identity changed; admission refused",
            ));
        }
        Ok(json!({"authorityId": id, "paused": state.durable.paused,
            "reservations": state.durable.reservations, "waiting": state.waiting.len(),
            "width": WIDTH, "spacingMs": SPACING.as_millis() as u64}))
    }

    /// Transfer an in-memory permit to durable occupancy before replying. Neither a lost
    /// reply, a disconnected member nor a restarted authority frees it. No TTL can prove
    /// that a remote harness stopped; only the member's completed prompt releases it.
    pub(super) async fn reserve(&self, ticket: &str, priority: u8) -> Result<(), RpcError> {
        if uuid::Uuid::parse_str(ticket).is_err() {
            return Err(RpcError::invalid_params("fleet ticket must be a UUID"));
        }
        let mut permit = self.enter(priority).await?;
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = state.durable.clone();
        if !next.reservations.insert(ticket.to_owned()) {
            return Err(RpcError::invalid_params("fleet ticket already reserved"));
        }
        self.persist(&next)?;
        state.durable = next;
        permit.active = false;
        Ok(())
    }

    pub(super) fn release(&self, ticket: &str) -> Result<(), RpcError> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = state.durable.clone();
        if next.reservations.remove(ticket) {
            self.persist(&next)?;
            state.durable = next;
            state.active -= 1;
            wake_first(&state);
        }
        Ok(())
    }

    pub(super) fn recovering(&self) -> bool {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.durable.paused.is_some()
            || !state.waiting.is_empty()
            || state.active > 0
            || Instant::now() < state.next
    }

    pub(super) fn start<T>(
        &self,
        person: bool,
        start: impl FnOnce() -> Result<T, RpcError>,
    ) -> Result<T, RpcError> {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match &state.durable.paused {
            _ if matches!(state.durable.binding, Some(Binding::Member { .. })) => start(),
            _ if person => start(),
            None => start(),
            Some(reason) => Err(RpcError::invalid_params(format!(
                "fleet resume is paused: {reason}"
            ))
            .with_data(
                json!({"reason": "fleet.paused", "next": "acpmux fleet-resume --reason REASON"}),
            )),
        }
    }

    pub(super) async fn enter(&self, priority: u8) -> Result<Permit<'_>, RpcError> {
        let changed = Arc::new(Notify::new());
        let key = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            state.sequence += 1;
            let key = (priority, state.sequence);
            state.waiting.insert(key, changed.clone());
            wake_first(&state);
            key
        };
        let mut permit = Permit { admission: self, key, active: false };
        let deadline = Instant::now() + WAIT_LIMIT;
        loop {
            let changed = changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let next = {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                if state.durable.paused.is_none()
                    && state.active < WIDTH
                    && state.waiting.first_key_value().map(|(key, _)| *key) == Some(key)
                    && Instant::now() >= state.next
                {
                    state.waiting.remove(&key);
                    state.active += 1;
                    state.next = Instant::now() + SPACING;
                    permit.active = true;
                    wake_first(&state);
                    return Ok(permit);
                }
                // Only the next eligible waiter owns a timer; the rest wait for a change.
                (state.durable.paused.is_none()
                    && state.active < WIDTH
                    && state.waiting.first_key_value().map(|(key, _)| *key) == Some(key))
                .then_some(state.next)
            };
            tokio::select! {
                _ = &mut changed => {},
                _ = tokio::time::sleep_until(next.unwrap_or(deadline).min(deadline)) => {
                    if Instant::now() >= deadline {
                        return Err(RpcError::invalid_params("automatic resume admission exceeded one hour")
                            .with_data(json!({"reason": "resume.admission_timeout"})));
                    }
                }
            }
        }
    }
}

pub(super) struct Permit<'a> {
    admission: &'a Admission,
    key: (u8, u64),
    active: bool,
}

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap_or_else(|e| e.into_inner());
        state.waiting.remove(&self.key);
        if self.active {
            state.active -= 1;
        }
        wake_first(&state);
    }
}

fn wake_first(state: &State) {
    if let Some((_, wake)) = state.waiting.first_key_value() {
        wake.notify_one();
    }
}

pub(super) fn automatic(opts: &PromptOptions) -> bool {
    opts.after_turn.is_some()
        || opts.provenance.as_ref().and_then(|p| p["kind"].as_str()) == Some("auto_resume")
}

/// Unlike the inbox's presentation flag, unverified programs and relay messages count as
/// background work even when they have no agent display name.
pub(super) fn person(agent: Option<&str>, provenance: Option<&Value>) -> bool {
    agent.is_none() && provenance.is_none_or(|p| p["kind"] == "person_message")
}

pub(super) fn priority(opts: &PromptOptions, session: &Session) -> u8 {
    let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(tag) = meta.tags.get("lane.priority") {
        match tag.value.as_str() {
            "high" => return 0,
            "normal" => return 1,
            _ => {}
        }
    }
    use crate::prompt_class::PromptClass;
    match opts.class {
        Some(PromptClass::Block | PromptClass::Question) => 0,
        Some(PromptClass::Result) => 1,
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn finished_shared_reservations_survive_crash_and_never_expire_into_free_slots() {
        let dir = tempfile::tempdir().unwrap();
        let authority = Admission::open(Some(dir.path()));
        let binding = Binding::Authority { id: "pinned-authority".into() };
        authority.bind(binding.clone()).unwrap();
        authority.pause(None).unwrap();
        let mut tickets = Vec::new();
        for _ in 0..WIDTH {
            let ticket = uuid::Uuid::now_v7().to_string();
            authority.reserve(&ticket, 0).await.unwrap();
            tickets.push(ticket);
        }
        drop(authority); // No member-completion receipt reached the authority.
        let restored = Admission::open(Some(dir.path()));
        assert_eq!(restored.binding(), Some(binding));
        assert_eq!(restored.state.lock().unwrap().active, WIDTH);
        let extra = uuid::Uuid::now_v7().to_string();
        assert!(restored.reserve(&extra, 0).await.is_err()); // One-hour bound, no lease expiry.
        assert_eq!(restored.state.lock().unwrap().active, WIDTH);
        restored.pause(Some("outage")).unwrap();
        restored.release(&tickets[0]).unwrap();
        assert!(restored.reserve(&extra, 0).await.is_err()); // Free room is still paused.
        restored.pause(None).unwrap();
        restored.reserve(&extra, 0).await.unwrap();
        assert!(restored.authority_status(Some("different-authority")).is_err());
        assert!(restored.bind(Binding::Authority { id: "replacement".into() }).is_err());
        assert_eq!(Admission::open(Some(dir.path())).state.lock().unwrap().active, WIDTH);
    }

    #[tokio::test(start_paused = true)]
    async fn finished_admission_limits_100_retries_and_admits_priority_first() {
        let admission = Arc::new(Admission::open(None));
        admission.pause(Some("503 outage")).unwrap();
        let started = Arc::new(StdMutex::new(Vec::new()));
        let mut jobs = tokio::task::JoinSet::new();
        let (ready, mut queued) = tokio::sync::mpsc::unbounded_channel();
        for id in 0..100 {
            let admission = admission.clone();
            let started = started.clone();
            let ready = ready.clone();
            jobs.spawn(async move {
                let mut waiting = Box::pin(admission.enter(if id >= 90 { 0 } else { 2 }));
                assert!(futures::poll!(&mut waiting).is_pending());
                ready.send(()).unwrap();
                let _permit = waiting.await.unwrap();
                let active = admission.state.lock().unwrap().active;
                started.lock().unwrap().push((id, Instant::now(), active));
                tokio::time::sleep(Duration::from_secs(10)).await;
            });
        }
        for _ in 0..100 {
            queued.recv().await.unwrap();
        }
        assert_eq!(admission.state.lock().unwrap().waiting.len(), 100);
        assert!(started.lock().unwrap().is_empty());
        admission.pause(None).unwrap();
        while let Some(job) = jobs.join_next().await {
            job.unwrap();
        }
        let started = started.lock().unwrap();
        assert_eq!(started.len(), 100);
        assert!(started[..10].iter().all(|(id, _, _)| *id >= 90));
        assert!(started.iter().all(|(_, _, active)| *active <= WIDTH));
        assert!(started.windows(2).all(|pair| pair[1].1 - pair[0].1 >= SPACING));
        assert_eq!(admission.state.lock().unwrap().active, 0);
    }

    #[tokio::test(start_paused = true)]
    async fn finished_admission_pause_survives_restart_and_cancelled_waits_release_the_queue() {
        let dir = tempfile::tempdir().unwrap();
        Admission::open(Some(dir.path())).pause(Some("outage")).unwrap();
        let admission = Admission::open(Some(dir.path()));
        assert!(admission.start(false, || Ok(())).is_err());
        assert!(admission.start(true, || Ok(())).is_ok());
        let mut waiting = Box::pin(admission.enter(0));
        assert!(futures::poll!(&mut waiting).is_pending());
        drop(waiting);
        assert!(admission.state.lock().unwrap().waiting.is_empty());
        let error = match admission.enter(0).await {
            Err(error) => error,
            Ok(_) => panic!("paused work started"),
        };
        assert_eq!(error.data.unwrap()["reason"], "resume.admission_timeout");
        assert!(admission.state.lock().unwrap().waiting.is_empty());
        admission.pause(None).unwrap();
        assert!(Admission::open(Some(dir.path())).start(false, || Ok(())).is_ok());
        std::fs::write(dir.path().join("resume-admission.json"), b"broken").unwrap();
        assert!(Admission::open(Some(dir.path())).start(false, || Ok(())).is_err());
    }
}
