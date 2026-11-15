//! A workspace row's own layout (`sidebar_row_layout`): the person writes which lines a sidebar
//! row draws and what each line says, as token rows, and can give one kind of workspace or one
//! agent its own layout (CMUX-383, Leo: "Sidebar customization (look at [reference] and [reference])").
//!
//! The settings, all optional and absent by default, so a row draws exactly as before:
//!
//! - `sidebar.workspaceRow.lines`: the layout for every row, e.g.
//!   `[["icon", "name", "branch"], ["agentStatus"]]`.
//! - `sidebar.workspaceRow.linesByKind`: `{ "agent": [...], "terminal": [...] }`, by the row's
//!   kind (`terminal`, `agent`, `browser`, `mixed`, the kinds of `sidebar.workspaceRow.<kind>.*`).
//! - `sidebar.workspaceRow.linesByAgent`: `{ "claude": [...], "codex": [...] }`, by the canonical
//!   id of the agent the row's front tab runs.
//!
//! The most specific layout wins: the agent's, then the kind's, then `lines`. With none of them
//! set (`custom` false) the row keeps the element switches and `secondLineOrder` it has today.
//!
//! The tokens are the row's elements (`WorkspaceRowElement` in the app) plus `name`. Three of
//! them are slots, not text: `icon` is the leading icon, `working` the trailing working mark and
//! `progress` the bar under the row; where they are written does not move them, it only turns
//! them on. Every other token is text and draws on its line in the written order.
//!
//! Rules, so any value a person or an agent writes still draws a row:
//!
//! - The name is always on the first line. Written on a later line it moves to the start of the
//!   first; left out, it is put there.
//! - A token shows once: a repeat is dropped.
//! - At most [`MAX_LINES`] lines and [`MAX_TOKENS`] text tokens on a line; an empty line is
//!   dropped.
//! - An unknown token, a value that is not a list of lists, or a token that is not a string is
//!   skipped. Each of these is reported in `problems` with where it is, so Settings and
//!   `cmux settings validate` can say what was ignored; a layout that is not a list at all
//!   falls through to the next one.
//!
//! Pure and bounded: one call reads at most [`MAX_LINES`] x [`MAX_SCANNED`] entries of the chosen
//! layout, whatever was written, so a row costs the same with a two-token layout and a
//! ten-thousand-token one. Settings hot reload: the app resolves again when a setting changes,
//! once per (kind, agent) pair it draws, never once per row.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The most lines a row draws.
pub const MAX_LINES: usize = 3;
/// The most text tokens on one line.
pub const MAX_TOKENS: usize = 6;
/// The most entries of one written line that are read; the rest are reported, never walked.
pub const MAX_SCANNED: usize = 16;

/// Every token, in the order the app's element list has them.
pub const TOKENS: &[&str] = &[
    "icon",
    "name",
    "working",
    "progress",
    "notification",
    "directory",
    "branch",
    "process",
    "agentStatus",
    "tabCount",
    "ports",
    "lastActivity",
    "pullRequest",
    "log",
];

/// The tokens that turn a fixed slot on instead of drawing on a line.
pub const SLOTS: &[&str] = &["icon", "working", "progress"];

/// The setting keys this resolves, for the problems' `at`.
pub const KEY_LINES: &str = "sidebar.workspaceRow.lines";
pub const KEY_BY_KIND: &str = "sidebar.workspaceRow.linesByKind";
pub const KEY_BY_AGENT: &str = "sidebar.workspaceRow.linesByAgent";

/// One row to resolve: the three settings as written (absent or null when unset) and the row's
/// kind and agent.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    #[serde(default)]
    pub lines: Option<Value>,
    #[serde(default)]
    pub lines_by_kind: Option<Value>,
    #[serde(default)]
    pub lines_by_agent: Option<Value>,
    /// `terminal`, `agent`, `browser` or `mixed`.
    #[serde(default)]
    pub kind: Option<String>,
    /// The canonical agent id (`claude`, `codex`, ...), none when the row runs no agent.
    #[serde(default)]
    pub agent: Option<String>,
}

/// Which slots are on.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Slots {
    pub icon: bool,
    pub working: bool,
    pub progress: bool,
}

/// A value that was skipped, and where.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Problem {
    /// The setting key and the path inside it, e.g. `sidebar.workspaceRow.lines[1][0]`.
    pub at: String,
    /// `unknownToken`, `notAString`, `notALine`, `notALayout`, `repeated`, `nameMoved`,
    /// `tooManyLines`, `tooManyTokens`.
    pub why: &'static str,
    /// The token, when there is one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

/// The row's layout.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Response {
    /// A layout setting applies to this row. False: the row keeps today's element switches, and
    /// `lines` and `slots` are empty.
    pub custom: bool,
    /// Which setting it came from: `agent`, `kind` or `all`; none when `custom` is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<&'static str>,
    /// The text tokens of each line, the name first on the first line.
    pub lines: Vec<Vec<&'static str>>,
    pub slots: Slots,
    /// What the chosen layout and the layouts it passed over had that was skipped.
    pub problems: Vec<Problem>,
}

fn known(token: &str) -> Option<&'static str> {
    TOKENS.iter().copied().find(|t| *t == token)
}

/// The written layout for `key` in a by-kind or by-agent map, with its `at` prefix.
fn entry<'a>(
    map: Option<&'a Value>,
    setting: &str,
    key: Option<&str>,
    problems: &mut Vec<Problem>,
) -> Option<(&'a Value, String)> {
    let map = map.filter(|v| !v.is_null())?;
    let Some(map): Option<&Map<String, Value>> = map.as_object() else {
        problems.push(Problem { at: setting.to_owned(), why: "notALayout", token: None });
        return None;
    };
    let key = key?;
    map.get(key).filter(|v| !v.is_null()).map(|v| (v, format!("{setting}.{key}")))
}

/// Resolves one row's layout.
pub fn respond(request: &Request) -> Response {
    let mut problems = Vec::new();
    let candidates = [
        (
            "agent",
            entry(
                request.lines_by_agent.as_ref(),
                KEY_BY_AGENT,
                request.agent.as_deref(),
                &mut problems,
            ),
        ),
        (
            "kind",
            entry(
                request.lines_by_kind.as_ref(),
                KEY_BY_KIND,
                request.kind.as_deref(),
                &mut problems,
            ),
        ),
        ("all", request.lines.as_ref().filter(|v| !v.is_null()).map(|v| (v, KEY_LINES.to_owned()))),
    ];
    for (source, candidate) in candidates {
        let Some((value, at)) = candidate else { continue };
        let Some(written) = value.as_array() else {
            problems.push(Problem { at, why: "notALayout", token: None });
            continue;
        };
        let mut response = layout(written, &at, &mut problems);
        response.source = Some(source);
        response.problems = problems;
        return response;
    }
    Response { problems, ..Response::default() }
}

/// One written layout (a list of lines) to lines and slots.
fn layout(written: &[Value], at: &str, problems: &mut Vec<Problem>) -> Response {
    let mut slots = Slots::default();
    let mut lines: Vec<Vec<&'static str>> = Vec::new();
    let mut seen: Vec<&'static str> = Vec::new();
    let mut name_on_first = false;
    if written.len() > MAX_LINES {
        problems.push(Problem {
            at: format!("{at}[{MAX_LINES}]"),
            why: "tooManyLines",
            token: None,
        });
    }
    for (l, line) in written.iter().take(MAX_LINES).enumerate() {
        let Some(line) = line.as_array() else {
            problems.push(Problem { at: format!("{at}[{l}]"), why: "notALine", token: None });
            continue;
        };
        let mut out: Vec<&'static str> = Vec::new();
        for (t, token) in line.iter().take(MAX_SCANNED).enumerate() {
            let here = || format!("{at}[{l}][{t}]");
            let Some(text) = token.as_str() else {
                problems.push(Problem { at: here(), why: "notAString", token: None });
                continue;
            };
            let Some(token) = known(text) else {
                problems.push(Problem {
                    at: here(),
                    why: "unknownToken",
                    token: Some(text.to_owned()),
                });
                continue;
            };
            if seen.contains(&token) {
                problems.push(Problem {
                    at: here(),
                    why: "repeated",
                    token: Some(token.to_owned()),
                });
                continue;
            }
            seen.push(token);
            match token {
                "icon" => slots.icon = true,
                "working" => slots.working = true,
                "progress" => slots.progress = true,
                "name" => {
                    if lines.is_empty() {
                        name_on_first = true;
                        out.push(token);
                    } else {
                        problems.push(Problem { at: here(), why: "nameMoved", token: None });
                    }
                }
                _ if out.iter().filter(|t| **t != "name").count() >= MAX_TOKENS => {
                    problems.push(Problem {
                        at: here(),
                        why: "tooManyTokens",
                        token: Some(token.to_owned()),
                    });
                }
                _ => out.push(token),
            }
        }
        if line.len() > MAX_SCANNED {
            problems.push(Problem {
                at: format!("{at}[{l}][{MAX_SCANNED}]"),
                why: "tooManyTokens",
                token: None,
            });
        }
        if !out.is_empty() {
            lines.push(out);
        }
    }
    if !name_on_first {
        // The name leads the first line when the person wrote it elsewhere or left it out. The
        // first line then holds the name and at most MAX_TOKENS other tokens: the name is never
        // the token that is cut.
        match lines.first_mut() {
            Some(first) if !first.contains(&"name") => first.insert(0, "name"),
            Some(_) => {}
            None => lines.push(vec!["name"]),
        }
    }
    Response { custom: true, source: None, lines, slots, problems: Vec::new() }
}

#[cfg(test)]
#[path = "sidebar_row_layout_tests.rs"]
mod tests;
