//! Every web route the app bundles is served from a layer too. A layer
//! carries only the archive folders in [`SURFACES`]; any other web folder the
//! app bundles is served from the bundle with the layer on, so a PR's change
//! to it never shows in `cmux customize use pr:N` (Agent Activity was one).
//! These read the repository: the folders build-web-bundles.sh writes, the
//! folders marked as build output (GENERATED.md), and every React page.

use super::SURFACES;
use std::path::{Path, PathBuf};

/// The repository root (this crate is cmux-tui/crates/cmux-tui).
fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read(path: &str) -> String {
    std::fs::read_to_string(repo().join(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

fn is_surface(folder: &str) -> bool {
    let folder = format!("{}/", folder.trim_end_matches('/'));
    SURFACES.iter().any(|(prefix, _)| *prefix == folder)
}

/// Output folders that are not the app's to serve, and why.
const NOT_APP_PAGES: [(&str, &str); 1] = [(
    "Native/OptChat/optchat-chief/inspector",
    "optchat-chief compiles the memory inspector into its own binary",
)];

/// The output folders build-web-bundles.sh names (`NAME="path"` under its
/// "The output paths" comment): every web bundle the app build ships.
fn bundle_outputs() -> Vec<String> {
    let script = read("scripts/cmux-next/build-web-bundles.sh");
    let block = script
        .split_once("# The output paths")
        .expect("build-web-bundles.sh lists its output paths")
        .1;
    let mut found = Vec::new();
    for line in block.lines().skip(1) {
        let Some((name, value)) = line.split_once('=') else { break };
        if !name.chars().all(|c| c.is_ascii_uppercase() || c == '_') {
            break;
        }
        let value = value.trim_matches('"');
        if value.starts_with('$') {
            break;
        }
        found.push(value.to_owned());
    }
    assert!(found.len() >= 4, "read too few outputs from build-web-bundles.sh: {found:?}");
    found
}

#[test]
fn every_web_bundle_the_app_ships_is_a_layer_surface() {
    for output in bundle_outputs() {
        if NOT_APP_PAGES.iter().any(|(path, _)| *path == output) {
            continue;
        }
        assert!(
            is_surface(&output),
            "{output} is bundled in the app but no layer surface: with a layer on, its pages \
             load from the bundle (add it to SURFACES and dir.rs BUILDERS)"
        );
    }
}

#[test]
fn every_folder_marked_as_build_output_is_a_layer_surface() {
    let sources = repo().join("Packages/macOS/CmuxNext/Sources");
    let mut marked = Vec::new();
    for module in std::fs::read_dir(&sources).unwrap().filter_map(Result::ok) {
        let Ok(resources) = std::fs::read_dir(module.path().join("Resources")) else { continue };
        for folder in resources.filter_map(Result::ok) {
            if folder.path().join("GENERATED.md").is_file() {
                let relative = folder.path().strip_prefix(repo()).unwrap().to_path_buf();
                marked.push(relative.to_string_lossy().into_owned());
            }
        }
    }
    assert!(marked.len() >= 3, "found too few bundled web folders: {marked:?}");
    for folder in marked {
        assert!(is_surface(&folder), "{folder} is bundled web output but no layer surface");
    }
}

/// The pages build-pages-web.sh builds (its `PAGES` lists).
fn built_pages() -> Vec<String> {
    let script = read("scripts/cmux-next/build-pages-web.sh");
    let mut pages = Vec::new();
    let mut in_list = false;
    for line in script.lines() {
        let line = line.trim();
        if line == "PAGES=\"" {
            in_list = true;
        } else if in_list && line == "\"" {
            in_list = false;
        } else if in_list {
            pages.push(line.to_owned());
        } else if let Some(rest) = line.strip_prefix("PAGES=\"$PAGES ") {
            pages.extend(rest.trim_end_matches('"').split_whitespace().map(str::to_owned));
        }
    }
    pages
}

#[test]
fn every_react_page_route_is_built_into_the_pages_surface() {
    assert!(is_surface("Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"));
    let built = built_pages();
    let pages = repo().join("webviews/src/pages");
    let mut routes = Vec::new();
    for page in std::fs::read_dir(&pages).unwrap().filter_map(Result::ok) {
        if page.path().join("index.html").is_file() {
            routes.push(page.file_name().to_string_lossy().into_owned());
        }
    }
    assert!(routes.len() >= 30, "found too few page routes: {routes:?}");
    assert!(routes.iter().any(|route| route == "onboarding"), "{routes:?}");
    for route in routes {
        assert!(
            built.contains(&route),
            "webviews/src/pages/{route} has an entry but build-pages-web.sh does not build it, \
             so neither the app nor a layer serves it"
        );
    }
}
