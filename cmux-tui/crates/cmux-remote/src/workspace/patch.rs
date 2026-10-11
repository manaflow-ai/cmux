use std::collections::{BTreeMap, BTreeSet};

use cmux_remote_protocol::{
    FilePrecondition, PatchFileAction, PatchFileResult, RpcError, RpcErrorDetails,
    WorkspaceResponse,
};

use super::files::{
    MAX_WRITE_BYTES, MutationFailure, MutationOutcome, WorkspaceFileSnapshot, hash_bytes,
    read_file_snapshot, remove_file_precondition_locked_with_outcome,
    write_bytes_locked_with_mode_and_outcome, write_bytes_locked_with_outcome,
};
use super::path::{WorkspaceRoot, normalize_protocol_path};

const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;
const MAX_PATCH_FILES: usize = 1_024;
const MAX_PATCH_TOTAL_BYTES: usize = 64 * 1024 * 1024;

type FileSnapshots = BTreeMap<String, Option<WorkspaceFileSnapshot>>;

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
    let _guard = root.mutation.lock().await;
    let (changes, changed_paths, snapshots) = if super::codex_patch::looks_like_patch(source) {
        prepare_codex_patch(root, source).await?
    } else {
        prepare_unified_patch(root, source).await?
    };
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

type PreparedPatch = (Vec<PreparedChange>, Vec<String>, FileSnapshots);

async fn prepare_unified_patch(
    root: &WorkspaceRoot,
    source: &str,
) -> Result<PreparedPatch, RpcError> {
    let sections = split_unified_patch(source)?;
    enforce_patch_file_count(sections.len())?;
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
        snapshot_change_paths(
            root,
            old_path.as_deref(),
            new_path.as_deref(),
            &mut changed_paths,
            &mut snapshots,
            &mut total_snapshot_bytes,
        )
        .await?;
        reject_existing_destination(&old_path, &new_path, &snapshots)?;
        let source_path = old_path.as_deref().or(new_path.as_deref()).unwrap_or_default();
        let original = existing_text(&snapshots, old_path.as_deref(), source_path)?;
        let applied = diffy::apply(&original, &parsed)
            .map_err(|error| RpcError::new("patch-conflict", error.to_string()))?;
        let new_contents = new_path
            .as_ref()
            .map(|_| checked_new_contents(applied, &mut total_new_bytes))
            .transpose()?;
        changes.push(PreparedChange { old_path, new_path, new_contents });
    }
    Ok(finish_preparation(changes, changed_paths, snapshots))
}

async fn prepare_codex_patch(
    root: &WorkspaceRoot,
    source: &str,
) -> Result<PreparedPatch, RpcError> {
    use super::codex_patch::Hunk;

    let hunks = super::codex_patch::parse_patch(source)
        .map_err(|error| RpcError::new("invalid-patch", error))?;
    enforce_patch_file_count(hunks.len())?;
    let mut changes = Vec::with_capacity(hunks.len());
    let mut changed_paths = BTreeSet::new();
    let mut snapshots = BTreeMap::new();
    let mut total_snapshot_bytes = 0usize;
    let mut total_new_bytes = 0usize;
    for hunk in hunks {
        let (old_path, new_path, new_contents) = match hunk {
            Hunk::Add { path, contents } => {
                let new = normalize_protocol_path(&path)?;
                snapshot_change_paths(
                    root,
                    None,
                    Some(&new),
                    &mut changed_paths,
                    &mut snapshots,
                    &mut total_snapshot_bytes,
                )
                .await?;
                reject_existing_destination(&None, &Some(new.clone()), &snapshots)?;
                let contents = checked_new_contents(contents, &mut total_new_bytes)?;
                (None, Some(new), Some(contents))
            }
            Hunk::Delete { path } => {
                let old = normalize_protocol_path(&path)?;
                snapshot_change_paths(
                    root,
                    Some(&old),
                    None,
                    &mut changed_paths,
                    &mut snapshots,
                    &mut total_snapshot_bytes,
                )
                .await?;
                existing_text(&snapshots, Some(&old), &old)?;
                (Some(old), None, None)
            }
            Hunk::Update { path, move_path, chunks } => {
                let old = normalize_protocol_path(&path)?;
                let new = move_path
                    .as_deref()
                    .map(normalize_protocol_path)
                    .transpose()?
                    .unwrap_or_else(|| old.clone());
                snapshot_change_paths(
                    root,
                    Some(&old),
                    Some(&new),
                    &mut changed_paths,
                    &mut snapshots,
                    &mut total_snapshot_bytes,
                )
                .await?;
                reject_existing_destination(&Some(old.clone()), &Some(new.clone()), &snapshots)?;
                let original = existing_text(&snapshots, Some(&old), &old)?;
                let applied = super::codex_patch::apply_update(&original, &old, &chunks)
                    .map_err(|error| RpcError::new("patch-conflict", error))?;
                let contents = checked_new_contents(applied, &mut total_new_bytes)?;
                (Some(old), Some(new), Some(contents))
            }
        };
        changes.push(PreparedChange { old_path, new_path, new_contents });
    }
    Ok(finish_preparation(changes, changed_paths, snapshots))
}

fn finish_preparation(
    changes: Vec<PreparedChange>,
    changed_paths: BTreeSet<String>,
    snapshots: FileSnapshots,
) -> PreparedPatch {
    (changes, changed_paths.into_iter().collect(), snapshots)
}

fn enforce_patch_file_count(count: usize) -> Result<(), RpcError> {
    if count > MAX_PATCH_FILES {
        Err(RpcError::new(
            "resource-exhausted",
            format!("patch changes more than {MAX_PATCH_FILES} files"),
        ))
    } else {
        Ok(())
    }
}

async fn snapshot_change_paths(
    root: &WorkspaceRoot,
    old_path: Option<&str>,
    new_path: Option<&str>,
    changed_paths: &mut BTreeSet<String>,
    snapshots: &mut FileSnapshots,
    total_snapshot_bytes: &mut usize,
) -> Result<(), RpcError> {
    let paths = old_path.into_iter().chain(new_path).collect::<BTreeSet<_>>();
    for path in paths {
        if !changed_paths.insert(path.to_owned()) {
            return Err(RpcError::new(
                "invalid-patch",
                format!("patch changes {path} more than once"),
            ));
        }
        snapshot_path(root, path, snapshots, total_snapshot_bytes).await?;
    }
    Ok(())
}

fn reject_existing_destination(
    old_path: &Option<String>,
    new_path: &Option<String>,
    snapshots: &FileSnapshots,
) -> Result<(), RpcError> {
    if let Some(new) = new_path
        && old_path.as_deref() != Some(new)
        && snapshots.get(new).is_some_and(Option::is_some)
    {
        return Err(RpcError::new(
            "patch-conflict",
            format!("patch destination already exists: {new}"),
        ));
    }
    Ok(())
}

fn existing_text(
    snapshots: &FileSnapshots,
    old_path: Option<&str>,
    display_path: &str,
) -> Result<String, RpcError> {
    let original = if let Some(old) = old_path {
        snapshots
            .get(old)
            .and_then(Option::as_ref)
            .map(|snapshot| snapshot.contents.clone())
            .ok_or_else(|| {
                RpcError::new("patch-conflict", format!("patch source does not exist: {old}"))
            })?
    } else {
        Vec::new()
    };
    String::from_utf8(original).map_err(|_| {
        RpcError::new("invalid-text", format!("patch target is not UTF-8 text: {display_path}"))
    })
}

fn checked_new_contents(
    contents: String,
    total_new_bytes: &mut usize,
) -> Result<Vec<u8>, RpcError> {
    *total_new_bytes = total_new_bytes.saturating_add(contents.len());
    if contents.len() > MAX_WRITE_BYTES || *total_new_bytes > MAX_PATCH_TOTAL_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            "patched contents exceed workspace mutation limits",
        ));
    }
    Ok(contents.into_bytes())
}

fn enforce_requested_preconditions(
    snapshots: &FileSnapshots,
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
            (FilePrecondition::ContentHash(expected), Some(snapshot))
                if hash_bytes(&snapshot.contents).eq_ignore_ascii_case(&expected) => {}
            (FilePrecondition::ContentHash(_), None) => {
                return Err(RpcError::new(
                    "conflict",
                    format!("patch precondition expected {path} to exist"),
                ));
            }
            (FilePrecondition::ContentHash(expected), Some(snapshot)) => {
                return Err(RpcError::new(
                    "conflict",
                    format!(
                        "patch precondition for {path} changed: expected {expected}, found {}",
                        hash_bytes(&snapshot.contents)
                    ),
                ));
            }
        }
    }
    Ok(())
}

fn patch_results(changes: &[PreparedChange], snapshots: &FileSnapshots) -> Vec<PatchFileResult> {
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

fn snapshot_hash(snapshots: &FileSnapshots, path: &str) -> Option<String> {
    snapshots.get(path).and_then(Option::as_ref).map(|snapshot| hash_bytes(&snapshot.contents))
}

async fn snapshot_path(
    root: &WorkspaceRoot,
    path: &str,
    snapshots: &mut FileSnapshots,
    total_bytes: &mut usize,
) -> Result<(), RpcError> {
    if snapshots.contains_key(path) {
        return Ok(());
    }
    let snapshot = match read_file_snapshot(root, path, MAX_WRITE_BYTES).await {
        Ok(snapshot) => Some(snapshot),
        Err(error) if error.code == "not-found" => None,
        Err(error) => return Err(error),
    };
    if let Some(snapshot) = &snapshot {
        *total_bytes = total_bytes.saturating_add(snapshot.contents.len());
        if *total_bytes > MAX_PATCH_TOTAL_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                "patch snapshots exceed workspace mutation limits",
            ));
        }
    }
    snapshots.insert(path.to_string(), snapshot);
    Ok(())
}

fn split_unified_patch(source: &str) -> Result<Vec<String>, RpcError> {
    let lines = source.split_inclusive('\n').collect::<Vec<_>>();
    let mut starts = Vec::new();
    let mut index = 0;
    let mut section_open = false;
    let mut hunk_remaining = None;
    while index < lines.len() {
        if let Some((old_remaining, new_remaining)) = hunk_remaining.as_mut() {
            if *old_remaining == 0 && *new_remaining == 0 {
                hunk_remaining = None;
                continue;
            }
            match lines[index].as_bytes().first().copied() {
                Some(b' ') if *old_remaining > 0 && *new_remaining > 0 => {
                    *old_remaining -= 1;
                    *new_remaining -= 1;
                }
                Some(b'-') if *old_remaining > 0 => *old_remaining -= 1,
                Some(b'+') if *new_remaining > 0 => *new_remaining -= 1,
                Some(b'\\') => {}
                _ => {
                    hunk_remaining = None;
                    continue;
                }
            }
            index += 1;
            continue;
        }
        if section_open && let Some(counts) = unified_hunk_line_counts(lines[index]) {
            hunk_remaining = Some(counts);
            index += 1;
            continue;
        }
        if lines[index].starts_with("--- ")
            && lines.get(index + 1).is_some_and(|line| line.starts_with("+++ "))
        {
            starts.push(index);
            section_open = true;
            index += 2;
            continue;
        }
        if lines[index].starts_with("diff --git ") {
            section_open = false;
        }
        index += 1;
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

fn unified_hunk_line_counts(line: &str) -> Option<(usize, usize)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let ranges = line.strip_prefix("@@ -")?;
    let (old_range, ranges) = ranges.split_once(" +")?;
    let (new_range, _) = ranges.split_once(" @@")?;
    Some((unified_range_line_count(old_range)?, unified_range_line_count(new_range)?))
}

fn unified_range_line_count(range: &str) -> Option<usize> {
    let (start, count) = range.split_once(',').map_or((range, "1"), |parts| parts);
    start.parse::<usize>().ok()?;
    count.parse().ok()
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
    snapshots: &FileSnapshots,
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
                let source_mode = commit_try!(snapshot_mode(snapshots, old));
                match write_bytes_locked_with_mode_and_outcome(
                    root,
                    new,
                    contents,
                    &destination,
                    true,
                    source_mode,
                )
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
    snapshots: &FileSnapshots,
    path: &str,
) -> Result<FilePrecondition, RpcError> {
    match snapshots.get(path) {
        Some(Some(snapshot)) => Ok(FilePrecondition::ContentHash(hash_bytes(&snapshot.contents))),
        Some(None) => Ok(FilePrecondition::Missing),
        None => Err(RpcError::new("internal", format!("patch snapshot is missing {path}"))),
    }
}

fn snapshot_mode(snapshots: &FileSnapshots, path: &str) -> Result<Option<u32>, RpcError> {
    match snapshots.get(path) {
        Some(Some(snapshot)) => Ok(snapshot.mode),
        Some(None) => Err(RpcError::new(
            "internal",
            format!("patch snapshot contents are missing for {path}"),
        )),
        None => Err(RpcError::new("internal", format!("patch snapshot is missing {path}"))),
    }
}

async fn rollback(
    root: &WorkspaceRoot,
    snapshots: &FileSnapshots,
    applied: &[AppliedMutation],
) -> RollbackReport {
    let mut report = RollbackReport::default();
    for AppliedMutation { path, state } in applied.iter().rev() {
        let snapshot = snapshots.get(path).and_then(Option::as_ref);
        let result = match (snapshot, state) {
            (Some(snapshot), AppliedState::Present(current_hash)) => {
                write_bytes_locked_with_mode_and_outcome(
                    root,
                    path,
                    &snapshot.contents,
                    &FilePrecondition::ContentHash(current_hash.clone()),
                    true,
                    snapshot.mode,
                )
                .await
                .map(|_| ())
            }
            (Some(snapshot), AppliedState::Missing) => write_bytes_locked_with_mode_and_outcome(
                root,
                path,
                &snapshot.contents,
                &FilePrecondition::Missing,
                true,
                snapshot.mode,
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
