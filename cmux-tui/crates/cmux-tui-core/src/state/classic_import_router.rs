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
//!   error, classic_running, plan, preview}` for one run, `automatic` (at launch) or
//!   `manual` (Import Workspaces from Classic cmux). `decision` says whether
//!   an automatic run starts; `plan` is what the run makes against the
//!   ledger, the workspaces open now and the groups that exist now.
//!   `classic_running` says whether the classic app that saved `source` is
//!   open now (its socket lock, or its launch sentinel and a recent save).
//!   Each tab's `scrollback` is the read-only text its new shell prints;
//!   `outline: true` leaves every one out (null) for a caller that only
//!   counts workspaces or lists folders.
//!   Without `consented: true`, the reply contains only availability, a stamp of known
//!   file metadata, and NEXT's ledger decision. It never opens a Classic file.
//! - `classic_import.record` (mutation): one import step. `seen` and
//!   `baseline` are a launch's first contact (nothing made); `begin` backs up
//!   the classic files read and marks the run in progress; `workspace` and
//!   `group` record what was made; `finish` marks it completed. `decline`
//!   keeps a launch's No (`declinedAt`): later launches skip with
//!   `declined` until a run begins or finishes, which clears it.
//!
//! A caller names a bundle id, never a path: the daemon reads only classic's
//! inputs selected by the verified app's confirmed import. A newer build's
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

/// The folder a DEV build's launch names for classic's data (BuildStatePaths `classicImportDirectoryKey`).
const CLASSIC_DIR_ENV: &str = "CMUX_NEXT_CLASSIC_IMPORT_DIR";

/// Advertised in identify: the daemon answers `classic_import.plan` and
/// `classic_import.record`.
pub const CAPABILITY: &str = "classic-import-v1";
/// Allows the app to check for an import source without reading Classic content.
pub const PROBE_CAPABILITY: &str = "classic-import-probe-v1";

/// Why there is no plan when the ledger is a newer build's.
pub(crate) const NEWER_LEDGER: &str = "ledger from a newer cmux";
/// Only the verified app runs these (`request_origin::USER_ONLY_OPERATIONS`).
pub(crate) const PLAN_OPERATION: &str = "classic_import.plan";
pub(crate) const RECORD_OPERATION: &str = "classic_import.record";
pub(crate) const UNREADABLE_LEDGER: &str = "ledger could not be read";

/// The most a plan's JSON takes in its `classic_import.plan` reply: the
/// server's control-reply limit (`REMOTE_SESSION_MESSAGE_MAX_BYTES`, past
/// which `send_control` closes the connection) less room for the envelope,
/// the source, the backups and the preview. A bigger plan keeps each
/// terminal's newest scrollback (`Plan::fit`).
pub(crate) const PLAN_REPLY_BUDGET: usize = crate::REMOTE_SESSION_MESSAGE_MAX_BYTES - 1024 * 1024;

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
    /// Classic's Application Support: `<home>/Library/Application Support`, or a DEV build's own folder
    /// ([`CLASSIC_DIR_ENV`]), which also holds the ledger (`cmux-next/<bundle id>/classic-migration`).
    pub(crate) support: PathBuf,
    /// The home whose classic socket locks say classic runs: `home`, or the DEV build's own folder.
    pub(crate) probe_home: PathBuf,
    /// Classic's config home (`XDG_CONFIG_HOME`, else `~/.config`): its
    /// `cmux/cmux.json` may hold inline harness profiles.
    pub(crate) config_home: PathBuf,
    /// NEXT's settings folder, where a consented import snapshots Classic's layers.
    pub(crate) settings_directory: PathBuf,
    pub(crate) xdg_state_home: Option<String>,
    /// Where classic's `/tmp` socket lock is (`/tmp`; a test's own folder).
    pub(crate) tmp: PathBuf,
}

impl Places {
    fn from_env() -> Option<Self> {
        Self::from_vars(|name| std::env::var_os(name))
    }

    /// The places of a process with the environment `var`. A DEV build's launch names its own folder
    /// ([`CLASSIC_DIR_ENV`]): classic's files, the ledger and whether classic runs are all read there, so a DEV
    /// build never imports (or records against) the person's classic, production data. The folder starts
    /// empty; a test puts a classic session in it.
    pub(crate) fn from_vars(var: impl Fn(&str) -> Option<std::ffi::OsString>) -> Option<Self> {
        let home_var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        let home = PathBuf::from(var(home_var).filter(|value| !value.is_empty())?);
        let fixture = var(CLASSIC_DIR_ENV).filter(|value| !value.is_empty()).map(PathBuf::from);
        let probe_home = fixture.clone().unwrap_or_else(|| home.clone());
        let xdg = var("XDG_CONFIG_HOME").filter(|value| !value.is_empty()).map(PathBuf::from);
        let config_home = match (&fixture, xdg) {
            (None, Some(xdg)) => xdg,
            _ => probe_home.join(".config"),
        };
        let settings_file = cmux_config::location::config_path_from(|name| {
            if name == "HOME" { Some(home.clone().into_os_string()) } else { var(name) }
        });
        let settings_directory = settings_file.parent()?.to_owned();
        let (support, xdg_state_home, tmp) = match fixture {
            Some(own) => (
                own.clone(),
                Some(own.join("state").to_string_lossy().into_owned()),
                own.join("tmp"),
            ),
            None => (
                home.join("Library/Application Support"),
                var("XDG_STATE_HOME").and_then(|value| value.into_string().ok()),
                PathBuf::from("/tmp"),
            ),
        };
        Some(Self {
            home,
            probe_home,
            support,
            xdg_state_home,
            tmp,
            config_home,
            settings_directory,
        })
    }

    fn finder(&self, bundle_id: &str) -> Finder {
        Finder::new(&self.support, Some(bundle_id))
    }

    /// Check known paths using metadata. Tagged palette plists have unknown names
    /// and can only be discovered by the accepted import. This app's own preferences
    /// file is no sign of classic: cmux NEXT NIGHTLY shares classic nightly's bundle id
    /// and writes `com.cmuxterm.app.nightly.plist` itself at its first launch, so a Mac
    /// that never had classic was asked "Import from classic cmux?" (first-run findings).
    fn classic_settings_present(&self, bundle_id: &str) -> bool {
        let prefs = self.probe_home.join("Library/Preferences");
        self.config_home.join("cmux/cmux.json").is_file()
            || cmux_classic_import::ghostty::source_path(&self.support, bundle_id).is_some()
            || cmux_classic_import::source::CHANNELS
                .iter()
                .filter(|id| **id != bundle_id)
                .any(|id| prefs.join(format!("{id}.plist")).is_file())
    }

    fn folder(&self, bundle_id: &str) -> Result<Folder, ResourceError> {
        ledger::directory_in(&self.support, bundle_id).map(Folder::new).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("bundle_id"),
                "bundle_id is a reverse-DNS bundle identifier",
            )
        })
    }

    fn classic_running(&self, source: &Source) -> bool {
        let root =
            RunningProbe::default_state_root(&self.probe_home, self.xdg_state_home.as_deref());
        RunningProbe { state_root: root }.is_open(
            source,
            &self.probe_home,
            &self.tmp,
            seconds(std::time::SystemTime::now()),
        )
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

fn outline(fields: &Map<String, Value>) -> Result<bool, ResourceError> {
    match fields.get("outline") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(outline)) => Ok(*outline),
        Some(_) => {
            Err(ResourceError::validation_invalid(Some("outline"), "outline must be a boolean"))
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
    /// The person cancelled the launch's preview: later launches stop
    /// asking until a manual run begins or finishes. `source` is recorded
    /// when the ledger names none yet.
    Decline {
        source: Option<Source>,
    },
    /// A consented snapshot of terminal and harness settings, independent of the workspace ledger.
    Settings,
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
    observed: Option<String>,
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
            "decline" => Event::Decline { source: source(false)? },
            "settings" => Event::Settings,
            "finish" => Event::Finish {
                source: source(false)?,
                cloud_vms: texts(fields, "cloud_vm_keys")?,
                app_version,
            },
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("event"),
                    "event must be seen, baseline, begin, workspace, group, decline, settings or finish",
                ));
            }
        };
        let mut fingerprint = fields.clone();
        fingerprint.insert("operation".into(), json!("classic_import.record"));
        Ok(Self {
            bundle_id: required(fields, "bundle_id")?.to_string(),
            event,
            observed: text(fields, "observed")?.map(str::to_owned),
            fingerprint: Value::Object(fingerprint),
        })
    }

    /// The ledger after this step, from what the file held; none leaves it as it is.
    fn apply(&self, load: Load, now: f64) -> Result<Option<Ledger>, String> {
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
                ledger = Ledger::new(State::Completed);
                ledger.baseline_classic_files = self.observed.clone();
            }
            Event::Seen | Event::Baseline => return Ok(None),
            Event::Begin { source, cloud_vms, app_version, .. } => {
                skip_cloud_vms(&mut ledger, cloud_vms);
                ledger.state = State::InProgress;
                ledger.declined_at = None;
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
            Event::Decline { source } => {
                ledger.declined_at = Some(now);
                // A declined resume ends too, so no launch asks again.
                ledger.state = State::Completed;
                if ledger.source.is_none() {
                    ledger.source = source.clone();
                }
            }
            // Settings are copied as a separate, idempotent side effect. The
            // following Finish event owns the durable completion marker, so an
            // interrupted settings import can still resume its session run.
            Event::Settings => return Ok(None),
            Event::Finish { source, cloud_vms, app_version } => {
                ledger.observed_classic_files = self.observed.clone();
                ledger.baseline_classic_files = None;
                skip_cloud_vms(&mut ledger, cloud_vms);
                ledger.state = State::Completed;
                // Asking by hand, even with nothing left to bring, takes back a launch's No.
                ledger.declined_at = None;
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
    fn classic_live_workspaces(&self) -> BTreeSet<String> {
        self.with_state(|state| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| [workspace.key.clone(), workspace.public_id.to_string()])
                .collect()
        })
    }

    fn classic_live(&self) -> (BTreeSet<String>, BTreeSet<String>) {
        let groups = self
            .personal_state_read(|connection| {
                personal_state_store::workspace_group_snapshots(connection, None)
            })
            .unwrap_or_default()
            .iter()
            .filter_map(|group| group.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();
        (self.classic_live_workspaces(), groups)
    }

    /// `classic_import.plan` for `bundle_id` (this app's) under `places`.
    pub(crate) fn classic_import_probe(
        &self,
        places: Option<&Places>,
        bundle_id: &str,
        mode: Mode,
    ) -> Result<Value, ResourceError> {
        use plan::{Decision, SkipReason};
        let mut reply = match json!({"available": false, "ledger": "none", "decision": null,
            "source": null, "backups": [], "error": null, "classic_running": false, "plan": null,
            "preview": null})
        {
            Value::Object(reply) => reply,
            _ => Map::new(),
        };
        let Some(places) = places else { return Ok(Value::Object(reply)) };
        let load = places.folder(bundle_id)?.load();
        let files = places.finder(bundle_id).session_metadata();
        let settings = places.classic_settings_present(bundle_id);
        let available = !files.is_empty() || settings;
        // Include only settings presence. Changing a Classic preference after a
        // one-time settings import must not cause another launch prompt.
        let mut stamp = Sha256::new();
        stamp.update([u8::from(settings)]);
        for (index, size, nanos) in files {
            stamp.update([index as u8]);
            stamp.update(size.to_le_bytes());
            stamp.update(nanos.to_le_bytes());
        }
        let observed = format!("{:x}", stamp.finalize());
        reply.insert("ledger".to_owned(), json!(load.name()));
        reply.insert("available".to_owned(), json!(available));
        reply.insert("observed".to_owned(), json!(&observed));
        if mode == Mode::Automatic {
            let decision = match &load {
                Load::Newer(_) | Load::Unreadable | Load::Failed(_) => {
                    Decision::Skip(SkipReason::LedgerNotUsable)
                }
                Load::Ledger(ledger) if ledger.state == State::InProgress => Decision::Resume,
                Load::Ledger(ledger) if ledger.declined_at.is_some() => {
                    Decision::Skip(SkipReason::Declined)
                }
                _ if !available => Decision::Skip(SkipReason::NoClassicSession),
                Load::Ledger(ledger)
                    if ledger.observed_classic_files.as_ref() == Some(&observed)
                        || ledger.baseline_classic_files.as_ref() == Some(&observed) =>
                {
                    Decision::Skip(SkipReason::Unchanged)
                }
                Load::Ledger(_) => Decision::Merge,
                Load::None => Decision::FirstRun,
            };
            if decision == Decision::Resume {
                reply.insert("available".to_owned(), json!(true));
            }
            reply.insert("decision".to_owned(), json!(decision));
        } else {
            match &load {
                Load::Ledger(ledger)
                    if ledger.state == State::Completed
                        && ledger.declined_at.is_none()
                        && ledger.observed_classic_files.as_ref() == Some(&observed) =>
                {
                    // Settings can offer a closed or partially restored workspace again, using NEXT state alone.
                    let live = self.classic_live_workspaces();
                    reply.insert(
                        "already_imported".to_owned(),
                        json!(ledger.workspaces.values().all(|entry| {
                            entry.stage == Stage::Skipped
                                || (entry.stage == Stage::Done
                                    && entry
                                        .next_workspace
                                        .as_ref()
                                        .is_some_and(|id| live.contains(id)))
                        })),
                    );
                }
                Load::Newer(_) => {
                    reply.insert("error".to_owned(), json!(NEWER_LEDGER));
                }
                Load::Failed(error) => {
                    reply
                        .insert("error".to_owned(), json!(format!("{UNREADABLE_LEDGER}: {error}")));
                }
                _ => {}
            }
        }
        Ok(Value::Object(reply))
    }

    pub(crate) fn classic_import_plan(
        &self,
        places: Option<&Places>,
        bundle_id: &str,
        mode: Mode,
        outline: bool,
    ) -> Result<Value, ResourceError> {
        let Some(places) = places else {
            return Ok(json!({"ledger": "none", "decision": null, "source": null, "backups": [],
                             "error": null, "classic_running": false, "plan": null,
                             "preview": null}));
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
        reply.insert(
            "settings_only".into(),
            json!(save.is_none() && error.is_none() && places.classic_settings_present(bundle_id)),
        );
        reply.insert("error".into(), json!(error));
        let source = save.as_ref().map(|save| &save.source);
        let running = source.is_some_and(|source| places.classic_running(source));
        reply.insert("classic_running".into(), json!(running));
        reply.insert("plan".into(), Value::Null);
        reply.insert("preview".into(), Value::Null);
        match mode {
            Mode::Automatic => {
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
        drop(save.snapshot);
        let mut made = if outline { made.outline() } else { made };
        // One reply carries the plan: past the control limit the connection closes.
        if let Err(too_large) = made.fit(PLAN_REPLY_BUDGET) {
            reply.insert("error".into(), json!(too_large.to_string()));
            return Ok(Value::Object(reply));
        }
        reply.insert("preview".into(), json!(Preview::new(&save.source, &made)));
        reply.insert("plan".into(), json!(made));
        Ok(Value::Object(reply))
    }

    /// Copy Classic's terminal and harness settings only after the app has
    /// obtained consent and requested the full import plan. Each importer is
    /// idempotent, so a retry cannot overwrite a person's NEXT edits.
    fn import_classic_sidecars(&self, places: &Places, bundle_id: &str) -> anyhow::Result<()> {
        cmux_classic_import::ghostty::import(
            &places.probe_home,
            &places.config_home.join("cmux"),
            &places.support,
            bundle_id,
            &places.settings_directory,
        )?;
        cmux_classic_import::harnesses::import_inline(
            &places.config_home.join("cmux/cmux.json"),
            &places.settings_directory,
        )?;
        Ok(())
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
        // A retried step that already ran answers its first result before
        // any file is checked or copied: classic may have saved again, or
        // removed a file, since. The commit checks again, for a retry that
        // races the first.
        if let Some(replayed) =
            self.state_commit_replay(mutation, RECORD_OPERATION, &record.fingerprint, None)?
        {
            return Ok(replayed);
        }
        if matches!(record.event, Event::Settings) {
            // Respect the same newer/unreadable ledger rules before touching the settings snapshots.
            record
                .apply(folder.load(), seconds(std::time::SystemTime::now()))
                .map_err(|reason| anyhow::anyhow!("bad request: {reason}"))?;
            self.import_classic_sidecars(places, &record.bundle_id)
                .map_err(|error| anyhow::anyhow!("settings import failed: {error}"))?;
        }
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
                    .apply(folder.load(), now)
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
    dispatch_in(mux, request, dispatch_places())
}

/// [`dispatch`] under `places` (a test's own home instead of the daemon's).
pub(crate) fn dispatch_in(
    mux: &std::sync::Arc<Mux>,
    request: ParsedResourceRequest,
    places: Option<Places>,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    match request.envelope.operation {
        ResourceOperation::ClassicImportPlan => {
            let bundle_id = required(&request.fields, "bundle_id")?;
            let mode = mode(&request.fields)?;
            let consented =
                request.fields.get("consented").and_then(Value::as_bool).unwrap_or(false);
            if !consented {
                mux.classic_import_probe(places.as_ref(), bundle_id, mode)
            } else {
                mux.classic_import_plan(places.as_ref(), bundle_id, mode, outline(&request.fields)?)
            }
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

/// The daemon's places; a test that drives the wire names its own home.
fn dispatch_places() -> Option<Places> {
    #[cfg(test)]
    if let Some(home) = TEST_HOME.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    {
        return Some(places_for_test(&home));
    }
    Places::from_env()
}

#[cfg(test)]
pub(crate) fn places_for_test(home: &std::path::Path) -> Places {
    Places {
        home: home.to_path_buf(),
        support: home.join("Library/Application Support"),
        probe_home: home.to_path_buf(),
        config_home: home.join(".config"),
        settings_directory: home.join(".config").join("cmux"),
        xdg_state_home: None,
        tmp: home.join("tmp"),
    }
}

/// The home the wire's `classic_import.*` reads in a test, in place of `HOME`.
#[cfg(test)]
pub(crate) static TEST_HOME: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);
