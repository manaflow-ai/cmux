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

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Compat, Schema};

/// The fixture file.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fixtures {
    /// Every case, in any order.
    #[serde(default)]
    pub cases: Vec<Case>,
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
