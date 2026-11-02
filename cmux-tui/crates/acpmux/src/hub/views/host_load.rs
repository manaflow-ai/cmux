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
    pub(crate) async fn host_pressure_status(&self) -> Value {
        let verdict = Meter::shared().current().await;
        let mut v = match verdict.and_then(|v| serde_json::to_value(v).ok()) {
            Some(v) => v,
            None => {
                json!({"host": Meter::shared().host(), "ok": null, "over": [], "warning": null})
            }
        };
        let mut top = Vec::new();
        let (mut turns, mut processes) = (0, 0);
        let mut heavy = None;
        for s in self.sessions() {
            let info = s.turn();
            let turn = usize::from(info.is_some());
            let running = self.running_processes_read(&s);
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
            obj.insert("local_turns".into(), json!(turns));
            obj.insert("background_processes".into(), json!(processes));
            obj.insert("top".into(), Value::Array(top));
            if let Some(heavy) = heavy {
                obj.insert("heavy".into(), json!(heavy));
            }
        }
        v
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
