//! Part of `Hub`; see `hub/mod.rs`. The daemon's memory consumers
//! (`crate::memory`, Chrome's `MemoryConsumer`s): what each holds and what it
//! gives back at each level.
//!
//! - Lossless, emptied at warning: the parsed login files behind the pool keys
//!   (read again on the next fingerprint), and the stderr tail of each session
//!   whose agent acpmux stopped (no failure report can quote it any more).
//! - Lossy, at critical: each session's completed prompt outcomes past its
//!   newest [`CRITICAL_PROMPT_OUTCOMES`] (an older retry runs again), and the
//!   live model lists (the curated lists stand in; they come back from disk at
//!   normal, or with the next probe). Watchers hear both changes as
//!   `_acpmux/harnesses_changed`.
//! - Reported only: the chat index and the login environment, which are the
//!   daemon's working state.

use super::{Hub, Session, prompt_ledger};
use crate::memory::{inline_bytes, string_bytes};
use crate::store::SessionStatus;
use crate::supervised::{Fatal, ShutdownBehavior};
use cmux_memory::{MemoryConsumer, PressureLevel, Registration, Retention};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError, Weak};

/// The completed prompt outcomes a session keeps at critical: a client's
/// retry comes within moments of its prompt, so the newest few cover it.
pub(super) const CRITICAL_PROMPT_OUTCOMES: usize = 8;

/// The registry names of the daemon's consumers.
pub(crate) mod names {
    pub const AUTH_CACHE: &str = "pool.auth_cache";
    pub const STDERR_TAILS: &str = "sessions.stderr_tails";
    pub const PROMPT_OUTCOMES: &str = "sessions.prompt_outcomes";
    pub const LIVE_MODELS: &str = "live_models";
    pub const CHAT_INDEX: &str = "chats.index";
    pub const LOGIN_ENV: &str = "login_env";
}

/// Whether `level` asks lossless consumers to give back (warning and up).
fn releases_lossless(level: PressureLevel) -> bool {
    level >= PressureLevel::Warning
}

impl Session {
    /// What the daemon keeps in memory for this session, estimated: the
    /// session itself, its metadata's text, queue, prompt outcomes, stderr
    /// tail and streaming text. Never blocks: a field whose lock is held now
    /// is left out.
    pub(crate) fn approx_bytes(&self) -> u64 {
        let mut bytes = inline_bytes::<Self>(1);
        if let Ok(meta) = self.meta.try_lock() {
            bytes += string_bytes(&meta.id)
                + string_bytes(&meta.name)
                + string_bytes(&meta.harness)
                + meta.harness_argv.iter().map(|a| string_bytes(a)).sum::<u64>()
                + meta.cwd.as_os_str().len() as u64
                + meta.title.as_deref().map_or(0, string_bytes);
        }
        if let Ok(queue) = self.queue.try_lock() {
            bytes += inline_bytes::<super::QueuedPrompt>(queue.capacity());
            bytes += queue
                .iter()
                .map(|q| {
                    string_bytes(&q.prompt_id)
                        + string_bytes(&q.turn_id)
                        + string_bytes(&q.client)
                        + string_bytes(&q.preview)
                })
                .sum::<u64>();
        }
        bytes += self.prompt_outcome_bytes();
        bytes += self.stderr_tail_bytes();
        if let Ok(stream) = self.stream.try_lock() {
            bytes += stream.trailing_text.capacity() as u64
                + inline_bytes::<u64>(stream.trailing_seqs.capacity());
        }
        bytes
    }

    fn stderr_tail_bytes(&self) -> u64 {
        self.stderr_tail.try_lock().map_or(0, |tail| {
            inline_bytes::<String>(tail.capacity())
                + tail.iter().map(|l| string_bytes(l)).sum::<u64>()
        })
    }

    fn prompt_outcome_bytes(&self) -> u64 {
        type Entry = (String, super::PromptOutcome);
        self.prompts.try_lock().map_or(0, |ledger| {
            inline_bytes::<Entry>(ledger.capacity())
                + ledger.iter().map(|(id, _)| string_bytes(id)).sum::<u64>()
        })
    }

    /// Drops the stderr tail of an agent acpmux stopped: no process, no
    /// start (`spawn_lock`, whose failure quotes the tail), no turn, and an
    /// idle or closed status. An agent that died on its own leaves the session
    /// disconnected, and the start, turn or request it failed still quotes its
    /// tail. Whether it dropped lines.
    pub(crate) fn drop_stderr_tail_of_stopped_agent(&self) -> bool {
        let Ok(_starting) = self.spawn_lock.try_lock() else { return false };
        let Ok(child) = self.child.try_lock() else { return false };
        let stopped = matches!(self.status(), SessionStatus::Idle | SessionStatus::Closed);
        if child.is_some() || self.turn().is_some() || !stopped {
            return false;
        }
        let tail =
            std::mem::take(&mut *self.stderr_tail.lock().unwrap_or_else(PoisonError::into_inner));
        !tail.is_empty()
    }

    /// Keeps only the newest `keep` completed prompt outcomes (pending ones
    /// stay) and gives back the ledger's spare room.
    pub(crate) fn trim_prompt_outcomes(&self, keep: usize) {
        let mut ledger = self.prompts.lock().unwrap_or_else(PoisonError::into_inner);
        prompt_ledger::prune_to(&mut ledger, keep);
        ledger.shrink_to_fit();
    }
}

impl Hub {
    /// The daemon's memory registry and its kernel source (`crate::memory`).
    pub fn memory(&self) -> &crate::memory::AcpmuxMemory {
        &self.memory
    }

    /// Registers the hub's consumers once; they hold the hub weakly and end
    /// with it.
    pub(super) fn register_memory_consumers(self: &Arc<Self>) {
        let registrations = self.memory_consumer_list();
        // A second call keeps the first set; the new one unregisters as it drops.
        let _ = self.memory_consumers.set(registrations);
    }

    fn memory_consumer_list(self: &Arc<Self>) -> Vec<Registration> {
        let registry = self.memory.registry();
        let hub = Arc::downgrade(self);
        let with = move |f: fn(&Hub) -> Option<u64>| {
            let hub = hub.clone();
            move || hub.upgrade().and_then(|hub| f(&hub))
        };
        let on = |f: fn(&Hub, PressureLevel)| {
            let hub = Arc::downgrade(self);
            move |level| {
                if let Some(hub) = hub.upgrade() {
                    f(&hub, level);
                }
            }
        };
        vec![
            registry.register(MemoryConsumer::new(
                names::AUTH_CACHE,
                Retention::Lossless,
                with(|hub| Some(hub.pool.auth_cache().approx_bytes())),
                on(|hub, level| {
                    if releases_lossless(level) {
                        hub.pool.auth_cache().clear();
                    }
                }),
            )),
            registry.register(MemoryConsumer::new(
                names::STDERR_TAILS,
                Retention::Lossless,
                with(|hub| Some(hub.sessions().iter().map(|s| s.stderr_tail_bytes()).sum())),
                on(|hub, level| {
                    if releases_lossless(level) {
                        hub.sessions().iter().for_each(|s| {
                            s.drop_stderr_tail_of_stopped_agent();
                        });
                    }
                }),
            )),
            registry.register(MemoryConsumer::new(
                names::PROMPT_OUTCOMES,
                Retention::Lossy,
                with(|hub| Some(hub.sessions().iter().map(|s| s.prompt_outcome_bytes()).sum())),
                on(|hub, level| {
                    if level == PressureLevel::Critical {
                        hub.sessions()
                            .iter()
                            .for_each(|s| s.trim_prompt_outcomes(CRITICAL_PROMPT_OUTCOMES));
                    }
                }),
            )),
            registry.register(self.live_models_consumer()),
            registry.register(MemoryConsumer::new(
                names::CHAT_INDEX,
                Retention::Lossy,
                with(|hub| hub.chats.get().and_then(|chats| chats.approx_bytes())),
                |_| {},
            )),
            registry.register(MemoryConsumer::new(
                names::LOGIN_ENV,
                Retention::Lossy,
                || Some(crate::login_env::imported_bytes()),
                |_| {},
            )),
        ]
    }

    /// The live model lists: emptied at critical, read back from their disk
    /// cache when the level returns to normal, each change announced to
    /// watchers, on the runtime that built the hub. A hub built with no
    /// runtime could neither announce nor refill them, so it keeps them.
    fn live_models_consumer(self: &Arc<Self>) -> MemoryConsumer {
        let runtime = tokio::runtime::Handle::try_current().ok();
        let emptied = Arc::new(AtomicBool::new(false));
        let (bytes_hub, release_hub): (Weak<Hub>, Weak<Hub>) =
            (Arc::downgrade(self), Arc::downgrade(self));
        MemoryConsumer::new(
            names::LIVE_MODELS,
            Retention::Lossy,
            move || bytes_hub.upgrade().map(|hub| hub.live_models_bytes()),
            move |level| {
                let (Some(hub), Some(runtime)) = (release_hub.upgrade(), &runtime) else { return };
                match level {
                    PressureLevel::Critical => {
                        let lists = std::mem::take(
                            &mut *hub.live_models.lock().unwrap_or_else(PoisonError::into_inner),
                        );
                        if !lists.is_empty() {
                            emptied.store(true, Ordering::Relaxed);
                            drop(lists);
                            let _on_runtime = runtime.enter();
                            let announced = hub.clone();
                            hub.supervise(
                                "hub.memory-announce",
                                Fatal,
                                ShutdownBehavior::Skip,
                                async move { announced.announce_harnesses().await },
                            );
                        }
                    }
                    PressureLevel::Normal if emptied.swap(false, Ordering::Relaxed) => {
                        let _on_runtime = runtime.enter();
                        let refilled = hub.clone();
                        hub.supervise(
                            "hub.memory-refill",
                            Fatal,
                            ShutdownBehavior::Skip,
                            async move {
                                if refilled.load_live_cache().await {
                                    refilled.announce_harnesses().await;
                                }
                            },
                        );
                    }
                    _ => {}
                }
            },
        )
    }

    fn live_models_bytes(&self) -> u64 {
        let live = self.live_models.lock().unwrap_or_else(PoisonError::into_inner);
        live.iter()
            .map(|(harness, models)| {
                string_bytes(harness)
                    + inline_bytes::<Vec<crate::live_models::LiveModel>>(1)
                    + models.iter().map(|m| m.approx_bytes()).sum::<u64>()
            })
            .sum()
    }
}

#[cfg(test)]
#[path = "memory_consumers_tests.rs"]
mod tests;
