//! `oracle-state`: the correctness oracle's daemon facet extras
//! (plans/cmux-next/chrome-parity/p15-oracle.md, task 021).
//!
//! The daemon facet is the public `session.snapshot` and `settings.snapshot`
//! plus the journal head of the snapshot's cut. This command returns that cut
//! from the `session.snapshot` builder (`resource_session_snapshot_at_cut`,
//! which also fills the connection's `clients`) and adds only what the public
//! reads lack: the refactor switch arms, terminal attach counts, live runtime
//! object counts, the owner's panic log and the holder exits this owner
//! counted (task 188, invariant I17). The counts are read from the
//! cut's own `State`, except `liveObjects.subscriptions` (event bus state,
//! read just after the cut). It is Blink's `InstanceCounters` read through `internals` in web tests
//! (third_party/blink/renderer/platform/instrumentation/instance_counters.h,
//! third_party/blink/renderer/core/testing/internals.cc): counts of live
//! objects, compiled only into test builds. Here that is debug builds and
//! `--features oracle`; a release daemon has no `oracle-state` command.
//!
//! The child exits are Chromium's `NoRendererCrashesAssertion`
//! (content/public/test/browser_test_base.h) for the daemon's children: the
//! terminal holders of this session that ended (lost, or replaced on their
//! running shell), counted by this owner where it logs them
//! (`Mux::note_holder_exit`). The count is this owner's own, so it never
//! falls with the loss log's rotation and never takes another session's
//! holders; it restarts at zero with the owner. The owner's own abnormal end
//! is not here: the app counts it (a connection lost without
//! `daemon-shutdown`), since a crashed owner cannot.
//!
//! Every map is a `BTreeMap`, so the reply's keys are sorted and two daemons
//! in the same state reply with the same bytes.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use crate::model::State;
use crate::panic_free::JsonFields;
use crate::{Mux, ResourceSelectors};

/// Switch name to arm (`old` or `new`).
pub(crate) type SwitchArms = BTreeMap<&'static str, &'static str>;

/// The F6 holder refactor switch (p15-oracle task 232).
const TERMINAL_HOLDER: &str = "terminal-holder";

/// The arms this daemon runs. The one daemon switch so far is the F6 holder,
/// which `holder_runtime` fixes once from the `terminalHolder` feature;
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
    /// Child exit kind (`holder`, one of the crashes facet's kinds) to the
    /// exits this owner counted since it started.
    #[serde(rename = "childExits")]
    pub(crate) child_exits: ChildExits,
}

/// Child exit kind to count.
pub(crate) type ChildExits = BTreeMap<&'static str, u64>;

/// A holder (terminal host) ended without its terminal's exit: a host loss,
/// or a host replaced on its still-running shell (the old host still died).
const HOLDER: &str = "holder";

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
        child_exits: child_exits(mux.oracle_holder_exits()),
    })
}

/// Attach counts and live object counts, from one read of the state.
fn runtime_counts(state: &State) -> (TerminalAttach, BTreeMap<&'static str, u64>) {
    let placed: BTreeSet<_> =
        state.surfaces.values().filter_map(|surface| surface.terminal_runtime_id()).collect();
    let mut attach = TerminalAttach::default();
    // Live terminals hosted out of process: their holders run. A local test
    // runtime has no host connection.
    let mut holders = 0;
    for terminal in state.terminal_catalog.values() {
        if !terminal.is_dead() && terminal.terminal_host_connection_state().is_some() {
            holders += 1;
        }
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
        ("holders", count(holders)),
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

/// The child exits this owner counted, by kind.
pub(crate) fn child_exits(holders: u64) -> ChildExits {
    BTreeMap::from([(HOLDER, holders)])
}

/// How invariant I9 treats one top-level section of `session.snapshot`:
/// the journal restore preview's value is compared with the live one, or
/// the section is not restored from the journal, for a reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "restore", rename_all = "camelCase")]
pub(crate) enum RestoreSection {
    Compared,
    Excluded { reason: &'static str },
}

/// The section map of I9 (p15-oracle task 205): every top-level key of
/// `session.snapshot`, in its order. A new section fails
/// `the_section_map_covers_every_session_snapshot_key` until it is added
/// here, compared or excluded with a reason. The compared sections are the
/// ones `journal_checkpoint::RestoreReducer` reduces (the resource
/// collections, the session resource and the cursor) and `extra`, which it
/// keeps at the checkpoint's value: it equals the live one only while no
/// `state_upsert`/`state_delete` change followed the checkpoint, and
/// [`RestorePreview::state_changes_not_reduced`] counts the ones that did
/// (I9 fails on them, as on an unsupported record).
pub(crate) const RESTORE_SECTIONS: [(&str, RestoreSection); 15] = [
    (
        "machine",
        RestoreSection::Excluded {
            reason: "the host the daemon runs on, not session state: no journal record \
                     changes it, so a preview only repeats the checkpoint's value",
        },
    ),
    ("session", RestoreSection::Compared),
    ("workspaces", RestoreSection::Compared),
    ("screens", RestoreSection::Compared),
    ("panes", RestoreSection::Compared),
    ("tabs", RestoreSection::Compared),
    ("terminals", RestoreSection::Compared),
    ("browsers", RestoreSection::Compared),
    (
        "clients",
        RestoreSection::Excluded {
            reason: "the connections of this daemon process: no journal record carries \
                     them, and a restored session starts with none",
        },
    ),
    ("notifications", RestoreSection::Compared),
    ("agents", RestoreSection::Compared),
    ("frontend_projections", RestoreSection::Compared),
    ("sidebar_views", RestoreSection::Compared),
    ("cursor", RestoreSection::Compared),
    ("extra", RestoreSection::Compared),
];

/// The `oracle-restore-preview` reply.
#[derive(Debug, Serialize)]
pub(crate) struct OracleRestorePreview {
    /// [`RESTORE_SECTIONS`], by section name.
    pub(crate) sections: BTreeMap<&'static str, RestoreSection>,
    /// `None` when the session has no journal checkpoint yet.
    pub(crate) preview: Option<RestorePreview>,
}

/// The journal checkpoint reduced through the journal head.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RestorePreview {
    pub(crate) checkpoint_id: String,
    pub(crate) checkpoint_sequence: u64,
    /// The journal head the reduction ended at: I9 compares the preview
    /// with a daemon facet whose `journalHead` is this sequence.
    pub(crate) head_sequence: u64,
    /// Required records the reducer could not apply: a restore loses them.
    pub(crate) unsupported_count: u64,
    /// The first of them (`sequence`, `event_id`, `kind`), at most 1,024.
    pub(crate) unsupported: Vec<Value>,
    /// `state_upsert`/`state_delete` changes of applied records that the
    /// reducer does not reduce: `extra` keeps the checkpoint's value, so a
    /// restore loses them.
    pub(crate) state_changes_not_reduced: u64,
    /// The compared sections of the reduced `session.snapshot`.
    pub(crate) session: BTreeMap<&'static str, Value>,
}

/// Build the `oracle-restore-preview` reply for the checkpoint `selector`
/// names (`latest` or a checkpoint id), reduced through `through` (an
/// `oracle-state` reply's `journal_head`) or the journal head, on the
/// journal reader path ([`Mux::oracle_restore_preview`]): no registry lock.
pub(crate) fn oracle_restore_preview(
    mux: &Mux,
    selector: &str,
    through: Option<u64>,
) -> anyhow::Result<OracleRestorePreview> {
    let preview =
        mux.oracle_restore_preview(selector, through)?.map(restore_preview).transpose()?;
    Ok(OracleRestorePreview { sections: BTreeMap::from(RESTORE_SECTIONS), preview })
}

/// The reply's preview from the reducer's result
/// (`journal_checkpoint::RestoreReducer::finish`).
fn restore_preview(mut reduced: Value) -> anyhow::Result<RestorePreview> {
    let decimal = |key: &str| -> anyhow::Result<u64> {
        reduced
            .field(key)
            .as_str()
            .and_then(|text| text.parse().ok())
            .ok_or_else(|| anyhow::anyhow!("restore preview {key} is not a decimal string"))
    };
    let checkpoint_sequence = decimal("checkpoint_source_sequence")?;
    let head_sequence = decimal("head_sequence")?;
    let unsupported_count = decimal("unsupported_required_record_count")?;
    let state_changes_not_reduced = match reduced.field("state").field("journal_replay") {
        Value::Object(replay) => match replay.get("state_changes_not_reduced") {
            None => 0,
            Some(count) => count.as_str().and_then(|text| text.parse().ok()).ok_or_else(|| {
                anyhow::anyhow!("restore preview state_changes_not_reduced is not a decimal string")
            })?,
        },
        _ => 0,
    };
    let Some(Value::Object(mut snapshot)) = reduced
        .get_mut("state")
        .and_then(|state| state.get_mut("session_snapshot"))
        .map(Value::take)
    else {
        anyhow::bail!("restore preview state has no session_snapshot object");
    };
    let session = RESTORE_SECTIONS
        .iter()
        .filter(|(_, section)| *section == RestoreSection::Compared)
        .filter_map(|(name, _)| snapshot.remove(*name).map(|value| (*name, value)))
        .collect();
    let Some(Value::String(checkpoint_id)) = reduced.get_mut("checkpoint_id").map(Value::take)
    else {
        anyhow::bail!("restore preview checkpoint_id is not a string");
    };
    let Some(Value::Array(unsupported)) =
        reduced.get_mut("unsupported_required_records").map(Value::take)
    else {
        anyhow::bail!("restore preview unsupported_required_records is not an array");
    };
    Ok(RestorePreview {
        checkpoint_id,
        checkpoint_sequence,
        head_sequence,
        unsupported_count,
        unsupported,
        state_changes_not_reduced,
        session,
    })
}

fn count(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "oracle_state_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "oracle_restore_preview_tests.rs"]
mod restore_preview_tests;
