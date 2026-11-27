//! Part of `Hub` (`hub/views.rs`). The host's CPU and RAM budget as this daemon
//! reports it (`host_pressure.rs`), with its own share of the load. Only this
//! daemon's sessions count: a peer's turns are that peer's load, and its daemon
//! reports them. Warns only; nothing is refused, queued or held.

use crate::host_pressure::Meter;
use crate::hub::*;

/// A turn's acceptance callback (`PromptOptions::on_accepted`).
type Accepted = Box<dyn FnOnce(Value) + Send>;

/// How many sessions `host_pressure.top` names.
const TOP: usize = 5;

impl Hub {
    /// `daemon status`'s `host_pressure`: the verdict, the turns and background
    /// processes running here, the sessions with the most of them, and the heaviest
    /// known build or test they run (`heavy`, for `acpmux machine load`: the shell
    /// commands of tool calls in flight and of running background processes, never a
    /// process scan). Waits at most
    /// `host_pressure::SAMPLE_WAIT` for a sample; with none yet, `ok` is null.
    /// Also carries the shadow admission readings (`shadow_admission.rs`).
    pub(crate) async fn host_pressure_status(&self) -> Value {
        // The power reading beside the verdict (`server/host_power.rs`, cached 5 s): the app's
        // Auto reads memory and battery from this one object (RFD 0072), never its own sampler.
        let (verdict, power) =
            tokio::join!(Meter::shared().current(), crate::server::host_power::power());
        let mut v = match verdict.as_ref().and_then(|v| serde_json::to_value(v).ok()) {
            Some(v) => v,
            None => {
                json!({"host": Meter::shared().host(), "ok": null, "over": [], "warning": null})
            }
        };
        let mut top = Vec::new();
        let (mut turns, mut processes) = (0, 0);
        let mut heavy = None;
        let mut roots = Vec::new();
        // The live sessions only, newest first as before: a close ends a session's agent, its
        // turn and (with the harness, `Hub::processes_lost`) its running processes, so a closed
        // one adds nothing here.
        for s in self.indexed_live_sessions() {
            let info = s.turn();
            let turn = usize::from(info.is_some());
            let running = self.running_processes_read(&s);
            // The pids this daemon started for it: its agent (never waited for: a start holding
            // the slot leaves it out of this sample) and its background tasks' runners.
            let harness = s.child.try_lock().ok().and_then(|c| c.as_ref().and_then(|c| c.pid));
            let mut pids: Vec<u32> = harness.into_iter().collect();
            pids.extend(self.bg_running_pids(&s));
            if !pids.is_empty() {
                let active = turn > 0 || running > 0 || pids.len() > usize::from(harness.is_some());
                roots.push(crate::hub::session_usage::Roots { id: s.id.clone(), active, pids });
            }
            let open = info.iter().flat_map(|t| t.doing.open_heavy.values().copied());
            heavy = open.chain(self.running_heavy_read(&s)).fold(heavy, crate::host_load::heavier);
            turns += turn;
            processes += running;
            if turn + running > 0 {
                top.push((running, turn, s.id.clone(), s.meta().name));
            }
        }
        top.sort_by_key(|t| std::cmp::Reverse((t.0, t.1)));
        let top: Vec<Value> = top
            .into_iter()
            .take(TOP)
            .map(|(processes, turns, id, name)| {
                json!({"session_id": id, "name": name, "turns": turns, "processes": processes})
            })
            .collect();
        if let Some(obj) = v.as_object_mut() {
            let assume = crate::server::host_power::assumed(crate::store::now_ms());
            if let Some(power) = crate::server::host_power::power_json(power, assume.as_ref()) {
                obj.insert("power".into(), power);
            }
            obj.insert("local_turns".into(), json!(turns));
            obj.insert("background_processes".into(), json!(processes));
            obj.insert("top".into(), Value::Array(top));
            if let Some(heavy) = heavy {
                obj.insert("heavy".into(), json!(heavy));
            }
            if let Some(stall) = crate::host_pressure::mem_stall::global() {
                obj.insert("mem_stall".into(), json!(stall));
            }
        }
        // The agents' own cores and memory (RFD 0072 piece 2), read off the runtime and at most
        // once per `session_usage::MIN_INTERVAL`; then Auto on reserve judges them in shadow
        // (RFD 0072 stage 1, `reserve_shadow.rs`): `reserve` says what it would move, nothing moves.
        let judged = verdict;
        let read = tokio::task::spawn_blocking(move || {
            let agents = crate::hub::session_usage::sample(roots);
            let sample = Meter::shared().last_sample();
            let reserve = crate::hub::reserve_shadow::judge_now(
                crate::store::now_ms(),
                sample.as_ref(),
                judged.as_ref(),
                &agents,
            );
            (serde_json::to_value(agents).ok(), reserve)
        })
        .await
        .ok();
        if let (Some(obj), Some((agents, reserve))) = (v.as_object_mut(), read) {
            if let Some(agents) = agents {
                obj.insert("agents".into(), agents);
            }
            if let Some(reserve) = reserve {
                obj.insert("reserve".into(), reserve);
            }
        }
        // The readings the shadow admission verdict uses beside the meter's
        // (`shadow_admission::local_readings`): `cpus`, `pressureAgeMs`, `load`,
        // `ram` and `swap`, so a reader of this builds the inputs placement does.
        crate::shadow_admission::with_readings(v, &crate::shadow_admission::local_readings())
    }

    /// Wraps a turn's `on_accepted` so its acceptance carries the verdict while the
    /// host is over budget: whoever sent it hears so. Reads the verdict now and never
    /// waits (`Meter::peek`): an await before acceptance would let a later prompt
    /// overtake this one.
    pub(in crate::hub) fn with_host_pressure(&self, f: Option<Accepted>) -> Option<Accepted> {
        let f = f?;
        let over = Meter::shared().peek().filter(|v| !v.ok);
        let Some(pressure) = over.and_then(|v| serde_json::to_value(v).ok()) else {
            return Some(f);
        };
        Some(Box::new(move |mut v: Value| {
            if let Some(obj) = v.as_object_mut() {
                obj.insert("host_pressure".into(), pressure);
            }
            f(v);
        }))
    }
}
