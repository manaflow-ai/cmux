//! Named timing and size budgets shared by the daemon, terminal hosts, and
//! clients.
//!
//! Every bounded wait in cmux-tui is a budget with one name, one value, and
//! one stage of the interaction lifecycle it belongs to. The constants here are
//! the single source for the values; the code sites that enforce them import
//! these constants instead of spelling the number again, and `cmux-tui diag
//! budgets` prints [`table`] so an operator or an agent can read every bound in
//! one place. A timeout error should name the budget it exhausted.
//!
//! Stages:
//! - `accept`: the request is validated and applied to in-memory state.
//! - `durable`: the journal batch that carries the request has committed.
//! - `settle`: an external effect (host launch, terminate, first frame) has
//!   reached its outcome.
//! - `frame`: a frontend paint cadence.
//! - `client`: a client-side wait on the daemon.
//! - `planned`: reserved by design and not enforced yet.

use std::time::Duration;

/// One bounded quantity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BudgetValue {
    Duration(Duration),
    Bytes(u64),
}

impl BudgetValue {
    /// Machine-readable unit name for JSON output.
    pub fn unit(self) -> &'static str {
        match self {
            BudgetValue::Duration(_) => "ms",
            BudgetValue::Bytes(_) => "bytes",
        }
    }

    /// Numeric value in [`Self::unit`].
    pub fn amount(self) -> u64 {
        match self {
            BudgetValue::Duration(duration) => u64::try_from(duration.as_millis()).unwrap_or(u64::MAX),
            BudgetValue::Bytes(bytes) => bytes,
        }
    }
}

/// One named budget and where it is enforced.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    /// Dotted name, unique in [`table`].
    pub name: &'static str,
    pub value: BudgetValue,
    /// One of `accept`, `durable`, `settle`, `frame`, `client`, `planned`.
    pub stage: &'static str,
    /// What exhausting the budget means.
    pub purpose: &'static str,
    /// Code site that enforces it, as `crate::path` or a file name.
    pub site: &'static str,
}

/// Every stage name a budget may carry.
pub const STAGES: &[&str] = &["accept", "durable", "settle", "frame", "client", "planned"];

// Terminal host launch, handshake, and teardown.
pub const HOST_CONNECT_WINDOW: Duration = Duration::from_secs(1);
pub const HOST_CONNECT_INTERVAL: Duration = Duration::from_millis(10);
pub const HOST_HANDSHAKE: Duration = Duration::from_secs(2);
pub const HOST_SNAPSHOT_BOUNDARY: Duration = Duration::from_millis(1500);
pub const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
pub const HOST_PTY_DRAIN: Duration = Duration::from_millis(250);
pub const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
pub const HOST_FORCED_DRAIN: Duration = Duration::from_millis(100);
pub const HOST_LAUNCH_ROLLBACK: Duration = Duration::from_secs(4);
pub const HOST_LAUNCH_OWNER: Duration = Duration::from_secs(5);
pub const HOST_CLIENT_WRITE: Duration = Duration::from_secs(2);
pub const HOST_CONTROL_RESPONSE: Duration = Duration::from_secs(2);
pub const TERMINAL_CLOSE_WAIT: Duration = Duration::from_secs(4);

// Journal writer.
pub const JOURNAL_DURABLE_WAIT: Duration = Duration::from_secs(2);
pub const JOURNAL_COMMIT_RESULT_WAIT: Duration = Duration::from_secs(1);

// Control server.
pub const SERVER_STREAM_WRITE: Duration = Duration::from_secs(2);
pub const SERVER_CONNECTION_SURFACE_SHUTDOWN: Duration = Duration::from_secs(3);

// Clients.
pub const CLIENT_REQUEST: Duration = Duration::from_secs(10);
pub const CLIENT_WRITE: Duration = Duration::from_secs(2);
pub const OWNER_ENSURE: Duration = Duration::from_secs(10);
pub const OWNER_POLL: Duration = Duration::from_millis(25);
pub const FRAME: Duration = Duration::from_millis(16);

// Planned, not enforced.
pub const INPUT_TYPEAHEAD_BYTES: u64 = 64 * 1024;

const fn duration(
    name: &'static str,
    value: Duration,
    stage: &'static str,
    purpose: &'static str,
    site: &'static str,
) -> Budget {
    Budget { name, value: BudgetValue::Duration(value), stage, purpose, site }
}

static TABLE: [Budget; 23] = [
    duration(
        "host.connect_window",
        HOST_CONNECT_WINDOW,
        "settle",
        "total time the daemon retries connecting to a freshly launched terminal host socket",
        "cmux_tui_core::terminal_host_runtime::HOST_CONNECT_RETRY_WINDOW",
    ),
    duration(
        "host.connect_interval",
        HOST_CONNECT_INTERVAL,
        "settle",
        "pause between host socket connect attempts inside host.connect_window",
        "cmux_tui_core::terminal_host_runtime::HOST_CONNECT_RETRY_INTERVAL",
    ),
    duration(
        "host.handshake",
        HOST_HANDSHAKE,
        "settle",
        "read and write timeout for one CMTH handshake exchange",
        "cmux_tui_core::terminal_host_runtime::HOST_HANDSHAKE_TIMEOUT",
    ),
    duration(
        "host.snapshot_boundary",
        HOST_SNAPSHOT_BOUNDARY,
        "settle",
        "how long a host waits for its VT parser to reach ground before snapshotting for a new client",
        "cmux_tui_core::terminal_host_runtime::HOST_SNAPSHOT_BOUNDARY_TIMEOUT",
    ),
    duration(
        "host.terminate_grace",
        HOST_TERMINATE_GRACE,
        "settle",
        "time after SIGHUP before the host escalates to SIGKILL",
        "cmux_tui_core::terminal_host_runtime::HOST_TERMINATE_GRACE",
    ),
    duration(
        "host.pty_drain",
        HOST_PTY_DRAIN,
        "settle",
        "time the host waits for the PTY to drain after the child exits",
        "cmux_tui_core::terminal_host_runtime::HOST_PTY_DRAIN_GRACE",
    ),
    duration(
        "host.kill_wait",
        HOST_KILL_WAIT,
        "settle",
        "time the host waits for the child to die after SIGKILL",
        "cmux_tui_core::terminal_host_runtime::HOST_KILL_WAIT",
    ),
    duration(
        "host.forced_drain",
        HOST_FORCED_DRAIN,
        "settle",
        "final forced PTY drain window when the child ignored SIGKILL escalation",
        "cmux_tui_core::terminal_host_runtime::HOST_FORCED_DRAIN_WINDOW",
    ),
    duration(
        "host.launch_rollback",
        HOST_LAUNCH_ROLLBACK,
        "settle",
        "time the daemon waits for a half-launched host to exit while rolling a failed create back",
        "cmux_tui_core::terminal_host_runtime::HOST_LAUNCH_ROLLBACK_WAIT",
    ),
    duration(
        "host.launch_owner",
        HOST_LAUNCH_OWNER,
        "settle",
        "time a host waits for its launch owner to send Activate before releasing the PTY reader itself",
        "cmux_tui_core::terminal_host_runtime::HOST_LAUNCH_OWNER_TIMEOUT",
    ),
    duration(
        "host.client_write",
        HOST_CLIENT_WRITE,
        "settle",
        "write timeout for daemon-to-host control frames",
        "cmux_tui_core::terminal_host_runtime::HOST_CLIENT_WRITE_TIMEOUT",
    ),
    duration(
        "host.control_response",
        HOST_CONTROL_RESPONSE,
        "settle",
        "time the daemon waits for a host control response such as TerminateAck",
        "cmux_tui_core::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT",
    ),
    duration(
        "terminal.close_wait",
        TERMINAL_CLOSE_WAIT,
        "settle",
        "total time a terminal close waits for the host to report Exit before killing it",
        "cmux_tui_core::mux::TERMINAL_HOST_CLOSE_WAIT",
    ),
    duration(
        "journal.durable_wait",
        JOURNAL_DURABLE_WAIT,
        "durable",
        "time a producer waits for journal lane admission and the durable receipt",
        "cmux_tui_core::journal_ingress::JOURNAL_DURABLE_WAIT",
    ),
    duration(
        "journal.commit_result_wait",
        JOURNAL_COMMIT_RESULT_WAIT,
        "durable",
        "time a producer waits for the writer to report its batch commit result",
        "cmux_tui_core::journal_ingress::JOURNAL_COMMIT_RESULT_WAIT",
    ),
    duration(
        "server.stream_write",
        SERVER_STREAM_WRITE,
        "client",
        "write timeout for one response or event line to a control connection",
        "cmux_tui_core::server::STREAM_WRITE_TIMEOUT",
    ),
    duration(
        "server.connection_surface_shutdown",
        SERVER_CONNECTION_SURFACE_SHUTDOWN,
        "client",
        "time the server waits for a connection's surface dispatcher to drain on close",
        "cmux_tui_core::server::CONNECTION_SURFACE_SHUTDOWN_TIMEOUT",
    ),
    duration(
        "client.request",
        CLIENT_REQUEST,
        "client",
        "time the TUI client waits for one control response",
        "cmux_tui::session::remote::REMOTE_REQUEST_TIMEOUT",
    ),
    duration(
        "client.write",
        CLIENT_WRITE,
        "client",
        "time the TUI client waits for an ordered socket write to be accepted",
        "cmux_tui::session::remote::remote_write_timeout",
    ),
    duration(
        "owner.ensure",
        OWNER_ENSURE,
        "client",
        "total time a client spends probing, spawning, and waiting for a session owner",
        "cmux_tui::local_owner::ENSURE_DEADLINE",
    ),
    duration(
        "owner.poll",
        OWNER_POLL,
        "client",
        "pause between owner readiness probes inside owner.ensure",
        "cmux_tui::local_owner::POLL_INTERVAL",
    ),
    duration(
        "frame",
        FRAME,
        "frame",
        "TUI paint cadence; any wait longer than this must be shown as state",
        "cmux_tui::app::TERMINAL_PAINT_CADENCE",
    ),
    Budget {
        name: "input.typeahead_bytes",
        value: BudgetValue::Bytes(INPUT_TYPEAHEAD_BYTES),
        stage: "planned",
        purpose: "reserved for IX2: bytes queued for a launching terminal before Activate; not yet enforced",
        site: "plans/cmux-tui-zero-wait-interaction.md L4",
    },
];

/// Every budget, in declaration order. Names are unique.
pub fn table() -> &'static [Budget] {
    &TABLE
}

/// Look one budget up by name.
pub fn find(name: &str) -> Option<&'static Budget> {
    TABLE.iter().find(|budget| budget.name == name)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn budget_names_are_unique_and_dotted() {
        let mut seen = BTreeSet::new();
        for budget in table() {
            assert!(seen.insert(budget.name), "duplicate budget name {}", budget.name);
            assert!(
                budget.name.chars().all(|c| c.is_ascii_lowercase() || c == '.' || c == '_'),
                "budget name {} must be lowercase dotted",
                budget.name
            );
            assert!(!budget.purpose.is_empty());
            assert!(!budget.site.is_empty());
        }
    }

    #[test]
    fn every_stage_is_known() {
        for budget in table() {
            assert!(STAGES.contains(&budget.stage), "{} has unknown stage {}", budget.name, budget.stage);
        }
    }

    #[test]
    fn table_values_match_the_named_constants() {
        let expect = |name: &str, value: BudgetValue| {
            assert_eq!(find(name).unwrap_or_else(|| panic!("missing {name}")).value, value, "{name}");
        };
        expect("host.connect_window", BudgetValue::Duration(HOST_CONNECT_WINDOW));
        expect("host.connect_interval", BudgetValue::Duration(HOST_CONNECT_INTERVAL));
        expect("host.handshake", BudgetValue::Duration(HOST_HANDSHAKE));
        expect("host.snapshot_boundary", BudgetValue::Duration(HOST_SNAPSHOT_BOUNDARY));
        expect("host.terminate_grace", BudgetValue::Duration(HOST_TERMINATE_GRACE));
        expect("host.pty_drain", BudgetValue::Duration(HOST_PTY_DRAIN));
        expect("host.kill_wait", BudgetValue::Duration(HOST_KILL_WAIT));
        expect("host.forced_drain", BudgetValue::Duration(HOST_FORCED_DRAIN));
        expect("host.launch_rollback", BudgetValue::Duration(HOST_LAUNCH_ROLLBACK));
        expect("host.launch_owner", BudgetValue::Duration(HOST_LAUNCH_OWNER));
        expect("host.client_write", BudgetValue::Duration(HOST_CLIENT_WRITE));
        expect("host.control_response", BudgetValue::Duration(HOST_CONTROL_RESPONSE));
        expect("terminal.close_wait", BudgetValue::Duration(TERMINAL_CLOSE_WAIT));
        expect("journal.durable_wait", BudgetValue::Duration(JOURNAL_DURABLE_WAIT));
        expect("journal.commit_result_wait", BudgetValue::Duration(JOURNAL_COMMIT_RESULT_WAIT));
        expect("server.stream_write", BudgetValue::Duration(SERVER_STREAM_WRITE));
        expect(
            "server.connection_surface_shutdown",
            BudgetValue::Duration(SERVER_CONNECTION_SURFACE_SHUTDOWN),
        );
        expect("client.request", BudgetValue::Duration(CLIENT_REQUEST));
        expect("client.write", BudgetValue::Duration(CLIENT_WRITE));
        expect("owner.ensure", BudgetValue::Duration(OWNER_ENSURE));
        expect("owner.poll", BudgetValue::Duration(OWNER_POLL));
        expect("frame", BudgetValue::Duration(FRAME));
        expect("input.typeahead_bytes", BudgetValue::Bytes(INPUT_TYPEAHEAD_BYTES));
    }

    #[test]
    fn planned_budgets_are_not_enforced_by_code_sites() {
        for budget in table().iter().filter(|budget| budget.stage == "planned") {
            assert!(!budget.site.contains("::"), "planned budget {} names a code site", budget.name);
        }
    }

    #[test]
    fn values_render_in_one_unit_each() {
        assert_eq!(BudgetValue::Duration(Duration::from_millis(1500)).amount(), 1500);
        assert_eq!(BudgetValue::Duration(Duration::from_millis(1500)).unit(), "ms");
        assert_eq!(BudgetValue::Bytes(65_536).amount(), 65_536);
        assert_eq!(BudgetValue::Bytes(65_536).unit(), "bytes");
    }
}
