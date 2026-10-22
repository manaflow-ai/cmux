//! Part of `Hub`; see `hub/mod.rs`. The host's CPU and RAM budget as this daemon
//! reports it (`host_pressure.rs`), with its own share of the load. Only this
//! daemon's sessions count: a peer's turns are that peer's load, and its daemon
//! reports them. Warns only; nothing is refused, queued or held.

use super::*;

/// How many sessions `host_pressure.top` names.
const TOP: usize = 5;

impl Hub {
    /// `daemon status`'s `host_pressure`: the verdict, the turns and background
    /// processes running here, and the sessions with the most of them.
    pub(super) fn host_pressure_status(&self) -> Value {
        let mut v =
            serde_json::to_value(self.host_pressure.verdict()).unwrap_or_else(|_| json!({}));
        let mut top = Vec::new();
        let (mut turns, mut processes) = (0, 0);
        for s in self.sessions() {
            let turn = usize::from(s.turn().is_some());
            let running = self.running_processes_read(&s);
            turns += turn;
            processes += running;
            if turn + running > 0 {
                top.push((running, turn, s.id.clone(), s.meta().name));
            }
        }
        top.sort_by(|a, b| (b.0, b.1).cmp(&(a.0, a.1)));
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
        }
        v
    }

    /// The verdict, for a turn's acceptance, while the host is over budget.
    pub(super) fn host_pressure_warning(&self) -> Option<Value> {
        let v = self.host_pressure.verdict();
        if v.ok {
            return None;
        }
        serde_json::to_value(v).ok()
    }
}
