//! Every recipe page of the extension-author skill (skills/cmux-extension-author/recipes), copied
//! as written into an empty folder, passes `cmux ext dev --once`: validated, built by bun against
//! the SDK built into the CLI, loaded and rendered once by the real QuickJS app host, and its
//! first scene shows the words the page's `<!-- recipe-check: shows "..." -->` line names. The
//! validator half, with no bun, is `cmux-app-manifest`'s `tests/recipes.rs`.

use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;

use super::daemon::Daemon;
use super::dev::{self, Phase};
use super::tests::{FakeDaemon, dev_options, global};

fn recipes_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../skills/cmux-extension-author/recipes")
}

/// The page's files: each fenced block whose info string names a path (```json cmux-app.json).
fn files(page: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut lines = page.lines();
    while let Some(line) = lines.next() {
        let Some(info) = line.strip_prefix("```") else { continue };
        let mut words = info.split_whitespace();
        let (Some(_lang), path) = (words.next(), words.next()) else { continue };
        let body: Vec<&str> = lines.by_ref().take_while(|l| !l.starts_with("```")).collect();
        if let Some(path) = path {
            out.push((path.to_string(), body.join("\n") + "\n"));
        }
    }
    out
}

/// The words the page says its first scene shows, when it names some.
fn shows(page: &str) -> Option<&str> {
    let rest = page.split("<!-- recipe-check: shows \"").nth(1)?;
    rest.split('"').next()
}

fn run(name: &str, page: &str, root: &Path, bun: &Path) -> Result<(), String> {
    let dir = root.join(name);
    for (path, text) in files(page) {
        let target = dir.join(&path);
        std::fs::create_dir_all(target.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(target, text).map_err(|e| e.to_string())?;
    }
    let manifest: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("cmux-app.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let id = manifest["id"].as_str().ok_or("no id")?.to_string();
    let fake = FakeDaemon::start_hosting(&root.join("state/apps/local"), &id);
    let mut options = dev_options(&dir);
    options.bun = Some(bun.to_path_buf());
    let (sender, wakes) = channel();
    let daemon = Daemon::connect(&global(&fake.socket), sender, wakes)?;
    let mut session = dev::Session::new(dir, &options, daemon);
    let outcome = session.reload(true);
    if outcome.phase != Phase::Done {
        return Err(format!("phase {:?}: {:?}", outcome.phase, outcome.errors));
    }
    if let Some(words) = shows(page) {
        let scene = outcome.scene.join("\n");
        if !scene.contains(words) {
            return Err(format!("the first scene does not show {words:?}:\n{scene}"));
        }
    }
    Ok(())
}

#[test]
fn every_recipe_passes_ext_dev_once_as_written() {
    let Some(bun) = dev::find_bun() else {
        eprintln!("SKIPPED: bun is not on PATH; the recipes are TypeScript, which bun builds");
        return;
    };
    let mut pages: Vec<PathBuf> = std::fs::read_dir(recipes_dir())
        .expect("recipes folder")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    pages.sort();
    assert!(pages.len() >= 9, "{pages:?}");
    let mut problems = Vec::new();
    for page in &pages {
        let name = page.file_stem().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(page).unwrap();
        let root = tempfile::tempdir().unwrap();
        match run(&name, &text, root.path(), &bun) {
            Ok(()) => eprintln!("recipe {name}: ext dev --once passes"),
            Err(problem) => problems.push(format!("{name}: {problem}")),
        }
    }
    assert!(problems.is_empty(), "\n{}", problems.join("\n"));
}

/// The same pages with no cmux running: `ext dev --once --headless` validates, builds, loads and
/// renders each in this process, and its first scene shows the page's words. This is what the
/// scheduled copy-paste prompt check (`scripts/cmux-next/ext-recipe-cold-model.py --prompts`) runs.
#[test]
fn every_recipe_passes_ext_dev_once_headless() {
    let Some(bun) = dev::find_bun() else {
        eprintln!("SKIPPED: bun is not on PATH; the recipes are TypeScript, which bun builds");
        return;
    };
    let mut problems = Vec::new();
    for entry in std::fs::read_dir(recipes_dir()).expect("recipes folder") {
        let page = entry.unwrap().path();
        if page.extension().is_none_or(|x| x != "md") {
            continue;
        }
        let name = page.file_stem().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&page).unwrap();
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join(&name);
        for (path, body) in files(&text) {
            let target = dir.join(&path);
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::write(target, body).unwrap();
        }
        let mut options = dev_options(&dir);
        options.bun = Some(bun.clone());
        options.headless = true;
        let outcome = dev::once(&global(&root.path().join("no-daemon.sock")), &options, false);
        if outcome.phase != Phase::Done {
            problems.push(format!("{name}: phase {:?}: {:?}", outcome.phase, outcome.errors));
            continue;
        }
        if let Some(words) = shows(&text) {
            let scene = outcome.scene.join("\n");
            if !scene.contains(words) {
                problems
                    .push(format!("{name}: the headless scene does not show {words:?}:\n{scene}"));
            }
        }
    }
    assert!(problems.is_empty(), "\n{}", problems.join("\n"));
}
