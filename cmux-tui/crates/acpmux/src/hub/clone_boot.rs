//! Part of `Hub`; see `hub/mod.rs`. The first start of a machine that began as a copy of another.
//!
//! A person's second Cloud machine starts from a capture of their first (cmux-platform
//! `Seed.ts`), so it is signed in already and nothing of their login passes through our servers
//! (Leo, 2026-11-02: "cuz man i dont wanna be liable for peoples' subscription tokns"). The copy
//! carries the first machine's acpmux home: its chats' logs, a turn that was running there and
//! the prompts that waited behind it. A restart goes on with those (`restart_resume.rs`); on a
//! copy that would run them twice, once on each machine. So on its first start a copy settles
//! them as stopped instead:
//!
//! - a turn the logs show open ends `cancelled` with `detail: clone_boot`, and no continuation
//!   is queued for it;
//! - every prompt its queue held is removed (`queue_removed`, `reason: clone_boot`);
//! - a restored auto-resume wait is skipped for good (`auto_resume_skipped`, `skipped:
//!   clone_boot`), so no later start of the copy restores it;
//! - every message its agent pairs held for it is dropped (`agent_pair_dropped`, `reason:
//!   clone_boot`), so no restored or later resume delivers it;
//! - its outbox is set aside unread (`daemon.rs`), and no held agent message goes in again.
//!
//! The chats stay, with their history, and the person can go on in any of them by hand.
//!
//! The marker is `clone-boot` in the acpmux home. cmux-host writes it (`cmux host cloud
//! clone-mark`) while the copy still runs in quarantine, before the cold boot that starts this
//! daemon, when the machine its new `bind.json` names differs from the one `bound.json` recorded.
//! It holds `{"from": <first machine>, "to": <this one>}`. The daemon reads it before any log,
//! and renames it to `clone-boot.done` once every log is read: a start cut short before then
//! settles the rest the same way on the next start (each settle is idempotent: a settled turn
//! is no longer open and a removed prompt is no longer queued).
use super::*;

/// The marker's name in the acpmux home.
pub const MARKER: &str = "clone-boot";
/// What the marker becomes once every log was read.
pub const DONE: &str = "clone-boot.done";

impl Hub {
    /// At daemon start, before any log is read: this start is a copy's first when `home` holds
    /// the marker. Returns the machine it was copied from ("" when the marker does not say).
    pub(crate) fn take_clone_marker(&self, home: &std::path::Path) -> Option<String> {
        let text = match std::fs::read_to_string(home.join(MARKER)) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            // Present but unreadable still says this is a copy.
            Err(e) => {
                tracing::warn!("clone marker unreadable, settling as a copy anyway: {e}");
                String::new()
            }
        };
        let from = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.get("from").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_default();
        self.set_clone_boot(from.clone());
        tracing::warn!(from = %from, "first start of a copied machine: open turns and queued prompts settle as stopped");
        Some(from)
    }

    /// This daemon settles what the logs left open as a copy does (tests set it directly).
    pub(crate) fn set_clone_boot(&self, from: String) {
        let _ = self.clone_boot.set(from);
    }

    /// The machine this one was copied from, when this start is a copy's first.
    pub(super) fn clone_of(&self) -> Option<&str> {
        self.clone_boot.get().map(String::as_str)
    }

    /// Every log was read: the marker is spent. Kept beside as `clone-boot.done`, so the copy
    /// shows what its first start did.
    pub(crate) fn finish_clone_boot(&self, home: &std::path::Path) {
        if self.clone_of().is_none() {
            return;
        }
        if let Err(e) = std::fs::rename(home.join(MARKER), home.join(DONE))
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!("clone marker not retired: {e}");
        }
    }

    /// A copy's first start: the turn the logs show open ends stopped, with no continuation.
    pub(super) fn settle_cloned_turn(
        &self,
        session: &Arc<Session>,
        from: &str,
        open: (u64, Value, Value, bool),
    ) {
        let (seq, turn_id, prompt_id, trigger) = open;
        let error = "this machine started as a copy of another; the turn running there was stopped here, not continued";
        if trigger {
            self.append(session, "mux", super::background_turn::RECORD_KIND, json!({
                "state":"ended", "id":format!("bg-trigger-{}", turn_id.as_str().unwrap_or_default()),
                "trigger":"system", "quiet":false, "reason":"exit"
            }));
        }
        self.append_unknown_outcome(session, json!({"status": "cancelled", "stopReason": "cancelled", "detail": "clone_boot", "cloneOf": from, "turnSeq": seq, "turnId": turn_id, "promptId": prompt_id, "trigger": trigger, "error": error, "errorText": error}));
        self.save_meta(session);
    }

    /// A copy's first start: every prompt the restored queue holds is removed, so none runs on
    /// this machine as well as on the one it was copied from.
    pub(super) fn drop_cloned_queue(&self, session: &Arc<Session>) {
        let Some(from) = self.clone_of() else { return };
        // And what its agent pairs held for it (`agent_pairs.rs`).
        self.drop_cloned_pair_holds(session, from);
        let ids: Vec<String> = session
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|q| q.prompt_id.clone())
            .collect();
        for id in ids {
            self.remove_queued_because(session, &id, Some("clone_boot"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};

    fn temp(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("acpmux-clone-boot-{tag}-{}", uuid::Uuid::now_v7()))
    }

    /// A store at `root` holding chat `c1`, whose log shows a turn the daemon left open and a
    /// prompt queued behind it (what a capture taken mid-turn carries).
    fn cut_chat(root: &std::path::Path) -> Config {
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        cfg.auto_resume_delays_ms = Some(vec![10_000]);
        let store = crate::store::open(&cfg.store, root).unwrap();
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg.clone(), store);
        let session = hub.resolve("c1").unwrap();
        hub.append(&session, "in", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
        hub.append(&session, "in", "user_message", json!({"turnId": "t1", "text": "do the thing"}));
        hub.append(
            &session,
            "mux",
            "queued",
            json!({"text": "next", "client": "acpmux",
            "position": 1, "promptId": "p2", "turnId": "t2", "control": "local",
            "prompt": [{"type": "text", "text": "next"}]}),
        );
        cfg
    }

    /// The chat's log after a daemon on `root` read it, as a copy's first start (`from`) or not.
    async fn load(
        root: &std::path::Path,
        cfg: &Config,
        from: Option<&str>,
    ) -> (Vec<EventRecord>, Vec<String>) {
        let hub = Hub::new_deferred(
            cfg.clone(),
            crate::store::open(&cfg.store, root).unwrap(),
            crate::mailbox::Mailbox::memory(),
        );
        if let Some(from) = from {
            hub.set_clone_boot(from.to_owned());
        }
        let session = hub.resolve("c1").unwrap();
        hub.load_session_log(&session);
        let queue = session.queue().into_iter().map(|q| q.prompt_id).collect();
        let events = hub.events("c1", 0, 10_000).unwrap();
        hub.shutdown_all().await;
        (events, queue)
    }

    #[tokio::test]
    async fn a_copy_stops_the_open_turn_and_drops_the_queue() {
        let root = temp("copy");
        let cfg = cut_chat(&root);
        let (events, queue) = load(&root, &cfg, Some("vm_first")).await;
        assert!(queue.is_empty(), "a copy ran a queued prompt: {queue:?}");
        let results: Vec<&Value> =
            events.iter().filter(|e| e.kind == "turn_result").map(|e| &e.msg).collect();
        assert_eq!(results.len(), 1, "{results:?}");
        assert_eq!(
            (
                &results[0]["status"],
                &results[0]["detail"],
                &results[0]["cloneOf"],
                &results[0]["turnId"]
            ),
            (&json!("cancelled"), &json!("clone_boot"), &json!("vm_first"), &json!("t1")),
        );
        // No continuation of the cut turn was queued: the only `queued` is the one it carried.
        let queued: Vec<&Value> =
            events.iter().filter(|e| e.kind == "queued").map(|e| &e.msg["promptId"]).collect();
        assert_eq!(queued, [&json!("p2")], "{events:?}");
        let removed: Vec<&Value> =
            events.iter().filter(|e| e.kind == "queue_removed").map(|e| &e.msg).collect();
        assert_eq!(removed.len(), 1, "{removed:?}");
        assert_eq!(
            (&removed[0]["promptId"], &removed[0]["reason"]),
            (&json!("p2"), &json!("clone_boot"))
        );

        // A later start of the copy (no marker) finds nothing open and nothing to run.
        let (again, queue) = load(&root, &cfg, None).await;
        assert!(queue.is_empty(), "{queue:?}");
        assert_eq!(again.len(), events.len(), "a later start changed the settled log");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn an_ordinary_restart_still_continues_the_cut_turn() {
        let root = temp("restart");
        let cfg = cut_chat(&root);
        let (events, queue) = load(&root, &cfg, None).await;
        assert!(queue.len() == 2 && queue[1] == "p2", "{queue:?}");
        assert!(queue[0].starts_with("p1"), "the continuation runs first: {queue:?}");
        assert!(events.iter().all(|e| e.msg["detail"] != "clone_boot"), "{events:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A store at `root` holding chat `c1`, whose log `write` fills.
    fn chat_with(root: &std::path::Path, write: impl Fn(&Hub, &Arc<Session>)) -> Config {
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        cfg.auto_resume_delays_ms = Some(vec![60_000]);
        let store = crate::store::open(&cfg.store, root).unwrap();
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg.clone(), store);
        let session = hub.resolve("c1").unwrap();
        write(&hub, &session);
        cfg
    }

    /// A daemon on `root` reads `c1`'s log and resumes what it restored, as a copy's first start
    /// (`from`) or not: the log after, and what its agent pairs hold for `c1` (held messages,
    /// restored resumes to run).
    async fn start(
        root: &std::path::Path,
        cfg: &Config,
        from: Option<&str>,
    ) -> (Vec<EventRecord>, (usize, usize)) {
        let hub = Hub::new_deferred(
            cfg.clone(),
            crate::store::open(&cfg.store, root).unwrap(),
            crate::mailbox::Mailbox::memory(),
        );
        if let Some(from) = from {
            hub.set_clone_boot(from.to_owned());
        }
        let session = hub.resolve("c1").unwrap();
        hub.load_session_log(&session);
        hub.resume_restored_as(std::slice::from_ref(&session), true);
        let holds = hub.pair_holds_for("c1");
        let events = hub.events("c1", 0, 10_000).unwrap();
        hub.shutdown_all().await;
        (events, holds)
    }

    /// The capture holds a turn that failed on a dropped connection and the retry it scheduled.
    fn failed_with_retry(hub: &Hub, session: &Arc<Session>) {
        hub.append(
            session,
            "mux",
            "turn_started",
            json!({
                "turnId": "t1", "promptId": "p1", "control": "local", "trustGate": false
            }),
        );
        hub.append_unknown_outcome(session, json!({
            "turnId": "t1", "promptId": "p1", "status": "failed", "errorText": "stream disconnected"
        }));
        hub.append(
            session,
            "mux",
            "auto_resume_scheduled",
            json!({
                "turnId": "t1", "promptId": "p1", "attempt": 1, "of": 1, "reason": "transport",
                "nextAt": crate::hub::now_ms() + 600_000
            }),
        );
    }

    fn kinds<'a>(events: &'a [EventRecord], kind: &str) -> Vec<&'a Value> {
        events.iter().filter(|e| e.kind == kind).map(|e| &e.msg).collect()
    }

    #[tokio::test]
    async fn a_copy_settles_the_inherited_retry_wait_for_good() {
        // An ordinary restart restores the wait (the fixture is one a restart retries).
        let root = temp("retry-control");
        let cfg = chat_with(&root, failed_with_retry);
        let (events, _) = start(&root, &cfg, None).await;
        assert_eq!(kinds(&events, "auto_resume_restored").len(), 1, "{events:?}");
        let _ = std::fs::remove_dir_all(&root);

        // A copy's first start skips it, durably.
        let root = temp("retry");
        let cfg = chat_with(&root, failed_with_retry);
        let (events, _) = start(&root, &cfg, Some("vm_first")).await;
        assert!(kinds(&events, "auto_resume_restored").is_empty(), "{events:?}");
        let skipped = kinds(&events, "auto_resume_skipped");
        assert_eq!(skipped.len(), 1, "{events:?}");
        assert_eq!(
            (&skipped[0]["turnId"], &skipped[0]["skipped"], &skipped[0]["cloneOf"]),
            (&json!("t1"), &json!("clone_boot"), &json!("vm_first"))
        );

        // The copy's next, ordinary restart restores nothing and writes nothing new.
        let (again, _) = start(&root, &cfg, None).await;
        assert!(kinds(&again, "auto_resume_restored").is_empty(), "{again:?}");
        assert_eq!(again.len(), events.len(), "a later start changed the settled log");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The capture holds a pair with `a` paused, a message from `a` held for `c1`, and the
    /// person's resume that was delivering it when the first machine's daemon stopped.
    fn paused_pair(hub: &Hub, session: &Arc<Session>) {
        hub.append(
            session,
            "mux",
            "agent_pair_paused",
            json!({"peer": "a", "reason": "alternating"}),
        );
        hub.append(
            session,
            "mux",
            "agent_pair_held",
            json!({
                "from": "a", "to": "c1", "promptId": "h1", "client": "acpmux", "order": 1,
                "prompt": [{"type": "text", "text": "over to you"}],
                "provenance": {"kind": "subsession_message", "from": "a", "to": "c1"},
            }),
        );
        hub.append(session, "mux", "agent_pair_resumed", json!({"peer": "a", "by": "request"}));
    }

    #[tokio::test]
    async fn a_copy_drops_what_its_agent_pairs_held_for_good() {
        // An ordinary restart holds the message and drains the resumed pair.
        let root = temp("pair-control");
        let cfg = chat_with(&root, paused_pair);
        let (_, holds) = start(&root, &cfg, None).await;
        assert_eq!(holds, (1, 1));
        let _ = std::fs::remove_dir_all(&root);

        // A copy's first start drops it, in the log, and leaves nothing to deliver.
        let root = temp("pair");
        let cfg = chat_with(&root, paused_pair);
        let (events, holds) = start(&root, &cfg, Some("vm_first")).await;
        assert_eq!(holds, (0, 0), "a copy would deliver the first machine's message");
        let dropped = kinds(&events, "agent_pair_dropped");
        assert_eq!(dropped.len(), 1, "{events:?}");
        assert_eq!(
            (&dropped[0]["promptId"], &dropped[0]["peer"], &dropped[0]["reason"]),
            (&json!("h1"), &json!("a"), &json!("clone_boot"))
        );

        // The copy's next, ordinary restart holds nothing either.
        let (again, holds) = start(&root, &cfg, None).await;
        assert_eq!(holds, (0, 0));
        assert_eq!(again.len(), events.len(), "a later start changed the settled log");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_marker_names_the_first_machine_and_is_retired_once() {
        let home = temp("marker");
        std::fs::create_dir_all(&home).unwrap();
        let hub = Hub::new(
            Config::default(),
            crate::store::open(&Config::default().store, &home).unwrap(),
        );
        assert_eq!(hub.take_clone_marker(&home), None);
        hub.finish_clone_boot(&home);
        assert!(!home.join(DONE).exists(), "no copy, nothing to retire");

        std::fs::write(home.join(MARKER), r#"{"from":"vm_a","to":"vm_b"}"#).unwrap();
        assert_eq!(hub.take_clone_marker(&home).as_deref(), Some("vm_a"));
        assert_eq!(hub.clone_of(), Some("vm_a"));
        hub.finish_clone_boot(&home);
        assert!(!home.join(MARKER).exists());
        assert!(home.join(DONE).exists());

        // A marker that cannot be read still says this start is a copy's.
        let other = Hub::new(
            Config::default(),
            crate::store::open(&Config::default().store, &home).unwrap(),
        );
        std::fs::write(home.join(MARKER), "not json").unwrap();
        assert_eq!(other.take_clone_marker(&home).as_deref(), Some(""));
        let _ = std::fs::remove_dir_all(&home);
    }
}
