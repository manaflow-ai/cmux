//! The compactor runner (section 4) with fake models.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_host::*;

/// A recorded call: its node, the context it saw, the nodes done before it.
type Call = (NodeId, String, Vec<NodeId>);

#[test]
fn nodes_are_built_in_spec_order() {
    let dir = tempfile::tempdir().unwrap();
    // Each call records its node, the context it saw, and which nodes were done.
    let done: Arc<Mutex<Vec<NodeId>>> = Arc::default();
    let calls: Arc<Mutex<Vec<Call>>> = Arc::default();
    let running = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let model = {
        let (done, calls, running, peak) =
            (done.clone(), calls.clone(), running.clone(), peak.clone());
        Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
            let now = running.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(now, Ordering::SeqCst);
            calls
                .lock()
                .unwrap()
                .push((r.node, r.context.clone(), done.lock().unwrap().clone()));
            std::thread::sleep(Duration::from_millis(2));
            done.lock().unwrap().push(r.node);
            running.fetch_sub(1, Ordering::SeqCst);
            // 300 bytes: two children never fit in 512, so merges need the model too.
            Ok(Reply::text(summary(r.node, 300)))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    // Append everything at once: the compactor must still go in order.
    for n in 0..64 {
        chat.append(Kind::User, &long(n)).unwrap();
    }
    assert!(chat.wait_idle(None, WAIT));
    let calls = calls.lock().unwrap();
    // Messages are compressed one at a time, in order.
    let level0: Vec<u64> = calls.iter().filter(|c| c.0.l == 0).map(|c| c.0.i).collect();
    assert_eq!(level0, (0..64).collect::<Vec<_>>());
    for (node, context, done_before) in calls.iter() {
        // No call ever sees a placeholder or an id (section 4.2, 6).
        assert!(!context.contains("not summarized yet"), "{node:?}");
        assert!(!context.contains('|'), "{node:?}");
        if node.l == 0 {
            // Every earlier message was summarized before this one started.
            for j in 0..node.i {
                assert!(
                    done_before.contains(&NodeId::new(0, j)),
                    "{node:?} before 0+{j}"
                );
            }
        } else {
            let a = NodeId::new(node.l - 1, 2 * node.i);
            let b = NodeId::new(node.l - 1, 2 * node.i + 1);
            assert!(
                done_before.contains(&a) && done_before.contains(&b),
                "{node:?}"
            );
        }
    }
    // The whole tree over 64 messages: 64 + 32 + ... + 1 nodes.
    assert_eq!(calls.len(), 127);
    assert_eq!(chat.status().built, 127);
    assert!(peak.load(Ordering::SeqCst) <= 8);
}

#[test]
fn a_failed_node_retries_after_the_fixed_wait_and_reports_once() {
    let dir = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new());
    let failures = Arc::new(AtomicUsize::new(2));
    let model = {
        let failures = failures.clone();
        Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
            if failures.load(Ordering::SeqCst) > 0 {
                failures.fetch_sub(1, Ordering::SeqCst);
                return Err(ModelError::new("overloaded"));
            }
            Ok(Reply::text(summary(r.node, 200)))
        }))
    };
    let (config, reports) = config(128_000);
    let chat = OptChat::open_with(dir.path(), config, model, clock.clone()).unwrap();
    chat.append(Kind::User, &long(0)).unwrap();

    assert!(clock.wait_for_sleepers(1, Duration::from_secs(30)));
    let status = chat.status();
    assert_eq!(
        status.failures,
        vec![Failure {
            node: NodeId::new(0, 0),
            error: "overloaded".into()
        }]
    );
    assert_eq!(status.busy, vec![NodeId::new(0, 0)]);
    assert!(!chat.settle(None, Some(Duration::from_millis(50))));
    // Not before RETRY.
    clock.advance(RETRY - Duration::from_secs(1));
    assert_eq!(clock.sleepers(), 1);
    clock.advance(Duration::from_secs(1));
    // Fails again: waits again, not reported again. The first sleeper left
    // `sleep` before the second call started, so the sleeper seen now is new.
    while failures.load(Ordering::SeqCst) > 0 {
        std::thread::yield_now();
    }
    assert!(clock.wait_for_sleepers(1, Duration::from_secs(30)));
    clock.advance(RETRY);
    assert!(chat.settle(None, WAIT));
    let node_failed = reports
        .lock()
        .unwrap()
        .iter()
        .filter(|r| matches!(r, Report::NodeFailed { .. }))
        .count();
    assert_eq!(node_failed, 1);
    assert!(chat.status().failures.is_empty());
}

#[test]
fn the_size_loop_retries_in_the_same_conversation() {
    let dir = tempfile::tempdir().unwrap();
    let seen: Arc<Mutex<Vec<Vec<Followup>>>> = Arc::default();
    let model = {
        let seen = seen.clone();
        Arc::new(Fake(move |r: &CompactRequest, f: &[Followup]| {
            seen.lock().unwrap().push(f.to_vec());
            if r.node.l > 0 {
                return Ok(Reply::text(summary(r.node, 100)));
            }
            Ok(Reply::text(match f.len() {
                0 => "a".repeat(700),
                _ => "b".repeat(400),
            }))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.wait_idle(None, WAIT));
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[1].len(), 1);
    assert_eq!(seen[1][0].reply.text, "a".repeat(700));
    assert!(seen[1][0]
        .retry
        .starts_with("That line is 700 bytes; the limit is 512."));
    assert!(seen[1][0].retry.ends_with("| ← LIMIT"));
    assert_eq!(chat.zoom(0, 1).unwrap(), format!("0+0|user: {}", long(0)));
    assert!(chat
        .render_view()
        .text
        .contains(&format!("0+1|{}", "b".repeat(400))));
}

#[test]
fn a_stubborn_node_keeps_its_shortest_try() {
    let dir = tempfile::tempdir().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let model = {
        let calls = calls.clone();
        Arc::new(Fake(move |_: &CompactRequest, f: &[Followup]| {
            calls.fetch_add(1, Ordering::SeqCst);
            // 600, 590, 580, 570, 560 bytes: always over.
            Ok(Reply::text("c".repeat(600 - 10 * f.len())))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(calls.load(Ordering::SeqCst), 5);
    assert!(chat
        .render_view()
        .text
        .contains(&format!("0+1|{}\n", "c".repeat(560))));
}

#[test]
fn settle_wakes_when_the_last_line_is_built() {
    let dir = tempfile::tempdir().unwrap();
    let (release, gate) = mpsc::channel::<()>();
    let gate = Mutex::new(gate);
    let model = Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        gate.lock().unwrap().recv().unwrap();
        Ok(Reply::text(summary(r.node, 200)))
    }));
    let chat = Arc::new(open(dir.path(), 128_000, model));
    chat.append(Kind::User, &long(0)).unwrap();
    assert_eq!(chat.status().unbuilt, 1);
    assert!(chat
        .render_view()
        .text
        .contains("0+1|(not summarized yet: zoom it)"));

    // A timeout and a cancel both end the wait with false.
    assert!(!chat.settle(None, Some(Duration::from_millis(20))));
    let cancel = chat.cancel_handle();
    let waiter = {
        let (chat, cancel) = (chat.clone(), cancel.clone());
        std::thread::spawn(move || chat.settle(Some(&cancel), None))
    };
    cancel.cancel();
    assert!(!waiter.join().unwrap());

    let waiter = {
        let chat = chat.clone();
        std::thread::spawn(move || chat.settle(None, None))
    };
    release.send(()).unwrap();
    assert!(waiter.join().unwrap());
    assert_eq!(chat.status().unbuilt, 0);
}

#[test]
fn shutdown_drops_late_results() {
    let dir = tempfile::tempdir().unwrap();
    let (release, gate) = mpsc::channel::<()>();
    let gate = Mutex::new(gate);
    let model = Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        let _ = gate.lock().unwrap().recv();
        Ok(Reply::text(format!("LATE {}", r.node.name())))
    }));
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    chat.shutdown();
    assert!(!chat.settle(None, None));
    release.send(()).unwrap();
    // The late result was not written: a new owner sees the node unbuilt.
    let reopened = open(dir.path(), 128_000, instant(200));
    assert!(reopened.wait_idle(None, WAIT));
    drop(chat);
    let view = reopened.render_view().text;
    assert!(
        view.contains("0+1|sum 0+1") && !view.contains("LATE"),
        "{view}"
    );
}
