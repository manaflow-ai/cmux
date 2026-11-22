//! `cmux live start --rust --build-host H` sends a build host cmux-tui/ and what its build reads
//! outside it: `scripts/cmux-next/rust-live.py inputs` computes that from the source (each
//! `include_str!`/`include_bytes!` target, each path a build script names, path dependencies,
//! submodules). A fresh worktree's build failed on the host when that set was a fixed list
//! (design-tokens.json and the ghostty-next submodule were never sent).
//!
//! This test checks the computed set against cargo's own record of what the build that made this
//! test read: the dep-info rustc wrote for each workspace crate (every source file and every
//! included file) and each build script's `rerun-if-changed` paths. A new outside include the
//! computation misses fails here, naming the file.
#![cfg(unix)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap()
}

/// Workspace package name -> its folder, from `cargo metadata --no-deps`.
fn workspace_packages(workspace: &Path) -> BTreeMap<String, PathBuf> {
    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let out = Command::new(cargo)
        .args(["metadata", "--format-version", "1", "--no-deps", "--offline"])
        .current_dir(workspace)
        .output()
        .expect("cargo metadata runs");
    assert!(out.status.success(), "cargo metadata: {}", String::from_utf8_lossy(&out.stderr));
    let meta: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    meta["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|package| {
            let manifest = PathBuf::from(package["manifest_path"].as_str().unwrap());
            (package["name"].as_str().unwrap().to_owned(), manifest.parent().unwrap().to_owned())
        })
        .collect()
}

/// `name-<hash>` -> `name`.
fn stem(file_name: &str) -> &str {
    file_name.rsplit_once('-').map_or(file_name, |(name, _)| name)
}

fn modified(path: &Path) -> SystemTime {
    path.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH)
}

/// The newest entry per name among `paths` (a crate built more than once keeps old hashes around).
fn newest<'a>(paths: impl Iterator<Item = (String, PathBuf)>) -> BTreeMap<String, PathBuf> {
    let mut newest: BTreeMap<String, PathBuf> = BTreeMap::new();
    for (name, path) in paths {
        match newest.get(&name) {
            Some(kept) if modified(kept) >= modified(&path) => {}
            _ => {
                newest.insert(name, path);
            }
        }
    }
    newest
}

/// The paths after the first `:` on each line of a dep-info file (spaces in a path are `\ `).
fn dep_info_paths(text: &str) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for line in text.lines().filter(|line| !line.starts_with('#')) {
        let Some((_, deps)) = line.split_once(": ") else { continue };
        let mut current = String::new();
        let mut chars = deps.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '\\' if chars.peek() == Some(&' ') => current.push(chars.next().unwrap()),
                ' ' => paths.extend((!current.is_empty()).then(|| PathBuf::from(&current))),
                c => current.push(c),
            }
            if c == ' ' {
                current.clear();
            }
        }
        paths.extend((!current.is_empty()).then(|| PathBuf::from(&current)));
    }
    paths
}

/// What cargo recorded that the workspace's build read: (file, the record that names it).
fn cargo_recorded_reads(workspace: &Path) -> Vec<(PathBuf, PathBuf)> {
    let packages = workspace_packages(workspace);
    let crates: BTreeSet<String> = packages.keys().map(|name| name.replace('-', "_")).collect();
    let exe = std::env::current_exe().unwrap();
    let deps = exe.parent().unwrap();
    let profile = deps.parent().unwrap();
    let mut reads = Vec::new();

    let dep_infos = std::fs::read_dir(deps).unwrap().filter_map(|entry| {
        let path = entry.ok()?.path();
        let name = path.file_name()?.to_str()?;
        let crate_name = stem(name.strip_suffix(".d")?);
        // Workspace crates only: a registry crate's includes stay in the registry.
        crates.contains(crate_name).then(|| (crate_name.to_owned(), path.clone()))
    });
    for (_, file) in newest(dep_infos) {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        // Cargo runs rustc in the workspace root with workspace paths relative to it, so the
        // dep-info names `crates/x/src/../../../../schemas/y.json`: relative to the workspace.
        reads.extend(
            dep_info_paths(&text).into_iter().map(|path| (workspace.join(path), file.clone())),
        );
    }

    let outputs =
        std::fs::read_dir(profile.join("build")).into_iter().flatten().filter_map(|entry| {
            let folder = entry.ok()?.path();
            let output = folder.join("output");
            let package = stem(folder.file_name()?.to_str()?).to_owned();
            (packages.contains_key(&package) && output.is_file()).then_some((package, output))
        });
    for (package, output) in newest(outputs) {
        let text = std::fs::read_to_string(&output).unwrap_or_default();
        for line in text.lines() {
            let Some(path) = line
                .strip_prefix("cargo::rerun-if-changed=")
                .or_else(|| line.strip_prefix("cargo:rerun-if-changed="))
            else {
                continue;
            };
            // A relative path is relative to the package's folder.
            reads.push((packages[&package].join(path), output.clone()));
        }
    }
    reads
}

/// What rust-live.py sends a build host besides cmux-tui/, from the repo root.
fn computed_inputs(root: &Path) -> Vec<String> {
    let out = Command::new("python3")
        .arg(root.join("scripts/cmux-next/rust-live.py"))
        .args(["inputs", "--json", "--worktree"])
        .arg(root)
        .output()
        .expect("python3 runs scripts/cmux-next/rust-live.py");
    assert!(out.status.success(), "rust-live.py inputs: {}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).expect("rust-live.py inputs --json prints a list")
}

#[test]
fn rust_live_sends_every_outside_input() {
    let root = repo_root();
    let workspace = root.join("cmux-tui");
    let target = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();
    let mut outside = BTreeMap::new();
    for (path, record) in cargo_recorded_reads(&workspace) {
        let Ok(path) = path.canonicalize() else { continue }; // a file since removed
        if !path.starts_with(&root) || path.starts_with(&workspace) || path.starts_with(&target) {
            continue;
        }
        // Git's own files (acpmux-build-id reruns on HEAD) say which commit, not what to build.
        if path.components().any(|part| part.as_os_str() == ".git") {
            continue;
        }
        let rel = path.strip_prefix(&root).unwrap().to_string_lossy().into_owned();
        outside.entry(rel).or_insert(record);
    }
    // The build of this test embeds the settings schema (cmux-config's include_str!) at least: without
    // it the dep-info was not read, not that nothing is included.
    assert!(
        outside.keys().any(|rel| rel.starts_with("schemas/")),
        "cargo's dep-info names no schemas/ file outside cmux-tui/; found {outside:?}"
    );

    let inputs = computed_inputs(&root);
    let covered = |rel: &str| {
        inputs.iter().any(|entry| rel == entry || rel.starts_with(&format!("{entry}/")))
    };
    let missed: Vec<String> = outside
        .iter()
        .filter(|(rel, _)| !covered(rel))
        .map(|(rel, record)| format!("{rel} (read per {})", record.display()))
        .collect();
    assert!(
        missed.is_empty(),
        "the build reads these outside cmux-tui/, and `rust-live.py inputs` (what `cmux live start \
         --rust --build-host` sends) misses them; teach outside_reads() in \
         scripts/cmux-next/rust-live.py the form that names them:\n  {}",
        missed.join("\n  ")
    );
}

#[test]
fn dep_info_lines_split_on_unescaped_spaces() {
    let text = "/t/deps/x.d: /r/a.rs /r/with\\ space.json\n\n/r/a.rs:\n# env-dep:X=1\n";
    assert_eq!(
        dep_info_paths(text),
        vec![PathBuf::from("/r/a.rs"), PathBuf::from("/r/with space.json")]
    );
}
