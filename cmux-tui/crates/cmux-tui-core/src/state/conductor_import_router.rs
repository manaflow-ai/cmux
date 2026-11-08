//! The `conductor_import.*` operations of `cmux.protocol/2`: Import from
//! Conductor on the daemon. The reading and planning live in the
//! `cmux-conductor-import` crate; this module finds Conductor under the
//! daemon's `HOME`, keeps the ledger in the personal state store
//! ([`super::conductor_import_store`]) and answers the app.
//!
//! - `conductor_import.plan` (read): `{found, plan}`, the dry run against
//!   the stored ledger and the workspaces open now; `plan` is null when
//!   nothing is found, and `error` says why when there is no plan to show.
//!   Each project's `recipe` is the worktree recipe the app saves on it
//!   (`project.update` `worktree`), unless the project already has one.
//! - `conductor_import.record` (mutation): one workspace's stage in the
//!   ledger, `pending` before the app makes it and `done` once made, and
//!   `run_completed` counts a finished run. A done record names the
//!   workspace its pending record named, and a done workspace whose cmux
//!   workspace is still open is not recorded over by another one.
//!
//! A ledger from a newer cmux, or one that breaks the ledger's invariants,
//! is never read past or written over.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_conductor_import::ledger::{Ledger, Load, Stage};
use cmux_conductor_import::{catalog, detect, inspect, plan, tools};
use serde_json::{Map, Value, json};

use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, mutation_result, resource_operation_error};
use crate::state::commit::StateEffects;
use crate::state::conductor_import_store as store;
use crate::state::prelude::State;
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
/// A record refused by [`Record::conflict`] names the field `cmux_workspace`:
/// the one refusal after which the caller knows its workspace is not the
/// ledger's.
fn record_error(error: anyhow::Error) -> ResourceError {
    if error.downcast_ref::<ResourceError>().is_none() {
        let message = error.to_string();
        if let Some(reason) = message.strip_prefix("conflict: ") {
            return ResourceError::validation_invalid(Some("cmux_workspace"), reason);
        }
        if let Some(reason) = message.strip_prefix("bad request: ") {
            return ResourceError::validation_invalid(None, reason);
        }
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

    /// Why this record may not change the ledger, if it may not. Done
    /// follows the pending record that named its workspace: a done record
    /// naming another workspace than the pending entry is refused, so of two
    /// runs that both recorded pending, only the later one's done lands and
    /// the other run closes the workspace it made. And a done entry whose
    /// cmux workspace is still open is kept against any record naming
    /// another workspace (or none, as a pending one about to be made), so the
    /// ledger never trades the open workspace for a duplicate. A done entry
    /// whose workspace was closed is offered again and may be recorded over,
    /// pending replaces pending, and the same workspace recorded again is no
    /// change.
    fn conflict(&self, ledger: &Ledger, state: &State) -> Option<String> {
        let entry = ledger.workspaces.get(&self.workspace)?;
        if entry.stage != Stage::Done {
            let (Stage::Done, Some(named)) = (self.stage, self.cmux_workspace.as_deref()) else {
                return None;
            };
            let pending = entry.cmux_workspace.as_deref()?;
            let same = pending == named
                || open_key(state, pending).is_some_and(|key| open_key(state, named) == Some(key));
            return (!same).then(|| {
                format!(
                    "Conductor workspace {} is being imported as cmux workspace {pending}, not {named}",
                    self.workspace
                )
            });
        }
        let made = entry.cmux_workspace.as_deref()?;
        let open = open_key(state, made)?;
        let named = self.cmux_workspace.as_deref().and_then(|name| open_key(state, name));
        (named != Some(open)).then(|| {
            format!(
                "Conductor workspace {} is already imported as cmux workspace {made}, which is still open",
                self.workspace
            )
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

/// The key of the open workspace `name` names, by its key (what the app
/// records: the key it created the workspace with) or its public id.
fn open_key<'a>(state: &'a State, name: &str) -> Option<&'a str> {
    state
        .workspaces
        .iter()
        .find(|workspace| workspace.key == name || workspace.public_id.to_string() == name)
        .map(|workspace| workspace.key.as_str())
}

impl Mux {
    /// Metadata from the existing chat-index relay; no second scan or watcher.
    fn agent_import_folders(&self) -> Result<Vec<(tools::AdapterKind, PathBuf)>, ResourceError> {
        self.read_registry_state(|connection| {
            let projects = super::projects_store::load(connection)?;
            Ok(projects
                .list(false)
                .into_iter()
                .flat_map(|project| {
                    let disabled = projects.disabled();
                    project.sources.keys().filter_map(move |source| {
                        if disabled.contains(source) {
                            return None;
                        }
                        tools::AdapterKind::from_id(source)
                            .map(|tool| (tool, PathBuf::from(&project.path)))
                    })
                })
                .collect())
        })
        .map_err(resource_operation_error)
    }

    /// Presence hints, not promises of worktrees the full plan can adopt.
    pub(crate) fn agent_import_detect(&self, home: Option<&Path>) -> Result<Value, ResourceError> {
        let found = home.map(detect::detect).unwrap_or_default();
        let mut sources = BTreeMap::<&str, usize>::new();
        for (tool, _) in self.agent_import_folders()? {
            *sources.entry(tool.id()).or_default() += 1;
        }
        let has_conductor = found.database.is_some() || found.workspaces.is_some();
        let card = (has_conductor || !sources.is_empty()).then(|| {
            json!({
                "id": "agents.conductor", "kind": "conductor", "name": "Agent worktrees",
                // These are folder hints, not verified linked worktree counts.
                "count": null,
            })
        });
        Ok(json!({"found": found, "plan": null, "candidate_folders": sources,
            "has_conductor": has_conductor, "card": card}))
    }

    /// The workspaces open now, each by its key and by its public id.
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
        let refusals = super::projects_store::refusals();
        self.conductor_import_plan_with_policy(home, &|path| {
            path.to_str().is_some_and(|path| refusals.normalize(path).is_ok())
        })
    }

    /// The same plan with an injected path policy for isolated fixture homes.
    pub(crate) fn conductor_import_plan_with_policy(
        &self,
        home: Option<&Path>,
        admit: &dyn Fn(&Path) -> bool,
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
            (None, None) => catalog::Catalog::default(),
        };
        let ledger = match usable(self.personal_state_read(store::load)?) {
            Ok(ledger) => ledger,
            Err(reason) => return Ok(json!({"found": found, "plan": null, "error": reason})),
        };
        let open = self.open_workspace_ids();
        // The app already relays the chat index's grouped folders into the
        // project registry. Reuse those detectors without another transcript
        // scan or watcher. Hidden projects and disabled sources stay excluded.
        let folders = self.agent_import_folders()?;
        let has_conductor = found.database.is_some() || found.workspaces.is_some();
        let mut source_error = None;
        let catalog = match tools::folders(catalog.clone(), &folders, admit) {
            Ok(catalog) => catalog,
            Err(error) if has_conductor => {
                source_error = Some(error);
                catalog.into()
            }
            Err(error) => return Ok(json!({"found": found, "plan": null, "error": error})),
        };
        if catalog.catalog.repos.is_empty() && !found.any() {
            return Ok(json!({"found": found, "plan": null}));
        }
        let facts = catalog.inspect(home);
        let mut plan = plan::plan(&catalog.catalog, &facts, &ledger, &open);
        self.exclude_open_import_workspaces(&mut plan)?;
        if let Some(detail) = source_error {
            plan.warnings.push(plan::Warning { code: "agent-source-scan-failed", detail });
        }
        if !has_conductor {
            plan.cloud_read_only = "";
            plan.cloud_shutdown = "";
            plan.warnings.retain(|warning| warning.code != plan::ARCHIVE_DELETES_FOLDER);
        }
        let sources: BTreeMap<_, Vec<_>> = catalog
            .tools
            .iter()
            .map(|(id, tools)| (id, tools.iter().map(|tool| tool.id()).collect()))
            .collect();
        let mut value = json!({
            "found": found,
            "plan": plan,
            "tool_sources": sources,
            "unreadable_folders": catalog.unreadable,
            "has_conductor": has_conductor,
        });
        value["plan"]["has_conductor"] = json!(has_conductor);
        if let Some(projects) = value.get_mut("plan").and_then(|plan| plan.get_mut("projects")) {
            self.place_recipes(projects);
        }
        Ok(value)
    }

    /// Each project's `recipe` gains `project_path`, the cmux project it is
    /// saved on (the folder resolved, as `project.add` keeps it). A project
    /// that already has a saved recipe keeps it: its `recipe` is null and
    /// `recipe_kept` true, so a rerun never writes over the user's edits.
    fn place_recipes(&self, projects: &mut Value) {
        let saved: BTreeSet<String> = self
            .read_registry_state(|connection| {
                let projects = super::projects_store::load(connection)?;
                Ok(projects
                    .list(true)
                    .into_iter()
                    .filter(|project| project.overlay.worktree.is_some())
                    .map(|project| project.path.clone())
                    .collect())
            })
            .unwrap_or_default();
        let refusals = super::projects_store::refusals();
        let projects = projects.as_array_mut().into_iter().flatten();
        for project in projects.filter_map(Value::as_object_mut) {
            if project.get("recipe").is_none_or(Value::is_null) {
                continue;
            }
            let Some(path) = project.get("path").and_then(Value::as_str).map(PathBuf::from) else {
                project.insert("recipe".into(), Value::Null);
                continue;
            };
            // As `project.add` stores it, so `project.update` finds it: resolved, then normalized
            // (the data volume firmlink removed).
            let path = std::fs::canonicalize(&path).unwrap_or(path).to_string_lossy().into_owned();
            let path = refusals.normalize(&path).unwrap_or(path);
            if saved.contains(&path) {
                project.insert("recipe".into(), Value::Null);
                project.insert("recipe_kept".into(), Value::Bool(true));
            } else if let Some(recipe) = project.get_mut("recipe").and_then(Value::as_object_mut) {
                recipe.insert("project_path".into(), Value::String(path));
            }
        }
    }

    /// `conductor_import.record`: one ledger change, committed with its
    /// idempotency key. A newer build's or a damaged ledger is refused, not
    /// written over, and so is a record over a done workspace that is still
    /// open ([`Record::conflict`]): read and written in the one transaction,
    /// so two runs cannot both pass the check.
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
            |transaction, state| {
                let mut ledger = usable(store::load(transaction)?)
                    .map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
                if let Some(reason) = record.conflict(&ledger, state) {
                    anyhow::bail!("conflict: {reason}");
                }
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
        ResourceOperation::ConductorImportPlan => match request.fields.get("detect_only") {
            Some(Value::Bool(true)) => mux.agent_import_detect(home().as_deref()),
            None | Some(Value::Bool(false)) => mux.conductor_import_plan(home().as_deref()),
            Some(_) => Err(ResourceError::validation_invalid(
                Some("detect_only"),
                "detect_only must be a boolean",
            )),
        },
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
