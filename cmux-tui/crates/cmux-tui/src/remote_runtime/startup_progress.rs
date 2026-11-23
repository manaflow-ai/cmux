//! What a client's first connect says while it is not connected yet, and the refusal that ends
//! it. A startup is never silent past [`PROGRESS_EVERY`]: each redial reports its failure, at
//! most once per interval, and a dial that stalls with nothing to report says it is still
//! connecting. Before this an `--invite-file` connect redialed a refused route for minutes
//! without a word (Leo: "we need to finish remote").

use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_remote::connection::ConnectionError;
use cmux_remote::link::{LinkError, Refusal};
use cmux_remote::provider::ProviderError;

/// The longest a startup goes without a stderr line, and the shortest gap between two.
pub(crate) const PROGRESS_EVERY: Duration = Duration::from_secs(4);

/// The first connect's progress lines.
pub(super) struct StartupProgress {
    started: Instant,
    state: Mutex<ProgressState>,
}

#[derive(Default)]
struct ProgressState {
    last_line: Option<Instant>,
    last_failure: Option<String>,
    /// The one line that says how to stop waiting has been printed.
    hinted: bool,
}

impl StartupProgress {
    pub(super) fn new() -> Self {
        Self { started: Instant::now(), state: Mutex::default() }
    }

    /// A dial failed and is redialed: says why, unless a line went out within the interval.
    pub(super) fn redialing(&self, failure: &anyhow::Error) {
        let failure = format!("{failure:#}");
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let due = state.last_line.is_none_or(|at| at.elapsed() >= PROGRESS_EVERY);
        if due {
            state.last_line = Some(Instant::now());
            eprintln!("remote connect: {failure}; redialing");
        }
        state.last_failure = Some(failure);
    }

    /// Says the startup is still connecting whenever [`PROGRESS_EVERY`] passed with no line.
    /// Never returns; the caller drops it once the connect ends.
    pub(super) async fn tick(&self) -> std::convert::Infallible {
        loop {
            let wait = {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                let since = state.last_line.unwrap_or(self.started).elapsed();
                match PROGRESS_EVERY.checked_sub(since).filter(|wait| !wait.is_zero()) {
                    Some(wait) => wait,
                    None => {
                        state.last_line = Some(Instant::now());
                        let seconds = self.started.elapsed().as_secs();
                        if !state.hinted {
                            // The reminder of how to stop goes out once.
                            state.hinted = true;
                            eprintln!(
                                "remote connect: Ctrl-C stops waiting; `--connect-timeout-seconds N` gives up by itself"
                            );
                        }
                        match &state.last_failure {
                            Some(failure) => eprintln!(
                                "remote connect: still connecting after {seconds}s; last: {failure}"
                            ),
                            None => eprintln!("remote connect: still connecting after {seconds}s"),
                        }
                        PROGRESS_EVERY
                    }
                }
            };
            tokio::time::sleep(wait).await;
        }
    }
}

/// The far side's refusal that ended a startup, when one did: found through the error's chain,
/// as a [`ProviderError`], a [`ConnectionError`] or a bare [`LinkError`].
pub fn startup_refusal(error: &anyhow::Error) -> Option<&Refusal> {
    error.chain().find_map(|cause| {
        cause
            .downcast_ref::<ProviderError>()
            .and_then(ProviderError::refusal)
            .or_else(|| cause.downcast_ref::<ConnectionError>().and_then(ConnectionError::refusal))
            .or_else(|| cause.downcast_ref::<LinkError>().and_then(LinkError::refusal))
    })
}
