//! A handback's import is only prepared until the holder loop accepts it: the imported chat
//! stays frozen while it waits for that, and starts nothing if the store gave the chat to
//! another holder meanwhile. The real importer runs against the store in memory; a gate holds
//! its result back, as a long fetch of Git data would.

use std::sync::atomic::{AtomicBool, Ordering};

use acpmux::auto_session::import::Importer;
use tokio::sync::Semaphore;

use super::*;

/// Holds the first import's result back until the test opens the gate.
struct Gated {
    real: Arc<dyn SessionImporter>,
    reached: Arc<AtomicBool>,
    open: Arc<Semaphore>,
    armed: AtomicBool,
}

impl SessionImporter for Gated {
    fn import<'a>(
        &'a self,
        session: &'a SessionView,
        reason: ImportReason,
    ) -> BoxFuture<'a, Result<Imported, ImportError>> {
        Box::pin(async move {
            let done = self.real.import(session, reason).await;
            if self.armed.swap(false, Ordering::SeqCst) {
                self.reached.store(true, Ordering::SeqCst);
                self.open.acquire().await.expect("the gate stays").forget();
            }
            done
        })
    }
}

#[derive(Clone)]
struct Gate {
    reached: Arc<AtomicBool>,
    open: Arc<Semaphore>,
}

impl Gate {
    fn new() -> Gate {
        Gate { reached: Arc::default(), open: Arc::new(Semaphore::new(0)) }
    }

    fn importer(
        &self,
        hub: Arc<Hub>,
        cloud: FakeAutoCloud,
        root: PathBuf,
    ) -> Arc<dyn SessionImporter> {
        let real: Arc<dyn SessionImporter> = Importer::new(hub, Arc::new(cloud), root);
        Arc::new(Gated {
            real,
            reached: self.reached.clone(),
            open: self.open.clone(),
            armed: AtomicBool::new(true),
        })
    }

    fn let_through(&self) {
        self.open.add_permits(1);
    }
}

/// A rig whose chat was taken by the machine and handed back: the laptop's import of the
/// Cloud copy is done and waits at the gate. Answers the chat's id and the epoch it comes home at.
async fn import_at_the_gate(rig: &mut Rig, gate: &Gate) -> (String, u64) {
    let setting = MachineSetting { team: TEAM.into(), machine: MACHINE.into() };
    rig.store.set_machine(&setting).await.unwrap();
    let id = rig.auto_chat().await;
    rig.start_shell(&id).await;
    rig.lapse_and_return();
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the laptop is listed as standby", || {
        store.peek(&id).is_some_and(|view| view.standby.contains(&me))
    })
    .await;
    let machine = rig.store.as_machine(MACHINE);
    let assigned = machine.assignments(0).await.unwrap();
    let epoch = assigned[0].session.epoch;
    let vm = Holder::vm(MACHINE);
    machine.ack_assignment(&id, &Fence::new(vm.clone(), epoch)).await.unwrap();
    let mut manifest = machine.snapshot(&id).await.unwrap().manifest;
    manifest.last_seq = rig.view(&id).last_seq;
    machine
        .post_snapshot(&id, &SnapshotPost { holder: vm.clone(), epoch, manifest })
        .await
        .unwrap();
    let done = LeaseRequest { holder: vm, epoch, needs_run: false, standby: None };
    assert_eq!(machine.lease(&id, &done).await.unwrap().role, Role::Lost);
    let home = rig.view(&id);
    assert_eq!(home.holder, rig.me);
    rig.pass(RENEW_MS);
    until("the import reached the gate", || gate.reached.load(Ordering::SeqCst)).await;
    (id, home.epoch)
}

/// A prompt sent while the import waits: it must not start the old copy's agent.
async fn prompt_during_import(rig: &mut Rig, id: &str) {
    let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": "while it waits"}]});
    let _ = tokio::time::timeout(Duration::from_secs(3), rig.reply("session/prompt", params)).await;
}

#[tokio::test]
async fn an_import_that_lost_the_chat_meanwhile_starts_nothing_and_changes_nothing() {
    let _hermetic = &HERMETIC;
    let gate = Gate::new();
    let mut rig = Rig::with_importer({
        let g = gate.clone();
        move |hub, cloud, root| g.importer(hub, cloud, root)
    })
    .await;
    let (id, home) = import_at_the_gate(&mut rig, &gate).await;
    let (agent_before, anchor_before) = (rig.prompts_at_agent(), rig.record(&id).unwrap().anchor);

    // The laptop hears nothing for longer than a lease, and another device takes the chat at
    // a higher epoch.
    rig.cloud.set_offline(true);
    rig.pass(LEASE_MS + 1_000);
    let other = Holder::device("laptop-2");
    let lapsed = rig.view(&id).epoch;
    let take = LeaseRequest {
        holder: other.clone(),
        epoch: lapsed,
        needs_run: false,
        standby: Some(true),
    };
    let got = rig.store.lease(&id, &take).await.unwrap();
    assert_eq!(got.role, Role::Holder, "{got:?}");
    let taken = rig.view(&id);
    assert!(taken.holder == other && taken.epoch > home, "{taken:?}");

    // A prompt arrives while the old import waits, and then the old import ends.
    prompt_during_import(&mut rig, &id).await;
    gate.let_through();
    tokio::time::sleep(Duration::from_millis(800)).await;

    assert_eq!(rig.prompts_at_agent(), agent_before, "the old copy ran work");
    let session = rig.hub.resolve(&id).unwrap();
    assert!(session.moving().is_some(), "the old copy was set free");
    assert_eq!(rig.record(&id).unwrap().anchor, anchor_before, "the old import changed the record");
    assert!(rig.view(&id).holder == other, "the store moved on");
}

#[tokio::test]
async fn an_import_the_store_still_stands_behind_activates_once() {
    let _hermetic = &HERMETIC;
    let gate = Gate::new();
    let mut rig = Rig::with_importer({
        let g = gate.clone();
        move |hub, cloud, root| g.importer(hub, cloud, root)
    })
    .await;
    let (id, home) = import_at_the_gate(&mut rig, &gate).await;
    let agent_before = rig.prompts_at_agent();

    // Nothing runs while the import waits for the loop's word.
    prompt_during_import(&mut rig, &id).await;
    assert_eq!(rig.prompts_at_agent(), agent_before, "work started before the import was accepted");

    gate.let_through();
    until("the chat is held here again", || {
        rig.record(&id).is_some_and(|record| record.here && record.epoch == home)
    })
    .await;
    until("the chat runs here", || rig.hub.resolve(&id).unwrap().moving().is_none()).await;
    let before = rig.prompts_at_agent();
    rig.prompt_once_running(&id, "hello").await;
    assert_eq!(rig.prompts_at_agent(), before + 1, "one prompt, one start");
}
