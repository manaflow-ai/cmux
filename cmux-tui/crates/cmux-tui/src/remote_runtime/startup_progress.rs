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
    /// The invitation this connect claims, when it claims one: its wait with no failure is the
    /// host's owner yet to approve it, and the line says so.
    invitation: Option<String>,
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
    pub(super) fn new(invitation: Option<String>) -> Self {
        Self { started: Instant::now(), invitation, state: Mutex::default() }
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
                        eprintln!(
                            "{}",
                            still_connecting_line(
                                seconds,
                                state.last_failure.as_deref(),
                                self.invitation.as_deref(),
                            )
                        );
                        PROGRESS_EVERY
                    }
                }
            };
            tokio::time::sleep(wait).await;
        }
    }
}

/// The periodic line of a startup with no answer yet. An invitation claim that reached the host
/// and failed nothing waits on the host's owner, so it names the two commands to run there; before
/// this it read only "still connecting after 4s" for the whole approval window.
pub(super) fn still_connecting_line(
    seconds: u64,
    last_failure: Option<&str>,
    invitation: Option<&str>,
) -> String {
    match (last_failure, invitation) {
        (Some(failure), _) => {
            format!("remote connect: still connecting after {seconds}s; last: {failure}")
        }
        (None, Some(id)) => format!(
            "remote connect: waiting {seconds}s for the host to approve this device; on the host, \
             `cmux remote enroll pending` lists it and `cmux remote enroll approve {id}` lets it in"
        ),
        (None, None) => format!("remote connect: still connecting after {seconds}s"),
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

#[cfg(test)]
mod tests {
    use super::still_connecting_line;

    #[test]
    fn an_invitation_wait_names_the_host_commands_that_approve_it() {
        let line = still_connecting_line(8, None, Some("CI3913cdem3cZSqR2jimyA"));
        assert_eq!(
            line,
            "remote connect: waiting 8s for the host to approve this device; on the host, \
             `cmux remote enroll pending` lists it and \
             `cmux remote enroll approve CI3913cdem3cZSqR2jimyA` lets it in"
        );
    }

    #[test]
    fn a_failing_or_plain_connect_keeps_its_line() {
        assert_eq!(
            still_connecting_line(4, Some("connection refused"), Some("id")),
            "remote connect: still connecting after 4s; last: connection refused"
        );
        assert_eq!(
            still_connecting_line(4, None, None),
            "remote connect: still connecting after 4s"
        );
    }
}
