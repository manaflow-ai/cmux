//! A computer use call that finds the helper unreachable recovers by itself.
//!
//! Leo, 2026-11-14: "ok i turned it off and on again idk why they should be
//! necessary for me to do/why you couldnt do it/it couldnt automatically do it".
//!
//! A chat's `cmux-cua mcp` proxy (the legacy driver) gets the helper's socket
//! and this app launch's agent token in its spawn env (acpmux `agent_tools.rs`).
//! An acpmux session outlives the app: after a relaunch (every nightly update)
//! the app serves a new agent token, so the old chat's proxy can no longer
//! authenticate. The proxy also gives up for good after one failed initial
//! connection. Both said "toggle Computer Use off and on", which restarted the
//! helper with the same new token and fixed neither, so every call of that
//! chat failed until the chat ended.
//!
//! Now, when a call answers that the helper is unreachable (its text,
//! [`unreachable`]), the call never ran, so this server:
//! 1. asks acpmux for the endpoint a new session would get now
//!    (`_acpmux/computer_use_endpoint`) and puts it in the proxy's spec,
//! 2. starts the proxy again and retries the call, with a short backoff,
//! 3. from the second try on, asks the app to restart its helper
//!    (`palette.computerUse.restart`, at most once per [`HELPER_RESTART_EVERY`]),
//!
//! until the call runs or [`TRIES`] are spent. A missing macOS grant is not
//! this: the setup gate (`computer_use_gate.rs`) asks the person for that,
//! naming the grant. What reaches the agent when recovery fails says what
//! was tried and never asks it to have the person toggle a setting.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::upstream::Spec;

/// The proxy's arg that names the helper socket.
const SOCKET_ARG: &str = "--socket";
/// The proxy's env that carries the agent token.
pub(super) const TOKEN_ENV: &str = "CMUX_CUA_SOCKET_AUTH_TOKEN";
/// Tries of one call, the first included.
pub(super) const TRIES: usize = 5;
/// The wait before each retry: the helper's own start is about a second.
const BACKOFF: [Duration; TRIES - 1] = [
    Duration::from_millis(200),
    Duration::from_millis(800),
    Duration::from_secs(2),
    Duration::from_secs(4),
];
/// A helper restart asked of the app at most this often by this server: the
/// app keeps its own restart budget, and two chats asking at once restart once.
pub(super) const HELPER_RESTART_EVERY: Duration = Duration::from_secs(30);
/// How long the endpoint read and the restart request may take.
// timeout: both are local answers from a running daemon/app; a miss only skips that recovery step and the retry goes on.
const ASK_TIMEOUT: Duration = Duration::from_secs(5);

/// What the `cmux-cua` proxy says when the helper does not answer on its
/// socket, the token it was given is refused, or it gave up on it. Matched as
/// text: the proxy is a separate program with no error code for it.
const UNREACHABLE: &[&str] = &[
    "computer-use daemon failed to start",
    "runtime is not listening on",
    "stayed unavailable",
    "after the previously-connected daemon exited",
    "timed out waiting for the daemon session control connection",
    "rejected unauthorized daemon peer",
];

/// Whether `text` (a call's error, or its error result's text) says the helper
/// was not reached, so the call did not run.
pub(super) fn unreachable(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    UNREACHABLE.iter().any(|marker| lower.contains(marker))
}

/// The text of an error result (`isError`), when it is one.
pub(super) fn error_text(result: &Value) -> Option<String> {
    if result["isError"] != true {
        return None;
    }
    let text = result["content"]
        .as_array()?
        .iter()
        .filter_map(|block| block["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    Some(text)
}

/// Where the current endpoint comes from: acpmux, or a test's. `Ok(None)`: acpmux
/// publishes none. `Err`: why it could not be read (said in the final error).
pub(super) type EndpointSource =
    Arc<dyn Fn() -> Result<Option<acpmux::cua_socket::Socket>, String> + Send + Sync>;

/// The endpoint the running acpmux would give a new local session now. Read on
/// its own thread: a call may run inside another runtime. Every failure says why:
/// on 2026-11-14 each read failed after an update relaunch, the
/// proxy kept the old launch's token for all five tries, and the final error
/// still said it had used "the current endpoint".
pub(super) fn acpmux_endpoint() -> EndpointSource {
    Arc::new(|| {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("cmux-mcp-cua-endpoint".into())
            .spawn(move || {
                let answer = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Err(error) => Err(format!("no runtime to ask acpmux: {error}")),
                    Ok(runtime) => match runtime
                        .block_on(tokio::time::timeout(ASK_TIMEOUT, acpmux::cua_socket::current()))
                    {
                        Err(_) => {
                            Err(format!("acpmux did not answer in {} s", ASK_TIMEOUT.as_secs()))
                        }
                        Ok(answer) => answer.map_err(|error| format!("acpmux refused: {error:#}")),
                    },
                };
                let _ = tx.send(answer);
            })
            .map_err(|error| format!("no thread to ask acpmux: {error}"))?;
        rx.recv_timeout(ASK_TIMEOUT + Duration::from_secs(1))
            .map_err(|_| format!("acpmux did not answer in {} s", ASK_TIMEOUT.as_secs()))?
    })
}

/// What the last endpoint read left the proxy with, for the final error: `None` when it
/// moved to (or already had) the endpoint acpmux gives now.
pub(super) fn endpoint_note(
    read: &Result<Option<acpmux::cua_socket::Socket>, String>,
) -> Option<String> {
    match read {
        Ok(Some(_)) => None,
        Ok(None) => Some("acpmux publishes no Computer Use endpoint".to_owned()),
        Err(why) => Some(format!("reading the current endpoint from acpmux failed: {why}")),
    }
}

/// Whether `spec` is the legacy driver's proxy with a socket: the only
/// server this recovers.
pub(super) fn applies(spec: &Spec) -> bool {
    spec.name == super::computer_use_gate::SERVER
        && spec.shared.is_none()
        && spec.args.iter().any(|arg| arg == SOCKET_ARG)
        && !spec.env.iter().any(|(key, _)| key == acpmux::cua_v2::ENDPOINT_DIR_ENV)
}

/// Puts `socket` in the proxy's `spec`: its `--socket` and its token.
/// Whether anything changed.
pub(super) fn apply(spec: &mut Spec, socket: &acpmux::cua_socket::Socket) -> bool {
    let path = socket.path.to_string_lossy().into_owned();
    let mut changed = false;
    if let Some(at) = spec.args.iter().position(|arg| arg == SOCKET_ARG)
        && let Some(value) = spec.args.get_mut(at + 1)
        && *value != path
    {
        *value = path;
        changed = true;
    }
    let current = spec.env.iter().position(|(key, _)| key == TOKEN_ENV);
    match (current, socket.token.is_empty()) {
        (Some(at), false) if spec.env[at].1 != socket.token => {
            spec.env[at].1 = socket.token.clone();
            changed = true;
        }
        (Some(at), true) => {
            spec.env.remove(at);
            changed = true;
        }
        (None, false) => {
            spec.env.push((TOKEN_ENV.to_owned(), socket.token.clone()));
            changed = true;
        }
        _ => {}
    }
    changed
}

/// The wait before try `attempt` (1 is the first retry).
pub(super) fn backoff(attempt: usize) -> Duration {
    BACKOFF.get(attempt.saturating_sub(1)).copied().unwrap_or(BACKOFF[BACKOFF.len() - 1])
}

/// When this server last asked the app to restart its helper.
static LAST_RESTART: Mutex<Option<Instant>> = Mutex::new(None);

/// Asks the app to restart its helper, unless this server did within
/// [`HELPER_RESTART_EVERY`]. Whether it asked.
pub(super) fn restart_helper(app: &super::computer_use_gate::AppCaller) -> bool {
    {
        let mut last = LAST_RESTART.lock().unwrap_or_else(PoisonError::into_inner);
        if last.is_some_and(|at| at.elapsed() < HELPER_RESTART_EVERY) {
            return false;
        }
        *last = Some(Instant::now());
    }
    let params = super::super::app::action_run_params(
        RESTART_ACTION_CLI,
        super::super::app::ActionName::Cli,
        "mcp",
    );
    (app)("action.run", Value::Object(params), ASK_TIMEOUT).is_ok()
}

/// The app's Restart Computer Use Helper action (`palette.computerUse.restart`).
pub(super) const RESTART_ACTION_CLI: &str = "agent restart-computer-use-helper";

/// Forget the last restart (tests).
#[cfg(test)]
pub(super) fn reset_restart_throttle() {
    *LAST_RESTART.lock().unwrap_or_else(PoisonError::into_inner) = None;
}

/// The proxy's text without its advice to the person: it names a toggle that
/// recovery has already done better.
pub(super) fn without_person_advice(text: &str) -> String {
    const ADVICE: &str = "Do not run `cmux-cua serve`";
    let text = text.split_once(ADVICE).map_or(text, |(before, _)| before);
    text.trim_end().trim_end_matches('.').to_owned()
}

/// What the agent gets when recovery ran out: what failed, what this server
/// tried, and what to do. Never "ask the person to toggle Computer Use".
/// `endpoint`: what kept the proxy off the current endpoint ([`endpoint_note`]), none when
/// it had it.
pub(super) fn gave_up(
    last: &str,
    tries: usize,
    restarted: bool,
    waited: Duration,
    endpoint: Option<&str>,
) -> Value {
    let restart = if restarted { ", asked cmux to restart its Computer Use helper" } else { "" };
    let with = match endpoint {
        None => " with the current endpoint".to_owned(),
        Some(why) => format!(" but kept its old endpoint ({why})"),
    };
    let message = format!(
        "cmux-cua: the cmux Computer Use helper did not answer. cmux reconnected {tries} times \
         over {:.0} s{with}{restart}, and it still did not answer: {}. \
         The call did not run. Retry in a minute; if it still fails, run `cmux setup \
         computer-use` and follow its step (it names a missing macOS permission when there \
         is one).",
        waited.as_secs_f64().ceil(),
        without_person_advice(last),
    );
    json!({"code": "upstream.failed", "message": message, "details": {"recovery": {
        "tries": tries, "helperRestartRequested": restarted, "endpoint": endpoint}},
        "retryable": true})
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEEN: &str = "computer-use daemon failed to start: the tag-scoped cmux Computer Use \
        runtime is not listening on /tmp/x/cua.sock: cmux-owned Computer Use daemon stayed \
        unavailable during initial connection. Do not run `cmux-cua serve`, `call`, or \
        `permissions` directly. Open cmux Settings > Computer Use, or toggle Computer Use off \
        and on, to recover the branded cmux Computer Use helper.";

    #[test]
    fn the_failure_of_2026_11_14_is_unreachable_and_loses_its_toggle_advice() {
        assert!(unreachable(SEEN));
        assert!(!unreachable("the window is gone"));
        assert!(!unreachable("Accessibility permission is not granted"));
        let cleaned = without_person_advice(SEEN);
        assert!(!cleaned.contains("toggle"), "{cleaned}");
        assert!(cleaned.ends_with("during initial connection"), "{cleaned}");
        let message = gave_up(SEEN, 5, true, Duration::from_secs(7), None);
        let text = message["message"].as_str().unwrap();
        assert!(!text.to_ascii_lowercase().contains("toggle"), "{text}");
        assert!(!text.contains("Settings > Computer Use"), "{text}");
    }

    /// 2026-11-14: every endpoint read failed, so the proxy kept
    /// the old launch's token, and the final error must say so, not "the current endpoint".
    #[test]
    fn a_failed_endpoint_read_is_named_in_the_final_error() {
        let read = Err("acpmux refused: only a proven acpmux session may ask".to_owned());
        let note = endpoint_note(&read);
        let message = gave_up(SEEN, 5, true, Duration::from_secs(58), note.as_deref());
        let text = message["message"].as_str().unwrap();
        assert!(!text.contains("with the current endpoint"), "{text}");
        assert!(text.contains("only a proven acpmux session may ask"), "{text}");
        assert!(endpoint_note(&Ok(None)).unwrap().contains("publishes no"));
        let now = acpmux::cua_socket::Socket { path: "/now.sock".into(), token: "now".into() };
        assert_eq!(endpoint_note(&Ok(Some(now))), None);
    }

    #[test]
    fn apply_moves_the_socket_and_the_token() {
        let mut spec = Spec {
            name: "cmux-cua".into(),
            command: "cmux-cua".into(),
            args: vec!["mcp".into(), "--socket".into(), "/old.sock".into()],
            env: vec![(TOKEN_ENV.into(), "old".into())],
            call_timeout: Duration::from_secs(1),
            shared: None,
            http: None,
        };
        assert!(applies(&spec));
        let same = acpmux::cua_socket::Socket { path: "/old.sock".into(), token: "old".into() };
        assert!(!apply(&mut spec, &same));
        let new = acpmux::cua_socket::Socket { path: "/new.sock".into(), token: "new".into() };
        assert!(apply(&mut spec, &new));
        assert_eq!(spec.args[2], "/new.sock");
        assert_eq!(spec.env, vec![(TOKEN_ENV.to_owned(), "new".to_owned())]);
    }
}
