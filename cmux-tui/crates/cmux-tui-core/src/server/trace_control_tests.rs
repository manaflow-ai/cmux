//! `trace-start`, `trace-stop` and `trace-status` over fake processes: what
//! is forwarded to whom, what is reported untraced, and the total cap.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use cmux_trace::TraceError;

use super::*;
use crate::holder_runtime::HolderTrace;
use crate::process_trace::TracedState;

fn traced(pid: u32, role: Role, recording: bool) -> TraceReport {
    TraceReport {
        pid,
        state: Ok(TracedState {
            recording,
            recording_path: Some(PathBuf::from(format!(
                "/state/trace/{}",
                cmux_trace::recording_file_name(role, pid)
            ))),
            recording_bytes: role.recording_bytes(),
            records_dropped: 0,
        }),
    }
}

/// One fake terminal host: whether its record takes trace control.
#[derive(Clone, Copy)]
struct FakeHost {
    pid: u32,
    takes_trace_control: bool,
}

/// A fake holder service: what it answers when a frame would go out.
#[derive(Clone)]
struct FakeHolder {
    answer: HolderTrace,
    /// Every call it got, as `holder:<call>`.
    calls: Arc<Mutex<Vec<String>>>,
}

impl HolderTraceControl for FakeHolder {
    fn trace_start(&self, categories: u64, budget_bytes: u64) -> HolderTrace {
        self.calls.lock().unwrap().push(format!("holder:start {categories:#x} {budget_bytes}"));
        self.answer.clone()
    }

    fn trace_stop(&self) -> HolderTrace {
        self.calls.lock().unwrap().push("holder:stop".to_owned());
        self.answer.clone()
    }

    fn trace_state(&self) -> HolderTrace {
        self.calls.lock().unwrap().push("holder:status".to_owned());
        self.answer.clone()
    }
}

struct FakeTargets {
    daemon: Result<(), TraceError>,
    /// `None`: no holder runs.
    holder: Option<HolderTrace>,
    hosts: Vec<FakeHost>,
    acpmux_runs: bool,
    /// Every forwarded call, as `role:op`.
    forwarded: Mutex<Vec<String>>,
}

impl FakeTargets {
    fn new(hosts: Vec<FakeHost>) -> Self {
        Self {
            daemon: Ok(()),
            holder: Some(HolderTrace::Untraced),
            hosts,
            acpmux_runs: true,
            forwarded: Mutex::default(),
        }
    }

    fn forwarded(&self) -> Vec<String> {
        self.forwarded.lock().unwrap().clone()
    }

    fn note(&self, role: Role, op: ControlOp) {
        self.forwarded.lock().unwrap().push(format!("{}:{op:?}", role.as_str()));
    }
}

impl TraceTargets for FakeTargets {
    fn daemon(&self, op: ControlOp) -> TraceReport {
        match self.daemon {
            Ok(()) => traced(10, Role::Daemon, matches!(op, ControlOp::Start { .. })),
            Err(error) => TraceReport { pid: 10, state: Err(error) },
        }
    }

    fn holder(&self, op: ControlOp, admit: &mut dyn FnMut() -> bool) -> Option<HolderSent> {
        let holder = FakeHolder { answer: self.holder.clone()?, calls: Arc::default() };
        let sent = forward_to_holder(&holder, op, admit);
        let calls = std::mem::take(&mut *holder.calls.lock().unwrap());
        self.forwarded.lock().unwrap().extend(calls);
        Some(sent)
    }

    fn begin_hosts(
        &self,
        op: ControlOp,
        _: Instant,
        admit: &mut dyn FnMut() -> bool,
    ) -> Vec<HostCall> {
        self.hosts
            .iter()
            .map(|host| HostCall {
                pid: host.pid,
                sent: if !host.takes_trace_control {
                    HostSent::Untraced
                } else if !admit() {
                    HostSent::OverCap
                } else {
                    self.note(Role::TerminalHost, op);
                    let pid = host.pid;
                    let recording = matches!(op, ControlOp::Start { .. });
                    HostSent::Pending(Box::new(move || {
                        Ok(traced(pid, Role::TerminalHost, recording))
                    }))
                },
            })
            .collect()
    }

    fn connect_acpmux(&self) -> Option<AcpmuxCall<'_>> {
        if !self.acpmux_runs {
            return None;
        }
        Some(Box::new(move |op, _| {
            self.note(Role::Acpmux, op);
            Ok(traced(30, Role::Acpmux, matches!(op, ControlOp::Start { .. })))
        }))
    }
}

fn start() -> Call {
    start_call(&StartParams::default()).unwrap()
}

fn process<'a>(reply: &'a Value, role: &str, pid: Option<u32>) -> &'a Value {
    reply["processes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|process| {
            process["role"] == role && pid.is_none_or(|pid| process["pid"] == json!(pid))
        })
        .unwrap_or_else(|| panic!("no {role} {pid:?} in {reply}"))
}

#[test]
fn trace_control_start_reaches_the_daemon_hosts_and_acpmux_with_their_rings() {
    let targets = FakeTargets::new(vec![
        FakeHost { pid: 21, takes_trace_control: true },
        FakeHost { pid: 22, takes_trace_control: true },
    ]);
    let reply = run(start(), &targets);

    assert_eq!(reply["op"], "start");
    assert_eq!(reply["recording"], true);
    let daemon = process(&reply, "daemon", Some(10));
    assert_eq!(daemon["state"], "recording");
    assert!(daemon["recording_path"].as_str().unwrap().ends_with("daemon-10.recording.cmxtrace"));
    for pid in [21, 22] {
        let host = process(&reply, "terminal-host", Some(pid));
        assert_eq!(host["state"], "recording", "{host}");
        assert_eq!(host["recording_bytes"], Role::TerminalHost.recording_bytes());
    }
    assert_eq!(process(&reply, "acpmux", Some(30))["state"], "recording");
    assert_eq!(reply["bytes_by_role"]["terminal-host"], 2 * Role::TerminalHost.recording_bytes());
    let total = Role::Daemon.recording_bytes()
        + 2 * Role::TerminalHost.recording_bytes()
        + Role::Acpmux.recording_bytes();
    assert_eq!(reply["total_bytes"], total);
    assert!(total <= TOTAL_CAP_BYTES);
    assert_eq!(reply["total_cap_bytes"], TOTAL_CAP_BYTES);
}

#[test]
fn trace_control_sends_an_ungranted_holder_and_an_older_host_nothing_and_says_untraced() {
    let targets = FakeTargets::new(vec![FakeHost { pid: 21, takes_trace_control: false }]);
    for call in [start(), Call::Status, Call::Stop] {
        let reply = run(call, &targets);
        let holder = process(&reply, "holder", None);
        assert_eq!(holder["state"], "untraced");
        assert_eq!(holder["reason"], "holder_untraced");
        let host = process(&reply, "terminal-host", Some(21));
        assert_eq!(host["state"], "untraced");
        assert_eq!(host["reason"], "host_untraced");
        // An untraced holder maps no ring: nothing of it is counted.
        assert!(reply["bytes_by_role"].get("holder").is_none(), "{reply}");
    }
    // The older host gets no frame. The holder service is asked and sends
    // an ungranted holder nothing (its own test: holder_runtime
    // an_older_holder_is_untraced_and_gets_no_new_frame).
    assert!(
        !targets.forwarded().iter().any(|call| call.starts_with("terminal-host:")),
        "{:?}",
        targets.forwarded()
    );
}

#[test]
fn trace_control_forwards_to_a_granted_holder_and_counts_its_ring() {
    let mut targets = FakeTargets::new(Vec::new());
    targets.holder = Some(HolderTrace::Traced);
    let reply = run(start(), &targets);
    let holder = process(&reply, "holder", None);
    assert_eq!(holder["state"], "recording", "{reply}");
    assert_eq!(reply["bytes_by_role"]["holder"], Role::Holder.recording_bytes());
    // Its budget is the ring the cap counted for it.
    let budget = Role::Holder.recording_bytes();
    let start = format!("holder:start {:#x} {budget}", category::RECORDING);
    assert!(targets.forwarded().contains(&start), "{:?}", targets.forwarded());

    // A status sends nothing and maps nothing: it reads the holder's state.
    let status = run(Call::Status, &targets);
    let holder = process(&status, "holder", None);
    assert_eq!((&holder["state"], &holder["reason"]), (&json!("traced"), &json!("holder_traced")));
    assert!(holder.get("recording_bytes").is_none(), "{status}");
    assert!(status["bytes_by_role"].get("holder").is_none(), "{status}");

    // A stop stops the ring: it is not counted.
    let stopped = run(Call::Stop, &targets);
    assert_eq!(process(&stopped, "holder", None)["state"], "idle", "{stopped}");
    assert!(stopped["bytes_by_role"].get("holder").is_none(), "{stopped}");
    let holder_calls: Vec<String> =
        targets.forwarded().into_iter().filter(|call| call.starts_with("holder:")).collect();
    assert_eq!(holder_calls, [start, "holder:status".to_owned(), "holder:stop".to_owned()]);
}

#[test]
fn trace_control_reports_a_refusing_or_unlinked_holder_without_its_ring() {
    let mut targets = FakeTargets::new(Vec::new());
    targets.holder = Some(HolderTrace::Refused("one already runs".to_owned()));
    let reply = run(start(), &targets);
    let holder = process(&reply, "holder", None);
    assert_eq!((&holder["state"], &holder["error"]), (&json!("error"), &json!("one already runs")));
    assert!(reply["bytes_by_role"].get("holder").is_none(), "{reply}");

    targets.holder = Some(HolderTrace::NotLinked);
    let reply = run(start(), &targets);
    assert_eq!(process(&reply, "holder", None)["reason"], "holder_not_linked", "{reply}");
    assert!(reply["bytes_by_role"].get("holder").is_none(), "{reply}");
}

/// The cap is checked before the holder gets a frame: a holder past it is
/// sent nothing, and reported over the cap.
#[test]
fn trace_control_sends_a_holder_past_the_cap_nothing() {
    let hosts = (0..400).map(|pid| FakeHost { pid: 100 + pid, takes_trace_control: true });
    let mut targets = FakeTargets::new(hosts.collect());
    targets.holder = Some(HolderTrace::Traced);
    let mut budget = Budget::new(start());
    // Fill the cap with everything but less than one holder ring.
    let room = TOTAL_CAP_BYTES - Role::Daemon.recording_bytes();
    budget.used += room - Role::Holder.recording_bytes() + 1;
    let sent =
        targets.holder(ControlOp::Start { categories: 1 }, &mut || budget.admit(Role::Holder));
    assert_eq!(sent, Some(HolderSent::OverCap));
    assert!(targets.forwarded().is_empty(), "{:?}", targets.forwarded());
    assert_eq!(holder_json(start(), HolderSent::OverCap)["reason"], "over_total_cap");
}

#[test]
fn trace_control_start_stays_under_the_total_cap() {
    let hosts = (0..400).map(|pid| FakeHost { pid: 100 + pid, takes_trace_control: true });
    let targets = FakeTargets::new(hosts.collect());
    let reply = run(start(), &targets);

    // The holder is untraced: it maps nothing, so it takes no share.
    let fit = (TOTAL_CAP_BYTES - Role::Daemon.recording_bytes() - Role::Acpmux.recording_bytes())
        / Role::TerminalHost.recording_bytes();
    let asked =
        targets.forwarded().iter().filter(|call| call.starts_with("terminal-host:")).count();
    assert_eq!(asked as u64, fit);
    assert!(fit > 100, "the cap leaves room for about 150 hosts, not {fit}");
    let over = reply["processes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|process| process["reason"] == "over_total_cap")
        .count();
    assert_eq!(over as u64, 400 - fit);
    assert!(reply["total_bytes"].as_u64().unwrap() <= TOTAL_CAP_BYTES, "{}", reply["total_bytes"]);

    // A stop maps nothing: it reaches every host.
    let stopped =
        FakeTargets::new((0..400).map(|pid| FakeHost { pid, takes_trace_control: true }).collect());
    run(Call::Stop, &stopped);
    let asked =
        stopped.forwarded().iter().filter(|call| call.starts_with("terminal-host:")).count();
    assert_eq!(asked, 400);
}

#[test]
fn trace_control_start_the_daemon_refuses_goes_nowhere_else() {
    let mut targets = FakeTargets::new(vec![FakeHost { pid: 21, takes_trace_control: true }]);
    targets.daemon = Err(TraceError::AlreadyRecording);
    targets.holder = Some(HolderTrace::Traced);
    let reply = run(start(), &targets);
    assert_eq!(process(&reply, "daemon", Some(10))["error"], "already_recording");
    assert_eq!(reply["processes"].as_array().unwrap().len(), 1, "{reply}");
    assert!(targets.forwarded().is_empty(), "{:?}", targets.forwarded());
}

/// acpmux's share is taken only when it runs: without it, its 8 MiB go to
/// the terminal hosts.
#[test]
fn trace_control_gives_a_missing_acpmux_share_to_the_hosts() {
    let hosts = (0..400).map(|pid| FakeHost { pid: 100 + pid, takes_trace_control: true });
    let mut targets = FakeTargets::new(hosts.collect());
    targets.acpmux_runs = false;
    let reply = run(start(), &targets);
    let fit =
        (TOTAL_CAP_BYTES - Role::Daemon.recording_bytes()) / Role::TerminalHost.recording_bytes();
    let asked =
        targets.forwarded().iter().filter(|call| call.starts_with("terminal-host:")).count();
    assert_eq!(asked as u64, fit);
    assert!(
        reply["processes"].as_array().unwrap().iter().all(|process| process["role"] != "acpmux")
    );
    assert!(reply["total_bytes"].as_u64().unwrap() <= TOTAL_CAP_BYTES, "{}", reply["total_bytes"]);
}

#[test]
fn trace_control_runs_one_call_at_a_time() {
    let gate = TraceControlGate::default();
    let turn = gate.begin().expect("the first call runs");
    assert_eq!(gate.begin().err(), Some(TraceControlRefused::Busy));
    drop(turn);
    assert!(gate.begin().is_ok(), "the next call runs once the first ended");
}

#[test]
fn trace_control_never_records_an_ephemeral_session_into_a_shared_directory() {
    assert_eq!(daemon_dir(None, start()), Err(TraceControlRefused::NoStateRoot));
    assert_eq!(daemon_dir(None, Call::Stop), Ok(None));
    assert_eq!(daemon_dir(None, Call::Status), Ok(None));
    assert_eq!(
        daemon_dir(Some(PathBuf::from("/state")), start()),
        Ok(Some(PathBuf::from("/state/trace")))
    );
}

#[test]
fn trace_control_skips_acpmux_when_it_does_not_run() {
    let mut targets = FakeTargets::new(Vec::new());
    targets.acpmux_runs = false;
    targets.holder = None;
    let reply = run(Call::Status, &targets);
    assert_eq!(reply["processes"].as_array().unwrap().len(), 1, "{reply}");
    assert!(reply.get("categories").is_none());
}

#[test]
fn trace_control_categories_are_names_and_keys_are_opt_in() {
    let Call::Start { categories, keys } = start() else { unreachable!() };
    assert_eq!(categories, category::RECORDING);
    assert!(!keys);
    assert_eq!(categories & category::KEY, 0);

    let params = |names: &[&str], keys: bool| StartParams {
        categories: Some(names.iter().map(|name| (*name).to_owned()).collect()),
        keys,
    };
    let Call::Start { categories, .. } = start_call(&params(&["frame", "daemon"], false)).unwrap()
    else {
        unreachable!()
    };
    assert_eq!(categories, category::FRAME | category::DAEMON);
    assert!(start_call(&params(&["key"], false)).is_err());
    assert!(start_call(&params(&["frame", "disk"], false)).is_err());
    let Call::Start { categories, keys } = start_call(&params(&["frame"], true)).unwrap() else {
        unreachable!()
    };
    assert!(keys);
    assert_eq!(categories, category::FRAME | category::KEY);

    let reply = run(start_call(&params(&["frame"], true)).unwrap(), &FakeTargets::new(Vec::new()));
    assert_eq!(reply["categories"], json!(["key", "frame"]));
    assert_eq!(reply["keys"], true);
}

#[test]
fn trace_control_params_carry_no_path() {
    // A `path` (or any other field) is not read: the daemon picks the directory.
    let params: StartParams =
        serde_json::from_value(json!({"path": "/etc", "categories": ["frame"]})).unwrap();
    let Call::Start { categories, .. } = start_call(&params).unwrap() else { unreachable!() };
    assert_eq!(categories, category::FRAME);
}

#[test]
fn trace_control_acpmux_answers_decode() {
    let report = traced(30, Role::Acpmux, true);
    assert_eq!(TraceReport::from_json(&report.json_fields()), Some(report));
    let refused = TraceReport { pid: 30, state: Err(TraceError::NotRecording) };
    assert_eq!(TraceReport::from_json(&refused.json_fields()), Some(refused));
    assert_eq!(TraceReport::from_json(&json!({"pid": 1, "state": "maybe"})), None);
    assert_eq!(
        acpmux_params(ControlOp::Start { categories: 3 }),
        json!({"op": "start", "categories": 3})
    );
}

/// The holder's `reason` in the reply is the holder service's own word.
#[test]
fn trace_control_holder_reasons_are_the_holder_services_words() {
    let cases = [
        (HolderTrace::Traced, HolderSent::Traced),
        (HolderTrace::Refused("no".to_owned()), HolderSent::Refused("no".to_owned())),
        (HolderTrace::Untraced, HolderSent::Untraced),
        (HolderTrace::NotLinked, HolderSent::NotLinked),
    ];
    for (trace, sent) in cases {
        assert_eq!(holder_json(Call::Status, sent)["reason"], trace.as_str(), "{trace:?}");
    }
}
