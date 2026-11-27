//! Resolve display membership once per opening. Late metadata cannot regroup a seed.
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

const GUESSED: &str = "\0repo:";
fn text<'a>(value: &'a Value, key: &str) -> &'a str { value[key].as_str().unwrap_or_default() }
fn key(repo: &Value) -> String {
    if let Some(github) = repo["github"].as_str().filter(|s| !s.is_empty()) {
        format!("\0github:{}", github.to_lowercase())
    } else { text(repo, "root").to_owned() }
}
fn guess(cwd: &str) -> Option<Value> {
    let parts: Vec<_> = cwd.trim_end_matches('/').split('/').collect();
    let n = parts.len();
    if n < 3 { return None; }
    let last = parts[n - 1];
    let parent = parts[n - 2];
    let grand = parts[n - 3];
    let (name, branch) = if n >= 4 && ((parts[n - 4] == ".cmux" && matches!(grand, "worktrees" | "worktrees.noindex")) || (parts[n - 4] == "conductor" && grand == "workspaces")) {
        (parent, Some(last.to_owned()))
    } else if n >= 4 && parts[n - 4] == ".codex" && grand == "worktrees" {
        (last, None)
    } else if parent == ".worktrees" { (grand, Some(last.to_owned()))
    } else if n >= 4 && grand == ".claude" && parent == "worktrees" { (parts[n - 4], Some(last.to_owned()))
    } else if grand == "checkouts" { (parent, Some(last.replace("--", "/")))
    } else if let Some(name) = parent.strip_suffix("-worktrees") { (name, Some(last.to_owned()))
    } else if n >= 4 && parts[n - 4] == "wt" && grand == "lanes" { (last, Some(parent.to_owned()))
    } else { return None; };
    let mut repo = json!({"root":format!("{GUESSED}{}", name.to_lowercase()),"name":name});
    if let Some(branch) = branch { repo["branch"] = json!(branch); }
    Some(repo)
}
fn scratch(cwd: &str) -> bool {
    cwd.split('/').any(|p| p.ends_with(".noindex")) || cwd.contains("/.wt-mirrors/") || cwd.contains("/.cache/") ||
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].iter().any(|s| cwd.starts_with(s))
}
pub fn freeze(rows: &mut [Value], current: Option<&str>) {
    let mut by_name: HashMap<String, Option<Value>> = HashMap::new();
    let mut checkouts = HashMap::new();
    for row in rows.iter() {
        let repo = &row["repo"];
        if !repo.is_object() { continue; }
        let name = text(repo, "name").to_lowercase();
        by_name.entry(name).and_modify(|old| {
            if old.as_ref().is_some_and(|old| key(old) != key(repo)) { *old = None; }
        }).or_insert_with(|| Some(repo.clone()));
        let root = text(repo, "root").trim_end_matches('/');
        let top = repo["top"].as_str().unwrap_or(root).trim_end_matches('/');
        checkouts.entry(top.to_owned()).or_insert_with(|| repo.clone());
        let mut main = repo.clone();
        if let Some(object) = main.as_object_mut() { object.remove("branch"); }
        main["top"] = json!(root);
        checkouts.entry(root.to_owned()).or_insert(main);
    }
    for row in rows.iter_mut().filter(|row| row.get("displayGroup").is_none()) {
        if row["repo"].is_object() { continue; }
        let cwd = text(row, "cwd");
        let mut ancestor = cwd;
        let mut resolved = None;
        while !ancestor.is_empty() {
            if let Some(repo) = checkouts.get(ancestor) { resolved = Some(repo.clone()); break; }
            ancestor = ancestor.rsplit_once('/').map_or("", |p| p.0);
        }
        if resolved.is_none() {
            resolved = guess(cwd).map(|guessed| {
                if let Some(Some(named)) = by_name.get(&text(&guessed, "name").to_lowercase()) {
                    let mut repo = named.clone();
                    if let Some(object) = repo.as_object_mut() { object.remove("top"); object.remove("branch"); }
                    if guessed["branch"].is_string() { repo["branch"] = guessed["branch"].clone(); }
                    repo
                } else { guessed }
            });
        }
        if let Some(repo) = resolved { row["repo"] = repo; }
    }
    let guessed: HashSet<String> = rows.iter().filter_map(|row| {
        let root = text(&row["repo"], "root"); root.starts_with(GUESSED).then(|| root.to_owned())
    }).collect();
    let mut groups: Vec<(String, Vec<usize>)> = Vec::new();
    let mut indexes = HashMap::new();
    let mut seeds = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        let cwd = text(row, "cwd");
        let group = &row["displayGroup"];
        let group_key = if group.is_object() {
            seeds.entry(text(group, "key").to_owned()).or_insert_with(|| group.clone());
            text(group, "key").to_owned()
        } else if row["repo"].is_object() { key(&row["repo"]) }
        else {
            let named = format!("{GUESSED}{}", text(row, "label").to_lowercase());
            if guessed.contains(&named) { named } else { cwd.to_owned() }
        };
        let position = *indexes.entry(group_key.clone()).or_insert_with(|| { groups.push((group_key, Vec::new())); groups.len() - 1 });
        groups[position].1.push(index);
    }
    for (group_key, members) in groups {
        let main = members.iter().copied().find(|&i| text(&rows[i], "cwd") == text(&rows[i]["repo"], "root"));
        let selected = members.iter().copied().find(|&i| Some(text(&rows[i], "cwd")) == current);
        let plain = members.iter().copied().find(|&i| !rows[i]["repo"].is_object());
        let first = members[0];
        let lead = selected.or(main).or(plain).unwrap_or(first);
        let main_lead = main.or(plain).or(selected).unwrap_or(first);
        let repo = members.iter().map(|&i| &rows[i]["repo"]).find(|r| r.is_object());
        let mut group = seeds.get(&group_key).cloned().unwrap_or_else(|| json!({
            "key":group_key,"name":repo.map_or(text(&rows[lead], "label"), |r| text(r,"name")),
            "lead":text(&rows[lead],"cwd"),"mainLead":text(&rows[main_lead],"cwd"),
            "github":repo.and_then(|r| r["github"].as_str())
        }));
        // A removed lead is replaced in its existing group slot; additions never steal it.
        for (field, fallback) in [("lead",lead),("mainLead",main_lead)] {
            if !members.iter().any(|&i| text(&rows[i],"cwd") == text(&group,field)) { group[field] = rows[fallback]["cwd"].clone(); }
        }
        for index in members {
            let row = &mut rows[index];
            let cwd = text(row,"cwd");
            let hidden = Some(cwd) != current && (super::new_tab_projects::is_home(cwd) || (!row["repo"].is_object() && scratch(cwd)));
            row["displayGroup"] = group.clone();
            row["displayGroup"]["hidden"] = json!(hidden);
        }
    }
}
