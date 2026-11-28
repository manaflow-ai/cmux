//! Resolve display membership once per opening. Late metadata cannot regroup a seed.
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

const GUESSED: &str = "\0repo:";
static NULL: Value = Value::Null;
/// `value[key]` without the panicking `Index`: Null when absent or not an object.
pub(super) fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&NULL)
}
/// `value[key] = new` for an object; a non-object is left as is.
pub(super) fn set(value: &mut Value, key: &str, new: Value) {
    if let Some(object) = value.as_object_mut() {
        object.insert(key.to_owned(), new);
    }
}
fn row(rows: &[Value], index: usize) -> &Value {
    rows.get(index).unwrap_or(&NULL)
}
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    field(value, key).as_str().unwrap_or_default()
}
fn key(repo: &Value) -> String {
    if let Some(github) = field(repo, "github").as_str().filter(|s| !s.is_empty()) {
        format!("\0github:{}", github.to_lowercase())
    } else {
        text(repo, "root").to_owned()
    }
}
fn guess(cwd: &str) -> Option<Value> {
    let mut parts = cwd.trim_end_matches('/').rsplit('/');
    let (Some(last), Some(parent), Some(grand)) = (parts.next(), parts.next(), parts.next()) else {
        return None;
    };
    // The fourth part from the end, when the path has one.
    let great = parts.next();
    let (name, branch) = if (great == Some(".cmux")
        && matches!(grand, "worktrees" | "worktrees.noindex"))
        || (great == Some("conductor") && grand == "workspaces")
    {
        (parent, Some(last.to_owned()))
    } else if great == Some(".codex") && grand == "worktrees" {
        (last, None)
    } else if parent == ".worktrees" {
        (grand, Some(last.to_owned()))
    } else if let Some(great) = great.filter(|_| grand == ".claude" && parent == "worktrees") {
        (great, Some(last.to_owned()))
    } else if grand == "checkouts" {
        (parent, Some(last.replace("--", "/")))
    } else if let Some(name) = parent.strip_suffix("-worktrees") {
        (name, Some(last.to_owned()))
    } else if great == Some("wt") && grand == "lanes" {
        (last, Some(parent.to_owned()))
    } else {
        return None;
    };
    let mut repo = json!({"root":format!("{GUESSED}{}", name.to_lowercase()),"name":name});
    if let Some(branch) = branch {
        set(&mut repo, "branch", json!(branch));
    }
    Some(repo)
}
fn scratch(cwd: &str) -> bool {
    cwd.split('/').any(|p| p.ends_with(".noindex"))
        || cwd.contains("/.wt-mirrors/")
        || cwd.contains("/.cache/")
        || ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
            .iter()
            .any(|s| cwd.starts_with(s))
}
pub fn freeze(rows: &mut [Value], current: Option<&str>) {
    let mut by_name: HashMap<String, Option<Value>> = HashMap::new();
    let mut checkouts = HashMap::new();
    for row in rows.iter() {
        let repo = field(row, "repo");
        if !repo.is_object() {
            continue;
        }
        let name = text(repo, "name").to_lowercase();
        by_name
            .entry(name)
            .and_modify(|old| {
                if old.as_ref().is_some_and(|old| key(old) != key(repo)) {
                    *old = None;
                }
            })
            .or_insert_with(|| Some(repo.clone()));
        let root = text(repo, "root").trim_end_matches('/');
        let top = field(repo, "top").as_str().unwrap_or(root).trim_end_matches('/');
        checkouts.entry(top.to_owned()).or_insert_with(|| repo.clone());
        let mut main = repo.clone();
        if let Some(object) = main.as_object_mut() {
            object.remove("branch");
        }
        set(&mut main, "top", json!(root));
        checkouts.entry(root.to_owned()).or_insert(main);
    }
    for row in rows.iter_mut().filter(|row| row.get("displayGroup").is_none()) {
        if field(row, "repo").is_object() {
            continue;
        }
        let cwd = text(row, "cwd");
        let mut ancestor = cwd;
        let mut resolved = None;
        while !ancestor.is_empty() {
            if let Some(repo) = checkouts.get(ancestor) {
                resolved = Some(repo.clone());
                break;
            }
            ancestor = ancestor.rsplit_once('/').map_or("", |p| p.0);
        }
        if resolved.is_none() {
            resolved = guess(cwd).map(|guessed| {
                if let Some(Some(named)) = by_name.get(&text(&guessed, "name").to_lowercase()) {
                    let mut repo = named.clone();
                    if let Some(object) = repo.as_object_mut() {
                        object.remove("top");
                        object.remove("branch");
                    }
                    if field(&guessed, "branch").is_string() {
                        set(&mut repo, "branch", field(&guessed, "branch").clone());
                    }
                    repo
                } else {
                    guessed
                }
            });
        }
        if let Some(repo) = resolved {
            set(row, "repo", repo);
        }
    }
    let guessed: HashSet<String> = rows
        .iter()
        .filter_map(|row| {
            let root = text(field(row, "repo"), "root");
            root.starts_with(GUESSED).then(|| root.to_owned())
        })
        .collect();
    let mut groups: Vec<(String, Vec<usize>)> = Vec::new();
    let mut indexes = HashMap::new();
    let mut seeds = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        let cwd = text(row, "cwd");
        let group = field(row, "displayGroup");
        let group_key = if group.is_object() {
            seeds.entry(text(group, "key").to_owned()).or_insert_with(|| group.clone());
            text(group, "key").to_owned()
        } else if field(row, "repo").is_object() {
            key(field(row, "repo"))
        } else {
            let named = format!("{GUESSED}{}", text(row, "label").to_lowercase());
            if guessed.contains(&named) { named } else { cwd.to_owned() }
        };
        let position = *indexes.entry(group_key.clone()).or_insert_with(|| {
            groups.push((group_key, Vec::new()));
            groups.len() - 1
        });
        if let Some((_, members)) = groups.get_mut(position) {
            members.push(index);
        }
    }
    for (group_key, members) in groups {
        let main = members
            .iter()
            .copied()
            .find(|&i| text(row(rows, i), "cwd") == text(field(row(rows, i), "repo"), "root"));
        let selected =
            members.iter().copied().find(|&i| Some(text(row(rows, i), "cwd")) == current);
        let selected_root = selected.map(|i| text(field(row(rows, i), "repo"), "root"));
        let selected_main = members.iter().copied().find(|&i| {
            Some(text(row(rows, i), "cwd")) == selected_root
                && text(row(rows, i), "cwd") == text(field(row(rows, i), "repo"), "root")
        });
        let plain = members.iter().copied().find(|&i| !field(row(rows, i), "repo").is_object());
        let Some(&first) = members.first() else { continue };
        let lead = selected.or(selected_main).or(main).or(plain).unwrap_or(first);
        let main_lead = selected_main.or(main).or(plain).or(selected).unwrap_or(first);
        let repo = members.iter().map(|&i| field(row(rows, i), "repo")).find(|r| r.is_object());
        let mut group = seeds.get(&group_key).cloned().unwrap_or_else(|| {
            json!({
                "key":group_key,"name":repo.map_or(text(row(rows, lead), "label"), |r| text(r,"name")),
                "lead":text(row(rows, lead),"cwd"),"mainLead":text(row(rows, main_lead),"cwd"),
                "github":repo.and_then(|r| field(r, "github").as_str())
            })
        });
        // A removed lead is replaced in its existing group slot; additions never steal it.
        for (name, fallback) in [("lead", lead), ("mainLead", main_lead)] {
            if !members.iter().any(|&i| text(row(rows, i), "cwd") == text(&group, name)) {
                set(&mut group, name, field(row(rows, fallback), "cwd").clone());
            }
        }
        for index in members {
            let Some(row) = rows.get_mut(index) else { continue };
            let cwd = text(row, "cwd");
            let hidden = Some(cwd) != current
                && (super::new_tab_projects::is_home(cwd)
                    || (!field(row, "repo").is_object() && scratch(cwd)));
            let mut display = group.clone();
            set(&mut display, "hidden", json!(hidden));
            set(row, "displayGroup", display);
        }
    }
}
