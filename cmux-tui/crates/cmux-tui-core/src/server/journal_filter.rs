//! Journal stream filters: parsing and validating the `filter` object of a
//! session journal stream (kinds and kind prefixes, subjects, classes,
//! maximum sensitivity, an optional payload or record regex) and matching
//! journal documents against it. Pure data; no connection or Mux state.

use std::collections::{HashMap, HashSet};

use regex::bytes::{Regex as BytesRegex, RegexBuilder as BytesRegexBuilder};
use serde_json::Value;

use crate::journal_kernel::JournalDocument;
use crate::resource::ResourceError;
use crate::{JournalClass, JournalSensitivity, JournalSubject};

pub(super) struct JournalStreamFilter {
    exact_kinds: HashSet<String>,
    kind_prefixes: Vec<String>,
    classes: [bool; 4],
    has_class_filter: bool,
    subject_kinds: HashSet<String>,
    subject_ids: HashSet<String>,
    exact_subjects: HashMap<String, HashSet<String>>,
    has_subject_filter: bool,
    pub(super) max_sensitivity: Option<JournalSensitivity>,
    pub(super) regex: Option<JournalCompiledRegex>,
}

impl Default for JournalStreamFilter {
    fn default() -> Self {
        Self {
            exact_kinds: HashSet::new(),
            kind_prefixes: Vec::new(),
            classes: [false; 4],
            has_class_filter: false,
            subject_kinds: HashSet::new(),
            subject_ids: HashSet::new(),
            exact_subjects: HashMap::new(),
            has_subject_filter: false,
            max_sensitivity: Some(JournalSensitivity::Metadata),
            regex: None,
        }
    }
}

enum JournalRegexField {
    Kind,
    Subjects,
    Payload,
    Record,
    TerminalOutput,
}

pub(super) struct JournalCompiledRegex {
    field: JournalRegexField,
    matcher: BytesRegex,
}

impl JournalCompiledRegex {
    pub(super) fn parse(value: &Value) -> Result<Self, ResourceError> {
        let object = value.as_object().ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("filter.regex"),
                "journal regex is not an object",
            )
        })?;
        let pattern = object.get("pattern").and_then(Value::as_str).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("filter.regex.pattern"),
                "journal regex pattern is absent",
            )
        })?;
        let field = match object.get("field").and_then(Value::as_str).unwrap_or("record") {
            "kind" => JournalRegexField::Kind,
            "subjects" => JournalRegexField::Subjects,
            "payload" => JournalRegexField::Payload,
            "record" => JournalRegexField::Record,
            "terminal_output" => JournalRegexField::TerminalOutput,
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("filter.regex.field"),
                    "journal regex field is invalid",
                ));
            }
        };
        let case_sensitive = object.get("case_sensitive").and_then(Value::as_bool).unwrap_or(true);
        let matcher = BytesRegexBuilder::new(pattern)
            .case_insensitive(!case_sensitive)
            .size_limit(1 << 20)
            .dfa_size_limit(2 << 20)
            .build()
            .map_err(|error| {
                ResourceError::validation_invalid(
                    Some("filter.regex.pattern"),
                    format!("journal regex is invalid: {error}"),
                )
            })?;
        Ok(Self { field, matcher })
    }

    pub(super) fn matches(&self, document: &JournalDocument) -> bool {
        let record = &document.record;
        match self.field {
            JournalRegexField::Kind => self.matcher.is_match(record.kind.as_bytes()),
            JournalRegexField::Subjects => self.matcher.is_match(document.subjects_bytes()),
            JournalRegexField::Payload => {
                document.payload_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            JournalRegexField::Record => {
                document.record_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            JournalRegexField::TerminalOutput => {
                document.terminal_output_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
        }
    }

    pub(super) fn exposes_payload_or_record(&self) -> bool {
        matches!(
            self.field,
            JournalRegexField::Payload
                | JournalRegexField::Record
                | JournalRegexField::TerminalOutput
        )
    }
}

impl JournalStreamFilter {
    pub(super) fn parse(value: Option<&Value>) -> Result<Self, ResourceError> {
        let Some(value) = value else { return Ok(Self::default()) };
        let object = value.as_object().ok_or_else(|| {
            ResourceError::validation_invalid(Some("filter"), "journal filter is not an object")
        })?;
        let mut exact_kinds = HashSet::new();
        let mut kind_prefixes = Vec::new();
        if let Some(kinds) = object.get("kinds") {
            let kinds = kinds.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.kinds"),
                    "journal kind filters are not an array",
                )
            })?;
            for kind in kinds {
                let kind = kind.as_str().ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("filter.kinds"),
                        "journal kind filter is not a string",
                    )
                })?;
                validate_journal_kind_filter(kind)?;
                if let Some(prefix) = kind.strip_suffix(".*") {
                    kind_prefixes.push(format!("{prefix}."));
                } else {
                    exact_kinds.insert(kind.to_string());
                }
            }
        }
        let mut classes = [false; 4];
        let mut has_class_filter = false;
        if let Some(values) = object.get("classes") {
            let values = values.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.classes"),
                    "journal class filters are not an array",
                )
            })?;
            has_class_filter = !values.is_empty();
            for value in values {
                let class =
                    serde_json::from_value::<JournalClass>(value.clone()).map_err(|_| {
                        ResourceError::validation_invalid(
                            Some("filter.classes"),
                            "journal class filter is invalid",
                        )
                    })?;
                if let Some(slot) = classes.get_mut(journal_class_index(class)) {
                    *slot = true;
                }
            }
        }
        let mut subject_kinds = HashSet::new();
        let mut subject_ids = HashSet::new();
        let mut exact_subjects = HashMap::<String, HashSet<String>>::new();
        let mut has_subject_filter = false;
        if let Some(values) = object.get("subjects") {
            let values = values.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.subjects"),
                    "journal subject filters are not an array",
                )
            })?;
            has_subject_filter = !values.is_empty();
            for value in values {
                let subject = value.as_object().ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("filter.subjects"),
                        "journal subject filter is not an object",
                    )
                })?;
                let kind = subject.get("kind").and_then(Value::as_str);
                let id = subject.get("id").and_then(Value::as_str);
                match (kind, id) {
                    (Some(kind), Some(id)) => {
                        exact_subjects.entry(kind.into()).or_default().insert(id.into());
                    }
                    (Some(kind), None) => {
                        subject_kinds.insert(kind.into());
                    }
                    (None, Some(id)) => {
                        subject_ids.insert(id.into());
                    }
                    (None, None) => {
                        return Err(ResourceError::validation_invalid(
                            Some("filter.subjects"),
                            "journal subject filters require kind or id",
                        ));
                    }
                }
            }
        }
        let max_sensitivity = object
            .get("max_sensitivity")
            .map(|value| {
                serde_json::from_value::<JournalSensitivity>(value.clone()).map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("filter.max_sensitivity"),
                        "journal sensitivity filter is invalid",
                    )
                })
            })
            .transpose()?
            .or(Some(JournalSensitivity::Metadata));
        if max_sensitivity == Some(JournalSensitivity::Secret) {
            return Err(ResourceError::validation_invalid(
                Some("filter.max_sensitivity"),
                "journal subscriptions cannot include secret records",
            ));
        }
        let regex = object.get("regex").map(JournalCompiledRegex::parse).transpose()?;
        Ok(Self {
            exact_kinds,
            kind_prefixes,
            classes,
            has_class_filter,
            subject_kinds,
            subject_ids,
            exact_subjects,
            has_subject_filter,
            max_sensitivity,
            regex,
        })
    }

    /// Whether the kind filter lets a record of `kind` through (the other
    /// filters are not asked).
    pub(super) fn may_match_kind(&self, kind: &str) -> bool {
        kind_filter_admits(&self.exact_kinds, &self.kind_prefixes, kind)
    }

    /// The part of the filter that decides by a record's kind and
    /// sensitivity alone, as it stands now (take it after a remote client's
    /// limit is set). `matches` asks the same two functions.
    pub(super) fn row_gate(&self) -> JournalRowGate {
        JournalRowGate {
            exact_kinds: self.exact_kinds.clone(),
            kind_prefixes: self.kind_prefixes.clone(),
            max_sensitivity: self.max_sensitivity,
        }
    }

    pub(super) fn matches(&self, document: &JournalDocument) -> bool {
        let record = &document.record;
        let kind_matches = self.may_match_kind(&record.kind);
        let class_matches = !self.has_class_filter
            || self.classes.get(journal_class_index(record.class)).copied().unwrap_or(false);
        let subject_matches = !self.has_subject_filter
            || record.subjects.iter().any(|subject| {
                self.subject_kinds.contains(&subject.kind)
                    || self.subject_ids.contains(&subject.id)
                    || self
                        .exact_subjects
                        .get(&subject.kind)
                        .is_some_and(|ids| ids.contains(&subject.id))
            });
        kind_matches
            && class_matches
            && subject_matches
            && sensitivity_limit_admits(self.max_sensitivity, record.sensitivity)
            && self.regex.as_ref().is_none_or(|regex| regex.matches(document))
    }

    pub(super) fn indexed_subjects(&self) -> Option<Vec<JournalSubject>> {
        if !self.has_subject_filter
            || !self.subject_kinds.is_empty()
            || !self.subject_ids.is_empty()
            || self.exact_subjects.is_empty()
        {
            return None;
        }
        Some(
            self.exact_subjects
                .iter()
                .flat_map(|(kind, ids)| {
                    ids.iter().map(|id| JournalSubject { kind: kind.clone(), id: id.clone() })
                })
                .collect(),
        )
    }
}

/// The kind and sensitivity limits of one stream filter
/// (`JournalStreamFilter::row_gate`): which rows the stream can be sent at
/// all. The daemon asks it before it leaves a row out of the journal
/// (`Mux::follow_journal`).
#[derive(Clone, Debug)]
pub(super) struct JournalRowGate {
    exact_kinds: HashSet<String>,
    kind_prefixes: Vec<String>,
    max_sensitivity: Option<JournalSensitivity>,
}

impl JournalRowGate {
    /// Whether the stream can be sent a record of `kind` at `sensitivity`.
    /// The subject, class and regex filters are not asked: they can only
    /// let fewer records through.
    pub(super) fn may_send(&self, kind: &str, sensitivity: JournalSensitivity) -> bool {
        kind_filter_admits(&self.exact_kinds, &self.kind_prefixes, kind)
            && sensitivity_limit_admits(self.max_sensitivity, sensitivity)
    }

    /// The kind filter as the client sent it (`agent.*`), sorted; empty for
    /// every kind.
    pub(super) fn kinds(&self) -> Vec<String> {
        let mut kinds = self
            .exact_kinds
            .iter()
            .cloned()
            .chain(self.kind_prefixes.iter().map(|prefix| format!("{prefix}*")))
            .collect::<Vec<_>>();
        kinds.sort();
        kinds
    }

    pub(super) fn max_sensitivity(&self) -> Option<JournalSensitivity> {
        self.max_sensitivity
    }
}

/// The kind rule of a stream filter: no kind filter, an exact kind, or a
/// `prefix.*` (kept as `prefix.`).
fn kind_filter_admits(exact_kinds: &HashSet<String>, kind_prefixes: &[String], kind: &str) -> bool {
    (exact_kinds.is_empty() && kind_prefixes.is_empty())
        || exact_kinds.contains(kind)
        || kind_prefixes.iter().any(|prefix| kind.starts_with(prefix.as_str()))
}

/// The sensitivity rule of a stream filter: a record above the limit is
/// never sent.
fn sensitivity_limit_admits(
    maximum: Option<JournalSensitivity>,
    sensitivity: JournalSensitivity,
) -> bool {
    maximum.is_none_or(|maximum| {
        journal_sensitivity_rank(sensitivity) <= journal_sensitivity_rank(maximum)
    })
}

fn validate_journal_kind_filter(kind: &str) -> Result<(), ResourceError> {
    let base = kind.strip_suffix(".*").unwrap_or(kind);
    if base.is_empty()
        || kind.trim() != kind
        || kind.contains('*') != kind.ends_with(".*")
        || base.split('.').any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        return Err(ResourceError::validation_invalid(
            Some("filter.kinds"),
            "journal kind filters must be dotted names with an optional terminal .*",
        ));
    }
    Ok(())
}

const fn journal_sensitivity_rank(sensitivity: JournalSensitivity) -> u8 {
    match sensitivity {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

const fn journal_class_index(class: JournalClass) -> usize {
    match class {
        JournalClass::State => 0,
        JournalClass::Observation => 1,
        JournalClass::Effect => 2,
        JournalClass::Checkpoint => 3,
    }
}
