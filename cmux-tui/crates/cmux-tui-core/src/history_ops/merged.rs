//! The merged read model and the mutations of the history module.
//!
//! Per session: the agent and command folds over the session journal and
//! the history revision ([`HistoryHost`], one mutex). Per machine: the page
//! visit stores (pages.rs). Read from other owners: closed items from the
//! closed-history store and the app's location trail (sources.rs).
//!
//! What each kind allows (history.md section 3): page visits are deleted
//! into a backup (restore id); agent and command entries live in the
//! append-only journal and are hidden (`history.hidden`); closed items age
//! out in the closed-history store and are left alone; locations are the
//! app's view state and are refused.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};

use cmux_history::{
    AgentSessionFold, EntryContext, HiddenHistory, HistoryEntry, HistoryKind, TerminalCommandFold,
    hidden_id,
};
use serde_json::{Map, Value, json};

use super::pages::{self, run, wire};
use super::{hidden_doc, journal_feed, sources, store_failed};
use crate::Mux;
use crate::resource::ResourceError;
use crate::workspace_registry::Actor;

/// The machine name the folds qualify ids with. It matches the Swift app's
/// `MachineRegistry.localID`, so hides it stored (`local/<provider>/<id>`)
/// keep applying.
pub(super) const LOCAL_MACHINE: &str = "local";
/// `history.entries.remove` refuses the whole request for a location id.
pub(crate) const LOCATION_CLIENT_OWNED: &str = "history.location_client_owned";
const TRAIL_SUBJECT: &str = "history.trail";

/// The session's history state: the journal folds, the journal cursor they
/// reached and the history revision.
pub(crate) struct HistoryHost {
    state: Mutex<HostState>,
    feed_claimed: AtomicBool,
}

struct HostState {
    agents: AgentSessionFold,
    commands: TerminalCommandFold,
    cursor: u64,
    revision: u64,
}

impl Default for HistoryHost {
    fn default() -> Self {
        Self {
            state: Mutex::new(HostState {
                agents: AgentSessionFold::new(LOCAL_MACHINE),
                commands: TerminalCommandFold::new(LOCAL_MACHINE),
                cursor: 0,
                revision: 1,
            }),
            feed_claimed: AtomicBool::new(false),
        }
    }
}

impl HistoryHost {
    fn lock(&self) -> std::sync::MutexGuard<'_, HostState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn cursor(&self) -> u64 {
        self.lock().cursor
    }

    /// Folds the journal records scanned after `from` through `scanned`. A
    /// concurrent fold that already moved the cursor wins. Returns the kinds
    /// that changed.
    pub(super) fn fold(
        &self,
        from: u64,
        scanned: u64,
        records: &[(HistoryKind, Value)],
    ) -> Vec<HistoryKind> {
        let mut state = self.lock();
        if state.cursor != from {
            return Vec::new();
        }
        let pick = |kind| -> Vec<Value> {
            records.iter().filter(|(of, _)| *of == kind).map(|(_, value)| value.clone()).collect()
        };
        let (agents, commands) = (pick(HistoryKind::Agent), pick(HistoryKind::Command));
        let mut changed = Vec::new();
        if !agents.is_empty() {
            state.agents.apply(&agents);
            changed.push(HistoryKind::Agent);
        }
        if !commands.is_empty() {
            state.commands.apply(&commands);
            changed.push(HistoryKind::Command);
        }
        state.cursor = scanned;
        changed
    }

    /// Agent and command entries the hides leave visible.
    fn journal_entries(
        &self,
        wants: impl Fn(HistoryKind) -> bool,
        hidden: &HiddenHistory,
    ) -> Vec<HistoryEntry> {
        let state = self.lock();
        let context = EntryContext { local_machine: LOCAL_MACHINE, available: true };
        let mut entries = Vec::new();
        if wants(HistoryKind::Agent) {
            entries.extend(state.agents.entries(&context, hidden));
        }
        if wants(HistoryKind::Command) {
            entries.extend(state.commands.entries(&context, hidden));
        }
        entries
    }

    fn revision(&self) -> u64 {
        self.lock().revision
    }

    /// Bumps the history revision and emits `history-changed`.
    pub(crate) fn changed(&self, mux: &Mux, kinds: &[HistoryKind]) {
        let revision = {
            let mut state = self.lock();
            state.revision += 1;
            state.revision
        };
        mux.emit(crate::MuxEvent::HistoryChanged {
            revision,
            kinds: kinds.iter().map(|kind| kind.as_str().to_owned()).collect(),
        });
    }

    pub(super) fn claim_feed(&self) -> bool {
        !self.feed_claimed.swap(true, Ordering::AcqRel)
    }

    pub(super) fn release_feed(&self) {
        self.feed_claimed.store(false, Ordering::Release);
    }
}

fn failed(operation: &str, error: &anyhow::Error) -> ResourceError {
    store_failed(operation, format!("{error:#}"))
}

/// `history.entries.list`: every selected kind, newest first.
pub(super) fn list(
    mux: &std::sync::Arc<Mux>,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "history.entries.list";
    let query = pages::query(fields)?;
    let profile = pages::text(fields, "profile")?;
    let wants = |kind| query.wants(kind) && (profile.is_none() || kind == HistoryKind::Page);
    let mut entries = Vec::new();
    if wants(HistoryKind::Page)
        && let Some(shared) = pages::shared(mux, OPERATION)?
    {
        let mut shared = shared.lock().unwrap_or_else(PoisonError::into_inner);
        entries.extend(
            pages::entries(&mut shared.stores, &query, profile, now_ms, day_start_ms)
                .map_err(|error| store_failed(OPERATION, error))?,
        );
    }
    if wants(HistoryKind::Agent) || wants(HistoryKind::Command) {
        journal_feed::start(mux);
        let changed = journal_feed::catch_up(mux).map_err(|error| failed(OPERATION, &error))?;
        if !changed.is_empty() {
            mux.history.changed(mux, &changed);
        }
        let (hidden, _) = hidden_doc::load(mux).map_err(|error| failed(OPERATION, &error))?;
        entries.extend(mux.history.journal_entries(wants, &hidden));
    }
    if wants(HistoryKind::Closed) {
        let items = mux
            .read_registry_state(crate::state::closed_history_query::closed_items)
            .map_err(|error| failed(OPERATION, &error))?;
        entries.extend(items.iter().filter_map(sources::closed_entry));
    }
    if wants(HistoryKind::Location) {
        let trail = mux
            .get_frontend_projection(hidden_doc::FRONTEND, hidden_doc::SCOPE, TRAIL_SUBJECT)
            .map_err(|error| failed(OPERATION, &error))?;
        if let Some(trail) = trail {
            entries.extend(sources::location_entries(&trail.projection));
        }
    }
    let matched = query.apply(&entries, now_ms, day_start_ms, |path| Path::new(path).is_dir());
    Ok(json!({
        "entries": matched.iter().map(wire).collect::<Vec<_>>(),
        "revision": mux.history.revision().to_string(),
    }))
}

/// Runs one mutation once (the caller checked the key): its result value
/// and the kinds it changed.
pub(super) fn mutate(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    operation: &str,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    let pages_only = |mux: &Mux| -> Result<(Value, Vec<HistoryKind>), ResourceError> {
        let value = pages::with_stores(mux, operation, |stores| {
            run(stores, operation, fields, now_ms, day_start_ms)
        })?;
        let changed = changed_pages(&value);
        Ok((value, changed))
    };
    match operation {
        "history.entries.remove" => remove(mux, key, actor, fields, now_ms, day_start_ms),
        "history.clear" => clear(mux, key, actor, fields, now_ms, day_start_ms),
        _ => pages_only(mux),
    }
}

/// Whether a page result changed anything: a removal, restore or import of
/// at least one visit, a recorded visit, a changed title.
fn changed_pages(value: &Value) -> Vec<HistoryKind> {
    let counted = ["removed", "restored", "updated", "imported"]
        .iter()
        .any(|field| value.get(field).and_then(Value::as_u64).is_some_and(|n| n > 0));
    if counted || value.get("id").is_some() { vec![HistoryKind::Page] } else { Vec::new() }
}

/// `history.entries.remove`: page visits into a backup, agent and command
/// entries hidden; any location id refuses the whole request.
fn remove(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    const OPERATION: &str = "history.entries.remove";
    let ids = pages::ids(fields)?;
    if let Some(location) = ids.iter().find(|id| id.starts_with("location:")) {
        return Err(ResourceError::operation_failed(
            OPERATION,
            LOCATION_CLIENT_OWNED,
            json!({"id": location, "message": "locations belong to the app's trail; remove them in the app"}),
        ));
    }
    let mut changed = Vec::new();
    let mut value = json!({"removed": 0, "restore_id": null});
    if ids.iter().any(|id| id.starts_with("page:")) {
        value = pages::with_stores(mux, OPERATION, |stores| {
            run(stores, OPERATION, fields, now_ms, day_start_ms)
        })?;
        changed = changed_pages(&value);
    }
    let hides: Vec<(&str, HistoryKind)> = ids
        .iter()
        .filter_map(|id| {
            let kind = match id.split(':').next() {
                Some("agent") => HistoryKind::Agent,
                Some("command") => HistoryKind::Command,
                _ => return None,
            };
            hidden_id(id).map(|hidden| (hidden, kind))
        })
        .collect();
    if !hides.is_empty() {
        hidden_doc::change(mux, key, actor, |document| {
            for (id, _) in &hides {
                document.hide_entry(id);
            }
        })
        .map_err(|error| failed(OPERATION, &error))?;
        let pages = value["removed"].as_u64().unwrap_or(0);
        value["removed"] = json!(pages + hides.len() as u64);
        for (_, kind) in &hides {
            if !changed.contains(kind) {
                changed.push(*kind);
            }
        }
    }
    Ok((value, changed))
}

/// `history.clear`: page visits of the range into a backup (in `profile` or
/// every profile); agent and command entries hidden by range unless a
/// profile narrows the clear to pages. Closed and location entries are
/// never touched.
fn clear(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<(Value, Vec<HistoryKind>), ResourceError> {
    const OPERATION: &str = "history.clear";
    let kinds = pages::kinds(fields)?;
    let wants = |kind| kinds.is_empty() || kinds.contains(&kind);
    let since = pages::range(fields, true)?.start(now_ms, day_start_ms);
    let profile = pages::text(fields, "profile")?;
    let mut changed = Vec::new();
    let mut value = json!({"removed": 0, "restore_id": null});
    if wants(HistoryKind::Page) && pages::shared(mux, OPERATION)?.is_some() {
        value = pages::with_stores(mux, OPERATION, |stores| {
            run(stores, OPERATION, fields, now_ms, day_start_ms)
        })?;
        changed = changed_pages(&value);
    }
    let hidden: Vec<HistoryKind> = [HistoryKind::Agent, HistoryKind::Command]
        .into_iter()
        .filter(|kind| profile.is_none() && wants(*kind))
        .collect();
    if !hidden.is_empty() {
        hidden_doc::change(mux, key, actor, |document| {
            for kind in &hidden {
                document.hide_range(since, now_ms, Some(kind.as_str()));
            }
        })
        .map_err(|error| failed(OPERATION, &error))?;
        changed.extend(hidden);
    }
    Ok((value, changed))
}
