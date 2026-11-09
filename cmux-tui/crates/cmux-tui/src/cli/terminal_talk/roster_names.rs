//! What `terminal list --agents` adds to each roster row: the agent's name
//! (its tab's name, when that is a valid agent name), the tab and pane that
//! show it, and the agent's last reply (`extra.last_reply` of its agent
//! record, folded to one line and cut to 200 characters by the daemon). It
//! also prints one word per harness and source (agent_vocabulary.rs).
//! Pure: the caller reads the snapshot.

use std::collections::HashMap;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::super::agent_names::valid_agent_name;
use super::super::agent_vocabulary::{harness_name, source_name};
use super::roster::{self, AgentRow};

/// The tab that shows one terminal.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct TabFacts {
    pub tab_id: Option<String>,
    pub tab_name: Option<String>,
    pub pane_id: Option<String>,
    pub last_reply: Option<String>,
}

impl TabFacts {
    /// The agent name: the tab name when it follows the agent name grammar.
    pub(in crate::cli) fn name(&self) -> Option<&str> {
        self.tab_name.as_deref().filter(|name| valid_agent_name(name).is_ok())
    }
}

fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|text| !text.is_empty()).map(str::to_owned)
}

/// Each terminal's [`TabFacts`], by terminal id.
pub(in crate::cli) fn facts(snapshot: &Value) -> HashMap<String, TabFacts> {
    let list = |key: &str| snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default();
    let tabs: HashMap<&str, &Value> =
        list("tabs").iter().filter_map(|tab| Some((tab["id"].as_str()?, tab))).collect();
    let replies: HashMap<&str, String> = list("agents")
        .iter()
        .filter_map(|agent| {
            Some((agent["terminal_id"].as_str()?, text(agent.pointer("/extra/last_reply")?)?))
        })
        .collect();
    list("terminals")
        .iter()
        .filter_map(|terminal| {
            let id = terminal["id"].as_str()?;
            let tab = terminal["tab_id"]
                .as_str()
                .and_then(|tab| tabs.get(tab))
                .or_else(|| tabs.values().find(|tab| tab["content_id"] == id));
            let facts = TabFacts {
                tab_id: tab.and_then(|tab| text(&tab["id"])),
                tab_name: tab.and_then(|tab| text(&tab["name"])),
                pane_id: tab.and_then(|tab| text(&tab["pane_id"])),
                last_reply: replies.get(id).cloned(),
            };
            Some((id.to_owned(), facts))
        })
        .collect()
}

/// The roster rows of `snapshot`, with canonical harness and source words.
pub(in crate::cli) fn rows(snapshot: &Value) -> Vec<AgentRow> {
    let mut rows = roster::agent_rows(snapshot);
    for row in &mut rows {
        row.harness = harness_name(&row.harness);
        row.source = source_name(&row.source);
    }
    rows
}

/// One row as JSON: the roster's fields plus `name`, `tab_id`, `tab_name`,
/// `pane_id` and `last_reply` (null when unknown).
pub(in crate::cli) fn row_json(
    row: &AgentRow,
    facts: &HashMap<String, TabFacts>,
    now_ms: u64,
) -> Value {
    let mut value = row.to_json(now_ms);
    let known = facts.get(&row.terminal).cloned().unwrap_or_default();
    value.set("name", json!(known.name()));
    value.set("tab_id", json!(known.tab_id));
    value.set("tab_name", json!(known.tab_name));
    value.set("pane_id", json!(known.pane_id));
    value.set("last_reply", json!(known.last_reply));
    value
}

/// Longest NAME cell the table prints.
const NAME_WIDTH: usize = 32;

/// The roster's table with a NAME column first and a REPLY column last
/// (the first line of the agent's last reply, `-` when there is none).
pub(in crate::cli) fn table(
    rows: &[AgentRow],
    facts: &HashMap<String, TabFacts>,
    now_ms: u64,
) -> String {
    let names: Vec<String> = rows
        .iter()
        .map(|row| {
            let known = facts.get(&row.terminal);
            known
                .and_then(TabFacts::name)
                .map(str::to_owned)
                .unwrap_or_else(|| "-".to_owned())
                .chars()
                .take(NAME_WIDTH)
                .collect()
        })
        .collect();
    let width = names.iter().map(|name| name.chars().count()).max().unwrap_or(0).max(4);
    let replies = rows.iter().map(|row| {
        facts
            .get(&row.terminal)
            .and_then(|known| known.last_reply.as_deref())
            .map_or_else(|| "-".to_owned(), reply_cell)
    });
    let body = roster::table(rows, now_ms);
    let lines: Vec<String> = body
        .lines()
        .zip(std::iter::once("NAME".to_owned()).chain(names))
        .map(|(line, name)| {
            let pad = width.saturating_sub(name.chars().count());
            format!("{name}{}  {line}", " ".repeat(pad))
        })
        .collect();
    let body_width = lines.iter().map(|line| line.chars().count()).max().unwrap_or(0);
    lines
        .iter()
        .zip(std::iter::once("REPLY".to_owned()).chain(replies))
        .map(|(line, reply)| {
            let pad = body_width.saturating_sub(line.chars().count());
            format!("{line}{}  {reply}", " ".repeat(pad))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Longest REPLY cell the table prints, ellipsis included.
const REPLY_WIDTH: usize = 60;

/// The REPLY cell: the first non-blank line of the agent's last reply,
/// control characters made inert, cut at [`REPLY_WIDTH`].
fn reply_cell(reply: &str) -> String {
    let line = reply.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or("-");
    let clean: String = line.chars().map(|c| if c.is_control() { '\u{fffd}' } else { c }).collect();
    if clean.chars().count() <= REPLY_WIDTH {
        return clean;
    }
    let mut cut: String = clean.chars().take(REPLY_WIDTH - 1).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
#[path = "roster_names_tests.rs"]
mod tests;
