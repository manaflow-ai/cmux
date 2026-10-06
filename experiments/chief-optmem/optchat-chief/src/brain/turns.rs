//! The turn loop (section 7): the settle worker, taking the queue into a
//! turn, delivering messages between tool calls (native engine) or
//! stopping the turn for them (acpmux engine), and the turn's end.

use std::sync::Arc;
use std::sync::mpsc::channel;

use optchat_core::Kind;

use super::{Brain, Engine, Input, Phase, Queued, STALL_NOTICE, Source, reply_entry, reply_key};
use std::sync::atomic::Ordering;

use crate::acpmux::SessionSpec;
use crate::compactor::is_marker_limit_error;
use crate::prompt::{cached_layout, turn_blocks};
use crate::state::{Batch, ChildRef, ChildStatus, Item, PendingTurn};
use crate::turn::{self, Interrupt, TurnOutcome, TurnStart};

impl Brain {
    /// Starts a turn worker when idle with something queued.
    pub(super) fn maybe_start_turn(&mut self) {
        if self.phase != Phase::Idle || self.queue.is_empty() || !self.ready() {
            return;
        }
        self.phase = Phase::Settling;
        self.interrupt = Arc::new(Interrupt::new());
        let (chat, agents, tx, log, engine, interrupt, marker_refused) = (
            self.chat.clone(),
            self.agents.clone(),
            self.tx.clone(),
            self.log.clone(),
            self.settings.engine.clone(),
            self.interrupt.clone(),
            self.marker_refused.clone(),
        );
        let spawned = std::thread::Builder::new()
            .name("turn".into())
            .spawn(move || {
                // Section 6: no turn starts before every view line is a summary.
                // The wait has no deadline; a line each minute says what it
                // waits on, and the first one with a failing node also goes to
                // the conversation, so the user is not left without a word.
                let mut told = false;
                while !chat.settle(None, Some(STALL_NOTICE)) {
                    let status = chat.status();
                    if status.closed || status.fatal.is_some() {
                        let _ = tx.send(Input::SettleFailed);
                        return;
                    }
                    let failing: Vec<String> = status
                        .failures
                        .iter()
                        .map(|f| format!("{}: {}", f.node.name(), f.error))
                        .collect();
                    log(&format!(
                        "turn waits for the compactor: {} view lines unbuilt; failing: {}",
                        status.unbuilt,
                        if failing.is_empty() {
                            "none".to_owned()
                        } else {
                            failing.join("; ")
                        }
                    ));
                    if !told && let Some(first) = status.failures.first() {
                        told = true;
                        let _ = tx.send(Input::Stalled(format!(
                            "(waiting: the Chief's memory cannot summarize line {} yet, so your message waits. First error: {}. It is retried every 10 s.)",
                            first.node.name(),
                            first.error
                        )));
                    }
                }
                let (reply, start) = channel();
                if tx.send(Input::Settled(reply)).is_err() {
                    return;
                }
                let Ok(Some(start)) = start.recv() else {
                    return;
                };
                let outcome = match &engine {
                    Engine::Acpmux => {
                        let progress = |session_id: &str, after: u64| {
                            let _ = tx.send(Input::TurnProgress {
                                key: start.key.clone(),
                                session_id: session_id.to_owned(),
                                after,
                            });
                        };
                        let outcome =
                            turn::run(&*agents, &chat, &start, &interrupt, &*log, &progress);
                        // Claude Code placed all four cache breakpoints
                        // itself: the same turn again without the marker
                        // (the refused request did nothing), and later
                        // turns go without it.
                        let marked = start
                            .blocks
                            .iter()
                            .any(|b| b.get("cache_control").is_some());
                        match &outcome.error {
                            Some(e) if marked && is_marker_limit_error(e) => {
                                marker_refused.store(true, Ordering::SeqCst);
                                log(&format!(
                                    "turn {}: Claude Code refused the cache_control marker ({e}); running the turn again without it, and later turns go without it",
                                    start.key
                                ));
                                let mut again = start.clone();
                                for block in &mut again.blocks {
                                    if let Some(b) = block.as_object_mut() {
                                        b.remove("cache_control");
                                    }
                                }
                                again.prompt_id = format!("{}:unmarked", start.prompt_id);
                                turn::run(&*agents, &chat, &again, &interrupt, &*log, &progress)
                            }
                            _ => outcome,
                        }
                    }
                    Engine::Native(native) => {
                        let mailbox = || {
                            let (reply, texts) = channel();
                            let asked = tx.send(Input::Boundary {
                                key: start.key.clone(),
                                reply,
                            });
                            if asked.is_err() {
                                return Vec::new();
                            }
                            texts.recv().unwrap_or_default()
                        };
                        native.run(&chat, &start, &*log, &mailbox, &|| interrupt.is_set())
                    }
                };
                let _ = tx.send(Input::TurnEnded {
                    key: start.key,
                    outcome,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting a turn failed: {e}"));
            self.phase = Phase::Idle;
        }
    }

    /// The worker settled the view. Between its check and now the brain may
    /// have lost acpmux (the turn would fail at once and consume the queue)
    /// or appended to the log (an orphan's fold), which can leave a view line
    /// unsummarized again; then the queue stays and the wait starts over
    /// (section 6: no call ever sees the placeholder).
    pub(super) fn settled(&mut self) -> Option<TurnStart> {
        if !self.ready() {
            // The next `Up` starts the turn.
            self.phase = Phase::Idle;
            return None;
        }
        if self.chat.status().unbuilt > 0 {
            self.phase = Phase::Idle;
            self.maybe_start_turn();
            return None;
        }
        let start = self.take_turn();
        if start.is_none() && self.phase == Phase::Settling {
            self.phase = Phase::Idle;
        }
        start
    }

    /// Section 7 after `settle`: take every queued message, render the view
    /// BEFORE logging them, then log each as `user`.
    fn take_turn(&mut self) -> Option<TurnStart> {
        if self.queue.is_empty() {
            return None;
        }
        let items: Vec<Queued> = self.queue.drain(..).collect();
        let view = self.chat.render_view();
        // Saved before the first append: a crash between an append and the
        // next save must not log a message twice at restart (recover.rs).
        let first_id = self.chat.status().messages;
        self.state.turn = Some(PendingTurn {
            conversation: self.state.conversation.clone(),
            session: format!("{}-{first_id}", self.settings.turn_prefix),
            first_id: Some(first_id),
            items: items.iter().map(item).collect(),
            ..PendingTurn::default()
        });
        self.save();
        let first = self.log_items(&items)?;
        let key = reply_key(&self.chat, first);
        if let Some(turn) = self.state.turn.as_mut() {
            turn.key = key.clone();
        }
        self.save();
        self.set_cursor(self.handled);
        self.set_typing(true);
        self.phase = Phase::Running;
        self.stop_wanted = false;
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        // The cached layout on a Claude harness whose acpmux takes a preset
        // system prompt; else the view and the messages as blocks.
        let cached = matches!(self.settings.engine, Engine::Acpmux)
            .then_some(self.settings.turn_preset.as_deref())
            .flatten()
            .filter(|preset| self.agents.system_prompt(preset));
        let (blocks, system_prompt, preset) = match cached {
            Some(preset) => {
                let layout = cached_layout(
                    &self.settings.system_text,
                    &view.text,
                    &texts.join("\n\n"),
                    !self.marker_refused.load(Ordering::SeqCst),
                );
                (layout.blocks, Some(layout.system), Some(preset.to_owned()))
            }
            None => (turn_blocks(&view.text, &texts), None, None),
        };
        if self.settings.turn_preset.is_some() {
            // The system prompt carries the instructions in the cached
            // layout; the old layout reads them from CLAUDE.md.
            let text = system_prompt
                .is_none()
                .then_some(self.settings.system_text.as_str());
            if let Err(e) = crate::session_dir::set_claude_md(&self.settings.session_dir, text) {
                (self.log)(&format!("updating the session directory's CLAUDE.md: {e}"));
            }
        }
        Some(TurnStart {
            prompt_id: format!("optchat:{first}"),
            session: SessionSpec {
                name: format!("{}-{first}", self.settings.turn_prefix),
                cwd: self.settings.session_dir.clone(),
                harness: self.settings.harness.clone(),
                policy: self.settings.policy.clone(),
                model: self.settings.model.clone(),
                effort: self.settings.effort.clone(),
                preset,
                tags: crate::acpmux::chief_tags(&self.settings.chief_id, "turn"),
            },
            blocks,
            system_prompt,
            key,
            limit: self.settings.turn_limit,
        })
    }

    /// Logs `items` as `user` entries and finishes their bookkeeping; returns
    /// the first one's id. On a failed write nothing is posted for them and
    /// the host stops (the conversation's cursor stays before them).
    fn log_items(&mut self, items: &[Queued]) -> Option<u64> {
        let mut first = None;
        for item in items {
            match self.chat.append(Kind::User, &item.text) {
                Ok(id) => {
                    first.get_or_insert(id);
                }
                Err(e) => {
                    (self.log)(&format!("logging a message failed: {e}"));
                    self.fatal = Some(format!("the memory stopped writing: {e}"));
                    self.phase = Phase::Idle;
                    return None;
                }
            }
        }
        for item in items {
            if let Source::Child { session_id, floor } = &item.source
                && let Some(record) = self.state.children.get_mut(session_id)
            {
                record.status = ChildStatus::Reported;
                record.floor = *floor;
            }
        }
        // The queue is empty now, so every handled seq is logged or needed no log.
        self.state.logged_seq = self.handled;
        first
    }

    /// A native turn is between tool calls: everything queued is logged as
    /// `user` and delivered (section 7: "Messages the user types mid-run are
    /// delivered at the agent's next tool boundary and logged as `user`").
    pub(super) fn boundary(&mut self, key: &str) -> Vec<String> {
        let current = self.state.turn.as_ref().is_some_and(|t| t.key == key);
        if self.phase != Phase::Running || !current {
            return Vec::new();
        }
        // Everything queued is delivered now: the interrupt is answered.
        self.interrupt.clear();
        if self.queue.is_empty() {
            return Vec::new();
        }
        let items: Vec<Queued> = self.queue.drain(..).collect();
        let at = self.chat.status().messages;
        if let Some(turn) = self.state.turn.as_mut() {
            turn.mid.push(Batch {
                at,
                items: items.iter().map(item).collect(),
                done: false,
            });
        }
        self.save();
        if self.log_items(&items).is_none() {
            return Vec::new();
        }
        if let Some(batch) = self.state.turn.as_mut().and_then(|t| t.mid.last_mut()) {
            batch.done = true;
        }
        self.save();
        self.set_cursor(self.handled);
        items.into_iter().map(|i| i.text).collect()
    }

    /// A human message arrived during a turn (decision 2026-10-04): the
    /// model is interrupted at once, even mid-thinking, and a running tool
    /// call finishes first. The native engine aborts its stream and calls
    /// the model again with the message; the acpmux engine stops the turn
    /// (`session/cancel`, sent by the turn's runner once no tool runs, and
    /// again until the turn ends), and the next fresh turn answers with the
    /// view of everything the stopped turn did. "thanks" interrupts too.
    pub(super) fn interrupt_for_newer(&mut self) {
        if self.phase != Phase::Running {
            return;
        }
        if matches!(self.settings.engine, Engine::Acpmux) {
            self.stop_wanted = true;
        }
        self.interrupt.request();
    }

    /// An acpmux turn's session id and fold position, saved so a host that
    /// stops mid-turn folds the rest at the next start.
    pub(super) fn progress(&mut self, key: &str, session_id: String, after: u64) {
        let Some(turn) = self.state.turn.as_mut().filter(|t| t.key == key) else {
            return;
        };
        if turn.session_id.as_deref() != Some(session_id.as_str()) || turn.after != after {
            turn.session_id = Some(session_id);
            turn.after = after;
            self.save();
        }
    }

    pub(super) fn turn_ended(&mut self, key: &str, outcome: TurnOutcome) {
        let conversation = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .and_then(|t| t.conversation.clone());
        // A turn stopped for a newer message posts nothing: the next turn,
        // which starts now with that message, answers both.
        let superseded = outcome.cancelled && self.stop_wanted;
        // A turn that failed after it said something posts both: its last
        // words alone (often "Let me check.") would read as the answer.
        let text = match (outcome.reply, outcome.error) {
            _ if superseded => String::new(),
            (Some(reply), Some(error)) => format!("{reply}\n\n(turn failed: {error})"),
            (Some(reply), None) => reply,
            (None, Some(error)) => format!("(turn failed: {error})"),
            (None, None) => String::new(),
        };
        if superseded {
            (self.log)(&format!("turn {key} stopped for a newer message"));
        }
        if let Some(orphan) = outcome.orphan {
            self.state.orphans.push(orphan);
        }
        match conversation {
            Some(conversation) if !text.is_empty() => {
                self.state
                    .outbox
                    .push(reply_entry(conversation, key, &text));
            }
            Some(_) => {}
            None => (self.log)(&format!(
                "turn {key} ended with no conversation to answer in"
            )),
        }
        self.state.turn = None;
        self.stop_wanted = false;
        self.save();
        self.flush_outbox();
        self.set_typing(false);
        self.phase = Phase::Idle;
        if let Some(hook) = &self.after_turn {
            hook(key);
        }
        self.maybe_start_turn();
    }
}

/// A queued item's source as the pending turn saves it.
fn item(queued: &Queued) -> Item {
    match &queued.source {
        Source::Message { seq } => Item {
            seq: Some(*seq),
            child: None,
        },
        Source::Child { session_id, floor } => Item {
            seq: None,
            child: Some(ChildRef {
                session_id: session_id.clone(),
                floor: *floor,
            }),
        },
        Source::Note => Item::default(),
    }
}
