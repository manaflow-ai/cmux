//! `debug-hang-inject` on the wire: the trusted local connection arms, lists
//! and disarms; other transports are refused; an armed daemon lane blocks its
//! next run inside the request watchdog's scope.

use std::time::Instant;

use serde_json::json;

use super::*;
use crate::SurfaceOptions;
use crate::server::{BoundedOutbound, ClientTransport, QueuedSink};

fn fields(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(fields) => fields,
        _ => unreachable!("an object literal"),
    }
}

/// Every [`WatchKind`] but the owner's hang test is a lane the matrix can arm.
#[test]
fn every_watch_kind_is_listed() {
    fn listed(kind: WatchKind) -> bool {
        match kind {
            WatchKind::MuxConn
            | WatchKind::JournalWriter
            | WatchKind::LineOut
            | WatchKind::PtyInput
            | WatchKind::AttachOut
            | WatchKind::RenderAttachOut => DAEMON_LANES.contains(&kind),
            #[cfg(unix)]
            WatchKind::HolderLink => DAEMON_LANES.contains(&kind),
            WatchKind::OwnerTest => !DAEMON_LANES.contains(&kind),
        }
    }
    for kind in DAEMON_LANES.iter().copied().chain([WatchKind::OwnerTest]) {
        assert!(listed(kind), "{kind:?}");
    }
}

#[test]
fn requests_read_their_fields_and_refuse_others() {
    assert_eq!(
        parse(fields(json!({"lane": "mux-conn"})), 42),
        Ok(Request::Arm { lane: "mux-conn".into(), pid: 42, block: DEFAULT_BLOCK })
    );
    assert_eq!(
        parse(fields(json!({"lane": "holder-loop", "ms": 5000, "pid": 77})), 42),
        Ok(Request::Arm { lane: "holder-loop".into(), pid: 77, block: Duration::from_secs(5) })
    );
    assert_eq!(
        parse(fields(json!({"action": "disarm", "lane": "x"})), 42),
        Ok(Request::Disarm { lane: "x".into(), pid: 42 })
    );
    assert_eq!(parse(fields(json!({"action": "list"})), 42), Ok(Request::List));
    for refused in [
        json!({}),
        json!({"lane": 3}),
        json!({"lane": "x", "ms": -1}),
        json!({"lane": "x", "ms": 1.5}),
        json!({"lane": "x", "pid": 0}),
        json!({"lane": "x", "pid": "1"}),
        json!({"lane": "x", "path": "/tmp"}),
        json!({"action": "list", "lane": "x"}),
        json!({"action": "crash", "lane": "x"}),
    ] {
        let error = parse(fields(refused.clone()), 42).unwrap_err();
        assert!(error.starts_with("bad request"), "{refused}: {error}");
    }
}

#[test]
fn an_arm_goes_into_the_page_and_every_answer_lists_it() {
    let page = Page::new();
    let request = Request::Arm { lane: "mux-conn".into(), pid: 9, block: DEFAULT_BLOCK };
    let reply = answer(&request, Some(&page), Some("/state/owner-hangs-s.jsonl".into())).unwrap();
    assert_eq!(reply["hang_log"], "/state/owner-hangs-s.jsonl");
    assert_eq!((reply["armed"].clone(), reply["for_pid"].clone()), (json!("mux-conn"), json!(9)));
    assert_eq!(reply["ms"], 3000);
    assert_eq!(
        reply["entries"],
        json!([{"lane": "mux-conn", "pid": 9, "ms": 3000, "taken": false}])
    );
    assert_eq!(reply["pid"], std::process::id());
    let lanes = reply["lanes"].as_array().unwrap();
    assert!(lanes.contains(&json!({"name": "mux-conn", "hang_ms": 2000})), "{lanes:?}");
    assert!(lanes.contains(&json!({"name": "mux-line-out", "hang_ms": 100})), "{lanes:?}");

    let again = answer(&request, Some(&page), None).unwrap_err();
    assert!(again.contains("armed already"), "{again}");
    let disarmed =
        answer(&Request::Disarm { lane: "mux-conn".into(), pid: 9 }, Some(&page), None).unwrap();
    assert_eq!(disarmed["disarmed"], 1);
    assert_eq!(disarmed["entries"], json!([]));
}

#[test]
fn with_no_page_an_arm_is_refused_and_a_list_answers() {
    let request = Request::Arm { lane: "x".into(), pid: 1, block: DEFAULT_BLOCK };
    let error = answer(&request, None, None).unwrap_err();
    assert!(error.contains("no hang-injection page"), "{error}");
    assert_eq!(answer(&Request::List, None, None).unwrap()["entries"], json!([]));
}

#[test]
fn only_the_trusted_local_connection_is_answered_and_other_lines_pass() {
    let mux = Mux::new_for_test("debug-hang-inject", SurfaceOptions::default());
    let connect = |transport| {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        (mux.control_clients.register(transport, writer.clone()), outbound, writer)
    };
    let reply = |(client, out, writer): &(u64, Arc<BoundedOutbound>, MessageWriter),
                 line: Value| {
        assert_eq!(try_handle(&mux, *client, &line.to_string(), writer), Some(true));
        serde_json::from_str::<Value>(&out.try_pop().expect("reply")).unwrap()
    };
    let local = connect(ClientTransport::Unix);
    let web = connect(ClientTransport::WebSocket);

    let list = reply(&local, json!({"id": 4, "cmd": COMMAND, "action": "list"}));
    assert_eq!((list["ok"].clone(), list["id"].clone()), (json!(true), json!(4)), "{list}");
    assert!(list["data"]["lanes"].is_array(), "{list}");

    let refused = reply(&web, json!({"id": 5, "cmd": COMMAND, "action": "list"}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(refused["error"].as_str().unwrap().contains("trusted local connection"), "{refused}");

    let (client, _, writer) = &local;
    assert_eq!(try_handle(&mux, *client, r#"{"id":6,"cmd":"ping"}"#, writer), None);
    assert_eq!(try_handle(&mux, *client, "not json", writer), None);
}

/// The request watchdog's own scope takes the arm: a run of the armed lane
/// blocks for `ms` inside its scope, once.
#[cfg(unix)]
#[test]
fn an_armed_daemon_lane_blocks_its_next_run_once() {
    let page = hang_inject::page().expect("the process page maps in /tmp");
    let watchdog = crate::server::RequestWatchdog::new(Duration::from_secs(1));
    page.arm(WatchKind::JournalWriter.name(), std::process::id(), Duration::from_millis(300))
        .unwrap();
    let started = Instant::now();
    drop(watchdog.watch(WatchKind::JournalWriter, 0));
    assert!(started.elapsed() >= Duration::from_millis(300), "{:?}", started.elapsed());
    let started = Instant::now();
    drop(watchdog.watch(WatchKind::JournalWriter, 0));
    assert!(started.elapsed() < Duration::from_millis(300), "taken once");
}
