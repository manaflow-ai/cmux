//! URL navigation for a browser surface, including navigation that arrives
//! before the surface has a live CDP session.
//!
//! Owner: the browser surface on the session host. [`NavigationHold`] is
//! written under its own lock by the command worker (hold a navigation), the
//! bootstrap thread (consume the held entry while it publishes the live
//! session, or record that no attach will come) and nothing else. A raw
//! `browser-navigate` is acknowledged when it is enqueued, so it must never be
//! dropped after that: while an attach is pending the worker holds the newest
//! navigation (latest wins by command sequence) and attach replays it. Once a
//! bootstrap failed for good, navigation is refused before the acknowledgement.
//! The record's URL changes only when the page is navigated to the target, so
//! a client waiting for the record's URL event settles on the target or on the
//! surface's failure status. If the replayed navigation fails, the record keeps
//! its URL and the failure is reported as a status (intended: the record never
//! claims a URL the page did not load). A confirmed navigation (a resource op
//! that waits for its outcome) is not held: it fails with "browser is still
//! starting".
//!
//! Follow-up (plans/cmux-next/COORDINATION.md): a v2 navigation op that
//! carries the browser tab record's expected URL revision, owned by the
//! workspace store.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::sync::mpsc::TrySendError;

use super::{
    BrowserCommand, BrowserSession, BrowserSurface, BrowserWorkerSuccess, SequencedBrowserCommand,
    normalize_url,
};

#[derive(Default)]
pub(super) struct NavigationHold {
    /// Sequence of the newest navigation the worker has run or held. An older
    /// navigation reaching the worker afterwards is superseded.
    newest: Option<u64>,
    held: Option<HeldNavigation>,
    /// Set when no attach will come (a bootstrap failed for good); cleared
    /// when a new bootstrap attempt starts or an attach succeeds.
    attach_failure: Option<String>,
}

struct HeldNavigation {
    sequence: u64,
    url: String,
}

impl NavigationHold {
    fn is_current(&self, sequence: u64) -> bool {
        self.newest.is_none_or(|newest| sequence >= newest)
    }
}

impl crate::Mux {
    /// Raw `browser-navigate`: a frontend-rendered page has no daemon CDP
    /// target, so the daemon refuses instead of acknowledging and dropping.
    pub(crate) fn navigate_browser_surface(
        &self,
        surface: &crate::Surface,
        url: &str,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            !self.is_frontend_browser_surface(surface),
            "browser surface is rendered by the frontend; navigate it through its record"
        );
        surface.browser_navigate(url)
    }
}

impl BrowserSurface {
    pub fn navigate(&self, url: &str) -> anyhow::Result<()> {
        if let Some(reason) = self.navigation_hold.lock().unwrap().attach_failure.clone() {
            anyhow::bail!("browser failed: {reason}");
        }
        self.enqueue_latest_nav(BrowserCommand::Navigate(url.to_string()))
    }

    /// A bootstrap failed for good: fail the surface, drop any held
    /// navigation and refuse new ones until a new bootstrap attempt starts.
    pub(crate) fn abandon_attach(&self, message: String) {
        {
            let mut hold = self.navigation_hold.lock().unwrap();
            hold.attach_failure = Some(message.clone());
            hold.held = None;
        }
        self.mark_failed(message);
    }

    #[cfg(test)]
    pub(super) fn has_held_navigation(&self) -> bool {
        self.navigation_hold.lock().unwrap().held.is_some()
    }

    /// A new bootstrap attempt started, so navigation may be held again.
    pub(super) fn expect_attach(&self) {
        self.navigation_hold.lock().unwrap().attach_failure = None;
    }

    pub(crate) fn navigate_confirmed(&self, url: &str) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Navigate(url.to_string()))
    }

    pub(super) fn enqueue_latest_nav(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        *self.latest_nav.lock().unwrap() = Some(command);
        let wake = order.sequence(BrowserCommand::WakeLatest);
        match tx.try_send(wake) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => {
                self.latest_nav.lock().unwrap().take();
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    /// Worker entry point for a URL navigation with its command sequence.
    pub(super) fn run_navigation(
        &self,
        sequence: u64,
        url: &str,
        confirmed: bool,
    ) -> anyhow::Result<BrowserWorkerSuccess> {
        let used = {
            // Lock order: hold, then session. attach_live publishes the
            // session under the same hold lock, so a navigation is either
            // held before attach consumes the hold or runs against the live
            // session; it can never fall between the two.
            let mut hold = self.navigation_hold.lock().unwrap();
            if !hold.is_current(sequence) {
                anyhow::ensure!(!confirmed, "navigation was superseded by a newer navigation");
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let session = self.session.lock().unwrap().clone();
            if session.is_none() && !self.is_dead() {
                if let Some(reason) = &hold.attach_failure {
                    anyhow::bail!("browser failed: {reason}");
                }
                // A rejected confirmed navigation leaves the hold untouched,
                // so it can never supersede an acknowledged raw navigation.
                anyhow::ensure!(!confirmed, "browser is still starting");
                hold.newest = Some(sequence);
                hold.held = Some(HeldNavigation { sequence, url: url.to_string() });
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            hold.newest = Some(sequence);
            session
        };
        match self.navigate_blocking(url) {
            Ok(()) => Ok(BrowserWorkerSuccess::BrowserResponded),
            Err(error) if confirmed || self.is_dead() => Err(error),
            Err(error) => self.retry_after_session_change(sequence, url, used, error),
        }
    }

    /// A raw navigation failed. If the session it ran against was replaced
    /// meanwhile (provider reconnect or lease replacement), the failure says
    /// nothing about the target: hold it for the next attach, or replay it on
    /// the new session. A failure on the same session is reported.
    fn retry_after_session_change(
        &self,
        sequence: u64,
        url: &str,
        used: Option<BrowserSession>,
        error: anyhow::Error,
    ) -> anyhow::Result<BrowserWorkerSuccess> {
        let mut hold = self.navigation_hold.lock().unwrap();
        if !hold.is_current(sequence) {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let current = self.session.lock().unwrap().clone();
        let target = HeldNavigation { sequence, url: url.to_string() };
        match current {
            None if hold.attach_failure.is_none() => {
                hold.held = Some(target);
                Ok(BrowserWorkerSuccess::LocallySettled)
            }
            Some(current) if !used.as_ref().is_some_and(|used| same_session(used, &current)) => {
                drop(hold);
                self.publish_held_navigation(target);
                Ok(BrowserWorkerSuccess::LocallySettled)
            }
            _ => Err(error),
        }
    }

    /// Publish a freshly attached session and load the record's current
    /// target: the held navigation if any, else the record's URL when the
    /// bootstrap captured an older one. The bootstrap URL is stamped only
    /// when it is still the record's URL.
    pub(super) fn attach_live(
        &self,
        session: BrowserSession,
        bootstrap_url: &str,
    ) -> anyhow::Result<()> {
        let mut hold = self.navigation_hold.lock().unwrap();
        self.mark_live(session)?;
        hold.attach_failure = None;
        let newest = hold.newest;
        let held = hold.held.take().filter(|held| newest.is_none_or(|n| held.sequence >= n));
        let record_url = self.url();
        let target = held.or_else(|| {
            if record_url == bootstrap_url {
                return None;
            }
            Some(HeldNavigation { sequence: newest.unwrap_or(0), url: record_url })
        });
        match target {
            Some(target) => self.publish_held_navigation(target),
            None => self.set_url_title(bootstrap_url.to_string(), bootstrap_url.to_string()),
        }
        Ok(())
    }

    /// Replay a held navigation through the latest-wins slot with its
    /// original sequence, so any navigation issued after it still wins.
    fn publish_held_navigation(&self, target: HeldNavigation) {
        let Ok(tx) = self.command_sender() else { return };
        let mut order = self.command_order.lock().unwrap();
        {
            let mut latest = self.latest_nav.lock().unwrap();
            if latest.as_ref().is_some_and(|newer| newer.sequence > target.sequence) {
                return;
            }
            *latest = Some(SequencedBrowserCommand {
                sequence: target.sequence,
                command: BrowserCommand::Navigate(target.url),
            });
        }
        let wake = order.sequence(BrowserCommand::WakeLatest);
        let _ = tx.try_send(wake);
    }

    pub(super) fn navigate_blocking(&self, url: &str) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let normalized = normalize_url(url);
        let invalidation = self.begin_latest_navigation_frame_transition(&session, true)?;
        match session.runtime.client.navigate(&session.session_id, &normalized) {
            Ok(result) => {
                if result.is_download {
                    // Chrome explicitly confirmed that the response was handed
                    // to the download manager, so the current document and its
                    // rendered frame remain authoritative.
                    self.restore_pointer_frame_after_failed_command(invalidation);
                    return Ok(());
                }
                if let Some(error) = result.error_text {
                    self.abandon_frame_transition();
                    self.mark_failed(error.clone());
                    anyhow::bail!("browser failed: {error}");
                }
                let loaderless = result.loader_id.is_none();
                if loaderless {
                    self.reconcile_loaderless_navigation(&session)?;
                } else {
                    self.finish_navigation_command(invalidation, Ok(()))?;
                }
            }
            Err(error) => self.finish_navigation_command(invalidation, Err(error))?,
        }
        self.set_url_title(normalized.clone(), normalized);
        self.dirty.store(true, Ordering::Release);
        Ok(())
    }
}

fn same_session(left: &BrowserSession, right: &BrowserSession) -> bool {
    Arc::ptr_eq(&left.runtime, &right.runtime)
        && left.target_id == right.target_id
        && left.session_id == right.session_id
}
