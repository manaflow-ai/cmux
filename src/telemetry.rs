use std::ffi::OsString;
use std::io::IsTerminal;
use std::time::{Duration, Instant};

use reqwest::blocking::Client;
use serde::Serialize;

use crate::cli::Error;
use crate::config::Config;

const TELEMETRY_PATH: &str = "/api/coderouter/analytics";
const TELEMETRY_TIMEOUT: Duration = Duration::from_millis(200);
const TELEMETRY_CONNECT_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CommandDimensions {
    command: &'static str,
    agent: &'static str,
    mode: &'static str,
}

#[derive(Serialize)]
struct AnalyticsBatch {
    events: [AnalyticsEvent; 2],
}

#[derive(Serialize)]
struct AnalyticsEvent {
    event: &'static str,
    properties: EventProperties,
}

/// This is the complete CLI-to-server analytics property contract. Keep this
/// concrete rather than accepting a map so callers cannot add arbitrary data.
#[derive(Serialize)]
struct EventProperties {
    schema_version: u8,
    command: &'static str,
    agent: &'static str,
    mode: &'static str,
    outcome: &'static str,
    failure_stage: &'static str,
    exit_code_class: &'static str,
    duration_bucket: &'static str,
    execution_context: &'static str,
    cli_version: &'static str,
}

#[derive(Clone)]
struct Transport {
    api_url: String,
    route_token: String,
}

pub(crate) struct CommandTelemetry {
    started: Instant,
    dimensions: CommandDimensions,
    execution_context: &'static str,
    initial_transport: Option<Transport>,
    enabled: bool,
}

impl CommandTelemetry {
    pub(crate) fn start(args: &[OsString]) -> Self {
        let credential_free = is_credential_free_command(args);
        let handoff = crate::handoff::requested();
        Self {
            started: Instant::now(),
            dimensions: classify_command(args),
            execution_context: if std::io::stdin().is_terminal() && std::io::stdout().is_terminal()
            {
                "interactive"
            } else {
                "headless"
            },
            // Capability discovery must not inspect or transmit the saved
            // session. It is intentionally usable before authentication.
            initial_transport: if credential_free || handoff {
                None
            } else {
                Transport::from_saved_config()
            },
            // A handoff route is intentionally process-local.  Do not send
            // analytics with a saved route token, and never include the lease
            // marker or inherited descriptor in analytics context.
            enabled: !credential_free && !handoff && telemetry_enabled(),
        }
    }

    /// Delivery is deliberately best-effort. It runs after the command,
    /// ignores every local/network/server failure, and has one short overall
    /// timeout with no retry.
    pub(crate) fn finish(self, result: &Result<i32, Error>, exit_code: i32) {
        if !self.enabled {
            return;
        }
        // Prefer the final saved scope after renewal or organization switching.
        // Fall back to the initial scope only when the command removed local
        // session state (for example, logout).
        let Some(transport) = Transport::from_saved_config().or(self.initial_transport) else {
            return;
        };
        let terminal = terminal_dimensions(result, exit_code);
        let shared = |outcome, failure_stage, exit_code_class, duration_bucket| EventProperties {
            schema_version: 1,
            command: self.dimensions.command,
            agent: self.dimensions.agent,
            mode: self.dimensions.mode,
            outcome,
            failure_stage,
            exit_code_class,
            duration_bucket,
            execution_context: self.execution_context,
            cli_version: env!("CARGO_PKG_VERSION"),
        };
        let batch = AnalyticsBatch {
            events: [
                AnalyticsEvent {
                    event: "coderouter_cli_command_started",
                    properties: shared("started", "none", "not_applicable", "not_applicable"),
                },
                AnalyticsEvent {
                    event: "coderouter_cli_command_completed",
                    properties: shared(
                        terminal.outcome,
                        terminal.failure_stage,
                        exit_code_class(exit_code),
                        duration_bucket(self.started.elapsed()),
                    ),
                },
            ],
        };
        transport.send(&batch);
    }
}

fn is_credential_free_command(args: &[OsString]) -> bool {
    matches!(
        args.get(1).and_then(|arg| arg.to_str()),
        Some("capabilities" | "-h" | "--help" | "help" | "-V" | "--version" | "version")
    )
}

impl Transport {
    fn from_saved_config() -> Option<Self> {
        let config = crate::config::load().ok()?;
        Self::from_config(config)
    }

    fn from_config(config: Config) -> Option<Self> {
        if !config.logged_in() || config.api_url.is_empty() {
            return None;
        }
        Some(Self {
            api_url: config.api_url,
            route_token: config.route_token,
        })
    }

    fn send(&self, batch: &AnalyticsBatch) {
        let Ok(client) = Client::builder()
            .timeout(TELEMETRY_TIMEOUT)
            .connect_timeout(TELEMETRY_CONNECT_TIMEOUT)
            .user_agent(format!("coderouter/{}", env!("CARGO_PKG_VERSION")))
            .build()
        else {
            return;
        };
        let _ = client
            .post(format!(
                "{}{TELEMETRY_PATH}",
                self.api_url.trim_end_matches('/')
            ))
            // The server authenticates this scoped route token and is solely
            // responsible for deriving pseudonymous user/team analytics scope.
            .bearer_auth(&self.route_token)
            .json(batch)
            .send();
    }
}

struct TerminalDimensions {
    outcome: &'static str,
    failure_stage: &'static str,
}

fn terminal_dimensions(result: &Result<i32, Error>, exit_code: i32) -> TerminalDimensions {
    match result {
        Ok(0) => TerminalDimensions {
            outcome: "success",
            failure_stage: "none",
        },
        Ok(_) => TerminalDimensions {
            outcome: if exit_code >= 128 {
                "cancelled"
            } else {
                "failure"
            },
            failure_stage: "child_process",
        },
        Err(Error::Usage(_)) => TerminalDimensions {
            outcome: "failure",
            failure_stage: "validation",
        },
        Err(Error::Backend(_)) => TerminalDimensions {
            outcome: "failure",
            failure_stage: "control_plane",
        },
        Err(Error::Spawn { .. }) => TerminalDimensions {
            outcome: "failure",
            failure_stage: "child_start",
        },
        Err(Error::Io(_)) => TerminalDimensions {
            outcome: "failure",
            failure_stage: "local_io",
        },
    }
}

fn exit_code_class(code: i32) -> &'static str {
    match code {
        0 => "success",
        1 => "generic_failure",
        2 => "usage",
        126 | 127 => "launch_failure",
        128.. => "signal_or_terminated",
        _ => "other_failure",
    }
}

fn duration_bucket(duration: Duration) -> &'static str {
    match duration.as_secs() {
        0 => "under_1s",
        1..=4 => "1s_to_5s",
        5..=29 => "5s_to_30s",
        30..=119 => "30s_to_2m",
        _ => "2m_or_more",
    }
}

fn telemetry_enabled() -> bool {
    !["DO_NOT_TRACK", "CODEROUTER_TELEMETRY_DISABLED"]
        .iter()
        .any(|name| std::env::var(name).is_ok_and(|value| opt_out_value(&value)))
}

fn opt_out_value(value: &str) -> bool {
    !matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "0" | "false" | "no" | "off"
    )
}

fn classify_command(args: &[OsString]) -> CommandDimensions {
    let top = args.get(1).and_then(|value| value.to_str());
    let sub = args.get(2).and_then(|value| value.to_str());
    match top {
        None => dimensions("accounts", "none", "summary"),
        Some("-h" | "--help" | "help") => dimensions("help", "none", "default"),
        Some("-V" | "--version" | "version") => dimensions("version", "none", "default"),
        Some("codex") => dimensions("agent", "codex", "routed"),
        Some("opencode") => dimensions("agent", "opencode", "routed"),
        Some("pi") => dimensions("agent", "pi", "routed"),
        Some("naked" | "direct") => dimensions("agent", "codex", "direct"),
        Some("add") => match sub {
            None => dimensions("add", "none", "interactive"),
            Some("codex") => dimensions("add", "codex", "specified"),
            Some("opencode" | "opencode-go" | "go") => dimensions("add", "opencode", "specified"),
            Some("cancel") => dimensions("add", "none", "cancel"),
            _ => dimensions("add", "none", "unknown"),
        },
        Some("remove" | "rm") => dimensions("remove", "none", "default"),
        Some("login")
            if args[2..]
                .iter()
                .any(|value| value.to_str() == Some("--code")) =>
        {
            dimensions("login", "none", "code")
        }
        Some("login")
            if args[2..].iter().any(|value| {
                matches!(
                    value.to_str(),
                    Some("--no-browser" | "--device-auth" | "--device")
                )
            }) =>
        {
            dimensions("login", "none", "device")
        }
        Some("login") => dimensions("login", "none", "interactive"),
        Some("logout") => dimensions("logout", "none", "default"),
        Some("org" | "organization" | "team") => match sub {
            None | Some("current" | "status") => dimensions("organization", "none", "current"),
            Some("list" | "ls") => dimensions("organization", "none", "list"),
            Some("switch" | "use") => dimensions("organization", "none", "switch"),
            _ => dimensions("organization", "none", "unknown"),
        },
        Some("upgrade") => dimensions("upgrade", "none", "default"),
        Some("accounts" | "account" | "usage") => dimensions("accounts", "none", "summary"),
        Some("doctor") => dimensions("doctor", "none", "default"),
        Some(_) => dimensions("unknown", "none", "unknown"),
    }
}

const fn dimensions(
    command: &'static str,
    agent: &'static str,
    mode: &'static str,
) -> CommandDimensions {
    CommandDimensions {
        command,
        agent,
        mode,
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::net::TcpListener;
    use std::thread;

    use serde_json::Value;

    use super::*;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn all_top_level_commands_and_aliases_are_categorized() {
        let cases = [
            (None, "accounts"),
            (Some("--help"), "help"),
            (Some("--version"), "version"),
            (Some("codex"), "agent"),
            (Some("opencode"), "agent"),
            (Some("pi"), "agent"),
            (Some("naked"), "agent"),
            (Some("direct"), "agent"),
            (Some("add"), "add"),
            (Some("remove"), "remove"),
            (Some("rm"), "remove"),
            (Some("login"), "login"),
            (Some("logout"), "logout"),
            (Some("org"), "organization"),
            (Some("organization"), "organization"),
            (Some("team"), "organization"),
            (Some("upgrade"), "upgrade"),
            (Some("accounts"), "accounts"),
            (Some("account"), "accounts"),
            (Some("usage"), "accounts"),
            (Some("doctor"), "doctor"),
            (Some("not-a-command"), "unknown"),
        ];
        for (top, expected) in cases {
            let values = match top {
                Some(top) => vec!["coderouter", top],
                None => vec!["coderouter"],
            };
            assert_eq!(classify_command(&args(&values)).command, expected);
        }
    }

    #[test]
    fn event_properties_are_exactly_allowlisted() {
        let properties = EventProperties {
            schema_version: 1,
            command: "agent",
            agent: "codex",
            mode: "routed",
            outcome: "success",
            failure_stage: "none",
            exit_code_class: "success",
            duration_bucket: "under_1s",
            execution_context: "headless",
            cli_version: "test",
        };
        let value = serde_json::to_value(properties).unwrap();
        let mut keys = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "agent",
                "cli_version",
                "command",
                "duration_bucket",
                "execution_context",
                "exit_code_class",
                "failure_stage",
                "mode",
                "outcome",
                "schema_version",
            ]
        );
    }

    #[test]
    fn classification_never_serializes_child_arguments_or_sensitive_values() {
        let sensitive = [
            "coderouter",
            "naked",
            "private-child-subcommand",
            "/Users/alice/private/project",
            "sk-secret-token",
            "person@example.com",
            "prompt text",
        ];
        let classified = classify_command(&args(&sensitive));
        let properties = EventProperties {
            schema_version: 1,
            command: classified.command,
            agent: classified.agent,
            mode: classified.mode,
            outcome: "success",
            failure_stage: "none",
            exit_code_class: "success",
            duration_bucket: "under_1s",
            execution_context: "headless",
            cli_version: "test",
        };
        let encoded = serde_json::to_string(&properties).unwrap();
        assert_eq!(classified, dimensions("agent", "codex", "direct"));
        for forbidden in &sensitive[2..] {
            assert!(!encoded.contains(forbidden), "leaked {forbidden:?}");
        }
    }

    #[test]
    fn standard_opt_out_values_disable_telemetry() {
        for value in ["1", "true", "yes", "on", " TRUE "] {
            assert!(opt_out_value(value));
        }
        for value in ["", "0", "false", "no", "off"] {
            assert!(!opt_out_value(value));
        }
    }

    #[test]
    fn capability_probe_does_not_load_or_send_the_saved_session() {
        let telemetry = CommandTelemetry::start(&args(&["coderouter", "capabilities", "--json"]));
        assert!(!telemetry.enabled);
        assert!(telemetry.initial_transport.is_none());
    }

    #[test]
    fn transport_is_short_timeout_and_fail_open() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            thread::sleep(Duration::from_secs(1));
        });
        let transport = Transport {
            api_url: format!("http://{address}"),
            route_token: "route-test".into(),
        };
        let batch = AnalyticsBatch {
            events: [
                AnalyticsEvent {
                    event: "coderouter_cli_command_started",
                    properties: test_properties("started"),
                },
                AnalyticsEvent {
                    event: "coderouter_cli_command_completed",
                    properties: test_properties("success"),
                },
            ],
        };
        let started = Instant::now();
        transport.send(&batch);
        assert!(
            started.elapsed() < Duration::from_millis(750),
            "telemetry exceeded its fail-open bound"
        );
        server.join().unwrap();
    }

    #[test]
    fn request_body_has_no_auth_scope_or_arbitrary_fields() {
        let properties = test_properties("success");
        let value: Value = serde_json::to_value(properties).unwrap();
        let encoded = value.to_string();
        for forbidden in [
            "team_id",
            "user_id",
            "account_id",
            "email",
            "token",
            "path",
            "arguments",
            "error",
            "distinct_id",
            "installation_id",
        ] {
            assert!(!encoded.contains(forbidden), "found {forbidden}");
        }
    }

    fn test_properties(outcome: &'static str) -> EventProperties {
        EventProperties {
            schema_version: 1,
            command: "accounts",
            agent: "none",
            mode: "summary",
            outcome,
            failure_stage: "none",
            exit_code_class: "success",
            duration_bucket: "under_1s",
            execution_context: "headless",
            cli_version: "test",
        }
    }
}
