//! One durable point per creation (create-txn).
//!
//! A creation commits several registry rows in a row. [`CreateTxn`] makes
//! those commits share one WAL sync (`workspace_registry::deferred_sync`)
//! and holds what the creating thread publishes meanwhile (mux events,
//! journal wakeups) until that sync, in the order it was published. Other
//! threads that read the registry, the mux state or the presentation cache
//! sync first, so nothing a creation committed is seen anywhere before it is
//! durable, and the creation answers only after it.

use std::cell::RefCell;

use super::*;
use crate::workspace_registry::deferred_sync::DeferScope;

/// What the creating thread published while its commits were unsynced.
struct HeldPublications {
    /// The mux that opened the scope (an address, compared only).
    mux: usize,
    depth: usize,
    events: Vec<MuxEvent>,
    journal_wake: bool,
}

thread_local! {
    static HELD: RefCell<Option<HeldPublications>> = const { RefCell::new(None) };
}

/// An open creation transaction on the current thread (see the module docs).
pub(crate) struct CreateTxn<'a> {
    mux: &'a Mux,
    scope: Option<DeferScope>,
}

impl Mux {
    /// Open a creation transaction on the current thread. Scopes nest; the
    /// outermost one syncs and publishes.
    pub(crate) fn begin_create_txn(&self) -> CreateTxn<'_> {
        let key = self as *const Mux as usize;
        let nested = HELD.with(|held| {
            let mut held = held.borrow_mut();
            match held.as_mut() {
                Some(held) if held.mux == key => {
                    held.depth += 1;
                    true
                }
                // Another mux's creation on this thread (tests run several
                // muxes in one process): leave it alone.
                Some(_) => true,
                None => {
                    *held = Some(HeldPublications {
                        mux: key,
                        depth: 1,
                        events: Vec::new(),
                        journal_wake: false,
                    });
                    false
                }
            }
        });
        let scope = (!nested).then(|| self.registry_connection.deferred_sync().scope());
        CreateTxn { mux: self, scope }
    }

    /// `event` if it may go out now, `None` when the current thread's
    /// creation holds it until its sync.
    pub(super) fn hold_event_in_create_txn(&self, event: MuxEvent) -> Option<MuxEvent> {
        let key = self as *const Mux as usize;
        HELD.with(|held| match held.borrow_mut().as_mut() {
            Some(held) if held.mux == key => {
                held.events.push(event);
                None
            }
            _ => Some(event),
        })
    }

    /// True when the current thread's creation holds journal wakeups.
    pub(super) fn hold_journal_wake_in_create_txn(&self) -> bool {
        let key = self as *const Mux as usize;
        HELD.with(|held| match held.borrow_mut().as_mut() {
            Some(held) if held.mux == key => {
                held.journal_wake = true;
                true
            }
            _ => false,
        })
    }
}

impl CreateTxn<'_> {
    /// Make every commit of the creation durable, then publish what it
    /// held. A sync failure is returned after the publications go out: the
    /// commits are in the database either way, and readers retry the sync.
    pub(crate) fn finish(mut self) -> anyhow::Result<()> {
        self.close()
    }

    fn close(&mut self) -> anyhow::Result<()> {
        let key = self.mux as *const Mux as usize;
        let outermost = HELD.with(|held| {
            let mut slot = held.borrow_mut();
            let last = match slot.as_mut() {
                Some(held) if held.mux == key => {
                    held.depth -= 1;
                    held.depth == 0
                }
                _ => false,
            };
            if last { slot.take() } else { None }
        });
        let Some(held) = outermost else { return Ok(()) };
        let synced = match self.scope.take() {
            Some(scope) => scope.finish(),
            None => Ok(()),
        };
        crate::debug_spans::mark("create_txn.synced");
        for event in held.events {
            self.mux.emit(event);
        }
        if held.journal_wake {
            self.mux.publish_journal_event();
        }
        synced.context("sync the registry WAL after a creation")
    }
}

impl Drop for CreateTxn<'_> {
    fn drop(&mut self) {
        if let Err(error) = self.close() {
            eprintln!("cmux-tui: {error:#}");
        }
    }
}
