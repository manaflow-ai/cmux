use std::io::{BufRead, BufReader, Read, Write};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};
use cmux_json::JsonSet as _;

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub(super) struct ServerPlan {
    pub action: ServerAction,
    pub session: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) enum ServerAction {
    Status,
    Stats,
    /// `terminal_reap_grace` reaches only an owner this call spawns; a
    /// running owner keeps the grace it was started with.
    Ensure {
        terminal_reap_grace: Option<Duration>,
        /// Test harnesses: the spawned owner ends with this pid (`local_owner::exit_with`).
        exit_with_pid: Option<crate::local_owner::ExitWith>,
        /// Private app contract (P8 3b-2): read the app's install key from
        /// stdin and hand it to an owner this call spawns.
        install_key_stdin: bool,
        /// Private app contract (cx-n3bs): while the owner restores, print
        /// one `{"progress":"restoring",...}` JSON line per progress interval
        /// on stdout before the result, so the app bounds its wait by
        /// progress instead of a fixed timeout.
        progress: bool,
        /// Private app contract (cx-hnmbt.2): an owner this call spawns
        /// opens its loopback WebSocket listener (`--ws-loopback`).
        websocket: Option<crate::local_owner::EnsureWebSocket>,
        /// Private app contract (cx-jniyz, the app's "Restart cmux-tui"):
        /// first stop an owner that accepts but does not answer `identify`
        /// (`local_owner::replace_if_unresponsive`), then ensure as usual.
        replace_unresponsive: bool,
    },
    Stop {
        force: bool,
        end_terminals: bool,
        /// How long to wait for an owner that still restores its session
        /// (`--restore-wait-seconds`, default `local_owner::RESTORE_DEADLINE`).
        restore_wait: Duration,
    },
    ReloadConfig,
    /// cx-ossub: rewrite the session's registry into a compact file with
    /// incremental auto-vacuum while no owner runs (refused while one does).
    /// Needs an explicit `--session`; `--state-dir` overrides the default
    /// state root (`CMUX_TUI_STATE_DIR` or the platform default).
    CompactRegistry {
        state_dir: Option<std::path::PathBuf>,
    },
}

pub(super) fn run(mut global: GlobalArgs, plan: ServerPlan) -> i32 {
    if global.machine.is_some() {
        return usage_error(
            crate::localization::catalog().local_server.machine_not_supported,
            global.output,
        );
    }
    if let Some(session) = plan.session {
        if global.session.as_deref().is_some_and(|global| global != session) {
            return usage_error(
                crate::localization::catalog().local_server.session_conflict,
                global.output,
            );
        }
        global.session = Some(session);
    }
    if let Some(session) = global.session.as_deref()
        && !valid_session_name(session)
    {
        return usage_error(
            crate::localization::catalog().machine_agent.invalid_session,
            global.output,
        );
    }
    let expected_session = global.session.clone();
    if let ServerAction::CompactRegistry { state_dir } = plan.action {
        return run_compact_registry(expected_session, state_dir, global.output);
    }
    let (socket, socket_is_derived) = match super::wire::resolve_socket_with_origin(&global) {
        Ok(resolved) => resolved,
        Err(error) => {
            // The resolver's typed refusal passes through unchanged.
            let failure = super::wire::resolve_failure(&error);
            if failure["code"] == "socket.no_daemon" {
                return super::wire::print_local_error(
                    &failure,
                    global.output,
                    super::wire::RESOLVE_FAILURE_EXIT,
                );
            }
            if let Some(session) = global.session.as_deref()
                && cmux_tui_core::server::validate_session_name(session).is_err()
            {
                return local_error_with_details(
                    "usage.invalid",
                    crate::localization::catalog().local_server.invalid_session,
                    json!({"reason": "invalid_session"}),
                    global.output,
                    2,
                );
            }
            return local_error_with_details(
                "server.unavailable",
                crate::localization::catalog().local_server.connect_failed,
                json!({"reason": "socket_path_unavailable"}),
                global.output,
                3,
            );
        }
    };
    let socket_output = socket.to_string_lossy().into_owned();
    if let ServerAction::Ensure {
        terminal_reap_grace,
        exit_with_pid,
        install_key_stdin,
        progress,
        websocket,
        replace_unresponsive,
    } = plan.action
    {
        // Read before anything else: stdin is the app's pipe, never argv/env.
        let install_key = match install_key_stdin.then(read_install_key_from_stdin).transpose() {
            Ok(key) => key,
            Err(_) => {
                let message = crate::localization::catalog().local_server.install_key_invalid;
                return local_error("server.install_key_invalid", message, global.output, 1);
            }
        };
        return run_ensure(
            expected_session,
            (terminal_reap_grace, exit_with_pid),
            install_key,
            (socket, socket_is_derived),
            (progress, replace_unresponsive),
            websocket,
            global.output,
        );
    }
    if let ServerAction::Stop { force, end_terminals, restore_wait } = plan.action {
        let stop = StopWait {
            socket: &socket,
            socket_is_derived,
            session: expected_session.as_deref(),
            limit: restore_wait,
            retry_flags: (force, end_terminals),
            output: global.output,
        };
        if let Err(exit_code) = stop.wait_for_restore() {
            return exit_code;
        }
    }
    let stream = match cmux_tui_core::server::connect_session_socket(&socket, socket_is_derived) {
        Ok(stream) => stream,
        Err(error) if matches!(plan.action, ServerAction::Stop { .. }) && is_absent(&error) => {
            return print_success(
                json!({
                    "status":"not_running",
                    "session":expected_session,
                    "socket":socket_output,
                    "message":crate::localization::catalog().local_server.not_running,
                }),
                global.output,
            );
        }
        Err(_) => {
            return local_error(
                "server.unavailable",
                crate::localization::catalog().local_server.connect_failed,
                global.output,
                3,
            );
        }
    };
    let mut connection = BufReader::new(stream);
    let deadline = Instant::now() + Duration::from_secs(10);
    let identity = match exchange(&mut connection, json!({"id":1,"cmd":"identify"}), deadline) {
        Ok(identity) => identity,
        // A timeout is a busy session, not a foreign one: say so, or the
        // reader restarts a healthy session with another build.
        Err(ExchangeError::Timeout) => {
            return local_error(
                "server.busy",
                crate::localization::catalog().local_server.identity_timeout,
                global.output,
                3,
            );
        }
        Err(ExchangeError::Closed | ExchangeError::Transport) => {
            return local_error(
                "server.unavailable",
                crate::localization::catalog().local_server.communication_failed,
                global.output,
                3,
            );
        }
        Err(_) => {
            return local_error(
                "server.identity_failed",
                crate::localization::catalog().local_server.identity_failed,
                global.output,
                3,
            );
        }
    };
    if identity["app"] != "cmux-tui" {
        return local_error(
            "server.wrong_owner",
            crate::localization::catalog().local_server.wrong_owner,
            global.output,
            1,
        );
    }
    match identity.get("lifecycle_ready") {
        Some(Value::Bool(true)) | None => {}
        Some(Value::Bool(false)) => {
            return local_error(
                "server.unavailable",
                crate::localization::catalog().local_server.starting,
                global.output,
                3,
            );
        }
        Some(_) => {
            return local_error(
                "server.invalid_identity",
                crate::localization::catalog().local_server.invalid_identity,
                global.output,
                3,
            );
        }
    }
    let actual_session = identity["session"].as_str().unwrap_or_default();
    if actual_session.is_empty() {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    }
    let Some(pid) = identity["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()) else {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    };
    let Some(generation) = identity["generation"].as_str().filter(|value| !value.is_empty()) else {
        return local_error(
            "server.invalid_identity",
            crate::localization::catalog().local_server.invalid_identity,
            global.output,
            3,
        );
    };
    if expected_session.as_deref().is_some_and(|expected| actual_session != expected) {
        return local_error(
            "server.different_session",
            crate::localization::catalog().local_server.different_session,
            global.output,
            1,
        );
    }

    match plan.action {
        ServerAction::Ensure { .. } | ServerAction::CompactRegistry { .. } => {
            unreachable!("ensure and compact-registry return before the lifecycle exchange")
        }
        ServerAction::Status => print_success(
            json!({
                "status":"running",
                "session":actual_session,
                "socket":socket_output,
                "pid":pid,
                "generation":generation,
                "message":crate::localization::catalog().local_server.running,
            }),
            global.output,
        ),
        ServerAction::Stats => {
            let supports_stats = identity
                .get("capabilities")
                .and_then(Value::as_array)
                .is_some_and(|capabilities| {
                    capabilities.iter().any(|capability| capability == "server-stats-v1")
                });
            match exchange(&mut connection, json!({"id":2,"cmd":"server-stats"}), deadline) {
                Ok(stats) => print_success(stats, global.output),
                Err(ExchangeError::Rejected(_error)) if !supports_stats => local_error(
                    "server.stats_unsupported",
                    crate::localization::catalog().local_server.stats_unsupported,
                    global.output,
                    1,
                ),
                Err(ExchangeError::Rejected(error)) => local_error_with_details(
                    "server.stats_rejected",
                    &error,
                    json!({"error":error}),
                    global.output,
                    1,
                ),
                Err(_) => local_error(
                    "server.stats_failed",
                    crate::localization::catalog().local_server.communication_failed,
                    global.output,
                    3,
                ),
            }
        }
        ServerAction::ReloadConfig => {
            let result =
                match exchange(&mut connection, json!({"id":2,"cmd":"reload-config"}), deadline) {
                    Ok(result) => result,
                    Err(ExchangeError::Rejected(_)) => {
                        return local_error(
                            "server.reload_failed",
                            crate::localization::catalog().local_server.reload_rejected,
                            global.output,
                            1,
                        );
                    }
                    Err(_) => {
                        return local_error(
                            "server.reload_failed",
                            crate::localization::catalog().local_server.communication_failed,
                            global.output,
                            3,
                        );
                    }
                };
            if result["reloaded"].as_bool() != Some(true) {
                return local_error(
                    "server.invalid_response",
                    crate::localization::catalog().local_server.invalid_response,
                    global.output,
                    3,
                );
            };
            print_success(
                json!({
                    "reloaded":true,
                    "session":actual_session,
                    "warnings":result["warnings"].as_array().cloned().unwrap_or_default(),
                    "message":crate::localization::catalog().local_server.reloaded,
                }),
                global.output,
            )
        }
        ServerAction::Stop { force, end_terminals, .. } => {
            if end_terminals
                && !identity["capabilities"]
                    .as_array()
                    .is_some_and(|values| values.iter().any(|value| value == "terminal-reap-v1"))
            {
                return local_error(
                    "server.end_terminals_unsupported",
                    &refused_with_fix(
                        crate::localization::catalog().local_server.end_terminals_unsupported,
                        &super::fix_command::this_cli(),
                        std::path::Path::new(&socket_output),
                    ),
                    global.output,
                    1,
                );
            }
            // Ending hosts waits for each one to exit, so allow more time.
            let deadline =
                if end_terminals { Instant::now() + Duration::from_secs(120) } else { deadline };
            if force
                && !identity["capabilities"].as_array().is_some_and(|values| {
                    values.iter().any(|value| value == "daemon-handoff-force-v1")
                })
            {
                return local_error(
                    "server.force_unsupported",
                    &refused_with_fix(
                        crate::localization::catalog().local_server.force_unsupported,
                        &super::fix_command::this_cli(),
                        std::path::Path::new(&socket_output),
                    ),
                    global.output,
                    1,
                );
            }
            let result = match exchange(
                &mut connection,
                json!({
                    "id":2,
                    "cmd":"shutdown-daemon",
                    "pid":pid,
                    "generation":generation,
                    "force":force,
                    "end_terminals":end_terminals,
                }),
                deadline,
            ) {
                Ok(result) => result,
                Err(ExchangeError::Rejected(_)) => {
                    return local_error(
                        "server.stop_failed",
                        crate::localization::catalog().local_server.stop_rejected,
                        global.output,
                        1,
                    );
                }
                Err(_) => {
                    return local_error(
                        "server.stop_failed",
                        crate::localization::catalog().local_server.communication_failed,
                        global.output,
                        3,
                    );
                }
            };
            if result["accepted"] != true {
                return local_error(
                    "server.invalid_response",
                    crate::localization::catalog().local_server.invalid_response,
                    global.output,
                    3,
                );
            }
            if let Err(message) = wait_for_close(&mut connection, deadline) {
                return local_error("server.stop_incomplete", &message, global.output, 3);
            }
            print_success(
                json!({
                    "status":"stopped",
                    "accepted":true,
                    "session":actual_session,
                    "pid":pid,
                    "generation":generation,
                    "ended_terminals":result["ended_terminals"].as_u64(),
                    "message":if end_terminals {
                        crate::localization::catalog().local_server.stopped_terminals_ended
                    } else {
                        crate::localization::catalog().local_server.stopped
                    },
                }),
                global.output,
            )
        }
    }
}

/// What a stop knows of an owner that is not ready yet.
#[derive(Clone, Copy)]
enum RestorePhase {
    /// The owner holds the connection unanswered: it restores its session
    /// (registry, terminal hosts), or it is too busy to answer.
    Restoring,
    /// The owner answered `lifecycle_ready: false` (its pid when it said):
    /// it restored and finishes its startup, and refuses `shutdown-daemon`.
    Starting(Option<u64>),
}

impl RestorePhase {
    fn name(self) -> &'static str {
        match self {
            Self::Restoring => "restoring",
            Self::Starting(_) => "starting",
        }
    }

    fn starting(self) -> bool {
        matches!(self, Self::Starting(_))
    }

    fn pid(self) -> Option<u64> {
        match self {
            Self::Restoring => None,
            Self::Starting(pid) => pid,
        }
    }
}

/// `server stop`'s wait for an owner that is still restoring.
///
/// Since d674e3164cc (cx-n3bs) an owner binds its socket before it restores
/// its session and holds every connection unanswered until the restore
/// ends; then `identify` says `lifecycle_ready: false` until its startup
/// ends, and `shutdown-daemon` is refused until then. A stop that met such
/// an owner used to give up after its 10 s identify deadline (or at once on
/// `lifecycle_ready: false`), so a stop during a slow restore never stopped
/// the owner. The stop now waits up to `limit`: by default the 2 minutes
/// `server ensure` gives a live owner's restore (`RESTORE_DEADLINE`, the
/// restore's own bound on the client side), so a stop never gives up on an
/// owner an ensure would still wait for.
struct StopWait<'a> {
    socket: &'a std::path::Path,
    socket_is_derived: bool,
    session: Option<&'a str>,
    limit: Duration,
    /// `--force` and `--end-terminals`, repeated in the retry command.
    retry_flags: (bool, bool),
    output: OutputMode,
}

/// How long one read waits before the stop checks its bound and its
/// progress report again.
const STOP_WAIT_SLICE: Duration = Duration::from_secs(1);

/// The pause before a stop asks an owner that said `lifecycle_ready: false`
/// again. The socket has no readiness event for a client that did not start
/// the owner (`local_owner` polls the same way), so the stop re-asks.
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(50);

impl StopWait<'_> {
    /// Returns once the owner on the socket is ready (or gone, or answers
    /// in a way the lifecycle exchange reports itself); `Err` with the exit
    /// code once it printed why the stop gives up.
    fn wait_for_restore(&self) -> Result<(), i32> {
        let started = Instant::now();
        let deadline = started + self.limit;
        let mut reported: Option<Instant> = None;
        let mut connects = 0_u32;
        'connect: loop {
            connects += 1;
            if connects > 1 {
                // A connection closed under the wait: past the bound, or for
                // an owner that keeps closing, the lifecycle exchange reports
                // what the socket does now.
                if Instant::now() >= deadline {
                    return Ok(());
                }
                std::thread::sleep(STOP_POLL_INTERVAL);
            }
            let Ok(stream) =
                cmux_tui_core::server::connect_session_socket(self.socket, self.socket_is_derived)
            else {
                // Absent or unreachable: the lifecycle exchange reports it.
                return Ok(());
            };
            let mut connection = BufReader::new(stream);
            let mut id = 0_u64;
            loop {
                id += 1;
                let request = json!({"id": format!("stop-wait-{id}"), "cmd": "identify"});
                let sent = writeln!(connection.get_mut(), "{request}")
                    .and_then(|()| connection.get_mut().flush());
                if sent.is_err() {
                    // A parked connection the owner dropped (its park cap)
                    // or an owner that exited: ask again on a new one.
                    continue 'connect;
                }
                let phase = loop {
                    let slice = deadline.max(Instant::now() + STOP_POLL_INTERVAL);
                    let slice = slice.min(Instant::now() + STOP_WAIT_SLICE);
                    match read_reply(&mut connection, &request["id"], slice) {
                        Ok(identity) => match identity.get("lifecycle_ready") {
                            Some(Value::Bool(false)) => {
                                break RestorePhase::Starting(
                                    identity.get("pid").and_then(Value::as_u64),
                                );
                            }
                            _ => return Ok(()),
                        },
                        Err(ExchangeError::Timeout) => {}
                        Err(ExchangeError::Closed | ExchangeError::Transport) => {
                            continue 'connect;
                        }
                        // A refused or malformed identify: the lifecycle
                        // exchange reports it with its own codes.
                        Err(_) => return Ok(()),
                    }
                    self.report(RestorePhase::Restoring, started, &mut reported);
                    if Instant::now() >= deadline {
                        return Err(self.give_up(RestorePhase::Restoring, started));
                    }
                };
                self.report(phase, started, &mut reported);
                if Instant::now() >= deadline {
                    return Err(self.give_up(phase, started));
                }
                std::thread::sleep(STOP_POLL_INTERVAL);
            }
        }
    }

    /// One progress line on stderr once the wait passes a slice, then one
    /// per `local_owner::PROGRESS_INTERVAL` (a quick owner start is silent).
    fn report(&self, phase: RestorePhase, started: Instant, reported: &mut Option<Instant>) {
        let now = Instant::now();
        let waited = now.duration_since(started);
        let due = match *reported {
            None => waited >= STOP_WAIT_SLICE,
            Some(last) => {
                now.duration_since(last) + STOP_POLL_INTERVAL
                    >= crate::local_owner::PROGRESS_INTERVAL
            }
        };
        if !due {
            return;
        }
        *reported = Some(now);
        let message = crate::localization::catalog().local_server.stop_waiting(
            phase.starting(),
            waited.as_secs(),
            self.limit.as_secs(),
        );
        let mut stderr = std::io::stderr().lock();
        let _ = match self.output {
            OutputMode::Quiet => return,
            OutputMode::Json | OutputMode::JsonLines => writeln!(
                stderr,
                "{}",
                json!({
                    "progress": "restoring",
                    "session": self.session,
                    "phase": phase.name(),
                    "pid": phase.pid(),
                    "waited_ms": u64::try_from(waited.as_millis()).unwrap_or(u64::MAX),
                    "message": message,
                })
            ),
            OutputMode::Human => writeln!(stderr, "{message}"),
        };
    }

    /// Prints why the stop gives up (`server.stop_restoring`, retryable)
    /// and the command that retries with a longer wait; the exit code.
    fn give_up(&self, phase: RestorePhase, started: Instant) -> i32 {
        let waited = started.elapsed();
        let longer = (self.limit * 2).max(crate::local_owner::RESTORE_DEADLINE);
        let mut retry =
            super::fix_command::stop_daemon(&super::fix_command::this_cli(), self.socket);
        let (force, end_terminals) = self.retry_flags;
        if force {
            retry.push_str(" --force");
        }
        if end_terminals {
            retry.push_str(" --end-terminals");
        }
        retry.push_str(&format!(" --restore-wait-seconds {}", longer.as_secs().min(3600)));
        let message = crate::localization::catalog().local_server.stop_gave_up(
            phase.starting(),
            waited.as_secs(),
            &retry,
        );
        super::wire::print_local_error(
            &json!({
                "code": "server.stop_restoring",
                "message": message,
                "details": {
                    "reason": "restoring",
                    "phase": phase.name(),
                    "pid": phase.pid(),
                    "session": self.session,
                    "waited_ms": u64::try_from(waited.as_millis()).unwrap_or(u64::MAX),
                    "retry": retry,
                },
                "retryable": true,
            }),
            self.output,
            3,
        )
    }
}

/// The reply to the request `id` on `connection`, skipping events and
/// other replies, before `deadline`.
fn read_reply(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    id: &Value,
    deadline: Instant,
) -> Result<Value, ExchangeError> {
    loop {
        let Some(response) = read_response(connection, deadline)? else {
            return Err(ExchangeError::Closed);
        };
        if response.get("event").is_some() || &response["id"] != id {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        let error =
            response.get("error").and_then(Value::as_str).unwrap_or("request rejected").to_string();
        return Err(ExchangeError::Rejected(error));
    }
}

/// Reads the install key straight from standard input (descriptor 0, or
/// the stdin handle on Windows): no buffered stdin copy outlives it; the
/// parsed key is zeroized on drop.
fn read_install_key_from_stdin() -> std::io::Result<cmux_tui_core::server::FrontendKey> {
    #[cfg(unix)]
    let stdin = {
        use std::os::fd::AsFd;
        std::fs::File::from(std::io::stdin().as_fd().try_clone_to_owned()?)
    };
    #[cfg(windows)]
    let stdin = {
        use std::os::windows::io::AsHandle;
        std::fs::File::from(std::io::stdin().as_handle().try_clone_to_owned()?)
    };
    cmux_tui_core::server::read_frontend_key(stdin)
}

/// `server ensure`: connect to a ready owner, spawning a detached one when
/// nothing serves the socket. Reports `running` for an owner that already
/// existed and `started` for one this call spawned. `socket` is the socket
/// path and whether it was derived from the session name; the owner pair is
/// the reap grace and `--exit-with-pid`, the flag pair `--restore-progress`
/// and `--replace-unresponsive`.
fn run_ensure(
    expected_session: Option<String>,
    (terminal_reap_grace, exit_with_pid): (Option<Duration>, Option<crate::local_owner::ExitWith>),
    install_key: Option<cmux_tui_core::server::FrontendKey>,
    (socket, socket_is_derived): (std::path::PathBuf, bool),
    (progress, replace_unresponsive): (bool, bool),
    websocket: Option<crate::local_owner::EnsureWebSocket>,
    output: OutputMode,
) -> i32 {
    let messages = &crate::localization::catalog().local_server;
    let socket_output = socket.to_string_lossy().into_owned();
    let spec = crate::local_owner::OwnerSpec {
        session: expected_session.clone().unwrap_or_else(|| "main".to_string()),
        socket,
        socket_is_derived,
        state: None,
        term: None,
        initial_host_colors: None,
        terminal_reap_grace,
        exit_with_pid,
        install_key,
        // The app's Chief owner: the brain tools socket this client was
        // started with (taken out of its environment at start).
        chief_tools_socket: crate::startup_env::chief_tools_socket(),
        // ...and the Chief brains the app gave it (taken out at start too).
        chief_brains: cmux_tui_core::chief_brains::taken(),
        websocket,
    };
    let replaced = if replace_unresponsive {
        match crate::local_owner::replace_if_unresponsive(&spec) {
            Ok(replaced) => replaced.map(|replaced| replaced.pid),
            Err(error) => {
                let details = match &error {
                    crate::local_owner::ReplaceError::Signal(error) => {
                        json!({"reason": error.to_string()})
                    }
                    _ => json!({}),
                };
                return local_error_with_details(
                    error.code(),
                    messages.replace_refused,
                    details,
                    output,
                    3,
                );
            }
        }
    } else {
        None
    };
    let deadline = Instant::now() + crate::local_owner::ENSURE_DEADLINE;
    let report = |restoring: &crate::local_owner::Restoring| {
        print_progress(&spec.session, restoring);
    };
    let reporter = if progress {
        crate::local_owner::RestoreProgress::new(&report)
    } else {
        crate::local_owner::RestoreProgress::silent()
    };
    match crate::local_owner::ensure_owner(&spec, expected_session.as_deref(), deadline, &reporter)
    {
        Ok(ensured) => {
            let (status, message, ready) = match &ensured {
                crate::local_owner::Ensured::Running(ready) => ("running", messages.running, ready),
                crate::local_owner::Ensured::Started(ready) if replaced.is_some() => {
                    ("replaced", messages.replaced, ready)
                }
                crate::local_owner::Ensured::Started(ready) => ("started", messages.started, ready),
            };
            let mut result = json!({
                "status":status,
                "session":ready.session,
                "socket":socket_output,
                "pid":ready.pid,
                "generation":ready.generation,
                "message":message,
            });
            if let Some(pid) = replaced {
                result.set("replaced_pid", json!(pid));
            }
            print_success(result, output)
        }
        Err(error) => {
            let message = messages.ensure_failed(&error);
            let (code, exit_code) = match error {
                crate::local_owner::EnsureError::Spawn(_error) => ("server.spawn_failed", 3),
                crate::local_owner::EnsureError::NotReady => ("server.unavailable", 3),
                crate::local_owner::EnsureError::RestoreTimeout => ("server.restore_timeout", 3),
                crate::local_owner::EnsureError::Busy => ("server.busy", 3),
                crate::local_owner::EnsureError::WrongOwner => ("server.wrong_owner", 1),
                crate::local_owner::EnsureError::DifferentSession => {
                    ("server.different_session", 1)
                }
                crate::local_owner::EnsureError::DifferentState => ("server.different_state", 1),
                crate::local_owner::EnsureError::InvalidIdentity => ("server.invalid_identity", 3),
                crate::local_owner::EnsureError::UnsupportedProtocol => {
                    ("server.unsupported_protocol", 3)
                }
            };
            // The app learns that the old owner is gone even when the new
            // one did not start.
            let details = replaced.map_or_else(|| json!({}), |pid| json!({"replaced_pid": pid}));
            local_error_with_details(code, &message, details, output, exit_code)
        }
    }
}

/// One restore progress line on stdout (`server ensure --restore-progress`). The
/// result stays the last JSON line, so a reader that takes the last line
/// still reads the result.
fn print_progress(session: &str, restoring: &crate::local_owner::Restoring) {
    use std::io::Write as _;
    let line = json!({
        "progress": "restoring",
        "session": session,
        "pid": restoring.pid,
        "waited_ms": u64::try_from(restoring.waited.as_millis()).unwrap_or(u64::MAX),
    });
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}").and_then(|()| stdout.flush());
}

fn valid_session_name(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= 64
        && session.chars().all(|character| !character.is_control() && !character.is_whitespace())
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ExchangeError {
    Transport,
    Timeout,
    Closed,
    InvalidResponse,
    Rejected(String),
}

fn exchange(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    request: Value,
    deadline: Instant,
) -> Result<Value, ExchangeError> {
    require_time_remaining(connection, deadline)?;
    writeln!(connection.get_mut(), "{request}")
        .and_then(|()| connection.get_mut().flush())
        .map_err(exchange_io_error)?;
    loop {
        let Some(response) = read_response(connection, deadline)? else {
            return Err(ExchangeError::Closed);
        };
        if response.get("event").is_some() || response["id"] != request["id"] {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        let error =
            response.get("error").and_then(Value::as_str).unwrap_or("request rejected").to_string();
        return Err(ExchangeError::Rejected(error));
    }
}

fn read_response(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<Option<Value>, ExchangeError> {
    require_time_remaining(connection, deadline)?;
    let mut bytes = Vec::new();
    match connection.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
        Ok(0) => return Ok(None),
        Ok(_) => {}
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) =>
        {
            return Err(ExchangeError::Timeout);
        }
        Err(error) => return Err(exchange_io_error(error)),
    }
    if bytes.len() > RESPONSE_LIMIT || !bytes.ends_with(b"\n") {
        return Err(ExchangeError::InvalidResponse);
    }
    bytes.pop();
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    serde_json::from_slice(&bytes).map(Some).map_err(|_| ExchangeError::InvalidResponse)
}

fn require_time_remaining(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<(), ExchangeError> {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return Err(ExchangeError::Timeout);
    };
    if remaining.is_zero() {
        return Err(ExchangeError::Timeout);
    }
    connection
        .get_mut()
        .set_read_timeout(Some(remaining))
        .and_then(|()| connection.get_mut().set_write_timeout(Some(remaining)))
        .map_err(exchange_io_error)
}

fn exchange_io_error(error: std::io::Error) -> ExchangeError {
    if matches!(error.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) {
        ExchangeError::Timeout
    } else if matches!(
        error.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::UnexpectedEof
    ) {
        ExchangeError::Closed
    } else {
        ExchangeError::Transport
    }
}

fn is_absent(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused)
}

fn wait_for_close(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    deadline: Instant,
) -> Result<(), String> {
    loop {
        match read_response(connection, deadline) {
            Ok(None) => return Ok(()),
            Ok(Some(event)) => {
                if event.get("event").is_some() {
                    continue;
                }
                return Err(crate::localization::catalog()
                    .local_server
                    .unexpected_after_stop
                    .to_string());
            }
            Err(ExchangeError::Closed | ExchangeError::Transport) => return Ok(()),
            Err(error) => {
                let messages = &crate::localization::catalog().local_server;
                return Err(if error == ExchangeError::Timeout {
                    messages.stop_timeout.to_string()
                } else {
                    messages.communication_failed.to_string()
                });
            }
        }
    }
}

fn usage_error(message: &str, output: OutputMode) -> i32 {
    local_error("usage.invalid", message, output, 2)
}

/// `server compact-registry --session <name> [--state-dir <path>]`: offline,
/// with the owner's session locks, so it needs no socket. The session is
/// never guessed: a wrong default would compact another session than the one
/// the user stopped. Exit 3 with `server.compact_owner_running` while an
/// owner holds the session.
fn run_compact_registry(
    expected_session: Option<String>,
    state_dir: Option<std::path::PathBuf>,
    output: OutputMode,
) -> i32 {
    let messages = &crate::localization::catalog().local_server;
    let Some(session) = expected_session else {
        return local_error("usage.invalid", messages.registry_compact_needs_session, output, 2);
    };
    let Some(root) = state_dir.or_else(cmux_tui_core::platform::workspace_state_dir) else {
        return local_error_with_details(
            "server.compact_no_registry",
            messages.registry_compact_no_registry,
            json!({"session": session, "reason": "no_state_dir"}),
            output,
            3,
        );
    };
    match cmux_tui_core::compact_registry(&root, &session) {
        Ok(compaction) => print_success(
            json!({
                "status": "compacted",
                "session": session,
                "path": compaction.path.to_string_lossy(),
                "before_bytes": compaction.before_bytes,
                "after_bytes": compaction.after_bytes,
                "warning": compaction.warning,
                "message": messages.registry_compacted,
            }),
            output,
        ),
        Err(cmux_tui_core::RegistryCompactError::NoRegistry(path)) => local_error_with_details(
            "server.compact_no_registry",
            messages.registry_compact_no_registry,
            json!({"session": session, "path": path.to_string_lossy()}),
            output,
            3,
        ),
        Err(cmux_tui_core::RegistryCompactError::OwnerRunning(error)) => local_error_with_details(
            "server.compact_owner_running",
            messages.registry_compact_owner_running,
            json!({"session": session, "reason": format!("{error:#}")}),
            output,
            3,
        ),
        Err(cmux_tui_core::RegistryCompactError::Failed(error)) => local_error_with_details(
            "server.compact_failed",
            messages.registry_compact_failed,
            json!({"session": session, "reason": format!("{error:#}")}),
            output,
            1,
        ),
    }
}

fn local_error(code: &str, message: &str, output: OutputMode, exit_code: i32) -> i32 {
    local_error_with_details(code, message, json!({}), output, exit_code)
}

fn local_error_with_details(
    code: &str,
    message: &str,
    details: Value,
    output: OutputMode,
    exit_code: i32,
) -> i32 {
    super::wire::print_local_error(
        &json!({"code":code,"message":message,"details":details,"retryable":false}),
        output,
        exit_code,
    )
}

fn print_success(value: Value, output: OutputMode) -> i32 {
    super::wire::print_local_success(&value, output)
}

/// A stop this daemon refuses (another build): `text` and the one command
/// that restarts the daemon at `socket` with `cli`'s build
/// (plans/cmux-next/version-skew.md).
fn refused_with_fix(text: &str, cli: &std::path::Path, socket: &std::path::Path) -> String {
    format!("{text} {}", super::fix_command::restart_daemon(cli, socket))
}

#[cfg(test)]
mod tests {
    use std::io::{self, Cursor, Read, Write};
    use std::net::Shutdown;
    use std::sync::{Arc, Mutex};

    use super::*;

    #[test]
    fn rejects_invalid_session_names_before_socket_resolution() {
        assert!(!valid_session_name(""));
        assert!(!valid_session_name("bad name"));
        assert!(!valid_session_name("bad\nname"));
        assert!(!valid_session_name(&"x".repeat(65)));
    }

    #[test]
    fn accepts_session_names_for_explicit_and_default_socket_routes() {
        assert!(valid_session_name("main"));
        assert!(valid_session_name("agent-1"));
    }

    struct UnreadableStream;

    impl Read for UnreadableStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            panic!("an expired lifecycle deadline must fail before reading")
        }
    }

    impl Write for UnreadableStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for UnreadableStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self))
        }

        fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    struct TimeoutRecordingStream {
        read_timeout: Arc<Mutex<Option<Duration>>>,
        write_timeout: Arc<Mutex<Option<Duration>>>,
    }

    impl Read for TimeoutRecordingStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Ok(0)
        }
    }

    impl Write for TimeoutRecordingStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for TimeoutRecordingStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self {
                read_timeout: self.read_timeout.clone(),
                write_timeout: self.write_timeout.clone(),
            }))
        }

        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            *self.read_timeout.lock().unwrap() = timeout;
            Ok(())
        }

        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            *self.write_timeout.lock().unwrap() = timeout;
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    struct TransportCloseStream;

    impl Read for TransportCloseStream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("transport closed after shutdown acknowledgement"))
        }
    }

    impl Write for TransportCloseStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for TransportCloseStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self))
        }

        fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    struct RejectedStream {
        response: Cursor<Vec<u8>>,
    }

    impl Read for RejectedStream {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            self.response.read(bytes)
        }
    }

    impl Write for RejectedStream {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for RejectedStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Ok(Box::new(Self { response: self.response.clone() }))
        }

        fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn expired_deadline_fails_before_reading_another_frame() {
        let stream: Box<dyn transport::Stream> = Box::new(UnreadableStream);
        let mut connection = BufReader::new(stream);
        let expired = Instant::now() - Duration::from_millis(1);

        assert_eq!(read_response(&mut connection, expired), Err(ExchangeError::Timeout));
    }

    #[test]
    fn lifecycle_deadline_bounds_reads_and_writes() {
        let read_timeout = Arc::new(Mutex::new(None));
        let write_timeout = Arc::new(Mutex::new(None));
        let stream: Box<dyn transport::Stream> = Box::new(TimeoutRecordingStream {
            read_timeout: read_timeout.clone(),
            write_timeout: write_timeout.clone(),
        });
        let mut connection = BufReader::new(stream);
        let requested = Duration::from_secs(1);

        require_time_remaining(&mut connection, Instant::now() + requested).unwrap();

        let read_timeout = read_timeout.lock().unwrap().unwrap();
        let write_timeout = write_timeout.lock().unwrap().unwrap();
        assert!(!read_timeout.is_zero());
        assert!(read_timeout <= requested);
        assert!(!write_timeout.is_zero());
        assert!(write_timeout <= requested);
    }

    #[test]
    fn stop_accepts_transport_close_after_shutdown_acknowledgement() {
        let stream: Box<dyn transport::Stream> = Box::new(TransportCloseStream);
        let mut connection = BufReader::new(stream);

        assert!(wait_for_close(&mut connection, Instant::now() + Duration::from_secs(1)).is_ok());
    }

    #[test]
    fn exchange_preserves_daemon_rejection_details() {
        let rejection = json!({
            "id": 2,
            "ok": false,
            "error": "trusted local connection required",
        });
        let stream: Box<dyn transport::Stream> = Box::new(RejectedStream {
            response: Cursor::new(format!("{rejection}\n").into_bytes()),
        });
        let mut connection = BufReader::new(stream);
        let error = exchange(
            &mut connection,
            json!({"id":2,"cmd":"server-stats"}),
            Instant::now() + Duration::from_secs(1),
        )
        .expect_err("rejected response");
        assert_eq!(error, ExchangeError::Rejected("trusted local connection required".into()));
    }

    #[test]
    fn lifecycle_io_errors_preserve_timeout_classification() {
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::TimedOut)),
            ExchangeError::Timeout
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::WouldBlock)),
            ExchangeError::Timeout
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::BrokenPipe)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::ConnectionReset)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::NotConnected)),
            ExchangeError::Closed
        );
        assert_eq!(
            exchange_io_error(io::Error::from(io::ErrorKind::Other)),
            ExchangeError::Transport
        );
    }
}
