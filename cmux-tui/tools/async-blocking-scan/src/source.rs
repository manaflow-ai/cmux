//! The files of a scan: production Rust files under each root, read from the
//! working tree or from a git revision, each with its crate name.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::config::ScanConfig;

/// One production Rust file.
#[derive(Debug, Clone)]
pub struct SourceFile {
    /// The root as given, joined with the file's path under it.
    pub display: String,
    pub krate: String,
    pub text: String,
}

/// Where file contents come from.
#[derive(Debug, Clone)]
pub enum Tree {
    Worktree,
    Git { rev: String },
}

#[derive(Debug)]
pub enum SourceError {
    Io { path: PathBuf, error: std::io::Error },
    Git { root: PathBuf, message: String },
}

impl fmt::Display for SourceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SourceError::Io { path, error } => write!(f, "{}: {error}", path.display()),
            SourceError::Git { root, message } => write!(f, "git at {}: {message}", root.display()),
        }
    }
}

impl std::error::Error for SourceError {}

/// The production Rust files under `root`.
pub fn collect(
    scan: &ScanConfig,
    root: &Path,
    tree: &Tree,
) -> Result<Vec<SourceFile>, SourceError> {
    let files = match tree {
        Tree::Worktree => read_worktree(scan, root)?,
        Tree::Git { rev } => read_git(root, rev)?,
    };
    Ok(production_files(scan, root, &files))
}

/// Paths under the root ('/'-separated) to contents, for `.rs` files and Cargo.toml.
type Files = BTreeMap<String, String>;

fn read_worktree(scan: &ScanConfig, root: &Path) -> Result<Files, SourceError> {
    let mut files = Files::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(rel) = pending.pop() {
        let dir = root.join(&rel);
        let entries = std::fs::read_dir(&dir)
            .map_err(|error| SourceError::Io { path: dir.clone(), error })?;
        for entry in entries {
            let entry = entry.map_err(|error| SourceError::Io { path: dir.clone(), error })?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let file_type =
                entry.file_type().map_err(|error| SourceError::Io { path: entry.path(), error })?;
            let child = rel.join(&name);
            if file_type.is_dir() {
                if !name.starts_with('.') && !scan.skip_dirs.contains(&name) {
                    pending.push(child);
                }
            } else if file_type.is_file() && wanted(&name) {
                let path = entry.path();
                let text = std::fs::read_to_string(&path)
                    .map_err(|error| SourceError::Io { path, error })?;
                files.insert(slash_path(&child), text);
            }
        }
    }
    Ok(files)
}

fn wanted(name: &str) -> bool {
    name.ends_with(".rs") || name == "Cargo.toml"
}

fn slash_path(path: &Path) -> String {
    path.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/")
}

fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>, SourceError> {
    let output = Command::new("git").arg("-C").arg(root).args(args).output().map_err(|error| {
        SourceError::Git { root: root.to_path_buf(), message: error.to_string() }
    })?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(SourceError::Git { root: root.to_path_buf(), message });
    }
    Ok(output.stdout)
}

fn read_git(root: &Path, rev: &str) -> Result<Files, SourceError> {
    let prefix =
        String::from_utf8_lossy(&git(root, &["rev-parse", "--show-prefix"])?).trim().to_string();
    // At the top level the prefix is empty, and git refuses an empty pathspec.
    let mut ls_tree = vec!["ls-tree", "-r", "-z", "--name-only", "--full-tree", rev];
    if !prefix.is_empty() {
        ls_tree.extend(["--", prefix.as_str()]);
    }
    let listing = git(root, &ls_tree)?;
    let names: Vec<String> = listing
        .split(|b| *b == 0)
        .filter(|n| !n.is_empty())
        .map(|n| String::from_utf8_lossy(n).into_owned())
        .filter(|n| wanted(n.rsplit('/').next().unwrap_or(n)))
        .collect();
    let contents = cat_files(root, rev, &names)?;
    Ok(names
        .into_iter()
        .zip(contents)
        .filter_map(|(name, text)| {
            name.strip_prefix(prefix.as_str()).map(|rel| (rel.to_string(), text))
        })
        .collect())
}

/// Every named blob at `rev`, read through one `git cat-file --batch`: one
/// request, then its answer (git flushes each object), so neither pipe fills.
fn cat_files(root: &Path, rev: &str, names: &[String]) -> Result<Vec<String>, SourceError> {
    let fail = |message: String| SourceError::Git { root: root.to_path_buf(), message };
    let top =
        String::from_utf8_lossy(&git(root, &["rev-parse", "--show-toplevel"])?).trim().to_string();
    let mut child = Command::new("git")
        .arg("-C")
        .arg(&top)
        .args(["cat-file", "--batch"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| fail(e.to_string()))?;
    let mut stdin = child.stdin.take().ok_or_else(|| fail("no stdin".to_string()))?;
    let stdout = child.stdout.take().ok_or_else(|| fail("no stdout".to_string()))?;
    let mut reader = BufReader::new(stdout);
    let mut contents = Vec::with_capacity(names.len());
    for name in names {
        stdin.write_all(format!("{rev}:{name}\n").as_bytes()).map_err(|e| fail(e.to_string()))?;
        let mut header = String::new();
        reader.read_line(&mut header).map_err(|e| fail(e.to_string()))?;
        let size: usize = header
            .split_whitespace()
            .nth(2)
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| fail(format!("{name}: {}", header.trim())))?;
        let mut blob = vec![0; size + 1];
        reader.read_exact(&mut blob).map_err(|e| fail(e.to_string()))?;
        blob.truncate(size);
        contents.push(String::from_utf8(blob).map_err(|_| fail(format!("{name} is not UTF-8")))?);
    }
    drop(stdin);
    let status = child.wait().map_err(|e| fail(e.to_string()))?;
    if !status.success() {
        return Err(fail(format!("cat-file exited with {status}")));
    }
    Ok(contents)
}

fn production_files(scan: &ScanConfig, root: &Path, files: &Files) -> Vec<SourceFile> {
    let (test_files, test_dirs) = test_modules(files);
    let crates = crate_names(files);
    let root_display = root.to_string_lossy().trim_end_matches('/').to_string();
    let fallback = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    files
        .iter()
        .filter(|(rel, _)| rel.ends_with(".rs"))
        .filter(|(rel, _)| !skipped(scan, rel))
        .filter(|(rel, _)| {
            !test_files.contains(*rel)
                && !test_dirs.iter().any(|d| rel.starts_with(&format!("{d}/")))
        })
        .map(|(rel, text)| {
            let display =
                if root_display.is_empty() { rel.clone() } else { format!("{root_display}/{rel}") };
            let krate = crate_of(&crates, rel).unwrap_or(&fallback).to_string();
            SourceFile { display, krate, text: text.clone() }
        })
        .filter(|f| !scan.exempt_files.iter().any(|e| f.display.ends_with(e.as_str())))
        .collect()
}

fn skipped(scan: &ScanConfig, rel: &str) -> bool {
    let mut parts: Vec<&str> = rel.split('/').collect();
    let name = parts.pop().unwrap_or_default();
    parts.iter().any(|p| p.starts_with('.') || scan.skip_dirs.iter().any(|d| d == p))
        || scan.skip_file_names.iter().any(|n| n == name)
        || scan.skip_file_suffixes.iter().any(|s| name.ends_with(s.as_str()))
}

/// The files and folders of out-of-line `#[cfg(test)] mod name;` modules
/// (`name.rs`, `name/mod.rs` or a `#[path]`, and the folder `name/` below them).
fn test_modules(files: &Files) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut test_files = BTreeSet::new();
    let mut test_dirs = BTreeSet::new();
    for (rel, text) in files.iter().filter(|(rel, _)| rel.ends_with(".rs")) {
        let (dir, name) = rel.rsplit_once('/').unwrap_or(("", rel.as_str()));
        let stem = name.trim_end_matches(".rs");
        let owner = if matches!(name, "mod.rs" | "lib.rs" | "main.rs") {
            dir.to_string()
        } else {
            join(dir, stem)
        };
        for decl in test_mod_decls(text) {
            match decl.path {
                Some(path) => {
                    let target = join(dir, &path);
                    if let Some(module_dir) = target.strip_suffix("/mod.rs") {
                        test_dirs.insert(module_dir.to_string());
                    }
                    test_files.insert(target);
                }
                None => {
                    let module = join(&owner, &decl.name);
                    test_files.insert(format!("{module}.rs"));
                    test_files.insert(format!("{module}/mod.rs"));
                    test_dirs.insert(module);
                }
            }
        }
    }
    (test_files, test_dirs)
}

fn join(dir: &str, name: &str) -> String {
    if dir.is_empty() { name.to_string() } else { format!("{dir}/{name}") }
}

struct ModDecl {
    name: String,
    path: Option<String>,
}

/// `mod name;` lines whose attribute lines directly above make them test-only.
fn test_mod_decls(text: &str) -> Vec<ModDecl> {
    let lines: Vec<&str> = text.lines().collect();
    let mut decls = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let Some(name) = mod_decl_name(line) else { continue };
        let attrs: Vec<&str> = lines[..index]
            .iter()
            .rev()
            .map(|l| l.trim())
            .take_while(|l| l.starts_with("#[") || l.starts_with("//"))
            .collect();
        let joined = attrs.join(" ");
        let item = format!("{joined} mod {name};");
        let test_only = syn::parse_str::<syn::ItemMod>(&item)
            .is_ok_and(|m| crate::attrs::is_test_only(&m.attrs));
        if test_only {
            let path = syn::parse_str::<syn::ItemMod>(&item)
                .ok()
                .and_then(|m| crate::attrs::path_attr(&m.attrs));
            decls.push(ModDecl { name, path });
        }
    }
    decls
}

fn mod_decl_name(line: &str) -> Option<String> {
    let mut rest = line.trim();
    if let Some(after) = rest.strip_prefix("pub") {
        rest = after.trim_start();
        if rest.starts_with('(') {
            rest = rest.split_once(')')?.1.trim_start();
        }
    }
    let name = rest.strip_prefix("mod ")?.trim().strip_suffix(';')?.trim();
    (!name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_'))
        .then(|| name.to_string())
}

/// Folder (under the root) to the `[package] name` of its Cargo.toml.
fn crate_names(files: &Files) -> HashMap<String, String> {
    let mut crates = HashMap::new();
    for (rel, text) in files {
        let Some(dir) = rel.strip_suffix("Cargo.toml") else { continue };
        let Ok(manifest) = toml::from_str::<toml::Table>(text) else { continue };
        let name = manifest.get("package").and_then(|p| p.get("name")).and_then(|n| n.as_str());
        if let Some(name) = name {
            crates.insert(dir.trim_end_matches('/').to_string(), name.to_string());
        }
    }
    crates
}

fn crate_of<'a>(crates: &'a HashMap<String, String>, rel: &str) -> Option<&'a str> {
    let mut dir = rel;
    loop {
        dir = dir.rsplit_once('/').map_or("", |(d, _)| d);
        if let Some(name) = crates.get(dir) {
            return Some(name);
        }
        if dir.is_empty() {
            return None;
        }
    }
}
