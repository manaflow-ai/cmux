//! `oracle-state`: the correctness oracle's daemon facet extras
//! (plans/cmux-next/chrome-parity/p15-oracle.md, task 021).
//!
//! The daemon facet is the public `session.snapshot` and `settings.snapshot`
//! plus the journal head of the snapshot's cut. This command returns that cut
//! from the `session.snapshot` builder (`resource_session_snapshot_at_cut`,
//! which also fills the connection's `clients`) and adds only what the public
//! reads lack: the refactor switch arms, terminal attach counts, live runtime
//! object counts and the owner's panic log. The counts are read from the
//! cut's own `State`, except `liveObjects.subscriptions` (event bus state,
//! read just after the cut). It is Blink's `InstanceCounters` read through `internals` in web tests
//! (third_party/blink/renderer/platform/instrumentation/instance_counters.h,
//! third_party/blink/renderer/core/testing/internals.cc): counts of live
//! objects, compiled only into test builds. Here that is debug builds and
//! `--features oracle`; a release daemon has no `oracle-state` command.
//!
//! Every map is a `BTreeMap`, so the reply's keys are sorted and two daemons
//! in the same state reply with the same bytes.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use crate::model::State;
use crate::{Mux, ResourceSelectors};

/// Switch name to arm (`old` or `new`).
pub(crate) type SwitchArms = BTreeMap<&'static str, &'static str>;

/// The F6 holder refactor switch (p15-oracle task 232).
const TERMINAL_HOLDER: &str = "terminal-holder";

/// The arms this daemon runs. The one daemon switch so far is the F6 holder,
/// which `holder_runtime` reads once from `CMUX_TUI_TERMINAL_HOST_MODEL`;
/// task 020's `Switches` value from `CMUX_TUI_SWITCHES` replaces this source.
pub(crate) fn launch_switch_arms() -> SwitchArms {
    let holder = if crate::holder_runtime::enabled() { "new" } else { "old" };
    BTreeMap::from([(TERMINAL_HOLDER, holder)])
}

/// The `oracle-state` reply.
#[derive(Debug, Serialize)]
pub(crate) struct OracleState {
    /// The session journal head read in the same projection lock as `session`.
    pub(crate) journal_head: u64,
    /// The `session.snapshot` result at `journal_head`.
    pub(crate) session: Value,
    /// The daemon's frozen switch arms ([`Mux::oracle_switches`]).
    pub(crate) switches: SwitchArms,
    /// From the cut's `State`.
    #[serde(rename = "terminalAttach")]
    pub(crate) terminal_attach: TerminalAttach,
    /// Runtime object kind to live count; all but `subscriptions` from the
    /// cut's `State`.
    #[serde(rename = "liveObjects")]
    pub(crate) live_objects: BTreeMap<&'static str, u64>,
    #[serde(rename = "panicLog")]
    pub(crate) panic_log: PanicLog,
}

/// The terminal catalog by attach state. A terminal whose process ended is
/// `dead`; a live one shown in at least one pane tab is `attached`; a live one
/// with no placement (a detached or a parked terminal) is `detached`.
#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub(crate) struct TerminalAttach {
    pub(crate) attached: u64,
    pub(crate) detached: u64,
    pub(crate) dead: u64,
}

/// The owner's panic log: one JSON line per panic (`cmux-panic-log`).
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct PanicLog {
    /// `None` when there is no state root to put it in.
    pub(crate) path: Option<String>,
    /// The log's length; `0` when no panic was written.
    pub(crate) bytes: u64,
}

/// Build the reply for control client `client`, whose `session.snapshot`
/// this `session` equals.
pub(crate) fn oracle_state(mux: &Mux, client: u64) -> anyhow::Result<OracleState> {
    let current = Some("current".to_string());
    let selectors =
        ResourceSelectors { machine: current.clone(), session: current, ..Default::default() };
    let (session, journal_head, (terminal_attach, mut live_objects)) =
        crate::server::resource_session_snapshot_at_cut(mux, client, &selectors, runtime_counts)?;
    live_objects.insert("subscriptions", count(mux.live_event_subscriber_count()));
    Ok(OracleState {
        journal_head,
        session,
        switches: mux.oracle_switches().clone(),
        terminal_attach,
        live_objects,
        panic_log: panic_log(&mux.session),
    })
}

/// Attach counts and live object counts, from one read of the state.
fn runtime_counts(state: &State) -> (TerminalAttach, BTreeMap<&'static str, u64>) {
    let placed: BTreeSet<_> =
        state.surfaces.values().filter_map(|surface| surface.terminal_runtime_id()).collect();
    let mut attach = TerminalAttach::default();
    for terminal in state.terminal_catalog.values() {
        let bucket = if terminal.is_dead() {
            &mut attach.dead
        } else if terminal.terminal_runtime_id().is_some_and(|id| placed.contains(&id)) {
            &mut attach.attached
        } else {
            &mut attach.detached
        };
        *bucket += 1;
    }
    let browsers = state.surfaces.values().filter(|surface| surface.as_browser().is_some());
    let live = BTreeMap::from([
        ("browsers", count(browsers.count())),
        ("panes", count(state.panes.len())),
        ("screens", count(state.workspaces.iter().map(|ws| ws.screens.len()).sum())),
        ("terminals", count(state.terminal_catalog.len())),
        ("views", count(state.surfaces.len())),
        ("workspaces", count(state.workspaces.len())),
    ]);
    (attach, live)
}

fn panic_log(session: &str) -> PanicLog {
    let path = crate::diagnostics::owner_panic_log_path(session);
    let bytes =
        path.as_deref().and_then(|path| std::fs::metadata(path).ok()).map_or(0, |m| m.len());
    PanicLog { path: path.map(|path| path.to_string_lossy().into_owned()), bytes }
}

fn count(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "oracle_state_tests.rs"]
mod tests;
