//! The `conductor_import.*` operations of `cmux.protocol/2`: Import from
//! Conductor on the daemon. The reading and planning live in the
//! `cmux-conductor-import` crate; this module finds Conductor under the
//! daemon's `HOME`, keeps the ledger in the personal state store
//! ([`super::conductor_import_store`]) and answers the app.
//!
//! - `conductor_import.plan` (read): `{found, plan}`, the dry run against
//!   the stored ledger and the workspaces open now; `plan` is null when
//!   nothing is found, and `error` says why when there is no plan to show.
//! - `conductor_import.record` (mutation): one workspace's stage in the
//!   ledger, `pending` before the app makes it and `done` once made, and
//!   `run_completed` counts a finished run.
//!
//! A ledger from a newer cmux is never read past or written over.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_conductor_import::ledger::{Ledger, Load, Stage};
use cmux_conductor_import::{catalog, detect, inspect, plan};
use serde_json::{Map, Value, json};

use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, mutation_result, resource_operation_error};
use crate::state::commit::StateEffects;
use crate::state::conductor_import_store as store;
use crate::state::store::{StateChanges, StateCommit};
use crate::workspace_registry::WorkspaceMutation;
use crate::{Mux, ResourceTarget};

/// Advertised in identify: the daemon answers `conductor_import.plan` and
/// `conductor_import.record`.
pub const CAPABILITY: &str = "conductor-import-v1";

/// Why there is no plan when the stored ledger is a newer build's.
pub(crate) const NEWER_LEDGER: &str = "ledger from a newer cmux";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::ConductorImportPlan | ResourceOperation::ConductorImportRecord
    )
}

/// The daemon's home folder, where Conductor keeps its database and
/// worktrees. A caller never names it.
fn home() -> Option<PathBuf> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).filter(|value| !value.is_empty()).map(PathBuf::from)
}

/// The stored ledger, or why it cannot be used.
fn usable(load: Load) -> Result<Ledger, String> {
    match load {
        Load::None => Ok(Ledger::new()),
        Load::Ledger(ledger) => Ok(ledger),
        Load::Newer(_) => Err(NEWER_LEDGER.to_string()),
        Load::Unreadable(reason) => Err(format!("ledger unreadable: {reason}")),
    }
}

/// `bad request: ...` failures are the caller's input (`validation.invalid`).
fn record_error(error: anyhow::Error) -> ResourceError {
    if error.downcast_ref::<ResourceError>().is_none()
        && let Some(reason) = error.to_string().strip_prefix("bad request: ")
    {
        return ResourceError::validation_invalid(None, reason);
    }
    resource_operation_error(error)
}

/// What `conductor_import.record` sets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Record {
    pub(crate) workspace: String,
    pub(crate) stage: Stage,
    pub(crate) cmux_workspace: Option<String>,
    pub(crate) run_completed: bool,
}

impl Record {
    fn parse(fields: &Map<String, Value>) -> Result<Self, ResourceError> {
        let text = |name: &'static str| match fields.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) if !text.is_empty() => Ok(Some(text.clone())),
            Some(_) => Err(ResourceError::validation_invalid(
                Some(name),
                format!("{name} must be a non-empty string"),
            )),
        };
        let workspace = text("workspace")?.ok_or_else(|| {
            ResourceError::validation_invalid(Some("workspace"), "name the Conductor workspace")
        })?;
        let stage = match text("stage")?.as_deref() {
            Some("pending") => Stage::Pending,
            Some("done") => Stage::Done,
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("stage"),
                    "stage must be pending or done",
                ));
            }
        };
        let cmux_workspace = text("cmux_workspace")?;
        if stage == Stage::Done && cmux_workspace.is_none() {
            return Err(ResourceError::validation_invalid(
                Some("cmux_workspace"),
                "a done workspace names the cmux workspace made for it",
            ));
        }
        let run_completed = match fields.get("run_completed") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(value)) => *value,
            Some(_) => {
                return Err(ResourceError::validation_invalid(
                    Some("run_completed"),
                    "run_completed must be a boolean",
                ));
            }
        };
        Ok(Self { workspace, stage, cmux_workspace, run_completed })
    }

    fn fingerprint(&self) -> Value {
        json!({
            "operation": "conductor_import.record",
            "workspace": self.workspace,
            "stage": stage_name(self.stage),
            "cmux_workspace": self.cmux_workspace,
            "run_completed": self.run_completed,
        })
    }

    /// The ledger after this record. A pending workspace keeps the cmux
    /// workspace named with it, so a cut-off run's half-made one is known.
    fn apply(&self, ledger: &mut Ledger) {
        match (self.stage, self.cmux_workspace.as_deref()) {
            (Stage::Done, Some(cmux_workspace)) => {
                ledger.mark_done(&self.workspace, cmux_workspace);
            }
            (_, cmux_workspace) => {
                ledger.mark_pending(&self.workspace);
                if let Some(entry) = ledger.workspaces.get_mut(&self.workspace) {
                    entry.cmux_workspace = cmux_workspace.map(str::to_string);
                }
            }
        }
        if self.run_completed {
            ledger.runs = ledger.runs.saturating_add(1);
        }
    }
}

fn stage_name(stage: Stage) -> &'static str {
    match stage {
        Stage::Pending => "pending",
        Stage::Done => "done",
    }
}

impl Mux {
    /// The workspaces open now, each by its key (what the app records: the
    /// key it created the workspace with) and by its public id.
    fn open_workspace_ids(&self) -> BTreeSet<String> {
        self.with_state(|state| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| [workspace.key.clone(), workspace.public_id.to_string()])
                .collect()
        })
    }

    /// `conductor_import.plan` under `home`. Git and the files are read
    /// with no lock held; the ledger and the open workspaces are read first.
    pub(crate) fn conductor_import_plan(
        &self,
        home: Option<&Path>,
    ) -> Result<Value, ResourceError> {
        let Some(home) = home else {
            return Ok(json!({"found": detect::Found::default(), "plan": null}));
        };
        let found = detect::detect(home);
        let catalog = match (found.database.as_deref(), found.workspaces.as_deref()) {
            (Some(database), _) => match catalog::read(database) {
                Ok(catalog) => catalog,
                Err(error) => {
                    return Ok(json!({"found": found, "plan": null, "error": error.to_string()}));
                }
            },
            (None, Some(workspaces)) => inspect::catalog_from_folder(workspaces),
            (None, None) => return Ok(json!({"found": found, "plan": null})),
        };
        let ledger = match usable(self.personal_state_read(store::load)?) {
            Ok(ledger) => ledger,
            Err(reason) => return Ok(json!({"found": found, "plan": null, "error": reason})),
        };
        let open = self.open_workspace_ids();
        let facts = inspect::inspect(&catalog, home);
        let plan = plan::plan(&catalog, &facts, &ledger, &open);
        Ok(json!({"found": found, "plan": plan}))
    }

    /// `conductor_import.record`: one ledger change, committed with its
    /// idempotency key. A newer build's or a damaged ledger is refused, not
    /// written over.
    pub(crate) fn state_conductor_import_record(
        &self,
        mutation: &WorkspaceMutation,
        record: &Record,
    ) -> anyhow::Result<StateCommit> {
        self.commit_state(
            mutation,
            "conductor_import.record",
            &record.fingerprint(),
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let mut ledger = usable(store::load(transaction)?)
                    .map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
                record.apply(&mut ledger);
                store::save(transaction, &ledger)?;
                let entry = ledger.workspaces.get(&record.workspace);
                let result = json!({
                    "workspace": record.workspace,
                    "stage": stage_name(record.stage),
                    "cmux_workspace": entry.and_then(|entry| entry.cmux_workspace.clone()),
                    "runs": ledger.runs,
                });
                Ok(StateChanges::new(result, Vec::new()))
            },
        )
    }
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    match request.envelope.operation {
        ResourceOperation::ConductorImportPlan => mux.conductor_import_plan(home().as_deref()),
        ResourceOperation::ConductorImportRecord => {
            let record = Record::parse(&request.fields)?;
            let mutation = request.mutation().map_err(resource_operation_error)?;
            let commit =
                mux.state_conductor_import_record(&mutation, &record).map_err(record_error)?;
            mutation_result(mux, commit.result, commit.revision, commit.replayed)
        }
        other => Err(ResourceError::validation_invalid(
            None,
            format!("{} is not a conductor_import operation", other.wire_name()),
        )),
    }
}
