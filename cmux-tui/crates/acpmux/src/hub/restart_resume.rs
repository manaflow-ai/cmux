//! A turn a daemon restart cut off goes on by itself. Leo, 2026-10-22: "OUR SHIT IS HARDLY EVER
//! GOING TO GO IDLE ... YOU'LL JUST HAVE TO ACCEPT IT BREAKING AT SOME POINT BUT IT RESUMES
//! WHATEVER IT INTERRUPTED". An update restarts the daemon mid-turn instead of waiting for idle.
//!
//! An agent under a live agent host outlives the daemon and is adopted, turn and all
//! (`hosts.rs`). When the agent ended with the daemon (agent hosts off, a reboot, a host that
//! died), the new daemon settles the open turn `outcome_unknown` (`mod.rs`
//! `mark_unknown_outcomes`) and, here, queues one continuation of it at the head of the chat's
//! queue: an acpmux prompt that quotes the cut turn's prompt and every message steered into it,
//! and tells the agent to check what finished before it goes on.
//!
//! - It is an ordinary `queued` record, so it runs through the restored queue (`queue.rs`
//!   `restore_queues`, `resume_queues`) before the prompts that waited behind the cut turn, and a
//!   crash before it ran puts it back like any queued prompt.
//! - Its prompt id is the cut prompt's next attempt (`P~resume-n`, as `auto_resume.rs`), and it
//!   is written before the cut turn's `turn_result`: a crash between the two finds the turn
//!   open again and the continuation already logged, so it is queued once.
//! - `auto_resume_scheduled` with `reason: "daemon_restart"` records it, and its `user_message`
//!   carries `_meta.provenance = {kind: "auto_resume", reason: "daemon_restart", ...}`.
//! - `autoResumeDelaysMs: []` turns it off, as it does the transport continuation, and a chain
//!   of restarts gives up after the attempts it configures ([`configured_attempts`]), as a
//!   transport cut does (`auto_resume_exhausted`).
//! - A crash between the continuation's `queued` record and its move to the head
//!   (`queue_order`) still restores it at the head (`queue.rs` `restore_queue`), and once.
//! - It goes through the trust gate as the cut turn did (`turn_started` records `trustGate`),
//!   and carries the images the cut turn's prompt and steers sent (`prompt_images.rs`).

use super::{DEFAULT_DELAYS_MS, SUFFIX, configured_attempts, split_attempt};
use crate::hub::{Hub, Session};
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::sync::Arc;

/// Longest quote of one cut prompt or steer, in characters.
const MAX_QUOTE_CHARS: usize = 4_000;

/// The text the agent gets: the cut turn's prompt, then what was steered into it.
fn continue_text(prompts: &[String]) -> String {
    let mut text = String::from(
        "acpmux restarted (an update or a crash) while your previous turn was running, and the \
         turn was cut off.",
    );
    for (i, p) in prompts.iter().enumerate() {
        let quoted: String = p.chars().take(MAX_QUOTE_CHARS).collect();
        let what = if i == 0 { "Its prompt" } else { "A message sent into it" };
        text.push_str(&format!("\n\n{what}:\n<message>\n{quoted}\n</message>"));
    }
    text.push_str(
        "\n\nCheck what already finished (files, commands, messages), then continue from where it \
         stopped. Do not redo work that completed.",
    );
    text
}

impl Hub {
    /// Before the cut turn `turn_id` is settled: logs the continuation that goes on with it, and
    /// returns its prompt id; `None` when it gets none (turned off, or too many attempts).
    pub(in crate::hub) fn log_restart_continuation(
        &self,
        session: &Arc<Session>,
        turn_id: &str,
    ) -> Option<String> {
        // One continuation per configured wait, as a transport cut gets: `[]` configures none,
        // which turns it off. A contended config lock reads as the default waits, never as off.
        let attempts = self.config.try_read().map_or(DEFAULT_DELAYS_MS.len(), |c| {
            configured_attempts(c.auto_resume_delays_ms.as_ref())
        });
        if attempts == 0 {
            return None;
        }
        // The cut turn's prompt id, control, trust gate, texts and images: its `turn_started`,
        // the `user_message` that started it and those steered into it.
        let (mut prompt_id, mut control, mut gate) = (None::<String>, None::<String>, None);
        let mut prompts: Vec<String> = Vec::new();
        let mut images: Vec<Value> = Vec::new();
        // A Web steer made the turn a Web turn (`web_control.rs` `check_steer`).
        let mut raised_to_web = false;
        // These durable markers are normally applied to live sessions. A dead-host restart has
        // no host replay, so carry their terminal control state into this decision too: a Web
        // continuation must not cross a remote-floor cancellation or stale ended control.
        let mut started = false;
        let mut control_ended = false;
        let mut floor_cancelled = false;
        let kinds = [
            "turn_started",
            "user_message",
            "turn_control",
            "remote_control_ended",
            "remote_control_restored",
            "remote_floor_cancel",
        ];
        let _ = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
            let is_turn = e.msg.get("turnId").and_then(Value::as_str) == Some(turn_id);
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
            match e.kind.as_str() {
                "turn_started" if is_turn => {
                    started = true;
                    prompt_id = field("promptId");
                    control = field("control");
                    gate = e.msg.get("trustGate").and_then(Value::as_bool);
                }
                "turn_control" if is_turn => {
                    raised_to_web |= field("control").as_deref() == Some("web")
                }
                "remote_control_ended" if started => control_ended = true,
                "remote_control_restored" if started => control_ended = false,
                "remote_floor_cancel" if started && is_turn => floor_cancelled = true,
                "user_message" if is_turn => {
                    let named = e.msg.get("images").and_then(Value::as_array);
                    let shown = named.map_or(0, Vec::len);
                    images.extend(named.into_iter().flatten().cloned());
                    let text = field("text").filter(|t| !t.trim().is_empty());
                    prompts.extend(text.or_else(|| {
                        (shown > 0).then(|| format!("({shown} image(s), attached again below)"))
                    }));
                }
                _ => {}
            }
            true
        });
        let prompt_id = prompt_id.filter(|p| !p.is_empty())?;
        let (root, done) = split_attempt(&prompt_id);
        let attempt = done + 1;
        if attempt > attempts {
            let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id, "reason": "daemon_restart"});
            self.append(session, "mux", "auto_resume_exhausted", msg);
            return None;
        }
        let effective_web = control.as_deref() == Some("web") || raised_to_web;
        let blocked = if effective_web && floor_cancelled {
            Some("remote_floor_cancel")
        } else if effective_web && control_ended {
            Some("remote_control_ended")
        } else {
            None
        };
        if let Some(reason) = blocked {
            self.append(
                session,
                "mux",
                "auto_resume_skipped",
                json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "skipped": reason}),
            );
            return None;
        }
        let id = format!("{root}{SUFFIX}{attempt}");
        // Logged by a daemon that crashed before it settled the turn: once is enough.
        if self.logged_prompt(session, &id).is_some() {
            return Some(id);
        }
        let msg = json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "delayMs": 0, "reason": "daemon_restart"});
        self.append(session, "mux", "auto_resume_scheduled", msg);
        let text = continue_text(&prompts);
        let provenance = json!({"kind": "auto_resume", "reason": "daemon_restart", "promptId": root, "attempt": attempt, "turnId": turn_id});
        let control = if raised_to_web { "web" } else { control.as_deref().unwrap_or("web") };
        let mut blocks = vec![json!({"type": "text", "text": text})];
        blocks.extend(super::super::prompt_images::blocks_of(&images));
        let mut queued = json!({
            "text": text,
            "client": "acpmux",
            "position": 0,
            "promptId": id,
            "turnId": format!("{turn_id}{SUFFIX}{attempt}"),
            "prompt": blocks,
            "control": control,
            // Checked again as the cut turn was: the folder's trust may have changed across the
            // restart. A Web turn (by its start or a Web steer) is always checked again, as is
            // one from a log from before `turn_started` recorded its gate.
            "trustGate": control == "web" || gate.unwrap_or(false),
        });
        if !images.is_empty() {
            queued["images"] = Value::Array(images);
        }
        let queued = crate::prompt_provenance::marked(queued, Some(&provenance));
        self.append(session, "mux", "queued", queued);
        Some(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};

    /// A hub holding one chat whose last turn a restart cut, with `delays` as
    /// `autoResumeDelaysMs` (`None`: the key is unset). `done` continuations ran for it already,
    /// as its prompt id's attempt suffix records. The caller removes `root` when it is done.
    fn cut_turn(
        delays: Option<Vec<u64>>,
        done: usize,
    ) -> (std::path::PathBuf, Arc<Hub>, Arc<Session>) {
        let root =
            std::env::temp_dir().join(format!("acpmux-restart-resume-{}", uuid::Uuid::now_v7()));
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        cfg.auto_resume_delays_ms = delays;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
            // `idle`: no child process, which is what a daemon restart leaves behind. "open" is
            // not a SessionStatus, and serde refused it before the fixture was even built.
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("c1").unwrap();
        let prompt_id = if done == 0 { "p1".to_owned() } else { format!("p1{SUFFIX}{done}") };
        hub.append(&session, "in", "turn_started", json!({"turnId": "t1", "promptId": prompt_id}));
        hub.append(&session, "in", "user_message", json!({"turnId": "t1", "text": "do the thing"}));
        (root, hub, session)
    }

    /// Why the chat logged `auto_resume_exhausted`, if it did.
    fn exhausted(hub: &Hub) -> Vec<Value> {
        hub.events("c1", 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "auto_resume_exhausted")
            .map(|e| e.msg)
            .collect()
    }

    /// What one cut turn's chain does with `delays` configured and `done` continuations behind
    /// it: the continuation's prompt id if one goes out, and what it logged as exhausted.
    async fn chain(delays: Option<Vec<u64>>, done: usize) -> (Option<String>, Vec<Value>) {
        let (root, hub, session) = cut_turn(delays, done);
        let id = hub.log_restart_continuation(&session, "t1");
        let gave_up = exhausted(&hub);
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
        (id, gave_up)
    }

    /// One continuation per configured wait, for a chain of restarts as for a transport cut:
    /// `autoResumeDelaysMs` is the whole loop, not only its waits.
    #[tokio::test]
    async fn the_configured_waits_set_how_many_restart_continuations_run() {
        // One wait: the first continuation goes out.
        let (id, gave_up) = chain(Some(vec![10_000]), 0).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}1")));
        assert!(gave_up.is_empty(), "{gave_up:?}");

        // The second has no wait left, so the chain gives up instead of running a fixed four.
        let (id, gave_up) = chain(Some(vec![10_000]), 1).await;
        assert_eq!(id, None);
        // The fields the record is for, not the whole object: a field added to the record later
        // is not this test's business.
        assert_eq!(gave_up.len(), 1, "{gave_up:?}");
        let msg = &gave_up[0];
        assert_eq!(
            (&msg["promptId"], &msg["attempts"], &msg["turnId"], &msg["reason"]),
            (&json!("p1"), &json!(1), &json!("t1"), &json!("daemon_restart")),
            "{msg}"
        );

        // A loop longer than the default's four runs all of its attempts.
        let (id, gave_up) = chain(Some(vec![10_000; 6]), 5).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}6")));
        assert!(gave_up.is_empty(), "{gave_up:?}");
    }

    /// The key unset keeps the default waits' four attempts, and `[]` still turns it off.
    #[tokio::test]
    async fn an_unset_key_keeps_the_default_attempts_and_an_empty_list_turns_it_off() {
        let (id, _) = chain(None, 3).await;
        assert_eq!(id, Some(format!("p1{SUFFIX}4")));

        let (id, gave_up) = chain(None, 4).await;
        assert_eq!(id, None);
        assert_eq!(gave_up.len(), 1, "{gave_up:?}");

        // Off is not a chain that ran out: it logs nothing.
        let (id, gave_up) = chain(Some(vec![]), 0).await;
        assert_eq!(id, None);
        assert!(gave_up.is_empty(), "{gave_up:?}");
    }

    #[test]
    fn the_continuation_quotes_the_cut_prompt_and_its_steers() {
        let text = continue_text(&["do the thing".into(), "also this".into()]);
        assert!(text.contains("Its prompt:\n<message>\ndo the thing\n</message>"), "{text}");
        assert!(text.contains("A message sent into it:\n<message>\nalso this\n</message>"));
        assert!(text.ends_with("Do not redo work that completed."));
        let long = continue_text(&["x".repeat(MAX_QUOTE_CHARS + 10)]);
        assert!(!long.contains(&"x".repeat(MAX_QUOTE_CHARS + 1)));
    }
}
