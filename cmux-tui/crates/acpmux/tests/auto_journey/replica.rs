//! A long running chat is restored from its off-machine replica in the middle of a quiet
//! tool call, without a second queued prompt accidentally forcing the missing checkpoint.

use std::time::Instant;

use cmux_auto_session::consts::{LEASE_MS, RENEW_MS};

use super::logs::{DEADLINE, log_of, log_when, prompts, send, times, until};
use super::native::{CLAUDE, conversation, resume_failed};
use super::steps::{TAKEOVER, answered, auto_chat, lines};
use super::world::{World, vm};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn running_replica_restores_a_long_chat_mid_silent_turn() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_agent(CLAUDE).await;
    let laptop = world.start_laptop();
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).unwrap();
    let history = "delta-chunks: 12000 128";
    send(&laptop.hub, &session, "history", history).await;
    log_when(&laptop.hub, &id, "the long history", |log| answered(log, history)).await;
    let sid = conversation(&laptop, &id);

    // Once the quiet turn starts there are no more tokens, completed tools or queued
    // prompts to request a copy. Its running state must reach the replica on the clock.
    let out = world.dir.path().join("replica-build.log");
    let text = format!("auto-run: {}", out.display());
    send(&laptop.hub, &session, "silent-build", &text).await;
    until("the tool is running", || lines(&out) == ["start"]).await;
    log_when(&laptop.hub, &id, "the open tool", |log| {
        log.iter().any(|event| event.kind == "tool_call")
    })
    .await;
    let before = world.view(&id).snapshot;
    let started = Instant::now();
    world.pass(RENEW_MS);
    world.until_view(&id, "the running checkpoint", |view| view.snapshot > before).await;
    let first = world.view(&id).snapshot;
    until("the holder acknowledged the checkpoint", || {
        laptop.record(&id).is_some_and(|record| record.snapshot >= first)
    })
    .await;
    // A second renewal with no new agent event proves this is a running replica, not
    // just a delayed copy requested by the preceding turn's end.
    world.pass(RENEW_MS);
    world
        .until_view(&id, "another checkpoint while the tool stays quiet", |view| {
            view.snapshot > first
        })
        .await;
    let manifest = loop {
        let manifest = world.manifest(&id).await.unwrap();
        if manifest.open_turn.as_ref().is_some_and(|turn| turn.tool.is_some()) {
            break manifest;
        }
        assert!(started.elapsed() < DEADLINE, "the replica lost the open turn");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };
    assert!(session.turn().is_some(), "the source is still RUNNING at the snapshot");
    assert!(manifest.queue.is_empty(), "no queued prompt forces the checkpoint");
    assert!(!manifest.native.is_empty(), "native conversation is replicated too");
    let source = log_of(&laptop.hub, &id);
    assert!(manifest.last_seq > 256, "the replica spans multiple event pages");

    // Losing the source's connection expires its lease. The existing fenced importer
    // restores the replica into a fresh daemon and continues the interrupted turn once.
    let restore_started = Instant::now();
    world.laptop_net.set_offline(true);
    world.pass_while_laptop_sleeps(LEASE_MS + 1_000);
    assert_eq!(world.view(&id).holder, vm());
    let restored = log_when(&world.machine.hub, &id, "the restored turn completes", |log| {
        prompts(log).iter().any(|text| text.starts_with(TAKEOVER))
            && log.iter().filter(|event| event.kind == "turn_result").count() >= 2
    })
    .await;
    let restore_ms = restore_started.elapsed().as_millis();
    let prefix = |log: &[acpmux::store::EventRecord]| {
        log.iter()
            .filter(|event| event.seq <= manifest.last_seq)
            .map(|event| (event.seq, event.kind.clone(), event.msg.clone()))
            .collect::<Vec<_>>()
    };
    assert_eq!(prefix(&restored), prefix(&source), "replicated content survives too");
    assert_eq!(times(&restored, history), 1);
    assert_eq!(times(&restored, &text), 1);
    assert_eq!(prompts(&restored).iter().filter(|text| text.starts_with(TAKEOVER)).count(), 1);
    assert_eq!(conversation(&world.machine, &id), sid);
    assert!(!resume_failed(&world.machine, &id));
    assert_eq!(lines(&out), ["start"], "the interrupted shell is not replayed");

    // Fence and stop only this test's old source tree once it learns it lost the lease.
    world.laptop_net.set_offline(false);
    world.laptop_clock_catches_up();
    laptop.holder.wake();
    until("the source is fenced", || laptop.record(&id).is_some_and(|r| !r.here)).await;
    eprintln!(
        "running-replica: chunks=12000 bytes=1536000 replicated_records={} restore_ms={}",
        manifest.last_seq, restore_ms
    );
}
