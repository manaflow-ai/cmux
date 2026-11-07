//! The reports reader (Swift `AcpmuxMailboxReader`): one thread that reads
//! the acpmux mailbox `reports:<user>` for the signed-in account. Each pass
//! is one `_acpmux/mail/wait` long wait (acpmux answers on a new message or
//! its timeout); failures back off 250 ms doubling for ten tries, then the
//! reader waits for a wakeup (the app turns active, the account changes).
//! It stops at `FeedClient::shutdown`.

use std::sync::Arc;
use std::time::Duration;

use cmux_feed_core::client::MailPage;
use serde_json::Value;

use super::{FeedEvent, Inner};

/// One mailbox wait's timeout (acpmux takes at most 30 s).
const MAIL_WAIT: Duration = Duration::from_secs(25);
/// Rows one wait asks for (acpmux takes at most 500).
const MAIL_LIMIT: usize = 500;
const FIRST_BACKOFF: Duration = Duration::from_millis(250);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
const RETRIES: u32 = 10;
/// A wait for a wakeup ends at least this often.
const IDLE_WAIT: Duration = Duration::from_secs(600);

/// The acpmux mailbox.
pub trait Mailbox: Send + Sync {
    /// acpmux runs here (its socket is known).
    fn available(&self) -> bool;
    /// `_acpmux/mail/wait {recipient, after, limit, timeoutMs}`'s result.
    fn wait(
        &self,
        recipient: &str,
        after: u64,
        limit: usize,
        timeout: Duration,
    ) -> Result<Value, String>;
}

pub(super) fn start(inner: &Arc<Inner>) {
    let inner = Arc::clone(inner);
    let spawned =
        std::thread::Builder::new().name("cmux-feed-reports".to_owned()).spawn(move || run(&inner));
    if let Err(error) = spawned {
        eprintln!("cmux-tui: feed: the reports reader did not start: {error}");
    }
}

/// Waits up to `timeout` for the reports generation to move past
/// `generation` (a wakeup or another account) or a shutdown.
fn wait_change(inner: &Inner, generation: u64, timeout: Duration) {
    let mut state = inner.lock();
    let deadline = std::time::Instant::now() + timeout;
    while state.reports_generation == generation && !inner.stopped() {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return;
        }
        state = inner
            .wake
            .wait_timeout(state, left)
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .0;
    }
}

fn backoff(failures: u32) -> Duration {
    FIRST_BACKOFF.saturating_mul(1 << failures.saturating_sub(1).min(16)).min(MAX_BACKOFF)
}

fn run(inner: &Inner) {
    let mut cursor = 0_u64;
    let mut reading: Option<String> = None;
    let mut failures = 0_u32;
    while !inner.stopped() {
        let (user, generation) = {
            let state = inner.lock();
            (state.account.clone(), state.reports_generation)
        };
        if user != reading {
            // Another account reads its own mailbox from the start.
            cursor = 0;
            failures = 0;
            reading.clone_from(&user);
        }
        let Some(user) = user else {
            wait_change(inner, generation, IDLE_WAIT);
            continue;
        };
        if !inner.deps.mailbox.available() {
            wait_change(inner, generation, IDLE_WAIT);
            continue;
        }
        match inner.deps.mailbox.wait(&format!("reports:{user}"), cursor, MAIL_LIMIT, MAIL_WAIT) {
            Ok(result) => {
                failures = 0;
                let page = MailPage::from_value(&result);
                let event = {
                    let mut state = inner.lock();
                    if state.account.as_deref() != Some(user.as_str()) {
                        continue;
                    }
                    cursor = page.cursor_after(cursor);
                    state
                        .reports
                        .apply(&page)
                        .then(|| FeedEvent::Reports { revision: state.reports.revision() })
                };
                inner.emit(event.into_iter().collect());
            }
            Err(_) => {
                failures += 1;
                let wait = if failures <= RETRIES { backoff(failures) } else { IDLE_WAIT };
                wait_change(inner, generation, wait);
                if failures > RETRIES {
                    failures = 0;
                }
            }
        }
    }
}
