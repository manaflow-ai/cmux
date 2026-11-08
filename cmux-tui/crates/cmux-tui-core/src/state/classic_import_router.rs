//! The `classic_import.*` operations of `cmux.protocol/2`: the one-time move
//! from classic cmux on the daemon (plans/cmux-next/classic-migration-DESIGN.md).
//! Reading classic's session, deciding and planning live in the
//! `cmux-classic-import` crate; this module finds classic's files under the
//! daemon's `HOME`, keeps the ledger where earlier builds kept it
//! (`~/Library/Application Support/cmux-next/<bundle id>/classic-migration`,
//! so a build on either side of this change reads the other's) and answers
//! the app, which makes the workspaces.
//!
//! - `classic_import.plan` (read): `{ledger, decision, source, backups,
//!   error, plan, preview}` for one run, `automatic` (at launch) or
//!   `manual` (Import Workspaces from Classic cmux). `decision` says whether
//!   an automatic run starts; `plan` is what the run makes against the
//!   ledger, the workspaces open now and the groups that exist now.
//! - `classic_import.record` (mutation): one ledger step. `seen` and
//!   `baseline` are a launch's first contact (nothing made); `begin` backs up
//!   the classic files read and marks the run in progress; `workspace` and
//!   `group` record what was made; `finish` marks it completed.
//!
//! A caller names a bundle id, never a path: the daemon reads only classic's
//! session files and writes only the migration's own folder. A newer build's
//! ledger is never written over.

use std::collections::BTreeSet;
use std::path::PathBuf;

use cmux_classic_import::ledger::{self, Entry, Folder, Ledger, Load, Stage, State};
use cmux_classic_import::plan::{self, Mode, Preview};
use cmux_classic_import::read;
use cmux_classic_import::source::{Finder, RunningProbe, Source, seconds};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, mutation_result, resource_operation_error};
use crate::state::commit::StateEffects;
use crate::state::personal_state_store;
use crate::state::store::{StateChanges, StateCommit};
use crate::workspace_registry::WorkspaceMutation;
use crate::{Mux, ResourceTarget};

/// Advertised in identify: the daemon answers `classic_import.plan` and
/// `classic_import.record`.
pub const CAPABILITY: &str = "classic-import-v1";

/// Why there is no plan when the ledger is a newer build's.
pub(crate) const NEWER_LEDGER: &str = "ledger from a newer cmux";
/// Only the verified app runs these (`request_origin::USER_ONLY_OPERATIONS`).
pub(crate) const PLAN_OPERATION: &str = "classic_import.plan";
pub(crate) const RECORD_OPERATION: &str = "classic_import.record";
pub(crate) const UNREADABLE_LEDGER: &str = "ledger could not be read";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::ClassicImportPlan | ResourceOperation::ClassicImportRecord
    )
}

/// Where classic's files are and where the ledger goes: the daemon's own
/// home and environment, never the caller's.
#[derive(Debug, Clone)]
pub(crate) struct Places {
    pub(crate) home: PathBuf,
    pub(crate) xdg_state_home: Option<String>,
}

impl Places {
    fn from_env() -> Option<Self> {
        let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        let home = std::env::var_os(var).filter(|value| !value.is_empty())?;
        Some(Self {
            home: PathBuf::from(home),
            xdg_state_home: std::env::var("XDG_STATE_HOME").ok(),
        })
    }

    fn support(&self) -> PathBuf {
        self.home.join("Library/Application Support")
    }

    fn finder(&self, bundle_id: &str) -> Finder {
        Finder::new(&self.support(), Some(bundle_id))
    }

    fn folder(&self, bundle_id: &str) -> Result<Folder, ResourceError> {
        ledger::default_directory(&self.home, bundle_id).map(Folder::new).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("bundle_id"),
                "bundle_id is a reverse-DNS bundle identifier",
            )
        })
    }

    fn classic_running(&self, source: &Source) -> bool {
        let root = RunningProbe::default_state_root(&self.home, self.xdg_state_home.as_deref());
        RunningProbe { state_root: root }.is_running(source, seconds(std::time::SystemTime::now()))
    }
}

fn text<'a>(
    fields: &'a Map<String, Value>,
    name: &'static str,
) -> Result<Option<&'a str>, ResourceError> {
    match fields.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if !text.is_empty() => Ok(Some(text)),
        Some(_) => Err(ResourceError::validation_invalid(
            Some(name),
            format!("{name} must be a non-empty string"),
        )),
    }
}

fn required<'a>(
    fields: &'a Map<String, Value>,
    name: &'static str,
) -> Result<&'a str, ResourceError> {
    text(fields, name)?
        .ok_or_else(|| ResourceError::validation_invalid(Some(name), format!("{name} is required")))
}

fn texts(fields: &Map<String, Value>, name: &'static str) -> Result<Vec<String>, ResourceError> {
    match fields.get(name) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().filter(|text| !text.is_empty()).map(str::to_string))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some(name),
                    format!("{name} holds non-empty strings"),
                )
            }),
        Some(_) => {
            Err(ResourceError::validation_invalid(Some(name), format!("{name} must be an array")))
        }
    }
}

fn mode(fields: &Map<String, Value>) -> Result<Mode, ResourceError> {
    match required(fields, "mode")? {
        "automatic" => Ok(Mode::Automatic),
        "manual" => Ok(Mode::Manual),
        _ => {
            Err(ResourceError::validation_invalid(Some("mode"), "mode must be automatic or manual"))
        }
    }
}

/// One `classic_import.record` step.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Event {
    /// A launch's first contact with no session to record: a completed, empty ledger.
    Seen,
    /// A launch's first contact while cmux NEXT was already in use: every
    /// classic workspace recorded as seen, none made.
    Baseline,
    /// A confirmed run starts: the files read are backed up, the run is marked in progress.
    Begin {
        source: Source,
        backups: Vec<String>,
        cloud_vms: Vec<String>,
        app_version: Option<String>,
    },
    Workspace {
        key: String,
        entry: Entry,
    },
    Group {
        classic: String,
        next: String,
    },
    /// The run (or a plan with nothing to make) is done.
    Finish {
        source: Option<Source>,
        cloud_vms: Vec<String>,
        app_version: Option<String>,
    },
}

/// What `classic_import.record` sets.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Record {
    pub(crate) bundle_id: String,
    pub(crate) event: Event,
    fingerprint: Value,
}

impl Record {
    pub(crate) fn parse(fields: &Map<String, Value>) -> Result<Self, ResourceError> {
        let source = |required: bool| -> Result<Option<Source>, ResourceError> {
            match fields.get("source") {
                None | Some(Value::Null) if !required => Ok(None),
                Some(value @ Value::Object(_)) => {
                    serde_json::from_value(value.clone()).map(Some).map_err(|error| {
                        ResourceError::validation_invalid(
                            Some("source"),
                            format!("source is the plan's source: {error}"),
                        )
                    })
                }
                _ => Err(ResourceError::validation_invalid(
                    Some("source"),
                    "begin names the plan's source",
                )),
            }
        };
        let app_version = text(fields, "app_version")?.map(str::to_string);
        let event = match required(fields, "event")? {
            "seen" => Event::Seen,
            "baseline" => Event::Baseline,
            "begin" => Event::Begin {
                source: source(true)?.ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("source"),
                        "begin names the plan's source",
                    )
                })?,
                backups: texts(fields, "backups")?,
                cloud_vms: texts(fields, "cloud_vm_keys")?,
                app_version,
            },
            "workspace" => {
                let stage = match required(fields, "stage")? {
                    "pending" => Stage::Pending,
                    "created" => Stage::Created,
                    "done" => Stage::Done,
                    "skipped" => Stage::Skipped,
                    _ => {
                        return Err(ResourceError::validation_invalid(
                            Some("stage"),
                            "stage must be pending, created, done or skipped",
                        ));
                    }
                };
                let next = text(fields, "next_workspace")?;
                if matches!(stage, Stage::Created | Stage::Done) && next.is_none() {
                    return Err(ResourceError::validation_invalid(
                        Some("next_workspace"),
                        "a created or done workspace names the cmux workspace made for it",
                    ));
                }
                Event::Workspace {
                    key: required(fields, "key")?.to_string(),
                    entry: Entry::new(stage, next, text(fields, "reason")?),
                }
            }
            "group" => Event::Group {
                classic: required(fields, "classic_group")?.to_string(),
                next: required(fields, "next_group")?.to_string(),
            },
            "finish" => Event::Finish {
                source: source(false)?,
                cloud_vms: texts(fields, "cloud_vm_keys")?,
                app_version,
            },
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("event"),
                    "event must be seen, baseline, begin, workspace, group or finish",
                ));
            }
        };
        let mut fingerprint = fields.clone();
        fingerprint.insert("operation".into(), json!("classic_import.record"));
        Ok(Self {
            bundle_id: required(fields, "bundle_id")?.to_string(),
            event,
            fingerprint: Value::Object(fingerprint),
        })
    }

    /// The ledger after this step, from what the file held; none leaves it as it is.
    fn apply(&self, load: Load, places: &Places, now: f64) -> Result<Option<Ledger>, String> {
        let first_contact = matches!(load, Load::None);
        let mut ledger = match load {
            Load::Newer(_) => return Err(NEWER_LEDGER.to_string()),
            Load::Failed(error) => return Err(format!("{UNREADABLE_LEDGER}: {error}")),
            Load::Ledger(ledger) => ledger,
            // An unreadable ledger was moved aside: the run starts a new one.
            Load::None | Load::Unreadable => Ledger::default(),
        };
        let skip_cloud_vms = |ledger: &mut Ledger, keys: &[String]| {
            for key in keys {
                ledger
                    .workspaces
                    .insert(key.clone(), Entry::new(Stage::Skipped, None, Some("cloud-vm")));
            }
        };
        match &self.event {
            Event::Seen if first_contact => ledger = Ledger::new(State::Completed),
            Event::Baseline if first_contact => {
                let finder = places.finder(&self.bundle_id);
                ledger = match read::read(&finder, None, &places.home) {
                    Ok(Some(save)) => {
                        let mut seen = plan::baseline(&save.snapshot, Ledger::default());
                        seen.source = Some(save.source);
                        seen
                    }
                    _ => Ledger::new(State::Completed),
                };
            }
            Event::Seen | Event::Baseline => return Ok(None),
            Event::Begin { source, cloud_vms, app_version, .. } => {
                skip_cloud_vms(&mut ledger, cloud_vms);
                ledger.state = State::InProgress;
                ledger.source = Some(source.clone());
                ledger.runs = ledger.runs.saturating_add(1);
                ledger.app_version = app_version.clone().or(ledger.app_version);
            }
            Event::Workspace { key, entry } => {
                ledger.workspaces.insert(key.clone(), entry.clone());
            }
            Event::Group { classic, next } => {
                ledger.groups.insert(classic.clone(), next.clone());
            }
            Event::Finish { source, cloud_vms, app_version } => {
                skip_cloud_vms(&mut ledger, cloud_vms);
                ledger.state = State::Completed;
                if let Some(source) = source {
                    ledger.source = Some(source.clone());
                }
                ledger.app_version = app_version.clone().or(ledger.app_version);
            }
        }
        ledger.updated_at = now;
        Ok(Some(ledger))
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

impl Mux {
    /// The workspaces open now, by key and public id, and the groups that exist now.
    fn classic_live(&self) -> (BTreeSet<String>, BTreeSet<String>) {
        let workspaces = self.with_state(|state| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| [workspace.key.clone(), workspace.public_id.to_string()])
                .collect()
        });
        let groups = self
            .personal_state_read(|connection| {
                personal_state_store::workspace_group_snapshots(connection, None)
            })
            .unwrap_or_default()
            .iter()
            .filter_map(|group| group.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();
        (workspaces, groups)
    }

    /// `classic_import.plan` for `bundle_id` (this app's) under `places`.
    pub(crate) fn classic_import_plan(
        &self,
        places: Option<&Places>,
        bundle_id: &str,
        mode: Mode,
    ) -> Result<Value, ResourceError> {
        let Some(places) = places else {
            return Ok(json!({"ledger": "none", "decision": null, "source": null, "backups": [],
                             "error": null, "plan": null, "preview": null}));
        };
        let folder = places.folder(bundle_id)?;
        let load = folder.load();
        let finder = places.finder(bundle_id);
        // A cut-off run finishes from the save it started with, not a later one.
        let resumed = match (&mode, load.ledger()) {
            (Mode::Automatic, Some(ledger)) if ledger.state == State::InProgress => {
                ledger.source.as_ref().and_then(|source| {
                    read::resume(&finder, source, &folder.backups_path(), &places.home)
                })
            }
            _ => None,
        };
        let (save, error) = match resumed {
            Some(save) => (Some(save), None),
            None => match read::read(&finder, None, &places.home) {
                Ok(save) => (save, None),
                Err(error) => (None, Some(error.to_string())),
            },
        };
        let backups: Vec<String> = save.as_ref().map_or_else(Vec::new, |save| {
            save.backups.iter().map(|path| path.to_string_lossy().into_owned()).collect()
        });
        let mut reply = Map::new();
        reply.insert("ledger".into(), json!(load.name()));
        reply.insert("decision".into(), Value::Null);
        reply.insert("source".into(), json!(save.as_ref().map(|save| &save.source)));
        reply.insert("backups".into(), json!(backups));
        reply.insert("error".into(), json!(error));
        reply.insert("plan".into(), Value::Null);
        reply.insert("preview".into(), Value::Null);
        match mode {
            Mode::Automatic => {
                let source = save.as_ref().map(|save| &save.source);
                let running = source.is_some_and(|source| places.classic_running(source));
                let decision = plan::decision(&load, source, running);
                reply.insert("decision".into(), json!(decision));
                if matches!(decision, plan::Decision::Skip(_)) {
                    return Ok(Value::Object(reply));
                }
            }
            // A newer cmux NEXT's ledger is left alone: this build cannot tell what it recorded.
            Mode::Manual if matches!(load, Load::Newer(_)) => {
                reply.insert("error".into(), json!(NEWER_LEDGER));
                return Ok(Value::Object(reply));
            }
            // A ledger that is there but cannot be read is never recorded over.
            Mode::Manual if matches!(load, Load::Failed(_)) => {
                let error = if let Load::Failed(error) = &load { error.as_str() } else { "" };
                reply.insert("error".into(), json!(format!("{UNREADABLE_LEDGER}: {error}")));
                return Ok(Value::Object(reply));
            }
            Mode::Manual => {}
        }
        let Some(save) = save else { return Ok(Value::Object(reply)) };
        let (live, live_groups) = self.classic_live();
        let made = plan::plan(&save.snapshot, load.ledger().as_ref(), &live, &live_groups, mode);
        reply.insert("preview".into(), json!(Preview::new(&save.source, &made)));
        reply.insert("plan".into(), json!(made));
        Ok(Value::Object(reply))
    }

    /// `classic_import.record`: one ledger step, committed with its
    /// idempotency key so a retried step replays its first result. The
    /// ledger file is written inside the commit; a failed write fails it.
    pub(crate) fn classic_import_record(
        &self,
        places: Option<&Places>,
        mutation: &WorkspaceMutation,
        record: &Record,
    ) -> anyhow::Result<StateCommit> {
        let Some(places) = places else {
            anyhow::bail!("bad request: the daemon has no home folder")
        };
        let folder = places.folder(&record.bundle_id).map_err(anyhow::Error::from)?;
        // Classic's files are copied before the commit, with no lock held (a
        // session can be hundreds of megabytes), into a staged folder that
        // becomes a backup only inside the commit: a replayed step keeps
        // nothing and rotates nothing. Only classic's own session files are
        // copied.
        let key: String = Sha256::digest(mutation.id.as_bytes())
            .iter()
            .take(8)
            .map(|b| format!("{b:02x}"))
            .collect();
        let staged = match &record.event {
            Event::Begin { backups, .. } => {
                let finder = places.finder(&record.bundle_id);
                let files: Vec<PathBuf> = backups.iter().map(PathBuf::from).collect();
                if let Some(stray) = files.iter().find(|file| !finder.is_session_file(file)) {
                    anyhow::bail!(
                        "bad request: {} is not one of classic's session files",
                        stray.display()
                    );
                }
                let mut nonce = [0u8; 4];
                getrandom::fill(&mut nonce).map_err(|error| anyhow::anyhow!("{error}"))?;
                let name = format!("{key}-{}", u32::from_le_bytes(nonce));
                folder.stage(&files, &name)?
            }
            _ => None,
        };
        let commit = self.commit_state(
            mutation,
            RECORD_OPERATION,
            &record.fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |_transaction, _state| {
                let now = seconds(std::time::SystemTime::now());
                let changed = record
                    .apply(folder.load(), places, now)
                    .map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
                if let Some(staged) = &staged {
                    folder.keep(staged, &ledger::backup_stamp(now as i64, &key))?;
                }
                if let Some(ledger) = &changed {
                    folder.save(ledger)?;
                }
                let ledger = changed.or_else(|| folder.load().ledger());
                let result = json!({
                    "state": ledger.as_ref().map(|ledger| ledger.state),
                    "runs": ledger.as_ref().map_or(0, |ledger| ledger.runs),
                    "workspaces": ledger.as_ref().map_or(0, |ledger| ledger.workspaces.len()),
                    "changed": ledger.is_some(),
                });
                Ok(StateChanges::new(result, Vec::new()))
            },
        );
        // Kept copies were renamed away; a replay's or a failed step's are dropped.
        if let Some(staged) = &staged {
            let _ = std::fs::remove_dir_all(staged);
        }
        commit
    }
}

pub(crate) fn dispatch(
    mux: &std::sync::Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let places = Places::from_env();
    match request.envelope.operation {
        ResourceOperation::ClassicImportPlan => {
            let bundle_id = required(&request.fields, "bundle_id")?;
            mux.classic_import_plan(places.as_ref(), bundle_id, mode(&request.fields)?)
        }
        ResourceOperation::ClassicImportRecord => {
            let record = Record::parse(&request.fields)?;
            let mutation = request.mutation().map_err(resource_operation_error)?;
            let commit = mux
                .classic_import_record(places.as_ref(), &mutation, &record)
                .map_err(record_error)?;
            mutation_result(mux, commit.result, commit.revision, commit.replayed)
        }
        other => Err(ResourceError::validation_invalid(
            None,
            format!("{} is not a classic_import operation", other.wire_name()),
        )),
    }
}

#[cfg(test)]
pub(crate) fn places_for_test(home: &std::path::Path) -> Places {
    Places { home: home.to_path_buf(), xdg_state_home: None }
}
