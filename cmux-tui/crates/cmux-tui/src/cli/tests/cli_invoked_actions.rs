//! Every app action the CLI's own code runs by CLI name (`ActionName::Cli`: `run_action`,
//! `action_run_params`, `run_cli_action`, `cmux mcp`'s `.action(...)`, the names a match picks
//! for them, and `cmux vm`'s short verbs) must be a catalog action with that CLI name that the
//! CLI is offered (`Action::cli`). A name the catalog renamed, dropped or made GUI-only is
//! otherwise found by a person: `cmux vm new` made the machine and then said
//! "No CLI command 'cloud open-machine'".
//!
//! The names are read from the crate's source, so a new call site is checked with no list to
//! keep: a string literal at such a call site, shaped like a CLI name (lowercase words) and
//! starting with a catalog noun, is one.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use regex::Regex;

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap_or_else(|error| panic!("{}: {error}", dir.display()))
    {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// A file's code with comments dropped, whitespace collapsed and an inline `mod tests { ... }`
/// at its end cut off: a test's own literals are not call sites.
fn code_of(text: &str) -> String {
    let line_comment = Regex::new(r"//[^\n]*").unwrap();
    let space = Regex::new(r"\s+").unwrap();
    let code = space.replace_all(&line_comment.replace_all(text, ""), " ").into_owned();
    match code.find("#[cfg(test)] mod tests {") {
        Some(at) => code[..at].to_owned(),
        None => code,
    }
}

/// The CLI names the crate's non-test code runs by CLI name, each with the files that do.
fn cli_invoked_action_names() -> BTreeMap<String, BTreeSet<String>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rust_sources(&root, &mut files);
    let nouns: BTreeSet<&str> = cmux_action_catalog::actions()
        .filter_map(|action| action.cli_name.split(' ').next())
        .filter(|noun| !noun.is_empty())
        .collect();
    let shape = Regex::new(r"^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*){1,2}$").unwrap();
    let sites = [
        // `run_action("cloud exec", ...)`, `action_run_params("cloud list-machines", ...)`
        Regex::new(r#"(?:run_action|action_run_params)\( ?"([^"]+)""#).unwrap(),
        // `run_cli_action(&global, "cloud new-machine", ...)`
        Regex::new(r#"run_cli_action\([^,()]*, ?"([^"]+)""#).unwrap(),
        // `const ACTION: &str = "home primary-chief";` in a file that runs actions by CLI name
        Regex::new(r#"const [A-Z_]+: &str = "([^"]+)""#).unwrap(),
        // `.action("cloud file-read", ActionName::Cli, ...)`
        Regex::new(r#"\.action\( ?"([^"]+)" ?, ?ActionName::Cli"#).unwrap(),
        // a match arm that picks the name: `Some("open") => ("agent open", ...)`,
        // `Noun::Pane => "pane screenshot"`, `"tab" => "tab move-to-space"`
        Regex::new(r#"=> \(? ?"([^"]+)""#).unwrap(),
    ];
    // `("space switch", vec![...], ActionName::Cli)`: tried at each literal's own start, so
    // `"rename", old, new] => ("space rename", ...` finds both (one match must not swallow the next).
    let tuple = Regex::new(r#"^"([^"]+)" ?,[^;{}]{0,200}?ActionName::Cli"#).unwrap();
    let mut names: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for file in files {
        let relative = file.strip_prefix(&root).unwrap().display().to_string();
        if relative.contains("test") {
            continue;
        }
        let code = code_of(&std::fs::read_to_string(&file).unwrap());
        if !code.contains("ActionName::Cli") && !code.contains("run_cli_action(") {
            continue;
        }
        let mut add = |name: &str| {
            names.entry(name.to_owned()).or_default().insert(relative.clone());
        };
        for (at, _) in code.match_indices('"') {
            if let Some(found) = tuple.captures(&code[at..]) {
                add(&found[1]);
            }
        }
        for site in &sites {
            for found in site.captures_iter(&code) {
                add(&found[1]);
            }
        }
    }
    // `cmux vm pause dev` runs `cloud pause-machine` (vm_short.rs's table).
    for (_, long) in super::super::vm_short::VERBS {
        names.entry(format!("cloud {long}")).or_default().insert("cli/vm_short.rs".to_owned());
    }
    names.retain(|name, _| {
        shape.is_match(name) && name.split(' ').next().is_some_and(|noun| nouns.contains(noun))
    });
    names
}

#[test]
fn every_action_the_cli_runs_by_cli_name_is_a_cli_action_in_the_catalog() {
    let names = cli_invoked_action_names();
    // The scan still sees the call sites it was written for; a refactor that hides them from it
    // fails here instead of passing with nothing checked.
    for known in [
        "cloud exec",
        "cloud file-read",
        "home invite-to-team",
        "home primary-chief",
        "cloud new-machine",
        "cloud pause-machine",
        "space switch",
        "space rename",
        "agent open",
        "pane screenshot",
        "workspace move-to-space",
    ] {
        assert!(names.contains_key(known), "the scan no longer finds `{known}`: {names:?}");
    }
    let mut broken = Vec::new();
    for (name, files) in &names {
        let action = cmux_action_catalog::actions().find(|action| action.cli_name == name);
        match action {
            None => {
                broken.push(format!("`{name}` ({files:?}): no catalog action has this CLI name"))
            }
            Some(action) if !action.cli() => broken.push(format!(
                "`{name}` ({files:?}): `{}` is not offered to the CLI ({:?}), so the app answers \
                 \"No CLI command\"",
                action.id, action.surface_plan.cli
            )),
            Some(_) => {}
        }
    }
    assert!(broken.is_empty(), "the CLI runs actions it cannot:\n{}", broken.join("\n"));
}
