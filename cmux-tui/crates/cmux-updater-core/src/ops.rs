//! The JSON requests the app sends over the app FFI's JSON channel (`cmux_layout_reducer_json`,
//! ops `updater_*`), with their replies. Field names are camelCase, as Swift's `JSONEncoder`
//! writes them.

use serde::{Deserialize, Serialize};

use std::collections::BTreeMap;

use crate::appcast::{self, AppcastItem};
use crate::numeric;
use crate::rollback::{self, Kept, Refusal, RingReturn};
use crate::select::{self, Candidate, Outcome};
use crate::system_version::SystemVersion;
use crate::version;

/// `updater_version_compare`: Sparkle's order of each pair.
#[derive(Debug, Deserialize)]
pub struct CompareRequest {
    pub pairs: Vec<(String, String)>,
}

/// -1, 0 or 1 per pair: the first older, equal, or newer.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CompareReply {
    pub orders: Vec<i8>,
}

pub fn compare(request: &CompareRequest) -> CompareReply {
    CompareReply {
        orders: request.pairs.iter().map(|(a, b)| version::compare(a, b) as i8).collect(),
    }
}

/// `updater_appcast_parse`: the feed's text (the app refuses bytes that are not UTF-8 itself).
#[derive(Debug, Deserialize)]
pub struct ParseRequest {
    pub xml: String,
}

/// The items, or why the feed is not readable.
#[derive(Debug, Serialize, PartialEq)]
pub struct ParseReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<AppcastItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn parse(request: &ParseRequest) -> ParseReply {
    match appcast::parse(&request.xml) {
        Ok(items) => ParseReply { items: Some(items), error: None },
        Err(error) => ParseReply { items: None, error: Some(error.0) },
    }
}

/// `updater_appcast_select`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectRequest {
    pub items: Vec<Candidate>,
    pub current_build: String,
    pub system: SystemVersion,
}

pub fn select(request: &SelectRequest) -> Outcome {
    select::select(&request.items, &request.current_build, request.system)
}

/// `updater_system_version`: parses each text (`sparkle:minimumSystemVersion`,
/// `LSMinimumSystemVersion`), null where it is not a macOS version.
#[derive(Debug, Deserialize)]
pub struct SystemVersionRequest {
    pub texts: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct SystemVersionReply {
    pub versions: Vec<Option<SystemVersion>>,
}

pub fn system_versions(request: &SystemVersionRequest) -> SystemVersionReply {
    SystemVersionReply {
        versions: request.texts.iter().map(|text| SystemVersion::parse(text)).collect(),
    }
}

/// `updater_numeric_compare`: the numeric order (kept builds, channel tracks) of each pair.
pub fn numeric_compare(request: &CompareRequest) -> CompareReply {
    CompareReply {
        orders: request.pairs.iter().map(|(a, b)| numeric::compare(a, b) as i8).collect(),
    }
}

/// `updater_rollback`: the target of a rollback, or why it does not run.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackRequest {
    pub kept: Vec<Kept>,
    #[serde(default)]
    pub build: Option<String>,
    #[serde(default)]
    pub running: Option<String>,
    #[serde(default)]
    pub stored: BTreeMap<String, i64>,
    #[serde(default)]
    pub team_id: Option<String>,
    /// Only the previous build of `running` (`RollbackDecision.previous`), no checks.
    #[serde(default)]
    pub previous_only: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct RollbackReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
}

pub fn rollback(request: &RollbackRequest) -> RollbackReply {
    if request.previous_only {
        let target = request
            .running
            .as_deref()
            .and_then(|running| rollback::previous(&request.kept, running));
        return RollbackReply { target, refusal: None };
    }
    match rollback::decide(
        &request.kept,
        request.build.as_deref(),
        request.running.as_deref(),
        &request.stored,
        request.team_id.as_deref(),
    ) {
        Ok(target) => RollbackReply { target: Some(target), refusal: None },
        Err(refusal) => RollbackReply { target: None, refusal: Some(refusal) },
    }
}

/// `updater_ring_return`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RingReturnRequest {
    pub installed_build: String,
    pub offered: Vec<String>,
    #[serde(default)]
    pub promoted: Vec<String>,
    #[serde(default)]
    pub pulled: Vec<String>,
    /// Kept builds, newest first.
    #[serde(default)]
    pub kept: Vec<String>,
}

pub fn ring_return(request: &RingReturnRequest) -> RingReturn {
    rollback::ring_return(
        &request.installed_build,
        &request.offered,
        &request.promoted,
        &request.pulled,
        &request.kept,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn compare_answers_each_pair() {
        let request: CompareRequest = serde_json::from_value(
            json!({"pairs": [["1203", "1204"], ["1.0", "1.0.0"], ["2", "1"]]}),
        )
        .unwrap();
        assert_eq!(compare(&request), CompareReply { orders: vec![-1, 0, 1] });
    }

    #[test]
    fn parse_answers_items_or_an_error() {
        let reply = parse(&ParseRequest { xml: "<rss/>".into() });
        assert_eq!(
            serde_json::to_value(reply).unwrap(),
            json!({"error": "appcast has no <channel>"})
        );
        let reply = parse(&ParseRequest {
            xml: "<rss><channel><item><sparkle:version>7</sparkle:version></item></channel></rss>"
                .into(),
        });
        assert_eq!(
            serde_json::to_value(reply).unwrap(),
            json!({"items": [{"version": "7", "listsDeltas": false}]})
        );
    }

    #[test]
    fn select_reads_the_app_request() {
        let request: SelectRequest = serde_json::from_value(json!({
            "items": [{"version": "5", "minimumSystemVersion": {"major": 27, "minor": 0, "patch": 0}}, {"version": "4"}],
            "currentBuild": "3",
            "system": {"major": 26, "minor": 1, "patch": 0},
        }))
        .unwrap();
        assert_eq!(select(&request), Outcome::UpdateAvailable { item: 1 });
    }

    #[test]
    fn rollback_answers_a_target_or_a_refusal() {
        let request: RollbackRequest = serde_json::from_value(json!({
            "kept": [{"build": "1205", "storeSchemas": {"tabs": 3}, "teamId": "T", "keptAt": 2.0},
                     {"build": "1200", "storeSchemas": {"tabs": 3}, "teamId": "T", "keptAt": 1.0}],
            "running": "1210", "stored": {"tabs": 4}, "teamId": "T",
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(rollback(&request)).unwrap(),
            json!({"refusal": {"kind": "storeTooNew", "store": "tabs", "stored": 4, "readable": 3, "kept": 0}})
        );
        let request: RollbackRequest = serde_json::from_value(json!({
            "kept": [{"build": "1205", "keptAt": 1.0}, {"build": "1200", "keptAt": 2.0}],
            "running": "1210", "previousOnly": true,
        }))
        .unwrap();
        assert_eq!(serde_json::to_value(rollback(&request)).unwrap(), json!({"target": 1}));
    }

    #[test]
    fn ring_return_reads_the_app_request() {
        let request: RingReturnRequest = serde_json::from_value(json!({
            "installedBuild": "1210", "offered": ["1200"], "promoted": ["1205"], "kept": ["1205"],
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(ring_return(&request)).unwrap(),
            json!({"kind": "goBack", "kept": 0})
        );
    }

    #[test]
    fn numeric_compare_answers_each_pair() {
        let request: CompareRequest = serde_json::from_value(
            json!({"pairs": [["999", "1204"], ["1.10", "1.9"], ["7", "7"]]}),
        )
        .unwrap();
        assert_eq!(numeric_compare(&request), CompareReply { orders: vec![-1, 1, 0] });
    }

    #[test]
    fn system_versions_parse_each_text() {
        let reply = system_versions(&SystemVersionRequest { texts: vec!["26".into(), "x".into()] });
        assert_eq!(reply.versions, vec![Some(SystemVersion::new(26, 0, 0)), None]);
    }
}
