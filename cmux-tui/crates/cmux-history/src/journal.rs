//! Reading session journal records (cmux-tui/spec/session-journal.md) as
//! `serde_json::Value`, with the same field rules as the Swift decoders
//! `AgentJournalRecord` and `CommandJournalRecord`.

use serde_json::Value;

/// How fold output becomes entries: which machine is local (its entries have
/// no machine name) and whether the folded machine is connected now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EntryContext<'a> {
    /// The local machine (session) id; entries of this machine carry no
    /// `machine` name.
    pub local_machine: &'a str,
    /// False while the folded machine is not connected.
    pub available: bool,
}

/// One subject of a record: the terminal, tab, pane or workspace it is about.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Subject {
    pub kind: String,
    pub id: String,
}

/// The envelope fields both folds read. `None` from [`Envelope::parse`] means
/// the Swift decoder would drop the record: it is skipped and does not move
/// the cursor.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Envelope<'a> {
    pub sequence: u64,
    pub kind: &'a str,
    pub occurred_at_ms: Option<i64>,
    pub subjects: Vec<Subject>,
    pub payload: Option<&'a Value>,
}

impl<'a> Envelope<'a> {
    pub fn parse(record: &'a Value) -> Option<Self> {
        let object = record.as_object()?;
        let sequence = unsigned(object.get("sequence")?)?;
        let kind = object.get("kind")?.as_str()?;
        let occurred_at_ms = object.get("occurred_at_ms").and_then(signed);
        let subjects = match object.get("subjects") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items.iter().map(subject).collect::<Option<Vec<_>>>()?,
            Some(_) => return None,
        };
        let payload = match object.get("payload") {
            None | Some(Value::Null) => None,
            Some(value @ Value::Object(_)) => Some(value),
            Some(_) => return None,
        };
        Some(Self { sequence, kind, occurred_at_ms, subjects, payload })
    }

    /// The id of the first subject of `kind`.
    pub fn subject(&self, kind: &str) -> Option<&str> {
        self.subjects.iter().find(|subject| subject.kind == kind).map(|subject| subject.id.as_str())
    }
}

fn subject(value: &Value) -> Option<Subject> {
    let object = value.as_object()?;
    Some(Subject {
        kind: object.get("kind")?.as_str()?.to_owned(),
        id: object.get("id")?.as_str()?.to_owned(),
    })
}

/// A decimal string (the resource API sends sequences as strings) or a JSON
/// unsigned integer.
pub(crate) fn unsigned(value: &Value) -> Option<u64> {
    match value {
        Value::String(text) => text.parse().ok(),
        other => other.as_u64(),
    }
}

/// A decimal string or a JSON integer; anything else is absent.
pub(crate) fn signed(value: &Value) -> Option<i64> {
    match value {
        Value::String(text) => text.parse().ok(),
        other => other.as_i64(),
    }
}

/// A string field at `path` below `value`; a missing or non-string field is
/// absent.
pub(crate) fn string_at<'a>(value: Option<&'a Value>, path: &[&str]) -> Option<&'a str> {
    let mut current = value?;
    for key in path {
        current = current.get(key)?;
    }
    current.as_str()
}
