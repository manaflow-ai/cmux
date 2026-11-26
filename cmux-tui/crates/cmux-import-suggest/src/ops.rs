//! The JSON ops the app calls (`import_suggest_*`) over the layout reducer FFI. Each takes one
//! JSON request and answers with JSON; nothing is kept between calls, so the app's saved state
//! (UserDefaults, the jobs file) goes in and comes back changed.

use std::collections::BTreeSet;

use base64::Engine as _;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::deck::{Action, Deck, done_status};
use crate::iterm::Profiles;
use crate::job::{Failure, Job, Ledger, Pause};
use crate::model::{Counts, Family, Finding, Profile, SourceKind};
use crate::preview;
use crate::request::{self, Request};
use crate::scan::{self, ChromiumFacts, ClassicAvailability, FileAccess};
use crate::state::State;

pub const PREFIX: &str = "import_suggest_";

const OPS: [&str; 37] = [
    "import_suggest_cards",
    "import_suggest_fingerprint",
    "import_suggest_finding_facts",
    "import_suggest_job_facts",
    "import_suggest_ledger_put",
    "import_suggest_ledger_remove",
    "import_suggest_action_facts",
    "import_suggest_kind_facts",
    "import_suggest_state_hides",
    "import_suggest_state_dismiss",
    "import_suggest_state_restore",
    "import_suggest_state_raise",
    "import_suggest_state_drop",
    "import_suggest_state_expire",
    "import_suggest_request",
    "import_suggest_site",
    "import_suggest_job_from_finding",
    "import_suggest_job_from_request",
    "import_suggest_job_event",
    "import_suggest_job_done_status",
    "import_suggest_ledger_read",
    "import_suggest_ledger_relaunched",
    "import_suggest_iterm",
    "import_suggest_classic_lines",
    "import_suggest_app_name",
    "import_suggest_scan_browser_order",
    "import_suggest_scan_is_container",
    "import_suggest_scan_chromium_profiles",
    "import_suggest_scan_chromium_kinds",
    "import_suggest_scan_firefox_profiles",
    "import_suggest_scan_firefox_kinds",
    "import_suggest_scan_profiles_finding",
    "import_suggest_scan_safari",
    "import_suggest_scan_sessions",
    "import_suggest_scan_classic",
    "import_suggest_scan_conductor",
    "import_suggest_scan_extras",
];

/// The op is one of these.
pub fn serves(op: &str) -> bool {
    op.starts_with(PREFIX) && OPS.contains(&op)
}

/// What happened to a job (`ImportJob`'s transitions).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    Progressed {
        fraction: f64,
    },
    FinishedStep {
        index: usize,
        #[serde(default)]
        added: Counts,
    },
    ImportedClassic {
        workspaces: i64,
    },
    Paused {
        reason: Pause,
    },
    Resumed,
    Failed {
        reason: Failure,
    },
}

fn parse<T: DeserializeOwned>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|error| error.to_string())
}

fn reply<T: Serialize>(value: &T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn bytes(text: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD.decode(text).map_err(|error| error.to_string())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WithState {
    #[serde(default)]
    state: State,
    #[serde(default)]
    finding: Option<Finding>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    request: Option<Request>,
    #[serde(default)]
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WithJob {
    job: Job,
    event: Event,
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewRequest {
    browser: String,
    site: String,
    #[serde(default)]
    reason: String,
    requested_at: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassicLines {
    counts: preview::Counts,
    #[serde(default)]
    classic_running: bool,
    #[serde(default)]
    at_launch: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProfilesFinding {
    browser: String,
    name: String,
    profiles: Vec<Profile>,
    #[serde(default)]
    imported: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Safari {
    browser: String,
    name: String,
    history: FileAccess,
    #[serde(default)]
    bookmarks_readable: bool,
    #[serde(default)]
    has_cookie_file: bool,
    #[serde(default)]
    imported: BTreeSet<String>,
}

/// The findings that need no profile walk: the agents' session counts, Classic, Conductor,
/// iTerm2 and Ghostty, in scan order.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Extras {
    claude_sessions: i64,
    codex_threads: i64,
    classic: Option<ClassicAvailability>,
    conductor_workspaces: i64,
    conductor_database_bytes: i64,
    iterm2_profiles: Vec<String>,
    ghostty_config_bytes: Vec<i64>,
}

fn field<T: DeserializeOwned>(request: &Value, key: &str) -> Result<T, String> {
    parse(request.get(key).cloned().unwrap_or(Value::Null))
}

fn state_op(op: &str, request: Value) -> Result<Value, String> {
    let WithState { mut state, finding, id, request: raised, now } = parse(request)?;
    let id = || id.clone().ok_or_else(|| "missing id".to_owned());
    match op {
        "import_suggest_state_hides" => {
            let finding = finding.ok_or("missing finding")?;
            return Ok(json!(state.hides(&finding)));
        }
        "import_suggest_state_dismiss" => state.dismiss(&finding.ok_or("missing finding")?),
        "import_suggest_state_restore" => state.restore(&id()?),
        "import_suggest_state_raise" => state.raise(raised.ok_or("missing request")?),
        "import_suggest_state_drop" => state.drop_request(&id()?),
        _ => state.expire(now),
    }
    reply(&state)
}

/// Runs one op.
pub fn call(op: &str, request: Value) -> Result<Value, String> {
    if op.starts_with("import_suggest_state_") {
        return state_op(op, request);
    }
    match op {
        "import_suggest_cards" => reply(&parse::<Deck>(request)?.cards()),
        "import_suggest_fingerprint" => {
            Ok(json!(field::<Finding>(&request, "finding")?.fingerprint()))
        }
        "import_suggest_finding_facts" => {
            let finding: Finding = field(&request, "finding")?;
            Ok(json!({
                "kinds": finding.kinds(),
                "offersNothingNew": finding.offers_nothing_new(),
                "fingerprint": finding.fingerprint(),
            }))
        }
        "import_suggest_job_facts" => {
            let job: Job = field(&request, "job")?;
            let family: Option<Family> = field(&request, "family")?;
            Ok(json!({
                "fraction": job.fraction(),
                "nextStep": job.next_step(),
                "isActive": job.is_active(),
                "resumesQuietly": job.resumes_quietly(family),
            }))
        }
        "import_suggest_ledger_put" => {
            let mut ledger: Ledger = field(&request, "ledger")?;
            ledger.put(field(&request, "job")?);
            reply(&ledger)
        }
        "import_suggest_ledger_remove" => {
            let mut ledger: Ledger = field(&request, "ledger")?;
            ledger.remove(&field::<String>(&request, "id")?);
            reply(&ledger)
        }
        "import_suggest_action_facts" => {
            let action: Action = field(&request, "action")?;
            Ok(
                json!({ "startsWork": action.starts_work(), "confirmLabel": action.confirm_label() }),
            )
        }
        "import_suggest_kind_facts" => {
            let kind: SourceKind = field(&request, "kind")?;
            Ok(json!({
                "startReadsAnotherApp": kind.start_reads_another_app(),
                "displayName": kind.display_name(),
            }))
        }
        "import_suggest_request" => {
            let NewRequest { browser, site, reason, requested_at } = parse(request)?;
            let made = Request::new(browser, site, &reason, requested_at);
            Ok(json!({ "request": made, "id": made.id() }))
        }
        "import_suggest_site" => Ok(json!(request::site(&field::<String>(&request, "text")?))),
        "import_suggest_job_from_finding" => {
            reply(&Job::from_finding(&field(&request, "finding")?, field(&request, "now")?))
        }
        "import_suggest_job_from_request" => {
            let profile: String = field(&request, "profile")?;
            reply(&Job::from_request(
                &field(&request, "request")?,
                &profile,
                field(&request, "now")?,
            ))
        }
        "import_suggest_job_event" => {
            let WithJob { mut job, event, now } = parse(request)?;
            match event {
                Event::Progressed { fraction } => job.progressed(fraction, now),
                Event::FinishedStep { index, added } => job.finished_step(index, added, now),
                Event::ImportedClassic { workspaces } => job.imported_classic(workspaces, now),
                Event::Paused { reason } => job.paused(reason, now),
                Event::Resumed => job.resumed(now),
                Event::Failed { reason } => job.failed(reason, now),
            }
            Ok(
                json!({ "job": job, "fraction": job.fraction(), "nextStep": job.next_step(), "isActive": job.is_active() }),
            )
        }
        "import_suggest_job_done_status" => reply(&done_status(&field(&request, "job")?)),
        "import_suggest_ledger_read" => {
            reply(&Ledger::read(&bytes(&field::<String>(&request, "data")?)?))
        }
        "import_suggest_ledger_relaunched" => {
            let mut ledger: Ledger = field(&request, "ledger")?;
            ledger.relaunched(field(&request, "now")?);
            reply(&ledger)
        }
        "import_suggest_iterm" => {
            let data = bytes(&field::<String>(&request, "data")?)?;
            Ok(match Profiles::read(&data) {
                Some(profiles) => {
                    let preferred = profiles.preferred().cloned();
                    json!({ "profiles": profiles.profiles, "preferred": preferred })
                }
                None => Value::Null,
            })
        }
        "import_suggest_classic_lines" => {
            let ClassicLines { counts, classic_running, at_launch } = parse(request)?;
            reply(&counts.lines(classic_running, at_launch))
        }
        "import_suggest_app_name" => Ok(json!(preview::app_name(
            &field::<String>(&request, "bundle")?,
            &field::<String>(&request, "classic")?
        ))),
        _ => scan_op(op, request),
    }
}

fn scan_op(op: &str, request: Value) -> Result<Value, String> {
    match op {
        "import_suggest_scan_browser_order" => {
            reply(&scan::browser_order(&field::<Vec<String>>(&request, "candidates")?))
        }
        "import_suggest_scan_is_container" => {
            Ok(json!(scan::is_container(&field::<String>(&request, "path")?)))
        }
        "import_suggest_scan_chromium_profiles" => {
            reply(&scan::chromium_profile_names(&field::<Vec<String>>(&request, "listing")?))
        }
        "import_suggest_scan_chromium_kinds" => {
            reply(&scan::chromium_kinds(parse::<ChromiumFacts>(request)?))
        }
        "import_suggest_scan_firefox_profiles" => {
            reply(&scan::firefox_profile_names(&field::<Vec<String>>(&request, "listing")?))
        }
        "import_suggest_scan_firefox_kinds" => {
            let places = field::<Option<bool>>(&request, "places")?.unwrap_or(false);
            let cookies = field::<Option<bool>>(&request, "cookies")?.unwrap_or(false);
            reply(&scan::firefox_kinds(places, cookies))
        }
        "import_suggest_scan_profiles_finding" => {
            let ProfilesFinding { browser, name, profiles, imported } = parse(request)?;
            reply(&scan::profiles_finding(&browser, &name, profiles, &imported))
        }
        "import_suggest_scan_safari" => {
            let Safari { browser, name, history, bookmarks_readable, has_cookie_file, imported } =
                parse(request)?;
            reply(&scan::safari_finding(
                &browser,
                &name,
                history,
                bookmarks_readable,
                has_cookie_file,
                &imported,
            ))
        }
        "import_suggest_scan_sessions" => {
            Ok(json!(scan::session_files(&field::<Vec<String>>(&request, "listing")?)))
        }
        "import_suggest_scan_classic" => {
            reply(&scan::classic_finding(field(&request, "availability")?))
        }
        "import_suggest_scan_conductor" => reply(&scan::conductor_finding(
            field::<Option<i64>>(&request, "workspaces")?.unwrap_or(0),
            field::<Option<i64>>(&request, "databaseBytes")?.unwrap_or(0),
        )),
        "import_suggest_scan_extras" => {
            let extras: Extras = parse(request)?;
            let found: Vec<Finding> = [
                scan::sessions_finding(SourceKind::ClaudeCode, extras.claude_sessions),
                scan::sessions_finding(SourceKind::Codex, extras.codex_threads),
                extras.classic.and_then(scan::classic_finding),
                scan::conductor_finding(
                    extras.conductor_workspaces,
                    extras.conductor_database_bytes,
                ),
                scan::iterm2_finding(&extras.iterm2_profiles),
                scan::ghostty_finding(&extras.ghostty_config_bytes),
            ]
            .into_iter()
            .flatten()
            .collect();
            reply(&found)
        }
        _ => Err(format!("unknown op {op}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_op_is_served_and_others_are_not() {
        for op in OPS {
            assert!(serves(op), "{op}");
        }
        assert!(!serves("import_suggest_nope"));
        assert!(!serves("tab_discard_plan"));
    }

    #[test]
    fn dismiss_then_hides_round_trips_through_json() {
        let finding = json!({ "id": "agents.codex", "kind": "codex", "name": "Codex", "count": 3 });
        let state = call("import_suggest_state_dismiss", json!({ "finding": finding })).unwrap();
        assert_eq!(state["dismissed"]["agents.codex"], "agents.codex|ready");
        let hides =
            call("import_suggest_state_hides", json!({ "state": state, "finding": finding }))
                .unwrap();
        assert_eq!(hides, json!(true));
    }

    #[test]
    fn a_job_moves_through_its_events() {
        let finding = json!({ "id": "agents.codex", "kind": "codex", "name": "Codex", "count": 3 });
        let job =
            call("import_suggest_job_from_finding", json!({ "finding": finding, "now": 1000.0 }))
                .unwrap();
        let paused = call(
            "import_suggest_job_event",
            json!({ "job": job, "event": { "event": "paused", "reason": "interrupted" }, "now": 2000.0 }),
        )
        .unwrap();
        assert_eq!(paused["job"]["phase"], "paused");
        assert_eq!(paused["isActive"], json!(false));
    }

    #[test]
    fn facts_answer_for_findings_jobs_actions_and_kinds() {
        let finding = json!({ "id": "browser.chrome", "kind": "browser", "browser": "chrome", "name": "Chrome",
            "profiles": [{ "directoryName": "Default", "kinds": ["cookies", "bookmarks", "history"] }] });
        let facts = call("import_suggest_finding_facts", json!({ "finding": finding })).unwrap();
        assert_eq!(facts["kinds"], json!(["history", "bookmarks", "cookies"]));
        assert_eq!(facts["offersNothingNew"], json!(false));
        let job =
            call("import_suggest_job_from_finding", json!({ "finding": finding, "now": 1.0 }))
                .unwrap();
        let chromium =
            call("import_suggest_job_facts", json!({ "job": job, "family": "chromium" })).unwrap();
        assert_eq!(chromium["resumesQuietly"], json!(false));
        assert_eq!(chromium["nextStep"], json!(0));
        let firefox =
            call("import_suggest_job_facts", json!({ "job": job, "family": "firefox" })).unwrap();
        assert_eq!(firefox["resumesQuietly"], json!(true));
        let ledger =
            call("import_suggest_ledger_put", json!({ "ledger": {}, "job": job })).unwrap();
        let again =
            call("import_suggest_ledger_put", json!({ "ledger": ledger, "job": job })).unwrap();
        assert_eq!(again["jobs"].as_array().unwrap().len(), 1);
        let gone = call(
            "import_suggest_ledger_remove",
            json!({ "ledger": again, "id": "browser.chrome" }),
        )
        .unwrap();
        assert!(gone["jobs"].as_array().unwrap().is_empty());
        let retry = call("import_suggest_action_facts", json!({ "action": "retry" })).unwrap();
        assert_eq!(retry, json!({ "startsWork": true, "confirmLabel": "retry" }));
        let iterm = call("import_suggest_kind_facts", json!({ "kind": "iterm2" })).unwrap();
        assert_eq!(iterm, json!({ "startReadsAnotherApp": true, "displayName": "iTerm2" }));
    }

    #[test]
    fn extras_come_back_in_scan_order() {
        let found = call(
            "import_suggest_scan_extras",
            json!({ "claudeSessions": 2, "classic": "available", "iterm2Profiles": ["Default"], "ghosttyConfigBytes": [5] }),
        )
        .unwrap();
        let ids: Vec<&str> =
            found.as_array().unwrap().iter().map(|f| f["id"].as_str().unwrap()).collect();
        assert_eq!(
            ids,
            ["agents.claudeCode", "cmux.classic", "terminal.iterm2", "terminal.ghostty"]
        );
        assert!(found[1].get("count").is_none());
    }

    #[test]
    fn the_ledger_reads_from_base64_and_junk_is_empty() {
        let data = base64::engine::general_purpose::STANDARD.encode(b"not json");
        let ledger = call("import_suggest_ledger_read", json!({ "data": data })).unwrap();
        assert_eq!(ledger["jobs"], json!([]));
        assert_eq!(
            call("import_suggest_site", json!({ "text": "https://GitHub.com/x" })).unwrap(),
            json!("github.com")
        );
    }
}
