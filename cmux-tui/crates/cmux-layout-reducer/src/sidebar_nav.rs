//! `sidebar.nav`: the nav block a look may put at the top of the sidebar (a Codex-style column of
//! plain icon and label rows that run cmux actions: New chat, Search, Pull requests, ...).
//!
//! The setting is a list of strings, each `action.id` or `action.id | Title | sf.symbol` (the title
//! and the symbol are optional, either may be left empty). Rust owns the rules: each id must name a
//! catalog action (a legacy id becomes its canonical one), debug-only and destructive actions, and
//! any whose id quits, closes, clears, resets or removes, are
//! refused (a look must not plant a one-click Quit or Close All), a duplicate keeps its first row,
//! and titles and symbols are bounded. The native view maps the rows it gets and runs the action on
//! a click; an empty list (the default) draws no block, exactly today's sidebar.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The most rows the block draws (Codex shows six or seven).
pub const MAX_ROWS: usize = 12;
/// The most characters of an entry, a title, and a symbol name.
const MAX_ENTRY: usize = 256;
const MAX_TITLE: usize = 48;
const MAX_SYMBOL: usize = 64;

#[derive(Debug, Default, Deserialize)]
pub struct Request {
    /// The raw `sidebar.nav` value (absent: null).
    #[serde(default)]
    pub nav: Value,
}

#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub struct Reply {
    pub rows: Vec<Row>,
    pub problems: Vec<Problem>,
}

/// One nav row: the canonical action id, and the look's title and symbol when it set them (the
/// view otherwise draws the action's own localized title and symbol).
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Row {
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub path: String,
    pub why: String,
}

const PATH: &str = "sidebar.nav";

pub fn respond(request: &Request) -> Reply {
    let mut reply = Reply::default();
    let items = match &request.nav {
        Value::Null => return reply,
        Value::Array(items) => items,
        _ => {
            reply.problems.push(problem(PATH.into(), "expected a list of action ids"));
            return reply;
        }
    };
    for (index, item) in items.iter().enumerate() {
        let path = format!("{PATH}[{index}]");
        if reply.rows.len() == MAX_ROWS {
            reply.problems.push(problem(
                path,
                &format!("ignored: the nav block holds at most {MAX_ROWS} rows"),
            ));
            continue;
        }
        match row(item) {
            Ok(row) if reply.rows.iter().any(|seen| seen.action == row.action) => {
                reply.problems.push(problem(path, "duplicate action; keeping the first row"));
            }
            Ok(row) => reply.rows.push(row),
            Err(why) => reply.problems.push(problem(path, &why)),
        }
    }
    reply
}

/// The words of an action id that quit, close, end or remove something. Most such catalog actions
/// (`quit`, `closeAllWindows`, `workspace.closeAll`, `palette.auth.signOut`, ...) are not marked
/// `is_destructive`, so the id's own words are checked too: a look must not plant any of them as
/// a one-click row.
const ENDS_OR_REMOVES: &[&str] = &[
    "quit",
    "close",
    "kill",
    "delete",
    "remove",
    "clear",
    "reset",
    "uninstall",
    "restart",
    "terminate",
    "discard",
    "signout",
    "logout",
];

/// Whether ID has one of [`ENDS_OR_REMOVES`] as a whole camelCase or dotted word (`reopenClosed`
/// keeps `closed`, a different word), or `sign`/`log` followed by `out`.
fn ends_or_removes(id: &str) -> bool {
    let mut words: Vec<String> = Vec::new();
    for segment in id.split(['.', '_', '-']) {
        let mut word = String::new();
        for c in segment.chars() {
            if c.is_uppercase() && !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
            word.extend(c.to_lowercase());
        }
        if !word.is_empty() {
            words.push(word);
        }
    }
    words.iter().any(|w| ENDS_OR_REMOVES.contains(&w.as_str()))
        || words.windows(2).any(|pair| {
            matches!(pair, [first, second] if (first == "sign" || first == "log") && second == "out")
        })
}

fn problem(path: String, why: &str) -> Problem {
    Problem { path, why: why.into() }
}

fn row(item: &Value) -> Result<Row, String> {
    let entry =
        item.as_str().ok_or("expected a string: an action id, or \"id | Title | symbol\"")?;
    if entry.chars().count() > MAX_ENTRY {
        return Err(format!("expected at most {MAX_ENTRY} characters"));
    }
    let mut parts = entry.split('|').map(str::trim);
    let id = parts.next().unwrap_or_default();
    let title = parts.next().filter(|text| !text.is_empty());
    let symbol = parts.next().filter(|text| !text.is_empty());
    if parts.next().is_some() {
        return Err("expected at most three parts: \"id | Title | symbol\"".into());
    }
    if id.is_empty() {
        return Err("expected an action id".into());
    }
    let action = cmux_action_catalog::find(id)
        .ok_or_else(|| format!("no action {id:?} (`cmux action list` names them)"))?;
    if action.is_debug_only {
        return Err(format!("{id:?} is a debug action; the nav block runs only everyday actions"));
    }
    if action.is_destructive || ends_or_removes(action.id) {
        return Err(format!("{id:?} is destructive; the nav block never runs it in one click"));
    }
    if let Some(title) = title
        && (title.chars().count() > MAX_TITLE || title.chars().any(char::is_control))
    {
        return Err(format!("expected a one-line title of at most {MAX_TITLE} characters"));
    }
    if let Some(symbol) = symbol {
        let shaped = symbol.len() <= MAX_SYMBOL
            && symbol.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.')
            && !symbol.starts_with('.')
            && !symbol.ends_with('.');
        if !shaped {
            return Err("expected an SF Symbol name such as \"square.and.pencil\"".into());
        }
    }
    Ok(Row {
        action: action.id.into(),
        title: title.map(Into::into),
        symbol: symbol.map(Into::into),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn reply(nav: Value) -> Reply {
        respond(&Request { nav })
    }

    #[test]
    fn absent_or_empty_draws_no_block() {
        assert_eq!(reply(Value::Null), Reply::default());
        assert_eq!(reply(json!([])), Reply::default());
    }

    #[test]
    fn ids_titles_and_symbols_parse() {
        let got = reply(json!([
            "palette.newAgentChat | New chat | square.and.pencil",
            "search.chats|Search",
            "automations.show",
            "appStore.show | | puzzlepiece",
        ]));
        assert!(got.problems.is_empty(), "{:?}", got.problems);
        let rows: Vec<_> = got
            .rows
            .iter()
            .map(|r| (r.action.as_str(), r.title.as_deref(), r.symbol.as_deref()))
            .collect();
        assert_eq!(
            rows,
            [
                ("palette.newAgentChat", Some("New chat"), Some("square.and.pencil")),
                ("search.chats", Some("Search"), None),
                ("automations.show", None, None),
                ("appStore.show", None, Some("puzzlepiece")),
            ]
        );
    }

    #[test]
    fn a_legacy_id_becomes_its_canonical_one() {
        let (old, new) = cmux_action_catalog::tables::LEGACY_ALIASES
            .iter()
            .find(|(_, new)| {
                cmux_action_catalog::find(new).is_some_and(|a| {
                    !a.is_debug_only && !a.is_destructive && !ends_or_removes(a.id)
                })
            })
            .expect("a legacy alias to an everyday action");
        let got = reply(json!([old]));
        assert_eq!(got.rows.first().map(|r| r.action.as_str()), Some(*new));
    }

    #[test]
    fn bad_entries_are_dropped_with_a_reason_and_the_rest_draw() {
        let destructive = cmux_action_catalog::actions()
            .find(|a| a.is_destructive)
            .expect("a destructive action")
            .id;
        let got = reply(json!([
            "no.such.action",
            7,
            destructive,
            "home.show | Home | Bad Symbol",
            "home.show | a | b | c",
            "home.show",
            "home.show | Again",
            "",
        ]));
        assert_eq!(got.rows.len(), 1);
        assert_eq!(got.rows[0].action, "home.show");
        let paths: Vec<_> = got.problems.iter().map(|p| p.path.as_str()).collect();
        assert_eq!(
            paths,
            [
                "sidebar.nav[0]",
                "sidebar.nav[1]",
                "sidebar.nav[2]",
                "sidebar.nav[3]",
                "sidebar.nav[4]",
                "sidebar.nav[6]",
                "sidebar.nav[7]"
            ]
        );
        assert!(got.problems[2].why.contains("destructive"));
        assert!(got.problems[5].why.contains("duplicate"));
    }

    #[test]
    fn not_a_list_and_too_many_rows_are_bounded() {
        assert_eq!(reply(json!("home.show")).problems[0].path, "sidebar.nav");
        let everyday: Vec<_> = cmux_action_catalog::actions()
            .filter(|a| !a.is_debug_only && !a.is_destructive && !ends_or_removes(a.id))
            .take(MAX_ROWS + 3)
            .map(|a| a.id)
            .collect();
        let got = reply(json!(everyday));
        assert_eq!(got.rows.len(), MAX_ROWS);
        // Each dropped entry gets its own diagnostic, not just the first past the limit.
        let paths: Vec<_> = got.problems.iter().map(|p| p.path.clone()).collect();
        assert_eq!(paths, ["sidebar.nav[12]", "sidebar.nav[13]", "sidebar.nav[14]"]);
        assert!(got.problems.iter().all(|p| p.why.contains("at most")));
    }

    #[test]
    fn actions_that_quit_close_or_remove_are_refused_even_when_not_marked_destructive() {
        let got = reply(json!([
            "quit",
            "closeAllWindows",
            "workspace.closeAll",
            "palette.auth.signOut",
            "quitEndSessions",
            "home.show",
        ]));
        assert_eq!(got.rows.len(), 1, "{:?}", got.problems);
        assert_eq!(got.rows[0].action, "home.show");
        assert_eq!(got.problems.len(), 5);
        assert!(got.problems.iter().all(|p| p.why.contains("destructive")));
    }

    #[test]
    fn the_word_test_reads_whole_words() {
        assert!(ends_or_removes("closeAllWindows"));
        assert!(ends_or_removes("palette.auth.signOut"));
        assert!(!ends_or_removes("reopenClosedWorkspace"));
        assert!(!ends_or_removes("palette.newAgentChat"));
        assert!(!ends_or_removes("appearance.customize"));
    }

    #[test]
    fn a_long_title_is_refused() {
        let got = reply(json!([format!("home.show | {}", "x".repeat(MAX_TITLE + 1))]));
        assert!(got.rows.is_empty());
        assert!(got.problems[0].why.contains("title"));
    }
}
