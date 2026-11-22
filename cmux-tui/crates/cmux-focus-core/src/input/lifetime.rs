//! Sink lifetimes (DESIGN.md sections 4.6 and 4.7): creations and their
//! replies, and the sinks that ended.
//!
//! A creation's sink takes the keys typed for it from the creation on. The
//! creation stays known until its reply, and a done creation until a window
//! shows its tab: the reply and the store's delta that shows the tab are
//! separate messages, in either order (PR #34052 reviews: first review
//! finding 2, second review finding 1). A failure ends the sink, shown or not.
//!
//! A tab's sink that ended (its terminal, its content, its developer tools)
//! takes no key while its tab still shows.
//! - Exited (a terminal whose process ended, its tab stays with its end
//!   banner): it stays ended wherever its tab shows (another workspace, another
//!   window, a window closed and opened again) until a creation names it again
//!   (a restart) or its tab closes (second review, finding 2). A restart that
//!   fails leaves the dead tab, so the sink is exited again (third review).
//! - Closed or failed: it takes keys again only as a new sink of its id: a
//!   window shows it again after none did (Reopen Closed reuses the tab id),
//!   or a creation names it again (first review, finding 1). One that no
//!   window shows and no held key names is forgotten: nothing can aim a key
//!   at it, and a sink of its id is a new one.
//!
//! A window's field, overlay or dialog never ends that way: an end only drops
//! its waiting keys.

use super::router::{InputRouter, Press, content_sink};
use super::sink::{Sink, TerminalKey};
use super::{DropReason, GoneReason, InputEffect};
use crate::state::ExpectationKey;
use crate::topology::Kind;
use std::collections::HashSet;
use std::sync::Arc;

/// A creation, until its reply and a window shows its tab.
pub(super) struct Creation {
    pub(super) sink: Sink,
    pub(super) kind: Kind,
    /// The tab it makes, when its key or its sink names it.
    pub(super) tab: Option<Arc<str>>,
    /// Its reply came: it is done (a failure after it changes nothing).
    replied: bool,
    /// It names again a sink that had exited (a restart): if it fails, the
    /// dead tab stays, and so does the exit.
    restarts_exited: bool,
}

/// A tab's sink that ended.
#[derive(Clone, Copy)]
pub(super) struct Gone {
    pub(super) reason: GoneReason,
    /// No window showed the sink since it ended.
    left: bool,
}

impl InputRouter {
    /// A creation makes `sink`, a tab of `kind`, under `key`.
    pub(super) fn creation(&mut self, key: &ExpectationKey, sink: &Sink, kind: Kind) {
        let was = self.facts.gone.remove(sink);
        if was.is_some() {
            self.renew(sink);
        }
        let restarts_exited = was.is_some_and(|gone| gone.reason == GoneReason::Exited);
        let tab = match (key, sink) {
            (ExpectationKey::Tab { id }, _) => Some(Arc::from(id.as_str())),
            (
                ExpectationKey::Surface { .. },
                Sink::Content(tab) | Sink::DevTools(tab) | Sink::Terminal(TerminalKey::Tab(tab)),
            ) => Some(tab.clone()),
            (ExpectationKey::Surface { .. }, _) => None,
        };
        let creation = Creation { sink: sink.clone(), kind, tab, replied: false, restarts_exited };
        self.creations.insert(key.clone(), creation);
    }

    /// The creation under `key` is done: it is kept until a window shows its
    /// tab, so the keys typed for the tab still go to its sink.
    pub(super) fn creation_done(&mut self, key: &ExpectationKey) {
        if let Some(creation) = self.creations.get_mut(key) {
            creation.replied = true;
        }
        self.forget_shown_creations();
    }

    /// The creation under `key` failed: its sink ends (one reply a creation:
    /// a failure after it was done changes nothing). A failed restart of an
    /// exited sink leaves the dead tab: the sink is exited again.
    pub(super) fn creation_failed(&mut self, key: &ExpectationKey) {
        if self.creations.get(key).is_some_and(|creation| !creation.replied)
            && let Some(creation) = self.creations.remove(key)
        {
            let reason = if creation.restarts_exited {
                GoneReason::Exited
            } else {
                GoneReason::CreationFailed
            };
            self.end(&creation.sink, reason);
        }
    }

    /// Forgets the done creations a window shows the tab of: that window's
    /// topology names their sink from now (a route never changes by it).
    pub(super) fn forget_shown_creations(&mut self) {
        let windows = &self.windows;
        self.creations.retain(|key, creation| {
            !creation.replied || !windows.values().any(|window| window.shows(key))
        });
    }

    /// `sink` ended: its waiting keys are dropped with the reason. A tab's sink
    /// also takes no key later until it is a new sink, and its page's offers
    /// can get no answer. An exited sink whose tab then closes is gone for
    /// good (a reopen of the tab is a new sink).
    pub(super) fn end(&mut self, sink: &Sink, reason: GoneReason) {
        self.facts.ready.remove(sink);
        if sink.of_tab() {
            self.creations.retain(|_, creation| creation.sink != *sink);
            let left = !self.shown_sinks().contains(sink);
            let changed = match self.facts.gone.get_mut(sink) {
                Some(gone) if gone.reason == GoneReason::Exited && reason != GoneReason::Exited => {
                    *gone = Gone { reason, left };
                    true
                }
                Some(_) => false,
                None => {
                    self.facts.gone.insert(sink.clone(), Gone { reason, left });
                    true
                }
            };
            if changed {
                self.push(InputEffect::SinkEnded { sink: sink.clone(), reason });
            }
            self.close_offers_of(sink);
        }
        self.drop_lanes(vec![sink.clone()], DropReason::SinkGone(reason));
    }

    /// Why a key for `sink` reaches nothing now: the sink ended, or it is a
    /// dialog that no longer shows.
    pub(super) fn ended(&self, sink: &Sink) -> Option<GoneReason> {
        if let Sink::Dialog(dialog) = sink {
            return (!self.dialogs.iter().any(|(id, _)| id == dialog))
                .then_some(GoneReason::Closed);
        }
        self.facts.gone.get(sink).map(|gone| gone.reason)
    }

    /// After a topology changed or a window closed: a closed or failed sink
    /// that a window shows again after none did is a new sink; one that no
    /// window shows and no held key names is forgotten. An exited sink stays
    /// ended wherever its tab shows.
    pub(super) fn track_gone(&mut self) {
        self.forget_shown_creations();
        if self.facts.gone.is_empty() {
            return;
        }
        let shown = self.shown_sinks();
        let held: HashSet<Sink> = self
            .presses
            .values()
            .filter_map(|press| match press {
                Press::Sink { sink, .. } | Press::Offered(sink) => Some(sink.clone()),
                Press::Platform | Press::Consumed | Press::Nothing => None,
            })
            .collect();
        let mut renewed: Vec<Sink> = Vec::new();
        self.facts.gone.retain(|sink, gone| {
            if gone.reason == GoneReason::Exited {
                return true;
            }
            if shown.contains(sink) {
                if gone.left {
                    renewed.push(sink.clone());
                    return false;
                }
                return true;
            }
            gone.left = true;
            if held.contains(sink) {
                return true;
            }
            renewed.push(sink.clone());
            false
        });
        for sink in renewed {
            self.renew(&sink);
        }
    }

    /// `sink` names a new sink from now: the presses held for the ended one
    /// reach nothing.
    fn renew(&mut self, sink: &Sink) {
        for press in self.presses.values_mut() {
            let old = match press {
                Press::Sink { sink: held, .. } | Press::Offered(held) => held == sink,
                Press::Platform | Press::Consumed | Press::Nothing => false,
            };
            if old {
                *press = Press::Nothing;
            }
        }
        self.push(InputEffect::SinkNew { sink: sink.clone() });
    }

    /// Every tab sink a window shows: each tab's content and developer tools.
    fn shown_sinks(&self) -> HashSet<Sink> {
        let mut shown = HashSet::new();
        for window in self.windows.values() {
            for (tab, info) in &window.tabs {
                if let Some(sink) = content_sink(tab, info) {
                    shown.insert(sink);
                }
                shown.insert(Sink::DevTools(tab.clone()));
            }
        }
        shown
    }
}
