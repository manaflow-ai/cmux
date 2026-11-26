//! The directory's Chief list and the cloud Chiefs (CmuxNextHomeEngine `HomeChiefRecord.swift`,
//! `HomeArchivedChiefs.swift`; CmuxNextHostedChief `HostedChiefModels.swift`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

/// One Chief of the directory's `chief.list` (`HomeChiefRecord`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub rev: i64,
    pub main_conversation: Option<String>,
    pub placed: bool,
}

/// `NSNumber.intValue` of a JSON number (a fraction truncates).
fn int_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|n| n as i64))
        .or_else(|| value.as_f64().map(|n| n as i64))
}

fn objects<'a>(value: &'a Value, key: &str) -> Vec<&'a serde_json::Map<String, Value>> {
    match value.get(key) {
        Some(Value::Array(items)) if items.iter().all(Value::is_object) => {
            items.iter().filter_map(Value::as_object).collect()
        }
        // `as? [[String: Any]]` fails whole when one item is no object.
        _ => Vec::new(),
    }
}

/// `HomeChiefRecord.parse`: a Chief with an id that is not archived.
pub fn parse_record(object: &serde_json::Map<String, Value>) -> Option<Record> {
    let id = object.get("id")?.as_str()?;
    if object.get("archived_at").is_some_and(Value::is_string) {
        return None;
    }
    Some(Record {
        id: id.to_owned(),
        name: object.get("display_name").and_then(Value::as_str).unwrap_or_default().to_owned(),
        is_default: object.get("is_default").and_then(Value::as_bool).unwrap_or(false),
        rev: object.get("rev").and_then(int_value).unwrap_or(0),
        main_conversation: object
            .get("main_conversation")
            .and_then(Value::as_str)
            .map(str::to_owned),
        placed: object.get("brain_place").is_some_and(Value::is_object),
    })
}

/// `HomeChiefRecord.list(from:)`.
pub fn list(value: &Value) -> Vec<Record> {
    objects(value, "chiefs").into_iter().filter_map(parse_record).collect()
}

/// `HomeChiefRecord.archivedIDs(from:)`: archived Chiefs and every tombstone, in first-seen order.
pub fn archived_ids(value: &Value) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let archived = objects(value, "chiefs")
        .into_iter()
        .filter(|chief| chief.get("archived_at").is_some_and(Value::is_string))
        .filter_map(|chief| chief.get("id")?.as_str());
    let tombstones =
        objects(value, "tombstones").into_iter().filter_map(|stone| stone.get("id")?.as_str());
    archived.chain(tombstones).filter(|id| seen.insert(*id)).map(str::to_owned).collect()
}

/// A chat list row as `HomeArchivedChiefs` reads it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    /// `InboxRow.kind`'s raw value; `chief` rows are the ones an archived Chief hides.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub participants: Vec<String>,
}

/// `HomeArchivedChiefs`: the archived (and deleted) Chiefs' ids and the signed-in user.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Archived {
    #[serde(default)]
    pub ids: BTreeSet<String>,
    #[serde(default)]
    pub me: Option<String>,
}

impl Archived {
    fn shows(&self, row: &Row) -> bool {
        row.kind != "chief"
            || !row
                .participants
                .iter()
                .any(|p| Some(p.as_str()) != self.me.as_deref() && self.ids.contains(p))
    }

    /// `visible(_:)`.
    pub fn visible<'a>(&self, rows: &'a [Row]) -> Vec<&'a Row> {
        if self.ids.is_empty() {
            return rows.iter().collect();
        }
        rows.iter().filter(|row| self.shows(row)).collect()
    }

    /// `otherChiefs(than:in:)`.
    pub fn other_chiefs(&self, than: &str, rows: &[Row]) -> usize {
        self.visible(rows).into_iter().filter(|row| row.kind == "chief" && row.id != than).count()
    }

    /// `hiddenConversations(_:)`.
    pub fn hidden(&self, rows: &[Row]) -> Vec<String> {
        if self.ids.is_empty() {
            return Vec::new();
        }
        let shown: BTreeSet<&str> =
            self.visible(rows).into_iter().map(|row| row.id.as_str()).collect();
        rows.iter()
            .filter(|row| !shown.contains(row.id.as_str()))
            .map(|row| row.id.clone())
            .collect()
    }

    /// `openable(_:listed:participants:)`; `participants` are the unlisted conversation's.
    pub fn openable(
        &self,
        chief: Option<&str>,
        listed: &[Row],
        participants: &[String],
    ) -> Option<String> {
        let chief = chief?;
        let rows: Vec<Row> = listed.iter().filter(|row| row.id == chief).cloned().collect();
        if rows.is_empty() {
            return (!self.hides(participants)).then(|| chief.to_owned());
        }
        (!self.visible(&rows).is_empty()).then(|| chief.to_owned())
    }

    /// `hides(participants:)`: a DM with an archived Chief.
    pub fn hides(&self, participants: &[String]) -> bool {
        participants.len() == 2
            && participants
                .iter()
                .any(|p| self.ids.contains(p) && Some(p.as_str()) != self.me.as_deref())
    }
}

/// Where a placed Chief's brain runs (`CloudChief.BrainPlace`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrainPlace {
    pub host: String,
    pub install: String,
}

/// A Chief of the cloud's `chief.list` (`CloudChief`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudChief {
    pub id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub main_conversation: Option<String>,
    pub rev: i64,
    #[serde(default)]
    pub brain_place: Option<BrainPlace>,
}

/// `CloudChief.parse`: needs an id and a numeric rev; `brain_place` counts only with both strings.
pub fn parse_cloud_chief(value: &Value) -> Option<CloudChief> {
    let object = value.as_object()?;
    let id = object.get("id")?.as_str()?;
    let rev = object.get("rev").and_then(int_value)?;
    let brain_place = object.get("brain_place").and_then(Value::as_object).and_then(|raw| {
        Some(BrainPlace {
            host: raw.get("host")?.as_str()?.to_owned(),
            install: raw.get("install")?.as_str()?.to_owned(),
        })
    });
    Some(CloudChief {
        id: id.to_owned(),
        display_name: object
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        is_default: object.get("is_default").and_then(Value::as_bool).unwrap_or(false),
        main_conversation: object
            .get("main_conversation")
            .and_then(Value::as_str)
            .map(str::to_owned),
        rev,
        brain_place,
    })
}

/// `HomeChiefChoice`: which cloud Chief Home shows. Unknown or absent is `hosted`.
pub fn choice(raw: Option<&str>) -> &'static str {
    match raw {
        Some("placed") => "placed",
        _ => "hosted",
    }
}

/// `HomeCloudChiefs`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct CloudChiefs {
    #[serde(default)]
    pub hosted: Option<CloudChief>,
    #[serde(default)]
    pub placed: Option<CloudChief>,
}

impl CloudChiefs {
    /// `shown(choice:)`.
    pub fn shown(&self, choice: &str) -> Option<&CloudChief> {
        if choice == "placed"
            && let Some(placed) = &self.placed
        {
            return Some(placed);
        }
        self.hosted.as_ref().or(self.placed.as_ref())
    }

    /// `chief(for:)`.
    pub fn chief_for(&self, conversation: &str) -> Option<&CloudChief> {
        [&self.hosted, &self.placed]
            .into_iter()
            .flatten()
            .find(|chief| chief.main_conversation.as_deref() == Some(conversation))
    }

    /// `canSwitch`.
    pub fn can_switch(&self) -> bool {
        let main = |chief: &Option<CloudChief>| {
            chief.as_ref().is_some_and(|c| c.main_conversation.is_some())
        };
        main(&self.hosted) && main(&self.placed)
    }

    /// `otherHost(of:)`.
    pub fn other_host(&self, conversation: &str) -> Option<&'static str> {
        if !self.can_switch() {
            return None;
        }
        fn main(chief: &Option<CloudChief>) -> Option<&str> {
            chief.as_ref().and_then(|c| c.main_conversation.as_deref())
        }
        if main(&self.hosted) == Some(conversation) {
            Some("placed")
        } else if main(&self.placed) == Some(conversation) {
            Some("hosted")
        } else {
            None
        }
    }
}
