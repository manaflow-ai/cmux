//! Folded by content: a code layer whose change is already in the app is
//! "now built in" (RFD 0038, cmuxterm-hq docs/rfd/0038-customizations-across-updates.md,
//! phase 1 step 3). Merge containment (the app has the layer's head) is the
//! old test; it misses squash merges, re-lands and cherry-picks, whose
//! commits are new. Two content tests catch those, both measured from
//! `mb`, the merge base of the layer's head and the app's commit:
//!
//! ```text
//! tree    every path the layer changes (mb..head) the app changed too
//!         (mb..app), to the same blob, or removed it too
//! patch   the layer's whole diff (mb..head) has the stable patch-id of one
//!         commit in mb..app (a squash merge or a re-land), or every commit
//!         of mb..head has an equal one there (`git cherry`: cherry-picks)
//! ```
//!
//! A layer only partly in the app is not folded, and nor is one whose paths
//! the app changed some other way. Patch-ids need commits, so they run only
//! where a checkout holds both commits; the GitHub API answers the tree test
//! with two compares (`app...head` and `head...app` share their merge base).

use std::collections::{BTreeMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

use cmux_process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The note, the history line and the one line refresh prints.
pub const FOLDED: &str = "now built in";
/// The most app commits read for patch-ids (`mb..app`), newest first.
pub const MAX_APP_COMMITS: usize = 4000;
/// The most answers kept in the cache.
const CACHE_MAX: usize = 256;
const CACHE: &str = "folded.json";

/// How a layer was found in the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum How {
    /// The app's history has the layer's head.
    Contained,
    /// One app commit carries the layer's whole diff (squash merge, re-land).
    Patch,
    /// Every commit of the layer has an equal one in the app (cherry-picks).
    Cherry,
    /// The app has the layer's result at every path it changes.
    Tree,
}

/// One path a side changed from the merge base, and its blob there after
/// (`None`: removed).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Touched {
    pub path: String,
    pub blob: Option<String>,
}

/// The tree test: `layer` (mb..head) is non-empty and the app (`app`,
/// mb..app) changed each of its paths to the same blob. A path the app left
/// alone is still mb's, which is not the layer's, so it does not fold.
pub fn tree_folded(layer: &[Touched], app: &[Touched]) -> bool {
    if layer.is_empty() {
        return false;
    }
    let app: BTreeMap<&str, &Option<String>> =
        app.iter().map(|touched| (touched.path.as_str(), &touched.blob)).collect();
    layer.iter().all(|touched| app.get(touched.path.as_str()) == Some(&&touched.blob))
}

/// The patch test: the layer's diff's patch-id is one of the app's.
pub fn patch_folded(layer: Option<&str>, app: &HashSet<String>) -> bool {
    layer.is_some_and(|id| app.contains(id))
}

/// The paths a GitHub compare (`repos/R/compare/A...B`) lists as changed on
/// B's side, each with B's blob. `None` when the answer is not a full list:
/// GitHub lists at most 300 files, so a longer diff is not judged.
pub fn compare_files(compare: &Value) -> Option<Vec<Touched>> {
    let files = compare.get("files")?.as_array()?;
    if files.len() >= 300 {
        return None;
    }
    let mut out = Vec::new();
    for file in files {
        let path = file.get("filename")?.as_str()?.to_owned();
        let status = file.get("status").and_then(Value::as_str).unwrap_or_default();
        if status == "renamed"
            && let Some(old) = file.get("previous_filename").and_then(Value::as_str)
        {
            out.push(Touched { path: old.to_owned(), blob: None });
        }
        let blob = match status {
            "removed" => None,
            _ => Some(file.get("sha")?.as_str()?.to_owned()),
        };
        out.push(Touched { path, blob });
    }
    out.sort();
    Some(out)
}

/// The tree test on two GitHub compares that share a merge base: `layer` is
/// `app...head`, `app` is `head...app`. [`How::Contained`] when head is in
/// the app already (`app...head` is behind or identical).
pub fn compare_folded(layer: &Value, app: &Value) -> Option<How> {
    if matches!(layer.get("status").and_then(Value::as_str), Some("behind" | "identical")) {
        return Some(How::Contained);
    }
    let base = |value: &Value| {
        value.pointer("/merge_base_commit/sha").and_then(Value::as_str).map(str::to_owned)
    };
    if base(layer).is_none() || base(layer) != base(app) {
        return None;
    }
    tree_folded(&compare_files(layer)?, &compare_files(app)?).then_some(How::Tree)
}

/// Every test, in a checkout (`repo`) that has both commits. `None`: not
/// folded, or this checkout cannot say.
pub fn local_folded(repo: &Path, head: &str, app: &str) -> Option<How> {
    if !has_commit(repo, head) || !has_commit(repo, app) {
        return None;
    }
    let mb = git(repo, &["merge-base", head, app])?.trim().to_owned();
    if mb == head {
        return Some(How::Contained);
    }
    let layer = changes(repo, &mb, head)?;
    if layer.is_empty() {
        return None;
    }
    if tree_folded(&layer, &changes(repo, &mb, app)?) {
        return Some(How::Tree);
    }
    // Only the commits that touch the layer's paths, and only those paths
    // of each: a squash commit that also changed other files still carries
    // the layer's whole diff.
    let range = format!("{mb}..{app}");
    let max = format!("--max-count={MAX_APP_COMMITS}");
    let mut args = vec!["log", "--no-merges", "-p", max.as_str(), range.as_str()];
    args.extend(PLAIN_DIFF);
    args.push("--");
    args.extend(layer.iter().map(|touched| touched.path.as_str()));
    let app_ids: HashSet<String> = patch_ids(repo, &args)?.into_iter().collect();
    let mut args = vec!["diff", mb.as_str(), head];
    args.extend(PLAIN_DIFF);
    if patch_folded(patch_ids(repo, &args)?.first().map(String::as_str), &app_ids) {
        return Some(How::Patch);
    }
    cherry_all_in(repo, app, head, &mb).then_some(How::Cherry)
}

/// The same diff whatever the person's git config says.
const PLAIN_DIFF: [&str; 4] = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames"];

/// `git cherry APP HEAD MB`: every layer commit is marked `-` (an equal
/// change is in the app).
fn cherry_all_in(repo: &Path, app: &str, head: &str, mb: &str) -> bool {
    let Some(out) = git(repo, &["cherry", app, head, mb]) else { return false };
    let lines: Vec<&str> = out.lines().filter(|line| !line.trim().is_empty()).collect();
    !lines.is_empty() && lines.iter().all(|line| line.starts_with("- "))
}

fn has_commit(repo: &Path, commit: &str) -> bool {
    git(repo, &["cat-file", "-e", &format!("{commit}^{{commit}}")]).is_some()
}

/// `git diff --raw` from `from` to `to`: each changed path and its blob in
/// `to`, without rename detection (a rename is a removal and an addition).
fn changes(repo: &Path, from: &str, to: &str) -> Option<Vec<Touched>> {
    let out = git(repo, &["diff", "--raw", "--no-renames", "-z", "--no-abbrev", from, to])?;
    let mut parts = out.split('\0');
    let mut touched = Vec::new();
    while let Some(meta) = parts.next() {
        if meta.is_empty() {
            continue;
        }
        let path = parts.next()?;
        let new_sha = meta.split_whitespace().nth(3)?;
        let blob = (!new_sha.bytes().all(|b| b == b'0')).then(|| new_sha.to_owned());
        touched.push(Touched { path: path.to_owned(), blob });
    }
    touched.sort();
    Some(touched)
}

/// `git patch-id --stable` over what git command `args` (a `diff` or a
/// `log -p`) writes: the ids, in order. The patches go through a file of our
/// own, removed after.
fn patch_ids(repo: &Path, args: &[&str]) -> Option<Vec<String>> {
    static SEQ: AtomicU32 = AtomicU32::new(0);
    let file = std::env::temp_dir().join(format!(
        "cmux-customize-fold-{}-{}.patch",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let output = format!("--output={}", file.display());
    let mut written: Vec<&str> = args.to_vec();
    // `--output` goes before any `--` (the pathspec).
    let at = written.iter().position(|arg| *arg == "--").unwrap_or(written.len());
    written.insert(at, output.as_str());
    let ids = git(repo, &written).and_then(|_| {
        let out = Command::new("git")
            .args(["patch-id", "--stable"])
            .current_dir(repo)
            .open_stdin_path(&file)
            .stderr(Stdio::null())
            .output()
            .ok()?;
        out.status.success().then(|| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
                .collect()
        })
    });
    let _ = std::fs::remove_file(&file);
    ids
}

fn git(repo: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("--literal-pathspecs")
        .arg("-C")
        .arg(repo)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Answers by layer head and app commit: neither commit changes, so neither
/// does the answer. `None` inside is a "not folded" that was judged.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Cache {
    #[serde(default)]
    answers: Vec<(String, Option<How>)>,
}

fn cache_key(head: &str, app: &str) -> String {
    format!("{head}-{app}")
}

impl crate::Customize {
    /// The cached answer for `head` on `app`, when one was judged.
    pub fn folded_cached(&self, head: &str, app: &str) -> Option<Option<How>> {
        let key = cache_key(head, app);
        self.read_fold_cache().answers.into_iter().find(|(k, _)| *k == key).map(|(_, how)| how)
    }

    /// Keeps the answer for `head` on `app` (the newest [`CACHE_MAX`]).
    pub fn remember_folded(&self, head: &str, app: &str, how: Option<How>) {
        let key = cache_key(head, app);
        let mut cache = self.read_fold_cache();
        cache.answers.retain(|(k, _)| *k != key);
        cache.answers.push((key, how));
        let extra = cache.answers.len().saturating_sub(CACHE_MAX);
        cache.answers.drain(..extra);
        let dir = &self.roots().state_dir;
        if let Ok(text) = serde_json::to_string(&cache) {
            let _ = std::fs::create_dir_all(dir);
            let _ = cmux_config::fsio::write_atomic(&dir.join(CACHE), text.as_bytes());
        }
    }

    fn read_fold_cache(&self) -> Cache {
        std::fs::read(self.roots().state_dir.join(CACHE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn t(path: &str, blob: Option<&str>) -> Touched {
        Touched { path: path.to_owned(), blob: blob.map(str::to_owned) }
    }

    #[test]
    fn tree_needs_every_path_at_the_same_blob() {
        let layer = [t("a", Some("1")), t("b", None)];
        assert!(tree_folded(&layer, &[t("a", Some("1")), t("b", None), t("z", Some("9"))]));
        // Partly in: b is still there.
        assert!(!tree_folded(&layer, &[t("a", Some("1"))]));
        // The app changed a another way.
        assert!(!tree_folded(&layer, &[t("a", Some("2")), t("b", None)]));
        assert!(!tree_folded(&[], &[t("a", Some("1"))]));
    }

    #[test]
    fn compares_fold_on_the_same_merge_base_only() {
        let side = |files: Value| json!({ "status": "diverged", "merge_base_commit": { "sha": "mb" }, "files": files });
        let layer = side(json!([
            { "filename": "web/x.ts", "status": "modified", "sha": "b1" },
            { "filename": "web/new.ts", "status": "renamed", "previous_filename": "web/old.ts", "sha": "b2" }
        ]));
        let app = side(json!([
            { "filename": "web/x.ts", "status": "modified", "sha": "b1" },
            { "filename": "web/new.ts", "status": "added", "sha": "b2" },
            { "filename": "web/old.ts", "status": "removed", "sha": "b0" },
            { "filename": "Sources/y.swift", "status": "modified", "sha": "c1" }
        ]));
        assert_eq!(compare_folded(&layer, &app), Some(How::Tree));
        let partial = side(json!([{ "filename": "web/x.ts", "status": "modified", "sha": "b1" }]));
        assert_eq!(compare_folded(&layer, &partial), None);
        let mut other = app.clone();
        other["merge_base_commit"]["sha"] = json!("elsewhere");
        assert_eq!(compare_folded(&layer, &other), None);
        assert_eq!(compare_folded(&json!({ "status": "behind" }), &app), Some(How::Contained));
        let many: Vec<Value> = (0..300)
            .map(|n| json!({ "filename": format!("f{n}"), "status": "added", "sha": "s" }))
            .collect();
        assert_eq!(compare_folded(&layer, &side(Value::Array(many))), None);
    }
}
