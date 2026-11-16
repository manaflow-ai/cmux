//! Each classic workspace's name and key.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use crate::limits::objects;

/// The longest workspace name the daemon takes, in UTF-8 bytes.
pub const MAX_NAME_BYTES: usize = 1024;
/// The folder name used when a workspace's folder has none.
const UNNAMED: &str = "Imported workspace";

/// The first of `names` that holds a string.
pub fn text<'a>(value: &'a Map<String, Value>, names: &[&str]) -> Option<&'a str> {
    names.iter().find_map(|name| value.get(*name).and_then(Value::as_str))
}

/// The first of `names` that holds a non-empty string.
pub fn non_empty<'a>(value: &'a Map<String, Value>, names: &[&str]) -> Option<&'a str> {
    text(value, names).filter(|text| !text.is_empty())
}

/// Space and tab trimmed, as classic's reader trims (newlines kept).
pub fn trim_spaces(text: &str) -> &str {
    let space = |c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    };
    text.trim_matches(space)
}

/// A workspace's folder (`currentDirectory`), `home` when it names none.
pub fn directory(value: &Map<String, Value>, home: &str) -> String {
    text(value, &["currentDirectory", "current_directory"]).unwrap_or(home).to_string()
}

/// What can tell a classic workspace apart, most telling first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Clues {
    pub custom: Option<String>,
    /// Process and tab titles that are more than a path: a running command
    /// or a tab's title.
    pub titles: Vec<String>,
    pub agent: Option<String>,
    pub branch: Option<String>,
    pub folder: String,
}

pub fn clues(value: &Map<String, Value>, home: &str) -> Clues {
    let panels = objects(value.get("panels")).unwrap_or_default();
    let mut raw = vec![value.get("processTitle")];
    for panel in &panels {
        raw.push(panel.get("customTitle"));
        raw.push(panel.get("title"));
    }
    let titles = raw
        .into_iter()
        .filter_map(|title| title.and_then(Value::as_str).map(trim_spaces))
        .filter(|title| {
            !title.is_empty()
                && *title != "~"
                && !title.starts_with("~/")
                && !title.starts_with('/')
        })
        .map(str::to_string)
        .collect();
    let agent = panels
        .iter()
        .filter_map(|panel| panel.get("terminal")?.get("agent")?.get("kind")?.as_str())
        .find(|kind| !kind.is_empty())
        .map(str::to_string);
    let branch = std::iter::once(value)
        .chain(panels.iter().copied())
        .filter_map(|item| item.get("gitBranch")?.get("branch")?.as_str())
        .find(|branch| !branch.is_empty())
        .map(str::to_string);
    let folder = directory(value, home);
    let folder = folder.trim_end_matches('/');
    let folder = match folder.rsplit('/').next() {
        Some(last) if !folder.is_empty() && !last.is_empty() => last.to_string(),
        _ => UNNAMED.to_string(),
    };
    Clues {
        custom: non_empty(value, &["customTitle"]).map(str::to_string),
        titles,
        agent,
        branch,
        folder,
    }
}

/// The person's own title; else a running command or tab title, the agent
/// it ran, or the folder's name. Names several workspaces share take each
/// one's branch, and a number only as the last resort.
pub fn names(clues: &[Clues]) -> Vec<String> {
    // Room left for a branch or a number, so the final name fits the daemon's limit.
    let mut names: Vec<String> = clues
        .iter()
        .map(|clue| {
            let name = clue
                .custom
                .as_ref()
                .or(clue.titles.first())
                .or(clue.agent.as_ref())
                .unwrap_or(&clue.folder);
            fitting(name, MAX_NAME_BYTES - 128)
        })
        .collect();
    let mut counts: HashMap<String, usize> = HashMap::new();
    for name in &names {
        *counts.entry(name.clone()).or_default() += 1;
    }
    for (name, clue) in names.iter_mut().zip(clues) {
        if counts.get(name.as_str()).is_some_and(|count| *count > 1)
            && clue.custom.is_none()
            && let Some(branch) = clue.branch.as_ref().filter(|branch| *branch != name)
        {
            name.push_str(" · ");
            name.push_str(branch);
        }
        // Cut before numbering, with room for ` <n>`, so a number always tells two apart.
        *name = fitting(name, MAX_NAME_BYTES - NUMBER_ROOM);
    }
    let mut used: HashSet<String> = HashSet::new();
    let mut next: HashMap<String, usize> = HashMap::new();
    names
        .into_iter()
        .map(|name| {
            let count = next.entry(name.clone()).or_insert(1);
            let mut numbered = if *count == 1 { name.clone() } else { format!("{name} {count}") };
            // A number another workspace already has as its own name is skipped.
            while !used.insert(numbered.clone()) {
                *count += 1;
                numbered = format!("{name} {count}");
            }
            *count += 1;
            numbered
        })
        .collect()
}

/// Room kept after a name for ` <n>`; a run has at most 1,000 workspaces.
const NUMBER_ROOM: usize = 16;

/// `name` cut at a character so it takes at most `bytes` UTF-8 bytes.
pub fn fitting(name: &str, bytes: usize) -> String {
    if name.len() <= bytes {
        return name.to_string();
    }
    name.char_indices()
        .take_while(|(index, character)| index + character.len_utf8() <= bytes)
        .map(|(_, character)| character)
        .collect()
}

/// The workspace's identity across classic saves: `stableId`, else
/// `workspaceId`, else (a very old snapshot) an FNV-1a digest of its folder,
/// its name and its panel ids.
pub fn key(value: &Map<String, Value>, name: &str, home: &str) -> String {
    // The first field holding a non-empty string wins.
    let id = ["stableId", "stable_id", "workspaceId", "workspace_id"]
        .iter()
        .find_map(|field| value.get(*field).and_then(Value::as_str).filter(|id| !id.is_empty()));
    if let Some(id) = id {
        return id.to_string();
    }
    let panels = objects(value.get("panels")).unwrap_or_default();
    let mut parts = vec![directory(value, home), name.to_string()];
    parts.extend(panels.iter().filter_map(|panel| panel.get("id")?.as_str().map(str::to_string)));
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in parts.join("\u{1f}").bytes() {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
    }
    format!("derived:{hash:x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clue(title: &str, branch: Option<&str>) -> Clues {
        Clues {
            custom: None,
            titles: vec![title.into()],
            agent: None,
            branch: branch.map(str::to_string),
            folder: "f".into(),
        }
    }

    #[test]
    fn shared_names_take_their_branch_then_a_number() {
        let names = names(&[
            clue("vim", Some("main")),
            clue("vim", Some("dev")),
            clue("vim", None),
            clue("zsh", Some("x")),
        ]);
        assert_eq!(names, ["vim · main", "vim · dev", "vim", "zsh"]);
        let names = super::names(&[clue("vim", None), clue("vim", None)]);
        assert_eq!(names, ["vim", "vim 2"]);
    }

    #[test]
    fn a_name_over_the_daemons_limit_is_cut_at_a_character_and_stays_unique() {
        let long = "é".repeat(800);
        let names = names(&[clue(&long, None), clue(&long, None)]);
        assert!(names.iter().all(|name| name.len() <= MAX_NAME_BYTES));
        assert_eq!(names[0].len(), 896);
        assert_ne!(names[0], names[1]);
    }

    /// Two long names that differ only past the limit still come out different.
    #[test]
    fn names_cut_at_the_limit_stay_unique() {
        let long = "x".repeat(1_000);
        let (a, b) = (format!("{}a", "b".repeat(200)), format!("{}b", "b".repeat(200)));
        let names = names(&[
            clue(&long, Some(&a)),
            clue(&long, Some(&b)),
            clue("vim 2", None),
            clue("vim", None),
            clue("vim", None),
        ]);
        assert!(names.iter().all(|name| name.len() <= MAX_NAME_BYTES));
        assert_ne!(names[0], names[1]);
        assert_eq!(names[2..], ["vim 2", "vim", "vim 3"]);
    }

    #[test]
    fn path_titles_are_not_names_and_the_folder_is_the_last_resort() {
        let value: Value = serde_json::json!({
            "currentDirectory": "/Users/me/proj/",
            "processTitle": "~/proj",
            "panels": [{"title": "/bin/zsh"}, {"title": "  "}]
        });
        let clues = clues(value.as_object().unwrap(), "/Users/me");
        assert!(clues.titles.is_empty());
        assert_eq!(clues.folder, "proj");
        let root: Value = serde_json::json!({"currentDirectory": "/"});
        assert_eq!(super::clues(root.as_object().unwrap(), "/h").folder, UNNAMED);
    }
}
