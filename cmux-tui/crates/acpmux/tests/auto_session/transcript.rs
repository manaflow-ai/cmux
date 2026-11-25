//! The Mac's transcript of a chat the Cloud runs (`_acpmux/auto_session/transcript`): the
//! Cloud's events as a read-only projection, never written into the chat's own log and never
//! started as a local agent. It is gone once the chat is held here again.

use super::*;

use cmux_auto_session::wire::EventsAppend;
use cmux_auto_session::wire::SeqRecord;

/// One log record as the machine's daemon writes it, at `seq`.
fn record(seq: u64, kind: &str, text: &str) -> SeqRecord {
    let msg = json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}});
    let record = json!({"seq": seq, "at": T0 + seq, "dir": "in", "kind": kind, "msg": msg});
    SeqRecord { seq, record }
}

/// The projection's events after `after`, and the projection's own fields.
async fn read(rig: &mut Rig, id: &str, after: u64) -> (Vec<(u64, String)>, Value) {
    let params = json!({"sessionId": id, "after": after, "version": 1});
    let read = rig.call("_acpmux/auto_session/transcript", params).await;
    let events = read["events"]
        .as_array()
        .map(|events| {
            let text = |event: &Value| {
                event["record"]["msg"]["content"]["text"].as_str().unwrap_or_default().to_owned()
            };
            events.iter().map(|event| (event["seq"].as_u64().unwrap(), text(event))).collect()
        })
        .unwrap_or_default();
    (events, read["projection"].clone())
}

/// Reads until the projection has every event through `seq`.
async fn read_through(rig: &mut Rig, id: &str, seq: u64) -> Vec<(u64, String)> {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let (events, projection) = read(rig, id, 0).await;
        if events.last().is_some_and(|(last, _)| *last >= seq) {
            return events;
        }
        assert!(Instant::now() < deadline, "the projection never reached {seq}: {projection}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn cloud_texts(events: &[(u64, String)]) -> Vec<String> {
    events.iter().filter(|(_, text)| text.starts_with("cloud:")).map(|(_, t)| t.clone()).collect()
}

#[tokio::test]
async fn the_mac_reads_the_clouds_replies_while_away_and_never_runs_them() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let setting = MachineSetting { team: TEAM.into(), machine: MACHINE.into() };
    rig.store.set_machine(&setting).await.unwrap();
    let id = rig.auto_chat().await;
    let (_ticks, pid) = rig.start_shell(&id).await;

    // The machine takes the chat while the laptop is away; the laptop returns and stands by.
    rig.lapse_and_return();
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the laptop is listed as standby", || {
        store.peek(&id).is_some_and(|view| view.standby.contains(&me))
    })
    .await;
    until("the tool's shell is gone", || !daemon_env::alive(pid)).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let local_before = rig.hub.events(&id, 0, 100_000).unwrap();
    let prompts_before = rig.prompts_at_agent();

    // The machine runs the chat: a streaming reply, in two chunks.
    let machine = rig.store.as_machine(MACHINE);
    let assigned = machine.assignments(0).await.unwrap();
    let epoch = assigned[0].session.epoch;
    let vm = Holder::vm(MACHINE);
    machine.ack_assignment(&id, &Fence::new(vm.clone(), epoch)).await.unwrap();
    let base = rig.view(&id).last_seq;
    let chunks = vec![
        record(base + 1, "agent_message_chunk", "cloud: one"),
        record(base + 2, "agent_message_chunk", "cloud: two"),
    ];
    let append = EventsAppend { holder: vm.clone(), epoch, events: chunks };
    machine.append_events(&id, &append).await.unwrap();

    // The Mac's read shows them, in order, once, however often it reads.
    let seen = read_through(&mut rig, &id, base + 2).await;
    assert_eq!(cloud_texts(&seen), ["cloud: one", "cloud: two"]);
    let (again, projection) = read(&mut rig, &id, 0).await;
    assert_eq!(again, seen, "a second read is the same read");
    assert_eq!(projection["source"], "cloud", "{projection}");
    assert_eq!(projection["readOnly"], true, "{projection}");
    assert_eq!(projection["epoch"], epoch, "{projection}");
    let seqs: Vec<u64> = seen.iter().map(|(seq, _)| *seq).collect();
    assert!(seqs.windows(2).all(|pair| pair[0] < pair[1]), "in order, no repeat: {seqs:?}");

    // The final reply arrives; a read after the last seen seq has only it.
    let last = record(base + 3, "agent_message", "cloud: done");
    let append = EventsAppend { holder: vm.clone(), epoch, events: vec![last] };
    machine.append_events(&id, &append).await.unwrap();
    let all = read_through(&mut rig, &id, base + 3).await;
    assert_eq!(cloud_texts(&all), ["cloud: one", "cloud: two", "cloud: done"]);
    let (newer, _) = read(&mut rig, &id, base + 2).await;
    assert_eq!(newer, vec![(base + 3, "cloud: done".to_owned())]);

    // Nothing of it is in the chat's own log, and no agent ran here.
    let local_now = rig.hub.events(&id, 0, 100_000).unwrap();
    assert_eq!(local_now.len(), local_before.len(), "the runnable log is as it was");
    assert_eq!(rig.prompts_at_agent(), prompts_before);
    assert_eq!(rig.row(&id)["here"], false);

    // Handback: the machine stores its last copy and says it has nothing left to run.
    let mut manifest = machine.snapshot(&id).await.unwrap().manifest;
    manifest.last_seq = rig.view(&id).last_seq;
    machine
        .post_snapshot(&id, &SnapshotPost { holder: vm.clone(), epoch, manifest })
        .await
        .unwrap();
    let done = LeaseRequest { holder: vm, epoch, needs_run: false, standby: None };
    assert_eq!(machine.lease(&id, &done).await.unwrap().role, Role::Lost);
    let home = rig.view(&id);
    rig.pass(RENEW_MS);
    until("the chat is held here again", || {
        rig.record(&id).is_some_and(|record| record.here && record.epoch == home.epoch)
    })
    .await;

    // The projection is gone: the import is the chat's log now, and nothing was added twice.
    let (after_home, projection) = read(&mut rig, &id, 0).await;
    assert!(after_home.is_empty(), "{after_home:?}");
    assert_eq!(projection, Value::Null);
    let local_home = rig.hub.events(&id, 0, 100_000).unwrap();
    assert!(
        local_home.iter().all(|record| !record.msg.to_string().contains("cloud: ")),
        "the projection never reaches the local log"
    );
}

#[tokio::test]
async fn a_chat_held_here_has_no_projection_and_a_newer_read_version_is_refused() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;
    // Held here: the pane reads the chat's own log as it does today.
    let (events, projection) = read(&mut rig, &id, 0).await;
    assert!(events.is_empty());
    assert_eq!(projection, Value::Null);
    // A client that asks for a read this daemon does not speak gets a clear refusal, and goes
    // on with the chat's own log (as it does with a daemon that has no such method).
    let params = json!({"sessionId": id, "version": 2});
    let refused = rig.reply("_acpmux/auto_session/transcript", params).await.unwrap_err();
    assert_eq!(refused["data"]["reason"], "auto.transcript_version", "{refused}");
    assert_eq!(refused["data"]["version"], 1, "{refused}");
    // A client that names no version reads version 1.
    let plain = rig.call("_acpmux/auto_session/transcript", json!({"sessionId": id})).await;
    assert_eq!(plain["version"], 1, "{plain}");
}
