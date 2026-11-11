use super::*;

fn argv(args: &[&str]) -> FullAccessView {
    let mut argv = vec!["agent".to_owned()];
    argv.extend(args.iter().map(|a| (*a).to_owned()));
    FullAccessView::of_argv(&argv)
}

/// Every form the reviews of #23322 found, and what is not full access.
#[test]
fn each_form_of_full_access_is_found() {
    use FullAccessForm::*;
    for (pinned, why) in [
        (&["--yolo"][..], "round 1: --yolo"),
        (&["--permission-mode=bypassPermissions"], "round 1: bypass, one word"),
        (&["--permission-mode", "bypassPermissions"], "round 1: bypass, two words"),
        (&["-sdanger-full-access", "-a", "never"], "round 2: -s joined"),
        (&["--sandbox", "danger-full-access"], "round 2: --sandbox"),
        (&["-csandbox_mode=danger-full-access"], "round 2: -c joined"),
        (&["-c", "sandbox_mode=\"danger-full-access\""], "round 2: -c quoted"),
        (&["-y"], "round 2: -y"),
        (&["--approval-mode", "yolo"], "round 2: --approval-mode yolo"),
        (&["--dangerously-skip-permissions"], "skip permissions"),
    ] {
        assert_eq!(runs_full_access(&argv(pinned)), Some(Argv), "{why}");
    }
    for (asks, why) in [
        (&["--permission-mode", "default"][..], "an asking pinned mode"),
        (&["-s", "workspace-write"], "a narrower sandbox"),
        (&[], "nothing pinned"),
    ] {
        assert_eq!(runs_full_access(&argv(asks)), None, "{why}");
    }
    let mode = |m: &str| FullAccessView { mode: Some(m.to_owned()), ..Default::default() };
    assert_eq!(runs_full_access(&mode("agent-full-access")), Some(Mode));
    assert_eq!(runs_full_access(&mode("bypassPermissions")), Some(Mode));
    assert_eq!(runs_full_access(&mode("agent")), None);
    // Round 5: a harness that declares no modes reports one.
    let undeclared =
        |m: &str| FullAccessView { undeclared_mode: Some(m.to_owned()), ..Default::default() };
    assert_eq!(runs_full_access(&undeclared("bypassPermissions")), Some(UndeclaredMode));
    assert_eq!(runs_full_access(&undeclared("default")), None);
    // Round 5: a config option other than `mode`.
    let option = |id: &str, v: &str| FullAccessView {
        options: vec![json!({"id": id, "currentValue": v})],
        ..Default::default()
    };
    assert_eq!(runs_full_access(&option("sandbox", "danger-full-access")), Some(Option));
    assert_eq!(runs_full_access(&option("sandbox", "workspace-write")), None);
    // Round 8: the `mode` option says full access while `modes.currentModeId` asks.
    let split = FullAccessView {
        mode: Some("normal".to_owned()),
        options: vec![json!({"id": "mode", "currentValue": "full-access"})],
        ..Default::default()
    };
    assert_eq!(runs_full_access(&split), Some(Option));
}

/// Review 46: an off a probe started before ends it, though an unset follows it before the
/// probe looks.
#[tokio::test]
async fn an_off_ends_a_probe_though_an_unset_follows_it() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config =
        serde_json::from_value(json!({"harnesses": {"fake": {"argv": ["python3", fake]}}}))
            .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let latch = hub.off_latch();
    let mut bound = hub.probe_bound(&latch, &["agent".to_owned(), "--yolo".to_owned()]).unwrap();
    hub.apply_full_access_push(Some(false)).await;
    hub.apply_full_access_push(None).await;
    let ended = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        full_access_forced_off(bound.as_mut()),
    )
    .await;
    assert!(ended.is_ok(), "the unset after the off hid it from the probe");
}

/// Review 70: a full-access report under an empty or blank session id names no session, so it
/// counts for every one, as a report with no id does.
#[test]
fn a_report_under_a_blank_session_id_counts_for_every_session() {
    let full = |sid: Value| {
        json!({"sessionId": sid, "update": {"sessionUpdate": "current_mode_update",
                                             "currentModeId": "bypassPermissions"}})
    };
    for sid in [json!(""), json!("  "), json!(null), json!(7)] {
        let mut reports = StartReports::default();
        reports.note(&full(sid.clone()));
        assert!(reports.of(Some("fake-1")), "a report under {sid} was not counted");
    }
    let mut reports = StartReports::default();
    reports.note(&full(json!("fake-2")));
    assert!(!reports.of(Some("fake-1")), "another session's report counted for this one");
    assert!(reports.of(Some("fake-2")));
    // Review 74: a harness session with a blank id is not known, so any report counts.
    for blank in ["", "  "] {
        assert!(reports.of(Some(blank)), "a report did not count for the blank id {blank:?}");
    }
}

/// Review 75: an unset that lands while a start reads MDM's off does not erase an off that
/// held as the start began, for a probe or pooled start (`off_latch`) or a pinned probe
/// (`probe_bound`).
#[tokio::test]
async fn an_unset_racing_a_start_does_not_erase_the_off_it_began_under() {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let unset: fn(&Hub) = |hub| {
        hub.update_start_mode_state(None, |s| s.full_access_managed = None);
    };
    hub.apply_full_access_push(Some(false)).await;
    AFTER_OFF_COUNT.set(Some(unset));
    assert!(hub.off_latch().off(), "an unset during the latch's read erased the off");
    hub.apply_full_access_push(Some(false)).await;
    AFTER_OFF_COUNT.set(Some(unset));
    let pinned = hub.probe_bound(&hub.off_latch(), &["agent".to_owned(), "--yolo".to_owned()]);
    assert!(pinned.is_err(), "an unset during the read let a pinned probe start");
}

/// claude-sr2's bound: a forced off wins over the person's on; a forced on, or nothing
/// forced, leaves the person's own answer.
#[test]
fn a_forced_off_is_an_upper_bound_and_nothing_else_changes() {
    assert!(!full_access_allowed_by(Some(false), true));
    assert!(!full_access_allowed_by(Some(false), false));
    assert!(full_access_allowed_by(None, true));
    assert!(!full_access_allowed_by(None, false));
    assert!(full_access_allowed_by(Some(true), true));
    assert!(!full_access_allowed_by(Some(true), false), "a forced on raises nothing");
}

/// The other side of `a_report_tapped_and_applied_while_the_view_is_read_is_seen`.
static VIEW_READ: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static REPORT_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static DONE_IN_READ: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Reviews 3 to 5 of #26052: a report the tap counts and the inbound loop applies (it sets
/// the mode, then takes back the count) while the view is read is in the view: a view read
/// while a report came and went never says the agent asks. `BETWEEN_VIEW_READS` holds the
/// read 300 ms; the tap and `on_update` run on another thread meanwhile, counted only, or
/// counted and applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_report_tapped_and_applied_while_the_view_is_read_is_seen() {
    for applied in [false, true] {
        let (hub, chat, _) = two_chats_on(&[], false).await;
        chat.meta.lock().unwrap().modes =
            Some(json!({"currentModeId": "normal", "availableModes": []}));
        for flag in [&VIEW_READ, &REPORT_DONE, &DONE_IN_READ] {
            flag.store(false, Ordering::SeqCst);
        }
        let tap = hub.session_tap(&chat);
        let params = json!({"sessionId": "own",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "full-access"}});
        let report = crate::rpc::Message::Notification {
            method: crate::rpc::method::SESSION_UPDATE.to_owned(),
            params: Some(params.clone()),
        };
        let (h, c) = (hub.clone(), chat.clone());
        let reporter = tokio::task::spawn_blocking(move || {
            while !VIEW_READ.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            tap(crate::agent::Direction::In, &report, None);
            if applied {
                h.on_update(&c, Some(&params), false);
            }
            REPORT_DONE.store(true, Ordering::SeqCst);
        });
        BETWEEN_VIEW_READS.set(Some(|_: &Session| {
            VIEW_READ.store(true, Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(300));
            DONE_IN_READ.store(REPORT_DONE.load(Ordering::SeqCst), Ordering::SeqCst);
        }));
        let view = FullAccessView::of_session(&chat);
        reporter.await.unwrap();
        assert!(
            !DONE_IN_READ.load(Ordering::SeqCst) || runs_full_access(&view).is_some(),
            "a report that came and went while the view was read is missed ({applied})"
        );
    }
}

/// Review 4 of #26052: a report the off's ended agent sends after its end is not counted for
/// the agent after it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_report_of_an_ended_agent_is_not_counted() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    // The ended agent's tap.
    let tap = hub.session_tap(&chat);
    hub.end_managed_full_access(&chat).await;
    let report = crate::rpc::Message::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "ended",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "full-access"}})),
    };
    // Once its exit was handled (which drops the count too): the report comes after it.
    tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
    tap(crate::agent::Direction::In, &report, None);
    assert_eq!(
        chat.floor.unapplied_full_access.load(Ordering::SeqCst),
        0,
        "an ended agent's late report was counted"
    );
}

/// Review 1 of #26034: an off push never waits without bound on a session whose spawn lock
/// another operation holds (a start that cannot end its agent). That session's end is left
/// pending for the next check, and the push returns.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_does_not_wait_on_a_held_spawn_lock() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    *chat.floor.undeclared_mode.lock().unwrap() = Some("full-access".to_owned());
    let _held = chat.spawn_lock.lock().await;
    let pushed = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.apply_full_access_push(Some(false)),
    )
    .await;
    assert!(pushed.is_ok(), "the off push waited on a held spawn lock");
    assert!(
        chat.floor.full_access_end_pending.load(Ordering::SeqCst),
        "the session the push could not reach was not left for the next check"
    );
}

/// Review 2 of #26034: an end never waits without bound on a session whose agent slot another
/// operation holds (a stop ending a hosted agent whose link does not answer). Its end is left
/// pending for the next check.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_end_does_not_wait_on_a_held_agent_slot() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    let _held = chat.child.lock().await;
    let ended = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        hub.end_managed_full_access(&chat),
    )
    .await;
    assert_eq!(
        ended.ok(),
        Some(FullAccessEnd::StillRunning),
        "the end waited on a held agent slot"
    );
    assert!(chat.floor.full_access_end_pending.load(Ordering::SeqCst));
}

/// Review 6 of #26052: a mode report of an agent MDM's off ended, still queued while eight
/// agents after it start and end, is not applied to the ninth: it is not the current agent's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_report_queued_across_nine_ends_is_not_the_next_agents() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    // The first agent's report, queued: it reaches the inbound loop after all the rest.
    let report = Inbound::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "own",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "full-access"}})),
        agent: first.generation,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    };
    hub.end_managed_full_access(&chat).await;
    for _ in 0..8 {
        hub.child_for(&chat).await.expect("an agent");
        hub.end_managed_full_access(&chat).await;
    }
    let last = hub.child_for(&chat).await.expect("an agent");
    chat.inbound_tx.send(report).await.unwrap();
    let (done, drained) = tokio::sync::oneshot::channel();
    chat.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    drained.await.unwrap();
    assert_ne!(
        crate::web_modes::mode_of(&chat.meta()).as_deref(),
        Some("full-access"),
        "an ended agent's late report set the mode of the agent after it"
    );
    let current = chat.child.lock().await.clone().expect("the last agent");
    assert_eq!(current.generation, last.generation);
}

/// Review 7 of #26052, out of scope there: an agent a start's cap stopped
/// (`stop_full_access_agent`, a cold or pooled start found in full access) retires its mode
/// reports as MDM's end does: one it still had queued is not applied to the agent after it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_report_of_an_agent_a_cap_stopped_is_not_the_next_agents() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    // The first agent's report, queued: it reaches the inbound loop after the next agent.
    let report = Inbound::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "own",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "full-access"}})),
        agent: first.generation,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    };
    hub.stop_full_access_agent(&chat, true).await;
    let next = hub.child_for(&chat).await.expect("an agent");
    assert_ne!(first.generation, next.generation, "the stopped agent was handed out again");
    chat.inbound_tx.send(report).await.unwrap();
    let (done, drained) = tokio::sync::oneshot::channel();
    chat.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    drained.await.unwrap();
    assert_ne!(
        crate::web_modes::mode_of(&chat.meta()).as_deref(),
        Some("full-access"),
        "a stopped agent's late report set the mode of the agent after it"
    );
    let current = chat.child.lock().await.clone().expect("the next agent");
    assert_eq!(current.generation, next.generation);
}

/// Review 2 of #26257: the MDM off a start read holds for its stop, though an unset lands while
/// the start's mode change out of full access waits and the harness then refuses it: the
/// stopped agent's queued report is not the next agent's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cap_stop_after_an_unset_during_its_mode_change_retires_the_agent() {
    let env = ["FAKE_FULL_ACCESS=1", "FAKE_SET_MODE_FAIL=1", "FAKE_SET_MODE_DELAY_MS=600"];
    let (hub, chat, _) = two_chats_on(&env, false).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    hub.apply_full_access_push(Some(false)).await;
    let off = hub.off_latch();
    // The harness reports full access; set as the chat holds it, with no check woken.
    if let Some(modes) = chat.meta.lock().unwrap().modes.as_mut() {
        modes["currentModeId"] = json!("full-access");
    }
    // A mode the next agent never starts in (with MDM unset it may start in full access).
    let report = Inbound::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "own",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "strict"}})),
        agent: first.generation,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    };
    let profile = hub.config.read().await.profile("fake").cloned().expect("its profile");
    let unset = {
        let hub = hub.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            hub.apply_full_access_push(None).await;
        })
    };
    let capped = hub.cap_full_access(&chat, &first, &profile, &off).await;
    unset.await.unwrap();
    assert!(capped.is_err(), "the start was not refused");
    assert!(!hub.full_access_managed_off(), "the unset did not land first");
    let next = hub.child_for(&chat).await.expect("an agent");
    assert_ne!(first.generation, next.generation, "the stopped agent was handed out again");
    chat.inbound_tx.send(report).await.unwrap();
    let (done, drained) = tokio::sync::oneshot::channel();
    chat.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    drained.await.unwrap();
    assert_ne!(
        crate::web_modes::mode_of(&chat.meta()).as_deref(),
        Some("strict"),
        "a stopped agent's late report set the mode of the agent after it"
    );
}

/// Review 1 of #26257: a stop for the person's own off (MDM unset) retires nothing, as before:
/// a report the stopped agent still had queued is applied as it was on base.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_for_the_persons_own_off_retires_nothing() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    let report = Inbound::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "own",
                            "update": {"sessionUpdate": "current_mode_update",
                                       "currentModeId": "strict"}})),
        agent: first.generation,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    };
    let epoch = chat.floor.report_epoch.load(Ordering::SeqCst);
    hub.stop_full_access_agent(&chat, false).await;
    assert_eq!(chat.floor.retired_through.load(Ordering::SeqCst), 0, "a stop retired an agent");
    assert_eq!(chat.floor.report_epoch.load(Ordering::SeqCst), epoch, "a stop moved the epoch");
    hub.child_for(&chat).await.expect("an agent");
    chat.inbound_tx.send(report).await.unwrap();
    let (done, drained) = tokio::sync::oneshot::channel();
    chat.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    drained.await.unwrap();
    assert_eq!(
        crate::web_modes::mode_of(&chat.meta()).as_deref(),
        Some("strict"),
        "with MDM unset a stopped agent's queued report was dropped"
    );
}

/// Review 3 of #26057: under MDM's off, `child_for`'s fast path does not hand out an agent
/// whose reattached host's replay is not all in the log (`ChildAgent::replay_pending`), though
/// what the chat holds of it asks: the start judges it, as the off's teardown does.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_replaying_agent_is_not_handed_out_under_mdm_off() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    hub.apply_full_access_push(Some(false)).await;
    crate::agent::TEST_REPLAYING.store(first.generation, Ordering::SeqCst);
    let next = hub.child_for(&chat).await;
    crate::agent::TEST_REPLAYING.store(0, Ordering::SeqCst);
    assert!(
        next.as_ref().map_or(true, |next| next.generation != first.generation),
        "an agent whose replay is not all in the log was handed out under MDM's off"
    );
}

/// Review 2 of #26034: under MDM's off, an agent whose end is pending is not handed out by
/// `child_for`'s fast path, though what it reports no longer says full access: the start
/// ends it first.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_agent_whose_end_is_pending_is_not_handed_out() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    hub.apply_full_access_push(Some(false)).await;
    let first = hub.child_for(&chat).await.expect("an agent");
    chat.floor.full_access_end_pending.store(true, Ordering::SeqCst);
    let next = hub.child_for(&chat).await.expect("an agent");
    assert_ne!(first.generation, next.generation, "an agent whose end was pending was handed out");
}

/// Review 69 of #23322: a left host's log read back while the host records could not be read
/// is not kept as the last word: a later check reads the log again and finds what the host
/// reported since.
#[tokio::test]
async fn a_left_host_read_while_its_records_were_unreadable_is_read_again() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    hub.append(&chat, "mux", "host_started", json!({}));
    assert!(!hub.runs_full_access_by_records(&chat, None), "a log that asks read as full access");
    let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": chat.meta().agent_session_id,
        "update": {"sessionUpdate": "current_mode_update", "currentModeId": "full-access"}}});
    hub.append(&chat, "in", "current_mode_update", update);
    assert!(
        hub.runs_full_access_by_records(&chat, None),
        "a read while the host records could not be read hid the host's later full access"
    );
}

/// Review 2 of #26055: a host whose own record this build cannot read may run on unproven, and
/// it is never adopted, so its log never hears what it did since: under MDM's off it counts as
/// full access, whatever its log says.
#[tokio::test]
async fn a_host_whose_record_cannot_be_read_counts_as_full_access() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    hub.append(&chat, "mux", "host_started", json!({}));
    let ids = std::collections::HashSet::from([chat.id.clone()]);
    let records = super::super::hosts::HostRecords { live: ids.clone(), unreadable: ids };
    assert!(
        hub.runs_full_access_by_records(&chat, Some(&records)),
        "a host whose record cannot be read was judged by its log"
    );
}

/// Review 2 of #26055, round 2: a log read kept while the host records could be read
/// (`left_host_read`) does not outlast them. Once the host's own record cannot be read, the
/// host counts as full access; while the records cannot be read at all, its log is read again.
#[tokio::test]
async fn a_kept_left_host_read_does_not_outlast_readable_records() {
    use super::super::hosts::HostRecords;
    let (hub, chat, _) = two_chats_on(&[], false).await;
    hub.append(&chat, "mux", "host_started", json!({}));
    let ids = std::collections::HashSet::from([chat.id.clone()]);
    let readable = HostRecords { live: ids.clone(), unreadable: Default::default() };
    assert!(
        !hub.runs_full_access_by_records(&chat, Some(&readable)),
        "a log that asks read as full access"
    );
    let unreadable = HostRecords { live: ids.clone(), unreadable: ids };
    assert!(
        hub.runs_full_access_by_records(&chat, Some(&unreadable)),
        "a kept read hid a host whose record cannot be read now"
    );
    let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": chat.meta().agent_session_id,
        "update": {"sessionUpdate": "current_mode_update", "currentModeId": "full-access"}}});
    hub.append(&chat, "in", "current_mode_update", update);
    assert!(
        hub.runs_full_access_by_records(&chat, None),
        "a kept read hid the host's later full access while the records could not be read"
    );
}

/// A hub with two open chats on a stand-in agent that fails over to itself with
/// `FAKE_FALLBACK=1`; a cut turn goes on after 1 s.
async fn two_chats() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
    two_chats_on(&[], true).await
}

/// Reviews 70 and 74 of #23322 (`known_id`): the read-back of a host a restart left
/// (`reported_by_left_host`) takes a blank agent session id, the chat's or a report's, for no
/// session, so a subagent's report of full access under one is not the chat's own. Under the
/// chat's own id it is.
#[tokio::test]
async fn a_left_hosts_read_back_takes_a_blank_session_id_for_no_session() {
    let (hub, chat, _) = two_chats_on(&[], false).await;
    hub.append(&chat, "mux", "host_started", json!({}));
    let own_reports = |sid: &str| {
        chat.meta.lock().unwrap().agent_session_id = Some(sid.to_owned());
        let update = json!({"sessionUpdate": "current_mode_update",
                            "currentModeId": "bypassPermissions"});
        let meta = json!({"acpmux": {"subagent": {"id": "fake-subagent"}}});
        let params = json!({"sessionId": sid, "update": update, "_meta": meta});
        hub.append(&chat, "in", "current_mode_update", json!({"params": params}));
        let view = hub.reported_by_left_host(&chat).expect("the log reads back");
        view.mode.as_deref() == Some("bypassPermissions")
    };
    for blank in ["", " ", "\t\n"] {
        assert!(!own_reports(blank), "{blank:?} named the chat's own session");
    }
    assert!(own_reports("fake-own"), "the chat's own report did not count");
}

/// `two_chats`, the agent run with `env` (`FAKE_CLAUDE_STEER=1`: it steers as Claude Code),
/// and `fails_over` or not.
async fn two_chats_on(env: &[&str], fails_over: bool) -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut argv = vec!["python3", fake];
    for setting in env {
        let (key, value) = setting.split_once('=').unwrap();
        argv.extend(["--fake", key, value]);
    }
    let mut cfg = json!({
        "harnesses": {"fake": {"argv": argv}},
        "defaultHarness": "fake",
    });
    if fails_over {
        cfg["harnesses"]["fake"]["fallback"] = json!("fake-fallback");
        let fallback = ["python3", fake, "--fake", "FAKE_FALLBACK", "1"];
        cfg["harnesses"]["fake-fallback"] = json!({"argv": fallback});
        cfg["autoResumeDelaysMs"] = json!([1000]);
    }
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let a = hub.new_session(req()).await.unwrap();
    let b = hub.new_session(req()).await.unwrap();
    (hub, a, b)
}

/// Review 26 of #23322: under MDM's off a stored approve-all runs as ask, and sub-session
/// checks rank it so. A parent in approve-all may message an approve-edits child before the
/// push, never after it: the child would approve edits the parent must ask about.
#[tokio::test]
async fn under_an_mdm_off_approve_all_ranks_as_ask_between_sessions() {
    let (hub, parent, child) = two_chats().await;
    hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
    hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
    assert!(hub.receiver_check(&parent, &child).await.is_ok(), "before the push");
    hub.apply_full_access_push(Some(false)).await;
    let r = hub.receiver_check(&parent, &child).await;
    assert!(r.is_err(), "an approve-all parent messaged an approve-edits child under the off");
    assert_eq!(hub.effective_policy(&parent.meta()).await, PermissionPolicy::Ask);
}

/// A new chat held to its caller while MDM forces full access off is held to the policy its
/// caller is set to run, not to approve-all capped as ask: once the off is unset it is still
/// no laxer than its caller (`hold_subsession`, `hold_to_starter`).
#[tokio::test]
async fn a_chat_held_to_its_caller_under_an_mdm_off_is_no_laxer_once_it_is_unset() {
    let (hub, parent, child) = two_chats_on(&[], false).await;
    hub.set_policy(&parent, PermissionPolicy::ApproveEdits).await;
    hub.set_policy(&child, PermissionPolicy::ApproveAll).await;
    hub.apply_full_access_push(Some(false)).await;
    let _ = hub.hold_subsession(&parent.meta(), &child).await;
    hub.apply_full_access_push(None).await;
    assert!(
        !hub.policy_laxer_under(&child.meta(), &parent.meta(), hub.mdm_snapshot()).await,
        "a chat held under the off runs approve-all under an approve-edits caller after the unset"
    );
}

/// Review 33 of #23322: a family message checked under the old bound (an approve-all
/// parent to an approve-edits child) and not yet written to its agent holds an off push
/// until it is written: no message the old bound let through reaches an agent after the
/// push returns. A message checked after the push is refused (the test above).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_waits_for_a_family_message_checked_under_the_old_bound() {
    let (hub, parent, child) = two_chats().await;
    hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
    hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.family_write_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let send = {
        let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
        tokio::spawn(async move {
            let text = vec![json!({"type": "text", "text": "hello"})];
            hub.send_family_prompt(&parent, &child, text, None, false, false, None, None).await
        })
    };
    let wait = std::time::Duration::from_secs(10);
    tokio::time::timeout(wait, arrived)
        .await
        .expect("the message reaches its write")
        .expect("the seam fires");
    let push = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
    };
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let returned = push.is_finished();
    let _ = release.send(());
    tokio::time::timeout(wait, push).await.expect("the push returns").unwrap();
    let _ = tokio::time::timeout(wait, send).await;
    assert!(
        !returned,
        "an off push returned while a message checked under the old bound was still unwritten"
    );
}

/// Review 33 of #23322: a family message checked before MDM's off (`receiver_check`, an
/// approve-all parent to an approve-edits child) that steers into the child's running turn
/// after the push is checked again at the steer, and refused: the parent now asks.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_family_steer_after_an_off_push_is_checked_again() {
    let (hub, parent, child) = two_chats_on(&["FAKE_CLAUDE_STEER=1"], false).await;
    hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
    hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
    assert!(hub.receiver_check(&parent, &child).await.is_ok(), "checked before the push");
    let running = {
        let (hub, child) = (hub.clone(), child.clone());
        let text = vec![json!({"type": "text", "text": "until-cancel"})];
        tokio::spawn(async move {
            hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await
        })
    };
    let started = async {
        while child.meta().status != SessionStatus::Running {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    let wait = std::time::Duration::from_secs(20);
    tokio::time::timeout(wait, started).await.expect("the child's turn runs");
    hub.apply_full_access_push(Some(false)).await;
    let text = vec![json!({"type": "text", "text": "hello"})];
    let sent = tokio::time::timeout(
        wait,
        hub.send_family_prompt(&parent, &child, text, None, true, false, None, None),
    )
    .await
    .expect("the steer answers");
    running.abort();
    assert!(
        sent.is_err(),
        "a family steer checked under the old bound ran after the push: {sent:?}"
    );
}

/// Review 26 of #23322: a second push of the same off waits, as the first does, for an ask
/// deciding under the old bound (it holds the session's permission lock), so no push returns
/// before that decision is made.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_off_push_waits_for_an_ask_deciding_under_the_old_bound() {
    let (hub, session, _) = two_chats().await;
    // An ask deciding under the permission lock across the pushes: held on its own thread,
    // never across this task's awaits.
    let (locked_tx, locked) = std::sync::mpsc::channel();
    let (deciding, release) = std::sync::mpsc::channel::<()>();
    let holder = {
        let session = session.clone();
        std::thread::spawn(move || {
            let held = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let _ = locked_tx.send(());
            let _ = release.recv();
            drop(held);
        })
    };
    locked.recv().expect("the ask holds the permission lock");
    let push = || {
        let hub = hub.clone();
        tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
    };
    let first = push();
    let stored = async {
        while !hub.full_access_managed_off() {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(10), stored)
        .await
        .expect("the off is stored");
    let second = push();
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let returned = second.is_finished();
    drop(deciding);
    holder.join().expect("the ask's thread ends");
    let (_, _) = (first.await, second.await);
    assert!(!returned, "a second off push returned while an ask decided under the old bound");
}

const WAIT: std::time::Duration = std::time::Duration::from_secs(20);

/// `two_chats`, the first an approve-all parent of the second, an approve-edits child: the
/// parent's message passes under the old bound and is refused under MDM's off.
async fn approve_all_parent() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
    let (hub, parent, child) = two_chats().await;
    hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
    hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
    (hub, parent, child)
}

fn send(hub: &Arc<Hub>, from: &Arc<Session>, to: &Arc<Session>, text: &str) {
    let (hub, from, to) = (hub.clone(), from.clone(), to.clone());
    let text = vec![json!({"type": "text", "text": text})];
    tokio::spawn(async move {
        hub.send_family_prompt(&from, &to, text, None, false, false, None, None).await
    });
}

fn push_off(hub: &Arc<Hub>) -> tokio::task::JoinHandle<()> {
    let hub = hub.clone();
    tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
}

/// Waits for the first entry of `session`'s log whose kind is one of `kinds`: its kind.
async fn logged(hub: &Hub, session: &Session, kinds: &[&str]) -> String {
    let found = async {
        loop {
            let events = hub.events(&session.id, 0, 10_000).unwrap();
            if let Some(e) = events.iter().find(|e| kinds.contains(&e.kind.as_str())) {
                return e.kind.clone();
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, found).await.unwrap_or_else(|_| panic!("no {kinds:?} logged"))
}

/// Pauses `session`'s agent's input before the first line holding `pattern`
/// (`agent::InputSeam`): the line is queued, its transport takes nothing more.
async fn pause_input(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    pattern: &str,
) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
    pause_input_at(hub, session, pattern, false).await
}

/// `pause_input`, or (`writing`) once the writer took the line and is writing it.
async fn pause_input_at(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    pattern: &str,
    writing: bool,
) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
    let agent = hub.child_for(session).await.expect("a running agent");
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *agent.input_seam.lock().unwrap() = Some((pattern.to_owned(), writing, arrived_tx, release_rx));
    (arrived, release)
}

/// A family message checked under the old bound, queued for its agent while its transport
/// takes nothing, then MDM's off pushed. Its input moves again 300 ms into the push, or,
/// `stuck`, only once the push returned. Whether the push had returned at 300 ms, and how
/// the message's turn ended.
async fn off_push_over_a_held_write(stuck: bool) -> (bool, String) {
    let (hub, parent, child) = approve_all_parent().await;
    let (arrived, release) = pause_input(&hub, &child, "session/prompt").await;
    send(&hub, &parent, &child, "hello");
    tokio::time::timeout(WAIT, arrived).await.expect("the message is queued").unwrap();
    let push = push_off(&hub);
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let returned = push.is_finished();
    let mut release = Some(release);
    if !stuck {
        let _ = release.take().map(|r| r.send(()));
    }
    tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
    let _ = release.map(|r| r.send(()));
    (returned, logged(&hub, &child, &["turn_end", "turn_error"]).await)
}

/// Review 40 of #23322: a family message queued for its agent, not yet written, holds an
/// off push until its transport writes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_waits_for_a_queued_family_message_until_it_is_written() {
    let (returned, end) = off_push_over_a_held_write(false).await;
    assert!(
        !returned,
        "an off push returned while a message checked under the old bound was queued"
    );
    assert_eq!(end, "turn_end", "the message was written once its transport took it");
}

/// Review 40 of #23322: a transport that never takes the message holds the push only for a
/// bounded time, and the message it cut is never written after the push returns.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_cuts_a_family_message_its_transport_never_takes() {
    let (_, end) = off_push_over_a_held_write(true).await;
    assert_eq!(end, "turn_error", "a message the off push cut was written after it returned");
}

/// Review 40 of #23322: an ancestor's answer checked under the old bound holds an off push
/// until the answer is written to the asking agent, not only handed to the ask.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_waits_for_an_ancestors_answer_until_it_is_written() {
    let (hub, parent, child) = approve_all_parent().await;
    let asking = {
        let (hub, child) = (hub.clone(), child.clone());
        let text = vec![json!({"type": "text", "text": "question: Pick?"})];
        tokio::spawn(async move {
            hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await
        })
    };
    let pending = async {
        loop {
            if let Some(id) = child.permissions.lock().unwrap().pending.keys().next() {
                return id.clone();
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    let id = tokio::time::timeout(WAIT, pending).await.expect("the child asks");
    let (arrived, release) = pause_input(&hub, &child, "outcome").await;
    let answer = {
        let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    let push = push_off(&hub);
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let returned = push.is_finished();
    let _ = release.send(());
    tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
    let answered = answer.await.unwrap();
    asking.abort();
    assert!(answered.is_ok(), "{answered:?}");
    assert!(
        !returned,
        "an off push returned while an answer checked under the old bound was queued"
    );
}

/// Starts a turn on `child` that asks the question "Pick?": the ask's permission id.
async fn ask_pick(hub: &Arc<Hub>, child: &Arc<Session>) -> (String, tokio::task::JoinHandle<()>) {
    let asking = {
        let (hub, child) = (hub.clone(), child.clone());
        let text = vec![json!({"type": "text", "text": "question: Pick?"})];
        tokio::spawn(async move {
            let _ = hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await;
        })
    };
    let pending = async {
        loop {
            if let Some(id) = child.permissions.lock().unwrap().pending.keys().next() {
                return id.clone();
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    (tokio::time::timeout(WAIT, pending).await.expect("the child asks"), asking)
}

/// Review 81 of #23322: two ancestors answer one question at once. The answer that lost
/// never takes away the fence of the one that won, so an off push still waits for the
/// winning answer until it is written.
#[tokio::test]
async fn a_losing_ancestor_answer_leaves_the_winners_answer_fenced() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let (arrived, release) = pause_input(&hub, &child, "outcome").await;
    // The later answer is checked first and pauses right before it answers.
    let (at_tx, at) = tokio::sync::oneshot::channel();
    let (go, go_rx) = tokio::sync::oneshot::channel();
    *hub.family_write_seam.lock().unwrap() = Some((at_tx, go_rx));
    let late = {
        let (hub, parent, child, id) = (hub.clone(), parent.clone(), child.clone(), id.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "B"})).await
        })
    };
    tokio::time::timeout(WAIT, at).await.expect("the later answer is checked").unwrap();
    // It goes on only once this thread waits: the first answer wins, then the later one
    // loses, before the asking task writes the winner.
    let _ = go.send(());
    let first = hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await;
    let late = late.await.unwrap();
    assert!(first.is_ok() != late.is_ok(), "one answer wins: {first:?}, {late:?}");
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    let push = push_off(&hub);
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let returned = push.is_finished();
    let _ = release.send(());
    tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
    asking.abort();
    assert!(
        !returned,
        "an off push returned while the winning answer, checked under the old bound, was queued"
    );
}

/// Review 81 of #23322: a message its agent's writer already took when the transport stops
/// taking input is cut by ending that agent at once. The push returns in bounded time even
/// while the chat's agent slot is held elsewhere (a stop waiting on its host), and the
/// message never reaches the agent.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_returns_in_time_while_a_cut_message_is_being_written() {
    let (hub, parent, child) = approve_all_parent().await;
    let (arrived, release) = pause_input_at(&hub, &child, "session/prompt", true).await;
    send(&hub, &parent, &child, "hello");
    tokio::time::timeout(WAIT, arrived).await.expect("the writer takes the message").unwrap();
    let slot = child.child.lock().await;
    let push = push_off(&hub);
    let returned = tokio::time::timeout(std::time::Duration::from_secs(15), push).await;
    drop(slot);
    let _ = release.send(());
    assert!(returned.is_ok(), "an off push waited on a held agent slot past its bound");
    let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
    assert_eq!(end, "turn_error", "a message the off push cut reached its agent");
}

/// Review 84 of #23322: a cut that can not prove its message's agent ended in time (its
/// reaper holds its slot) tries again, and the push never returns while the message may
/// still reach the agent.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_off_push_waits_until_a_cut_messages_agent_is_ended() {
    let (hub, parent, child) = approve_all_parent().await;
    let (arrived, release) = pause_input_at(&hub, &child, "session/prompt", true).await;
    send(&hub, &parent, &child, "hello");
    tokio::time::timeout(WAIT, arrived).await.expect("the writer takes the message").unwrap();
    let slot = hub.child_for(&child).await.expect("a running agent").child_slot();
    let reaping = slot.lock().await;
    let push = push_off(&hub);
    // The cut gives up on the slot after about 3 s (the budget, then twice it on the lock).
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    let returned = push.is_finished();
    drop(reaping);
    tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
    let _ = release.send(());
    assert!(!returned, "an off push returned while a cut message's agent could still read it");
    let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
    assert_eq!(end, "turn_error", "a message the off push cut reached its agent");
}

/// Review 84 of #23322: an answer that lost to another settles its fence, so the next off
/// push does not wait on it.
#[tokio::test]
async fn a_losing_ancestor_answer_holds_no_later_push() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    // The later answer is checked first and pauses right before it answers.
    let (at_tx, at) = tokio::sync::oneshot::channel();
    let (go, go_rx) = tokio::sync::oneshot::channel();
    *hub.family_write_seam.lock().unwrap() = Some((at_tx, go_rx));
    let late = {
        let (hub, parent, child, id) = (hub.clone(), parent.clone(), child.clone(), id.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "B"})).await
        })
    };
    tokio::time::timeout(WAIT, at).await.expect("the later answer is checked").unwrap();
    let first = hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await;
    let _ = go.send(());
    let late = late.await.unwrap();
    assert!(first.is_ok() && late.is_err(), "the first answer wins: {first:?}, {late:?}");
    // The winner is written.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let started = std::time::Instant::now();
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    asking.abort();
    let took = started.elapsed();
    assert!(
        took < std::time::Duration::from_millis(500),
        "an off push waited {took:?} on an answer that lost"
    );
}

/// Review 84 of #23322: an answer the off push cut while queued never reaches the agent,
/// which still waits for one: the question is asked again, under the bound now.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_ancestor_answer_is_asked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let (arrived, release) = pause_input(&hub, &child, "outcome").await;
    let answer = {
        let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let answered = answer.await.unwrap();
    let again = async {
        while child.permissions.lock().unwrap().pending.is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    let asked = tokio::time::timeout(std::time::Duration::from_secs(5), again).await;
    asking.abort();
    assert!(answered.is_ok(), "{answered:?}");
    assert!(asked.is_ok(), "a cut answer left its agent waiting on a question nobody is asked");
}

/// Review 88 of #23322: a cut answer is asked again only of the agent that asked it: once
/// another agent took the session (a failover), whose request ids start over, its request
/// is not answered on that agent's ids.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_answer_is_not_asked_again_once_another_agent_took_the_session() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let (arrived, release) = pause_input(&hub, &child, "outcome").await;
    let answer = {
        let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    // Another live agent takes the session while the one that asked still runs.
    let other = hub.child_for(&parent).await.expect("the parent's agent");
    let asked_of = child.child.lock().await.replace(other);
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let answered = answer.await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let again = child.permissions.lock().unwrap().pending.len();
    *child.child.lock().await = asked_of;
    asking.abort();
    assert!(answered.is_ok(), "{answered:?}");
    assert_eq!(again, 0, "a cut answer was asked again for an agent that did not ask it");
}

/// Review 86 of #23322: a family prompt that fails before its write (its PDF attachment has
/// no folder to go to) settles its fence, so the next off push does not wait on it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_family_prompt_that_fails_before_its_write_holds_no_push() {
    let (hub, parent, child) = approve_all_parent().await;
    let dir = std::env::temp_dir().join(format!("hbf-pdf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    // A file where the agent's folder goes, so its attachment folder cannot be made.
    std::fs::write(&dir, "").unwrap();
    child.meta.lock().unwrap().cwd = dir.clone();
    let pdf = vec![json!({"type": "document", "name": "a.pdf", "data": "JVBERi0="})];
    let sent = hub.send_family_prompt(&parent, &child, pdf, None, false, false, None, None);
    tokio::time::timeout(WAIT, sent).await.expect("the send answers").unwrap();
    // The turn fails at its prompt's attachment, before anything is written.
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    let started = std::time::Instant::now();
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let took = started.elapsed();
    let _ = std::fs::remove_file(&dir);
    assert!(
        took < std::time::Duration::from_millis(500),
        "an off push waited {took:?} on a prompt that failed before its write"
    );
}

/// Review 86 of #23322: a question asked again after a restart (`reregister_permission`)
/// whose ancestor's answer an off push cut is not asked again once a stop cancelled it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_answer_to_a_cancelled_question_is_not_asked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let request = child.permissions.lock().unwrap().pending[&id].request.clone();
    let agent = hub.child_for(&child).await.expect("a running agent");
    let again = "asked-again".to_owned();
    hub.reregister_permission(&child, &agent, json!(9999), again.clone(), request, "test", None)
        .await;
    let (arrived, release) = pause_input(&hub, &child, "\"id\":9999").await;
    let answer = {
        let (hub, parent, child, again) =
            (hub.clone(), parent.clone(), child.clone(), again.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &again, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    hub.cancel_pending_permissions(&child);
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let _ = answer.await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let reasked = child.permissions.lock().unwrap().pending.contains_key(&again);
    asking.abort();
    assert!(!reasked, "a question a stop cancelled was asked again");
}

/// Review 88 of #23322, round 4: a Stop that comes once an ancestor's answer won, before its
/// reply goes out, still cancels the question: a cut of that answer does not ask it again
/// under the epoch the Stop started.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cut_answer_whose_question_a_later_stop_cancelled_is_not_asked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let request = child.permissions.lock().unwrap().pending[&id].request.clone();
    let agent = hub.child_for(&child).await.expect("a running agent");
    let again = "asked-again".to_owned();
    hub.reregister_permission(&child, &agent, json!(9999), again.clone(), request, "test", None)
        .await;
    // A Stop between the answer's win and its reply (its question already answered, so
    // only its epoch moves).
    child.permission_epoch.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let (arrived, release) = pause_input(&hub, &child, "\"id\":9999").await;
    let answer = {
        let (hub, parent, child, again) =
            (hub.clone(), parent.clone(), child.clone(), again.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &again, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let _ = answer.await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let reasked = child.permissions.lock().unwrap().pending.contains_key(&again);
    asking.abort();
    assert!(!reasked, "a question a stop cancelled was asked again");
}

/// Review 88 of #23322, round 7: the agent withdraws its question while an ancestor's answer
/// to it waits in the writer, and an off push then cuts that answer. The withdrawal is heard:
/// the question is not asked again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_question_withdrawn_while_its_cut_answer_was_queued_is_not_asked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let (request, incarnation) = {
        let state = child.permissions.lock().unwrap();
        let p = &state.pending[&id];
        (p.agent_request.clone().expect("the agent's request"), p.agent_host_incarnation.clone())
    };
    let (arrived, release) = pause_input(&hub, &child, "outcome").await;
    let answer = {
        let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    hub.withdraw_permission(&child, incarnation.as_deref(), &request);
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let answered = answer.await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let reasked = child.permissions.lock().unwrap().pending.len();
    asking.abort();
    assert!(answered.is_ok(), "{answered:?}");
    assert_eq!(reasked, 0, "a question its agent withdrew was asked again");
}

/// Review 88 of #23322, round 7: the same after a restart (`reregister_permission`): a
/// withdrawal while the cut answer was queued is heard, and the question is not asked again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restarts_question_withdrawn_while_its_cut_answer_was_queued_is_not_asked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let request = child.permissions.lock().unwrap().pending[&id].request.clone();
    let agent = hub.child_for(&child).await.expect("a running agent");
    let again = "asked-again".to_owned();
    // Open as a restart's recovery leaves it (`recovery_work`).
    hub.register_agent_request(&child, &json!(9999), Some("test"));
    hub.reregister_permission(&child, &agent, json!(9999), again.clone(), request, "test", None)
        .await;
    let (arrived, release) = pause_input(&hub, &child, "\"id\":9999").await;
    let answer = {
        let (hub, parent, child, again) =
            (hub.clone(), parent.clone(), child.clone(), again.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &again, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    hub.withdraw_permission(&child, Some("test"), &json!(9999));
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let _ = answer.await;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let reasked = child.permissions.lock().unwrap().pending.contains_key(&again);
    asking.abort();
    assert!(!reasked, "a question its agent withdrew was asked again after a restart");
}

/// Review 130 of #23322: a restart's question whose ancestor answer an off push cut is asked
/// again only of the agent that asked it: once another live agent took the session (a
/// failover), it is not re-registered for that agent.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restarts_cut_answer_is_not_asked_again_once_another_agent_took_the_session() {
    let (hub, parent, child) = approve_all_parent().await;
    let (id, asking) = ask_pick(&hub, &child).await;
    let request = child.permissions.lock().unwrap().pending[&id].request.clone();
    let agent = hub.child_for(&child).await.expect("a running agent");
    let again = "asked-again".to_owned();
    hub.register_agent_request(&child, &json!(9999), Some("test"));
    hub.reregister_permission(&child, &agent, json!(9999), again.clone(), request, "test", None)
        .await;
    let (arrived, release) = pause_input(&hub, &child, "\"id\":9999").await;
    let answer = {
        let (hub, parent, child, again) =
            (hub.clone(), parent.clone(), child.clone(), again.clone());
        tokio::spawn(async move {
            hub.ancestor_answer(&parent, &child, &again, json!({"Pick?": "A"})).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
    // Another live agent takes the session while the one that asked still runs.
    let other = hub.child_for(&parent).await.expect("the parent's agent");
    let asked_of = child.child.lock().await.replace(other);
    tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
    let _ = release.send(());
    let _ = answer.await;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let reasked = child.permissions.lock().unwrap().pending.contains_key(&again);
    *child.child.lock().await = asked_of;
    asking.abort();
    assert!(!reasked, "a restart's cut answer was asked again for an agent that did not ask it");
}

/// Review 86 of #23322: a family check ranks both sessions under the one bound its operation
/// read at its entry, never a newer push in between.
#[tokio::test]
async fn a_family_check_ranks_both_sessions_under_the_bound_it_read_once() {
    let (hub, parent, child) = approve_all_parent().await;
    let before = hub.mdm_snapshot();
    hub.apply_full_access_push(Some(false)).await;
    let after = hub.mdm_snapshot();
    assert!(!before.off && after.off && after.generation > before.generation);
    let checked = hub.receiver_check_under(&parent, &child, before).await;
    assert!(checked.is_ok(), "under the bound read before the push: {checked:?}");
    let checked = hub.receiver_check_under(&parent, &child, after).await;
    assert!(checked.is_err(), "under the off the approve-all parent asks");
}

/// Review 40 of #23322: a family message whose agent hit its limit after the off push is
/// checked again before it is resent to the fallback, and refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_family_message_that_fails_over_is_checked_again_before_its_resend() {
    let (hub, parent, child) = approve_all_parent().await;
    send(&hub, &parent, &child, "slow-limit");
    logged(&hub, &child, &["turn_started"]).await;
    hub.apply_full_access_push(Some(false)).await;
    let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
    assert_eq!(end, "turn_error", "the fallback ran a family message the off push refuses");
}

/// Review 40 of #23322: the automatic continuation of a family message's cut turn speaks
/// for its sender: after an off push it is checked again, and refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_continuation_of_a_family_message_is_checked_again() {
    let (hub, parent, child) = approve_all_parent().await;
    send(&hub, &parent, &child, "net-fail-once: x");
    logged(&hub, &child, &["auto_resume_scheduled"]).await;
    hub.apply_full_access_push(Some(false)).await;
    let end = logged(&hub, &child, &["turn_end", "auto_resume_skipped"]).await;
    assert_eq!(end, "auto_resume_skipped", "a family turn was continued after the off push");
}
