//! The conformance suite's trees (`exec_conformance.rs`): the fixture checkout each case starts
//! from ([`write_fixture`]), and what a case left behind ([`tree_of`]: every path, its kind, mode
//! and content hash, but the [`EXEMPT`] ones).

use std::collections::BTreeMap;
use std::path::Path;

use sha2::{Digest as _, Sha256};

use super::exec_conformance::EXEMPT;

/// One path of a tree: its kind and mode, and its content's hash (a symlink: its target).
fn entry_of(path: &Path) -> std::io::Result<String> {
    let meta = std::fs::symlink_metadata(path)?;
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt as _;
        meta.permissions().mode() & 0o7777
    };
    #[cfg(not(unix))]
    let mode = if meta.permissions().readonly() { 0o444 } else { 0o644 };
    Ok(if meta.file_type().is_symlink() {
        format!("link -> {}", std::fs::read_link(path)?.to_string_lossy())
    } else if meta.is_dir() {
        format!("dir {mode:o}")
    } else {
        let digest = Sha256::digest(std::fs::read(path)?);
        format!("file {mode:o} {}", hex(&digest))
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Every path under `root` but the [`EXEMPT`] ones, `/`-separated, with [`entry_of`]'s entry.
/// Folders count too: an empty folder one side made and the other did not is a difference.
pub fn tree_of(root: &Path) -> std::io::Result<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    let mut stack = vec![(root.to_owned(), String::new())];
    while let Some((dir, rel)) = stack.pop() {
        for e in std::fs::read_dir(&dir)? {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            if rel.is_empty() && EXEMPT.iter().any(|(x, _)| *x == name) {
                continue;
            }
            let rel = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            let path = e.path();
            let entry = entry_of(&path)?;
            if entry.starts_with("dir ") {
                stack.push((path, rel.clone()));
            }
            out.insert(rel, entry);
        }
    }
    Ok(out)
}

/// One hash for a whole [`tree_of`].
pub fn tree_digest(tree: &BTreeMap<String, String>) -> String {
    let mut h = Sha256::new();
    for (path, entry) in tree {
        h.update(path.as_bytes());
        h.update([0]);
        h.update(entry.as_bytes());
        h.update([b'\n']);
    }
    hex(&h.finalize())
}

/// The paths whose entries differ between two trees (one side only, or not the same).
pub fn tree_diff(a: &BTreeMap<String, String>, b: &BTreeMap<String, String>) -> Vec<String> {
    let mut paths: Vec<String> = Vec::new();
    for (path, entry) in a {
        if b.get(path) != Some(entry) {
            paths.push(path.clone());
        }
    }
    for path in b.keys() {
        if !a.contains_key(path) {
            paths.push(path.clone());
        }
    }
    paths.sort();
    paths
}

/// The fixture's files: (path, contents). `tool.sh` starts not executable; a case sets its bit.
const FIXTURE: &[(&str, &str)] = &[
    (".gitignore", "target/\n"),
    (
        "Cargo.toml",
        "[package]\nname = \"conformance-fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n\
         # Its own workspace, wherever it is written.\n[workspace]\n",
    ),
    (
        "src/lib.rs",
        "pub fn add(a: u32, b: u32) -> u32 {\n    a + b\n}\n\n#[cfg(test)]\nmod tests {\n    \
         #[test]\n    fn adds() {\n        assert_eq!(super::add(2, 2), 4);\n    }\n}\n",
    ),
    ("notes.txt", "notes, deleted by a case\n"),
    ("data/old.txt", "renamed by a case\n"),
    ("data/keep.txt", "keeps data/ from going empty\n"),
    ("tool.sh", "#!/bin/sh\necho tool\n"),
    ("scratch/a.txt", "removed with its folder\n"),
    ("edited.txt", "committed line\n"),
];

fn git(dir: &Path, args: &[&str]) -> anyhow::Result<()> {
    let out = cmux_process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=conformance", "-c", "user.email=conformance@cmux.invalid"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(cmux_process::Stdio::null())
        .output()?;
    anyhow::ensure!(
        out.status.success(),
        "git {}: {}",
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(())
}

/// Write the fixture checkout at `dir`: committed files, then an edit and a new file left
/// uncommitted (the snapshot a run VM starts from must carry them).
pub fn write_fixture(dir: &Path) -> anyhow::Result<()> {
    crate::home_fs::create_dirs(dir)?;
    for (rel, text) in FIXTURE {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            crate::home_fs::create_dirs(parent)?;
            checkout_mode(parent, 0o755)?;
        }
        crate::home_fs::write(&path, text)?;
        checkout_mode(&path, 0o644)?;
    }
    git(dir, &["init", "-q"])?;
    git(dir, &["add", "-A"])?;
    git(dir, &["commit", "-q", "-m", "conformance fixture"])?;
    for (rel, text) in [
        ("edited.txt", "committed line\nan uncommitted edit\n"),
        ("draft.txt", "an untracked file\n"),
    ] {
        crate::home_fs::write(dir.join(rel), text)?;
        checkout_mode(&dir.join(rel), 0o644)?;
    }
    Ok(())
}

/// Give a fixture path the mode a cloned checkout has (644 files, 755 folders): `home_fs` writes
/// 600 and 700, and a 600 file that a case copies, appends to or renames keeps 600 here while
/// the routed side's patch brings it back 644, a difference no real checkout has.
fn checkout_mode(path: &Path, mode: u32) -> anyhow::Result<()> {
    #[cfg(unix)]
    crate::home_fs::set_mode(path, mode)?;
    #[cfg(not(unix))]
    let _ = (path, mode);
    Ok(())
}

/// A fresh copy of `template` at `to` (`to` must not exist): every byte and mode, `.git` too.
pub(crate) fn copy_tree(template: &Path, to: &Path) -> anyhow::Result<()> {
    crate::home_fs::create_dirs(to)?;
    let status = cmux_process::Command::new("cp")
        .arg("-a")
        .arg(format!("{}/.", template.display()))
        .arg(to)
        .stdin(cmux_process::Stdio::null())
        .status()?;
    anyhow::ensure!(status.success(), "cp -a {} {}: {status}", template.display(), to.display());
    Ok(())
}

/// Whether `program` is on `PATH`.
pub fn on_path(program: &str) -> bool {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).any(|d| {
        let p = d.join(program);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::metadata(&p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            p.is_file()
        }
    })
}
