//! Rule fixtures: one concrete message per compat rule and direction.
//!
//! `cmux-tui/spec/api-compat-fixtures.json` holds, for every change in
//! `spec/api-compat.json`, at least one case that crosses it upgrading and
//! one that crosses it downgrading. The unit tests replay each case through
//! [`Compat`]; the cross-version matrix (plans/cmux-next/tui-tester-rollout.md
//! #5) replays the same cases against real old and new binaries, so a new rule
//! without a fixture fails CI before it can skip the matrix.
//!
//! ```json
//! { "cases": [ { "message": "event:tab-renamed", "from": 13, "to": 12,
//!               "input": {"event": "tab-renamed", "tab": 4},
//!               "output": {"event": "tab-renamed", "surface": 4} } ] }
//! ```
//!
//! The same file holds the translator's behavior vectors. Each [`Vector`]
//! carries its own rule chain, one message as written, and what the
//! translation must give. The crate's tests and `api-compat-check` replay
//! them with [`check_vectors`], as Mojo's validation vectors are replayed
//! (chromium/src `mojo/public/interfaces/bindings/tests/data/validation/`).
//!
//! ```json
//! { "vectors": [ { "id": "rename-upgrades", "title": "a rename upgrades",
//!                  "translation": {
//!                    "schema": {"protocol": "test", "base": 1, "revisions": [
//!                      {"rev": 2, "changes": [{"message": "event:workspace", "op": "rename",
//!                                              "path": "/name", "to": "title"}]}]},
//!                    "message": "event:workspace", "from": 1, "to": 2,
//!                    "input": "{\"name\":\"a\"}" },
//!                  "expect": {"bytes": "{\"title\":\"a\"}"} } ] }
//! ```

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Compat, CompatError, Schema};

/// The fixture file.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fixtures {
    /// Every case, in any order.
    #[serde(default)]
    pub cases: Vec<Case>,
    /// Translator behavior vectors, each on its own rule chain.
    #[serde(default)]
    pub vectors: Vec<Vector>,
}

/// One translation and what it must give.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Vector {
    /// Unique slug (`[a-z0-9][a-z0-9-]{0,63}`).
    pub id: String,
    /// What the vector shows.
    pub title: String,
    /// The translation to run.
    pub translation: Translation,
    /// What it must give.
    pub expect: Expect,
}

/// One message written at `from` under `schema`, as a reader at `to` gets it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Translation {
    /// The rule chain, in compat file form.
    pub schema: Schema,
    /// Message kind (`request:<cmd>`, `response:<cmd>`, `event:<name>`).
    pub message: String,
    /// The writer's revision.
    pub from: u32,
    /// The reader's revision.
    pub to: u32,
    /// The message as written, byte for byte.
    pub input: String,
}

/// A vector's expected result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Expect {
    /// Exactly these bytes.
    Bytes(String),
    /// JSON equal to this value; member order is free.
    Json(Value),
    /// A refusal of this kind.
    Error(ErrorKind),
}

/// The kind of a [`CompatError`], without its details.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// [`CompatError::BadPointer`].
    BadPointer,
    /// [`CompatError::InvalidChange`].
    InvalidChange,
    /// [`CompatError::InvalidSchema`].
    InvalidSchema,
    /// [`CompatError::UnsupportedRevision`].
    UnsupportedRevision,
    /// [`CompatError::Malformed`].
    Malformed,
}

impl From<&CompatError> for ErrorKind {
    fn from(error: &CompatError) -> Self {
        match error {
            CompatError::BadPointer(_) => Self::BadPointer,
            CompatError::InvalidChange(_) => Self::InvalidChange,
            CompatError::InvalidSchema(_) => Self::InvalidSchema,
            CompatError::UnsupportedRevision { .. } => Self::UnsupportedRevision,
            CompatError::Malformed(_) => Self::Malformed,
        }
    }
}

/// What a [`Translation`] gave: `{"output": "..."}` or
/// `{"error": {"kind": "malformed", "message": "..."}}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Outcome {
    /// The translated message. UTF-8 input gives UTF-8 output; a translator
    /// bug that breaks it shows as U+FFFD and fails the vector.
    Output(String),
    /// The translator refused the schema or the message.
    Error {
        /// Which refusal.
        kind: ErrorKind,
        /// Its text.
        message: String,
    },
}

impl Translation {
    /// Builds the schema's runtime and translates the input.
    pub fn run(&self) -> Outcome {
        let result = Compat::new(self.schema.clone()).and_then(|compat| {
            compat
                .translate(&self.message, self.from, self.to, self.input.as_bytes())
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        });
        match result {
            Ok(output) => Outcome::Output(output),
            Err(error) => {
                Outcome::Error { kind: ErrorKind::from(&error), message: error.to_string() }
            }
        }
    }
}

impl Vector {
    /// Why the translation does not give what the vector expects, if it does not.
    pub fn problem(&self) -> Option<String> {
        self.mismatch(&self.translation.run())
    }

    /// Why `outcome` is not what the vector expects, if it is not.
    pub fn mismatch(&self, outcome: &Outcome) -> Option<String> {
        let matches = match (&self.expect, outcome) {
            (Expect::Bytes(want), Outcome::Output(got)) => want == got,
            (Expect::Json(want), Outcome::Output(got)) => {
                serde_json::from_str::<Value>(got).is_ok_and(|got| &got == want)
            }
            (Expect::Error(want), Outcome::Error { kind, .. }) => want == kind,
            _ => false,
        };
        (!matches).then(|| {
            let expect = serde_json::to_string(&self.expect).unwrap_or_default();
            let got = serde_json::to_string(outcome).unwrap_or_default();
            format!("vector {}: got {got}, the fixture expects {expect}", self.id)
        })
    }
}

/// A vector id: `[a-z0-9][a-z0-9-]{0,63}`.
fn is_slug(id: &str) -> bool {
    let bytes = id.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0] != b'-'
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// Every problem with the vectors of `fixtures`: ids that are not unique
/// slugs, and translations that give something else.
pub fn check_vectors(fixtures: &Fixtures) -> Vec<String> {
    let mut problems = Vec::new();
    let mut seen = HashSet::new();
    for vector in &fixtures.vectors {
        if !is_slug(&vector.id) {
            problems.push(format!(
                "vector {:?}: the id is not a [a-z0-9][a-z0-9-]{{0,63}} slug",
                vector.id
            ));
        }
        if !seen.insert(vector.id.as_str()) {
            problems.push(format!("vector {}: the id repeats", vector.id));
        }
        problems.extend(vector.problem());
    }
    problems
}

/// One message written at `from`, as a reader at `to` must receive it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    /// Message kind (`request:<cmd>`, `response:<cmd>`, `event:<name>`).
    pub message: String,
    /// The writer's revision.
    pub from: u32,
    /// The reader's revision.
    pub to: u32,
    /// The message as written.
    pub input: Value,
    /// The message as the reader must see it.
    pub output: Value,
}

impl Case {
    fn crosses(&self, message: &str, rev: u32, up: bool) -> bool {
        self.message == message
            && if up {
                self.from < rev && rev <= self.to
            } else {
                self.to < rev && rev <= self.from
            }
    }
}

/// Every problem with `fixtures` against `schema`: cases that translate to
/// something else, and changes that no case crosses in some direction.
pub fn check_fixtures(schema: &Schema, fixtures: &Fixtures) -> Vec<String> {
    let mut problems = Vec::new();
    let compat = match Compat::new(schema.clone()) {
        Ok(compat) => compat,
        Err(error) => return vec![error.to_string()],
    };
    for (index, case) in fixtures.cases.iter().enumerate() {
        let input = case.input.to_string().into_bytes();
        match compat.translate(&case.message, case.from, case.to, &input) {
            Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                Ok(got) if got == case.output => {}
                Ok(got) => problems.push(format!(
                    "case {index} ({} {}->{}): got {got}, fixture says {}",
                    case.message, case.from, case.to, case.output
                )),
                Err(error) => problems.push(format!("case {index}: output is not JSON: {error}")),
            },
            Err(error) => problems.push(format!("case {index} ({}): {error}", case.message)),
        }
    }
    for revision in &schema.revisions {
        for change in &revision.changes {
            for (up, word) in [(true, "upgrade"), (false, "downgrade")] {
                if !fixtures
                    .cases
                    .iter()
                    .any(|case| case.crosses(&change.message, revision.rev, up))
                {
                    problems.push(format!(
                        "revision {} {} {}: no fixture case crosses it ({word})",
                        revision.rev,
                        change.message,
                        change.change.path()
                    ));
                }
            }
        }
    }
    problems
}
