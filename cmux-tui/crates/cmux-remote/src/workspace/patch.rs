use std::collections::{BTreeMap, BTreeSet};

use cmux_remote_protocol::{
    FilePrecondition, PatchFileAction, PatchFileResult, RpcError, RpcErrorDetails,
    WorkspaceResponse,
};

use super::files::{
    MAX_WRITE_BYTES, MutationFailure, MutationOutcome, hash_bytes, read_full_file,
    remove_file_precondition_locked_with_outcome, write_bytes_locked_with_outcome,
};
use super::path::{WorkspaceRoot, normalize_protocol_path};

const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;
const MAX_PATCH_FILES: usize = 1_024;
const MAX_PATCH_TOTAL_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug)]
struct PreparedChange {
    old_path: Option<String>,
    new_path: Option<String>,
    new_contents: Option<Vec<u8>>,
}

enum AppliedState {
    Present(String),
    Missing,
}

struct AppliedMutation {
    path: String,
    state: AppliedState,
}

#[derive(Default)]
struct CommitTracker {
    applied: Vec<AppliedMutation>,
    uncertain: BTreeSet<String>,
    recovery_paths: BTreeMap<String, BTreeSet<String>>,
}

struct CommitFailure {
    error: RpcError,
    applied: Vec<AppliedMutation>,
    uncertain: BTreeSet<String>,
    recovery_paths: BTreeMap<String, BTreeSet<String>>,
}

struct RollbackFailure {
    path: String,
    error: RpcError,
    outcome: MutationOutcome,
    recovery_path: Option<String>,
}

#[derive(Default)]
struct RollbackReport {
    failures: Vec<RollbackFailure>,
}

impl CommitTracker {
    fn applied(&mut self, path: &str, state: AppliedState) {
        self.applied.push(AppliedMutation { path: path.to_owned(), state });
    }

    fn failure(self, error: RpcError) -> CommitFailure {
        CommitFailure {
            error,
            applied: self.applied,
            uncertain: self.uncertain,
            recovery_paths: self.recovery_paths,
        }
    }

    fn mutation_failure(
        mut self,
        path: &str,
        applied_state: AppliedState,
        failure: MutationFailure,
    ) -> CommitFailure {
        match failure.outcome {
            MutationOutcome::Unchanged | MutationOutcome::Restored => {}
            MutationOutcome::Applied => self.applied(path, applied_state),
            MutationOutcome::Unknown => {
                self.uncertain.insert(path.to_owned());
            }
        }
        if let Some(recovery_path) = failure.recovery_path {
            self.recovery_paths
                .entry(path.to_owned())
                .or_default()
                .insert(recovery_path.to_string_lossy().into_owned());
        }
        self.failure(failure.error)
    }
}

impl RollbackReport {
    fn failure(&mut self, path: &str, failure: MutationFailure) {
        self.failures.push(RollbackFailure {
            path: path.to_owned(),
            error: failure.error,
            outcome: failure.outcome,
            recovery_path: failure.recovery_path.map(|path| path.to_string_lossy().into_owned()),
        });
    }
}

pub(crate) async fn apply_patch(
    root: &WorkspaceRoot,
    source: &str,
    dry_run: bool,
    requested_preconditions: &BTreeMap<String, FilePrecondition>,
) -> Result<WorkspaceResponse, RpcError> {
    if source.len() > MAX_PATCH_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("patch exceeds {MAX_PATCH_BYTES} bytes"),
        ));
    }
    let sections = split_unified_patch(source)?;
    if sections.len() > MAX_PATCH_FILES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("patch changes more than {MAX_PATCH_FILES} files"),
        ));
    }

    let _guard = root.mutation.lock().await;
    let mut changes = Vec::with_capacity(sections.len());
    let mut changed_paths = BTreeSet::new();
    let mut snapshots = BTreeMap::new();
    let mut total_snapshot_bytes = 0usize;
    let mut total_new_bytes = 0usize;
    for section in sections {
        let parsed = diffy::Patch::from_str(&section)
            .map_err(|error| RpcError::new("invalid-patch", error.to_string()))?;
        let old_path = parsed.original().map(normalize_patch_path).transpose()?.flatten();
        let new_path = parsed.modified().map(normalize_patch_path).transpose()?.flatten();
        if old_path.is_none() && new_path.is_none() {
            return Err(RpcError::new(
                "invalid-patch",
                "patch cannot use /dev/null for both paths",
            ));
        }
        let mut section_paths = BTreeSet::new();
        section_paths.extend(old_path.iter().cloned());
        section_paths.extend(new_path.iter().cloned());
        for path in &section_paths {
            if !changed_paths.insert(path.clone()) {
                return Err(RpcError::new(
                    "invalid-patch",
                    format!("patch changes {path} more than once"),
                ));
            }
            snapshot_path(root, path, &mut snapshots, &mut total_snapshot_bytes).await?;
        }
        if let Some(new) = &new_path
            && old_path.as_deref() != Some(new)
            && snapshots.get(new).is_some_and(Option::is_some)
        {
            return Err(RpcError::new(
                "patch-conflict",
                format!("patch destination already exists: {new}"),
            ));
        }
        let source_path = old_path.as_deref().or(new_path.as_deref()).unwrap_or_default();
        let original = if let Some(old) = &old_path {
            snapshots.get(old).and_then(Option::as_ref).cloned().ok_or_else(|| {
                RpcError::new("patch-conflict", format!("patch source does not exist: {old}"))
            })?
        } else {
            Vec::new()
        };
        let original = String::from_utf8(original).map_err(|_| {
            RpcError::new("invalid-text", format!("patch target is not UTF-8 text: {source_path}"))
        })?;
        let applied = diffy::apply(&original, &parsed)
            .map_err(|error| RpcError::new("patch-conflict", error.to_string()))?;
        let new_contents = if new_path.is_some() {
            total_new_bytes = total_new_bytes.saturating_add(applied.len());
            if applied.len() > MAX_WRITE_BYTES || total_new_bytes > MAX_PATCH_TOTAL_BYTES {
                return Err(RpcError::new(
                    "resource-exhausted",
                    "patched contents exceed workspace mutation limits",
                ));
            }
            Some(applied.into_bytes())
        } else {
            None
        };
        changes.push(PreparedChange { old_path, new_path, new_contents });
    }

    let changed_paths = changed_paths.into_iter().collect::<Vec<_>>();
    enforce_requested_preconditions(&snapshots, &changed_paths, requested_preconditions)?;
    let files = patch_results(&changes, &snapshots);
    if dry_run {
        return Ok(WorkspaceResponse::Patch { changed_paths, applied: false, files });
    }

    if let Err(failure) = commit_changes(root, &changes, &snapshots).await {
        let CommitFailure { error, applied, mut uncertain, mut recovery_paths } = failure;
        let rollback = rollback(root, &snapshots, &applied).await;
        let mut unresolved = uncertain.clone();
        let mut rollback_errors = Vec::new();
        for rollback_failure in rollback.failures {
            let RollbackFailure { path, error: rollback_error, outcome, recovery_path } =
                rollback_failure;
            unresolved.insert(path.clone());
            if outcome == MutationOutcome::Unknown {
                uncertain.insert(path.clone());
            }
            if let Some(recovery_path) = recovery_path {
                recovery_paths.entry(path.clone()).or_default().insert(recovery_path);
            }
            rollback_errors.push(format!(
                "{path} ({outcome:?}): {}: {}",
                rollback_error.code, rollback_error.message
            ));
        }
        if unresolved.is_empty() {
            return Err(error);
        }
        let unresolved = unresolved.into_iter().collect::<Vec<_>>();
        let recovery = if recovery_paths.is_empty() {
            String::new()
        } else {
            format!(
                "; retained recovery entries: {}",
                recovery_paths
                    .iter()
                    .flat_map(|(path, recoveries)| {
                        recoveries.iter().map(move |recovery| format!("{path} at {recovery}"))
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        let uncertain = if uncertain.is_empty() {
            String::new()
        } else {
            format!(
                "; unknown mutation outcomes: {}",
                uncertain.into_iter().collect::<Vec<_>>().join(", ")
            )
        };
        let rollback_errors = if rollback_errors.is_empty() {
            String::new()
        } else {
            format!("; rollback errors: {}", rollback_errors.join("; "))
        };
        return Err(RpcError::new(
            "partial-patch",
            format!(
                "patch failed: {}; unresolved paths: {}{}{}{}",
                error.message,
                unresolved.join(", "),
                uncertain,
                recovery,
                rollback_errors,
            ),
        )
        .with_details(RpcErrorDetails::PatchRollback { failed_paths: unresolved }));
    }
    Ok(WorkspaceResponse::Patch { changed_paths, applied: true, files })
}

fn enforce_requested_preconditions(
    snapshots: &BTreeMap<String, Option<Vec<u8>>>,
    changed_paths: &[String],
    requested: &BTreeMap<String, FilePrecondition>,
) -> Result<(), RpcError> {
    let mut normalized = BTreeMap::new();
    for (path, precondition) in requested {
        let path = normalize_protocol_path(path)?;
        if normalized.insert(path.clone(), precondition.clone()).is_some() {
            return Err(RpcError::new(
                "invalid-precondition",
                format!("multiple preconditions normalize to {path}"),
            ));
        }
    }
    for (path, precondition) in normalized {
        if changed_paths.binary_search(&path).is_err() {
            return Err(RpcError::new(
                "invalid-precondition",
                format!("precondition path is not changed by the patch: {path}"),
            ));
        }
        let snapshot = snapshots.get(&path).ok_or_else(|| {
            RpcError::new("internal", format!("patch snapshot is missing {path}"))
        })?;
        match (precondition, snapshot) {
            (FilePrecondition::Any, _) | (FilePrecondition::Missing, None) => {}
            (FilePrecondition::Missing, Some(_)) => {
                return Err(RpcError::new(
                    "conflict",
                    format!("patch precondition expected {path} to be missing"),
                ));
            }
            (FilePrecondition::ContentHash(expected), Some(contents))
                if hash_bytes(contents).eq_ignore_ascii_case(&expected) => {}
            (FilePrecondition::ContentHash(_), None) => {
                return Err(RpcError::new(
                    "conflict",
                    format!("patch precondition expected {path} to exist"),
                ));
            }
            (FilePrecondition::ContentHash(expected), Some(contents)) => {
                return Err(RpcError::new(
                    "conflict",
                    format!(
                        "patch precondition for {path} changed: expected {expected}, found {}",
                        hash_bytes(contents)
                    ),
                ));
            }
        }
    }
    Ok(())
}

fn patch_results(
    changes: &[PreparedChange],
    snapshots: &BTreeMap<String, Option<Vec<u8>>>,
) -> Vec<PatchFileResult> {
    changes
        .iter()
        .map(|change| match (&change.old_path, &change.new_path, &change.new_contents) {
            (Some(old), Some(new), Some(contents)) if old != new => PatchFileResult {
                path: new.clone(),
                previous_path: Some(old.clone()),
                action: PatchFileAction::Renamed,
                old_content_hash: snapshot_hash(snapshots, old),
                new_content_hash: Some(hash_bytes(contents)),
            },
            (Some(path), Some(_), Some(contents)) => PatchFileResult {
                path: path.clone(),
                previous_path: None,
                action: PatchFileAction::Modified,
                old_content_hash: snapshot_hash(snapshots, path),
                new_content_hash: Some(hash_bytes(contents)),
            },
            (None, Some(path), Some(contents)) => PatchFileResult {
                path: path.clone(),
                previous_path: None,
                action: PatchFileAction::Created,
                old_content_hash: None,
                new_content_hash: Some(hash_bytes(contents)),
            },
            (Some(path), None, None) => PatchFileResult {
                path: path.clone(),
                previous_path: None,
                action: PatchFileAction::Deleted,
                old_content_hash: snapshot_hash(snapshots, path),
                new_content_hash: None,
            },
            _ => unreachable!("prepared patches contain valid transitions"),
        })
        .collect()
}

fn snapshot_hash(snapshots: &BTreeMap<String, Option<Vec<u8>>>, path: &str) -> Option<String> {
    snapshots.get(path).and_then(Option::as_ref).map(|contents| hash_bytes(contents))
}

async fn snapshot_path(
    root: &WorkspaceRoot,
    path: &str,
    snapshots: &mut BTreeMap<String, Option<Vec<u8>>>,
    total_bytes: &mut usize,
) -> Result<(), RpcError> {
    if snapshots.contains_key(path) {
        return Ok(());
    }
    let contents = match read_full_file(root, path, MAX_WRITE_BYTES).await {
        Ok(contents) => Some(contents),
        Err(error) if error.code == "not-found" => None,
        Err(error) => return Err(error),
    };
    if let Some(contents) = &contents {
        *total_bytes = total_bytes.saturating_add(contents.len());
        if *total_bytes > MAX_PATCH_TOTAL_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                "patch snapshots exceed workspace mutation limits",
            ));
        }
    }
    snapshots.insert(path.to_string(), contents);
    Ok(())
}

fn split_unified_patch(source: &str) -> Result<Vec<String>, RpcError> {
    let lines = source.split_inclusive('\n').collect::<Vec<_>>();
    let mut starts = Vec::new();
    for index in 0..lines.len() {
        if lines[index].starts_with("--- ")
            && lines.get(index + 1).is_some_and(|line| line.starts_with("+++ "))
        {
            starts.push(index);
        }
    }
    if starts.is_empty() {
        return Err(RpcError::new(
            "invalid-patch",
            "expected unified diff headers beginning with --- and +++",
        ));
    }
    let mut sections = Vec::with_capacity(starts.len());
    for (position, start) in starts.iter().copied().enumerate() {
        let candidate_end = starts.get(position + 1).copied().unwrap_or(lines.len());
        let end = lines[start + 2..candidate_end]
            .iter()
            .position(|line| line.starts_with("diff --git "))
            .map(|offset| start + 2 + offset)
            .unwrap_or(candidate_end);
        sections.push(lines[start..end].concat());
    }
    Ok(sections)
}

fn normalize_patch_path(path: &str) -> Result<Option<String>, RpcError> {
    let path = path.trim();
    if path == "/dev/null" {
        return Ok(None);
    }
    let without_prefix =
        path.strip_prefix("a/").or_else(|| path.strip_prefix("b/")).unwrap_or(path);
    Ok(Some(normalize_protocol_path(without_prefix)?))
}

async fn commit_changes(
    root: &WorkspaceRoot,
    changes: &[PreparedChange],
    snapshots: &BTreeMap<String, Option<Vec<u8>>>,
) -> Result<(), CommitFailure> {
    let mut tracker = CommitTracker::default();
    macro_rules! commit_try {
        ($operation:expr) => {
            match $operation {
                Ok(value) => value,
                Err(error) => return Err(tracker.failure(error)),
            }
        };
    }
    for change in changes {
        match (&change.old_path, &change.new_path, &change.new_contents) {
            (Some(old), Some(new), Some(contents)) if old != new => {
                let destination = commit_try!(snapshot_precondition(snapshots, new));
                let source = commit_try!(snapshot_precondition(snapshots, old));
                match write_bytes_locked_with_outcome(root, new, contents, &destination, true).await
                {
                    Ok(hash) => tracker.applied(new, AppliedState::Present(hash)),
                    Err(failure) => {
                        return Err(tracker.mutation_failure(
                            new,
                            AppliedState::Present(hash_bytes(contents)),
                            failure,
                        ));
                    }
                }
                match remove_file_precondition_locked_with_outcome(root, old, &source).await {
                    Ok(()) => tracker.applied(old, AppliedState::Missing),
                    Err(failure) => {
                        return Err(tracker.mutation_failure(old, AppliedState::Missing, failure));
                    }
                }
            }
            (_, Some(new), Some(contents)) => {
                let precondition = commit_try!(snapshot_precondition(snapshots, new));
                match write_bytes_locked_with_outcome(root, new, contents, &precondition, true)
                    .await
                {
                    Ok(hash) => tracker.applied(new, AppliedState::Present(hash)),
                    Err(failure) => {
                        return Err(tracker.mutation_failure(
                            new,
                            AppliedState::Present(hash_bytes(contents)),
                            failure,
                        ));
                    }
                }
            }
            (Some(old), None, None) => {
                let precondition = commit_try!(snapshot_precondition(snapshots, old));
                match remove_file_precondition_locked_with_outcome(root, old, &precondition).await {
                    Ok(()) => tracker.applied(old, AppliedState::Missing),
                    Err(failure) => {
                        return Err(tracker.mutation_failure(old, AppliedState::Missing, failure));
                    }
                }
            }
            _ => {
                return Err(tracker.failure(RpcError::new(
                    "invalid-patch",
                    "patch produced an invalid file transition",
                )));
            }
        }
    }
    Ok(())
}

fn snapshot_precondition(
    snapshots: &BTreeMap<String, Option<Vec<u8>>>,
    path: &str,
) -> Result<FilePrecondition, RpcError> {
    match snapshots.get(path) {
        Some(Some(contents)) => Ok(FilePrecondition::ContentHash(hash_bytes(contents))),
        Some(None) => Ok(FilePrecondition::Missing),
        None => Err(RpcError::new("internal", format!("patch snapshot is missing {path}"))),
    }
}

async fn rollback(
    root: &WorkspaceRoot,
    snapshots: &BTreeMap<String, Option<Vec<u8>>>,
    applied: &[AppliedMutation],
) -> RollbackReport {
    let mut report = RollbackReport::default();
    for AppliedMutation { path, state } in applied.iter().rev() {
        let snapshot = snapshots.get(path).and_then(Option::as_ref);
        let result = match (snapshot, state) {
            (Some(contents), AppliedState::Present(current_hash)) => {
                write_bytes_locked_with_outcome(
                    root,
                    path,
                    contents,
                    &FilePrecondition::ContentHash(current_hash.clone()),
                    true,
                )
                .await
                .map(|_| ())
            }
            (Some(contents), AppliedState::Missing) => write_bytes_locked_with_outcome(
                root,
                path,
                contents,
                &FilePrecondition::Missing,
                true,
            )
            .await
            .map(|_| ()),
            (None, AppliedState::Present(current_hash)) => {
                match remove_file_precondition_locked_with_outcome(
                    root,
                    path,
                    &FilePrecondition::ContentHash(current_hash.clone()),
                )
                .await
                {
                    Ok(()) => Ok(()),
                    Err(failure) if failure.error.code == "not-found" => Ok(()),
                    Err(failure) => Err(failure),
                }
            }
            (None, AppliedState::Missing) => Ok(()),
        };
        if let Err(failure) = result {
            report.failure(path, failure);
        }
    }
    report
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use cmux_remote_protocol::WorkspaceId;
    use tempfile::tempdir;

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    use super::super::files::{
        MutationTestFault, MutationTestPoint, install_mutation_test_barrier,
        install_mutation_test_fault,
    };
    use super::*;

    async fn root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        let root =
            WorkspaceRoot::open(WorkspaceId("patch".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn unified_patch_supports_dry_run_then_apply() {
        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("hello.txt"), b"hello\n").await.unwrap();
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-hello\n+world\n";

        let preview = apply_patch(&root, patch, true, &BTreeMap::new()).await.unwrap();
        let WorkspaceResponse::Patch { changed_paths, applied, files } = preview else { panic!() };
        assert_eq!(changed_paths, ["hello.txt"]);
        assert!(!applied);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].action, PatchFileAction::Modified);
        assert_eq!(files[0].old_content_hash.as_deref(), Some(hash_bytes(b"hello\n").as_str()));
        assert_eq!(files[0].new_content_hash.as_deref(), Some(hash_bytes(b"world\n").as_str()));
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("hello.txt")).await.unwrap(),
            b"hello\n"
        );

        let applied = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap();
        let WorkspaceResponse::Patch { changed_paths, applied, files } = applied else { panic!() };
        assert_eq!(changed_paths, ["hello.txt"]);
        assert!(applied);
        assert_eq!(files.len(), 1);
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("hello.txt")).await.unwrap(),
            b"world\n"
        );
    }

    #[tokio::test]
    async fn conflicting_hunk_changes_nothing() {
        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("hello.txt"), b"current\n").await.unwrap();
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-stale\n+world\n";
        let error = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap_err();
        assert_eq!(error.code, "patch-conflict");
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("hello.txt")).await.unwrap(),
            b"current\n"
        );
    }

    #[tokio::test]
    async fn patch_digest_precondition_rejects_stale_source() {
        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("hello.txt"), b"hello\n").await.unwrap();
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-hello\n+world\n";
        let preconditions = BTreeMap::from([(
            "hello.txt".into(),
            FilePrecondition::ContentHash(hash_bytes(b"stale\n")),
        )]);

        let error = apply_patch(&root, patch, false, &preconditions).await.unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("hello.txt")).await.unwrap(),
            b"hello\n"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn patch_rejects_a_target_rewrite_between_snapshot_and_commit() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("hello.txt");
        tokio::fs::write(&target, b"hello\n").await.unwrap();
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-hello\n+world\n";
        let barrier =
            install_mutation_test_barrier(&root, "hello.txt", MutationTestPoint::AfterPrecondition);
        let patcher = {
            let root = Arc::clone(&root);
            tokio::spawn(async move { apply_patch(&root, patch, false, &BTreeMap::new()).await })
        };

        barrier.wait_until_reached().await;
        tokio::fs::write(&target, b"external-change\n").await.unwrap();
        barrier.resume();

        let error = patcher.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"external-change\n");
    }

    #[tokio::test]
    async fn rejects_patch_paths_outside_workspace() {
        let (_directory, root) = root().await;
        let patch = "--- /dev/null\n+++ b/../escape\n@@ -0,0 +1 @@\n+bad\n";
        let error = apply_patch(&root, patch, true, &BTreeMap::new()).await.unwrap_err();
        assert_eq!(error.code, "invalid-path");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn git_format_patch_applies_multiple_files() {
        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("first.txt"), b"old\n").await.unwrap();
        let patch = concat!(
            "diff --git a/first.txt b/first.txt\n",
            "--- a/first.txt\n",
            "+++ b/first.txt\n",
            "@@ -1 +1 @@\n",
            "-old\n",
            "+new\n",
            "diff --git a/second.txt b/second.txt\n",
            "new file mode 100644\n",
            "--- /dev/null\n",
            "+++ b/second.txt\n",
            "@@ -0,0 +1 @@\n",
            "+created\n",
        );

        let response = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap();
        let WorkspaceResponse::Patch { changed_paths, applied, files } = response else { panic!() };
        assert_eq!(changed_paths, ["first.txt", "second.txt"]);
        assert!(applied);
        assert_eq!(files.len(), 2);
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("first.txt")).await.unwrap(),
            b"new\n"
        );
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("second.txt")).await.unwrap(),
            b"created\n"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn creation_patch_refuses_to_replace_an_existing_file() {
        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("existing.txt"), b"keep\n").await.unwrap();
        let patch = "--- /dev/null\n+++ b/existing.txt\n@@ -0,0 +1 @@\n+replace\n";

        let error = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap_err();
        assert_eq!(error.code, "patch-conflict");
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("existing.txt")).await.unwrap(),
            b"keep\n"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn rollback_uses_digest_compare_and_swap() {
        let (_directory, root) = root().await;
        let path = root.canonical_root().join("value.txt");
        tokio::fs::write(&path, b"written-by-patch").await.unwrap();
        let snapshots = BTreeMap::from([("value.txt".into(), Some(b"original".to_vec()))]);
        let applied = vec![AppliedMutation {
            path: "value.txt".into(),
            state: AppliedState::Present(hash_bytes(b"written-by-patch")),
        }];

        assert!(rollback(&root, &snapshots, &applied).await.failures.is_empty());
        assert_eq!(tokio::fs::read(&path).await.unwrap(), b"original");

        tokio::fs::write(&path, b"external-change").await.unwrap();
        let failures = rollback(&root, &snapshots, &applied).await;
        assert_eq!(failures.failures.len(), 1);
        assert_eq!(failures.failures[0].path, "value.txt");
        assert_eq!(failures.failures[0].error.code, "conflict");
        assert_eq!(failures.failures[0].outcome, MutationOutcome::Unchanged);
        assert_eq!(tokio::fs::read(&path).await.unwrap(), b"external-change");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn patch_rolls_back_the_current_write_after_a_committed_sync_failure() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("hello.txt");
        tokio::fs::write(&target, b"old\n").await.unwrap();
        let _sync = install_mutation_test_fault(&root, "hello.txt", MutationTestFault::CommitSync);
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-old\n+new\n";

        let error = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap_err();

        assert_eq!(error.code, "committed-not-durable");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old\n");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn patch_rolls_back_the_current_write_after_recovery_cleanup_fails() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("hello.txt");
        tokio::fs::write(&target, b"old\n").await.unwrap();
        let _cleanup =
            install_mutation_test_fault(&root, "hello.txt", MutationTestFault::PublishedCleanup);
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-old\n+new\n";

        let error = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap_err();

        assert_eq!(error.code, "partial-write");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old\n");
        let recovery = std::fs::read_dir(root.canonical_root())
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with(".cmux-write-"))
            })
            .expect("the failed cleanup retains an explicit recovery entry");
        assert_eq!(tokio::fs::read(recovery).await.unwrap(), b"old\n");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn patch_reports_the_nested_rollback_error_and_retained_recovery_entry() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("hello.txt");
        tokio::fs::write(&target, b"old\n").await.unwrap();
        let after_exchange = install_mutation_test_barrier(
            &root,
            "hello.txt",
            MutationTestPoint::AfterContentHashExchange,
        );
        let patch = "--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-old\n+new\n";
        let patcher = {
            let root = Arc::clone(&root);
            tokio::spawn(async move { apply_patch(&root, patch, false, &BTreeMap::new()).await })
        };

        after_exchange.wait_until_reached().await;
        let _commit_cleanup =
            install_mutation_test_fault(&root, "hello.txt", MutationTestFault::PublishedCleanup);
        let _rollback_stat =
            install_mutation_test_fault(&root, "hello.txt", MutationTestFault::PrePublishStat);
        after_exchange.resume();

        let error = patcher.await.unwrap().unwrap_err();
        let recovery = std::fs::read_dir(root.canonical_root())
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with(".cmux-write-"))
            })
            .expect("the failed commit retains an explicit recovery entry");
        assert_eq!(error.code, "partial-patch");
        assert!(error.message.contains("hello.txt (Unchanged): injected-failure"));
        assert!(error.message.contains(&recovery.display().to_string()));
        assert_eq!(
            error.details,
            Some(RpcErrorDetails::PatchRollback { failed_paths: vec!["hello.txt".into()] })
        );
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new\n");
        assert_eq!(tokio::fs::read(recovery).await.unwrap(), b"old\n");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn patch_rename_restores_the_source_after_its_removal_was_committed() {
        let (_directory, root) = root().await;
        let source = root.canonical_root().join("source.txt");
        let destination = root.canonical_root().join("destination.txt");
        tokio::fs::write(&source, b"contents\n").await.unwrap();
        let _sync = install_mutation_test_fault(&root, "source.txt", MutationTestFault::CommitSync);
        let patch = concat!(
            "--- a/source.txt\n",
            "+++ b/destination.txt\n",
            "@@ -1 +1 @@\n",
            "-contents\n",
            "+contents\n",
        );

        let error = apply_patch(&root, patch, false, &BTreeMap::new()).await.unwrap_err();

        assert_eq!(error.code, "committed-not-durable");
        assert_eq!(tokio::fs::read(&source).await.unwrap(), b"contents\n");
        assert!(!destination.exists());
    }
}
