//! `git.diff`: one scope's changed files, with line counts and, on request,
//! each file's patch cut to a byte budget.

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path};

use base64::Engine as _;
use cmux_git::diff::{Comparison, ScopeError, diff_args, untracked_args};
use cmux_git::run::{GitOutput, GitWindow};
use serde_json::{Map, Value, json};

use super::{Repository, clamp, git_failed, parse};
use crate::resource::{ResourceError, WireDecimal};
use cmux_json::JsonSet as _;

const OPERATION: &str = "git.diff";
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;
/// git output read per patch run.
const MAX_PATCH_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
/// Patch bytes in one reply, across its files; past it, files are marked
/// `patch_truncated` without a patch.
const MAX_REPLY_PATCH_BYTES: usize = 8 * 1024 * 1024;
/// Paths per patch run, so a long file list never exceeds the argument limit.
const PATCH_BATCH: usize = 256;
/// Untracked files are read to count their lines; past this many the rest
/// are left out and counted in `untracked_skipped`.
const MAX_UNTRACKED_FILES: usize = 200;
const MAX_UNTRACKED_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// git's own test for a binary file: a NUL in the first 8000 bytes.
const BINARY_PROBE_BYTES: usize = 8000;
/// Base64 keeps arbitrary UTF-8 boundaries intact across bounded replies.
const PATCH_PAGE_BYTES: usize = 512 * 1024;

#[derive(Debug)]
struct ChangedFile {
    path: String,
    previous_path: Option<String>,
    status: &'static str,
    additions: u64,
    deletions: u64,
    binary: bool,
    patch: Option<String>,
    blob_fingerprint: Option<String>,
    patch_truncated: bool,
}

impl ChangedFile {
    fn new(path: String, status: &'static str) -> Self {
        Self {
            path,
            previous_path: None,
            status,
            additions: 0,
            deletions: 0,
            binary: false,
            patch: None,
            blob_fingerprint: None,
            patch_truncated: false,
        }
    }

    fn has_patch(&self) -> bool {
        self.status != "untracked" && !self.binary
    }

    fn to_json(&self) -> Value {
        let mut value = json!({
            "path":self.path,
            "status":self.status,
            "additions":clamp(self.additions),
            "deletions":clamp(self.deletions),
        });
        if let Some(previous_path) = &self.previous_path {
            value.set("previous_path", json!(previous_path));
        }
        if self.binary {
            value.set("binary", json!(true));
        }
        if let Some(patch) = &self.patch {
            value.set("patch", json!(patch));
        }
        if let Some(fingerprint) = &self.blob_fingerprint {
            value.set("blob_fingerprint", json!(fingerprint));
        }
        if self.patch_truncated {
            value.set("patch_truncated", json!(true));
        }
        value
    }
}

/// Stable request identity, independent of the current HEAD/tree. The revision
/// separately identifies immutable bytes. No caller supplies a cache key.
fn capture_key(
    repository: &Repository,
    fields: &Map<String, Value>,
    operation: &'static str,
) -> Result<String, ResourceError> {
    let scope = (operation == OPERATION)
        .then(|| fields.get("scope").and_then(Value::as_str).unwrap_or("uncommitted"));
    Ok(json!([
        repository.root,
        operation,
        pathspecs(fields)?,
        limit(fields, "context_lines", 3).min(MAX_CONTEXT_LINES),
        scope,
        fields.get("from"),
        fields.get("to")
    ])
    .to_string())
}

fn page_offset(fields: &Map<String, Value>) -> Result<Option<u64>, ResourceError> {
    fields
        .get("patch_offset")
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone()).map(WireDecimal::get).map_err(
                |_| {
                    ResourceError::validation_invalid(
                        Some("patch_offset"),
                        "patch_offset must be an unsigned decimal string",
                    )
                },
            )
        })
        .transpose()
}

/// Serve a continuation before rebuilding a live comparison. Unrelated
/// working-tree changes must not invalidate an already-issued page cursor.
pub(super) fn continuation(
    repository: &Repository,
    fields: &Map<String, Value>,
    operation: &'static str,
) -> Result<Option<Value>, ResourceError> {
    let Some(offset) = page_offset(fields)?.filter(|offset| *offset > 0) else {
        return Ok(None);
    };
    if fields.get("include_patch").and_then(Value::as_bool) != Some(true)
        || pathspecs(fields)?.len() != 1
    {
        return Err(ResourceError::validation_invalid(
            Some("patch_offset"),
            "a patch page requires include_patch and exactly one file path",
        ));
    }
    let revision = fields.get("patch_revision").and_then(Value::as_str).ok_or_else(|| {
        ResourceError::validation_invalid(
            Some("patch_revision"),
            "continuing a patch requires the first page's revision",
        )
    })?;
    let key = capture_key(repository, fields, operation)?;
    let Some((window, mut metadata)) = super::diff_pages::get(&key, revision) else {
        return Err(ResourceError::operation_failed(
            operation,
            "the patch capture expired; restart at offset zero",
            json!({"code":"patch_expired"}),
        ));
    };
    let bytes = window.read(offset, PATCH_PAGE_BYTES).map_err(|_| {
        ResourceError::operation_failed(
            operation,
            "could not read the captured patch",
            json!({"code":"patch_read_failed"}),
        )
    })?;
    metadata.set("patch_page", page_value(&window, revision, offset, bytes)?);
    Ok(Some(metadata))
}

pub(super) fn read(
    repository: &Repository,
    fields: &Map<String, Value>,
) -> Result<Value, ResourceError> {
    let scope = fields.get("scope").and_then(Value::as_str).unwrap_or("uncommitted");
    pathspecs(fields)?;
    if let Some(value) = continuation(repository, fields, OPERATION)? {
        return Ok(value);
    }
    let comparison = comparison(repository, scope)?;
    report(repository, &comparison, OPERATION, fields, json!({"scope":scope}))
}

/// One tree against another.
pub(in crate::git_ops) fn between(
    repository: &Repository,
    from: String,
    to: String,
    fields: &Map<String, Value>,
    operation: &'static str,
    complete: bool,
) -> Result<Value, ResourceError> {
    let comparison = cmux_git::diff::between(repository, from, to);
    let mut metadata = json!({"from":fields.get("from"), "complete":complete});
    if let Some(to) = fields.get("to") {
        metadata.set("to", to.clone());
    }
    report(repository, &comparison, operation, fields, metadata)
}

/// The most unchanged lines a patch carries around each change.
const MAX_CONTEXT_LINES: usize = 1_000_000;

/// How much of each file's patch a reply carries.
#[derive(Clone, Copy)]
struct PatchLimits {
    max_patch_bytes: usize,
    context_lines: usize,
}

/// The changed files a comparison finds, with counts and bounded patches.
fn report(
    repository: &Repository,
    comparison: &Comparison,
    operation: &'static str,
    fields: &Map<String, Value>,
    metadata: Value,
) -> Result<Value, ResourceError> {
    let include_patch = fields.get("include_patch").and_then(Value::as_bool).unwrap_or(false);
    let max_patch_bytes = limit(fields, "max_patch_bytes", 262_144);
    let max_files = limit(fields, "max_files", 500);
    // Unchanged lines around each change; enough for a whole file lets the
    // changes view show more lines (cx-ncc.85).
    let context_lines = limit(fields, "context_lines", 3).min(MAX_CONTEXT_LINES);
    let paths = pathspecs(fields)?;
    let page_offset = page_offset(fields)?;
    if page_offset.is_some() && (!include_patch || paths.len() != 1) {
        return Err(ResourceError::validation_invalid(
            Some("patch_offset"),
            "a patch page requires include_patch and exactly one file path",
        ));
    }
    let page_key = capture_key(repository, fields, operation)?;
    if let Some(value) = continuation(repository, fields, operation)? {
        return Ok(value);
    }

    let mut files = tracked(repository, comparison, operation, &paths)?;
    let mut untracked_skipped = 0;
    if comparison.untracked {
        let listing = git(repository, operation, &untracked_args(&paths), MAX_LISTING_BYTES)?;
        let mut names = parse::file_list(&listing.stdout);
        if listing.truncated {
            // The last name may be cut short.
            names.pop();
        }
        untracked_skipped = names.len().saturating_sub(MAX_UNTRACKED_FILES);
        let counted = names.into_iter().take(MAX_UNTRACKED_FILES);
        files.extend(counted.map(|name| untracked(&repository.root, name)));
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    let additions = files.iter().map(|file| file.additions).sum::<u64>();
    let deletions = files.iter().map(|file| file.deletions).sum::<u64>();
    let total_files = files.len();
    if let Some(after_path) = fields.get("after_path").and_then(Value::as_str) {
        files.retain(|file| file.path.as_str() > after_path);
    }
    let page_files = files.len();
    files.truncate(max_files);
    let files_omitted = page_files - files.len();
    let wants_patch = include_patch && page_offset.is_none() && comparison.revisions.is_some();
    if wants_patch && files.iter().any(|file| file.status != "untracked") {
        let batches = if files_omitted == 0 && !fields.contains_key("after_path") {
            // Every file is returned: the request's own paths select them.
            vec![paths.clone()]
        } else {
            returned_paths(&files).chunks(PATCH_BATCH).map(<[String]>::to_vec).collect()
        };
        let limits = PatchLimits { max_patch_bytes, context_lines };
        attach_patches(repository, comparison, operation, &batches, &mut files, limits)?;
    }

    let mut value = json!({
        "root":repository.root.to_string_lossy(),
        "files":files.iter().map(ChangedFile::to_json).collect::<Vec<_>>(),
        "additions":clamp(additions),
        "deletions":clamp(deletions),
        "total_files":clamp(total_files as u64),
        "files_omitted":clamp(files_omitted as u64),
    });
    if let Some(head) = &comparison.head {
        value.set("head", json!(head));
    }
    if let Some(base) = &comparison.base {
        value.set("base", json!(base));
    }
    if untracked_skipped > 0 {
        value.set("untracked_skipped", json!(clamp(untracked_skipped as u64)));
    }
    if files_omitted > 0
        && let Some(last) = files.last()
    {
        value.set("next_path", json!(last.path));
    }
    if let Some(extra) = metadata.as_object()
        && let Some(object) = value.as_object_mut()
    {
        object.extend(extra.clone());
    }
    if let Some(offset) = page_offset {
        let file = match files.as_slice() {
            [file] if paths.first() == Some(&file.path) && file.has_patch() => file,
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("paths"),
                    "a patch page requires one changed text file",
                ));
            }
        };
        let (page, revision) = patch_page(
            repository,
            comparison,
            operation,
            file,
            context_lines,
            offset,
            fields,
            &value,
        )?;
        super::diff_pages::put(page_key, revision, value.clone());
        value.set("patch_page", page);
    }
    Ok(value)
}

#[allow(clippy::too_many_arguments)]
fn patch_page(
    repository: &Repository,
    comparison: &Comparison,
    operation: &'static str,
    file: &ChangedFile,
    context_lines: usize,
    offset: u64,
    fields: &Map<String, Value>,
    metadata: &Value,
) -> Result<(Value, super::diff_pages::Capture), ResourceError> {
    let paths = returned_paths(std::slice::from_ref(file));
    let unified = format!("--unified={context_lines}");
    let arguments = diff_args(comparison, &["--patch", "--full-index", &unified], &paths);
    let output = repository
        .run_window(&arguments, offset, PATCH_PAGE_BYTES)
        .map_err(|failure| git_failed(operation, &failure))?;
    let Some(window) = output.window else {
        return Err(ResourceError::operation_failed(
            operation,
            "could not read the patch page",
            json!({"code":"patch_read_failed"}),
        ));
    };
    let revision = page_revision(&window, metadata);
    if fields
        .get("patch_revision")
        .and_then(Value::as_str)
        .is_some_and(|expected| expected != revision)
    {
        return Err(ResourceError::operation_failed(
            operation,
            "the file changed while its patch was loading",
            json!({"code":"repository_changed"}),
        ));
    }
    if offset > window.total_bytes {
        return Err(ResourceError::validation_invalid(
            Some("patch_offset"),
            "patch_offset is past the end of the patch",
        ));
    }
    let page = page_value(&window, &revision, offset, output.stdout)?;
    Ok((page, super::diff_pages::Capture { revision, window }))
}

/// A page revision names the captured patch bytes and the listing returned
/// with page zero together. Continuations replay that listing, so a later
/// page zero with the same bytes but a different listing (say `complete`
/// changed) is a different revision and can never lend its listing to an
/// earlier reader's continuation, or the reverse.
fn page_revision(window: &GitWindow, metadata: &Value) -> String {
    use sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    hash.update(window.sha256.as_bytes());
    hash.update([0]);
    hash.update(metadata.to_string().as_bytes());
    hash.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

fn page_value(
    window: &GitWindow,
    revision: &str,
    offset: u64,
    bytes: Vec<u8>,
) -> Result<Value, ResourceError> {
    if offset > window.total_bytes {
        return Err(ResourceError::validation_invalid(
            Some("patch_offset"),
            "patch_offset is past the end of the patch",
        ));
    }
    let next = offset + bytes.len() as u64;
    Ok(json!({
        "offset": WireDecimal::new(offset),
        "next_offset": WireDecimal::new(next),
        "total_bytes": WireDecimal::new(window.total_bytes),
        "revision": revision,
        "data_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
        "complete": next == window.total_bytes,
    }))
}

/// A scope's comparison, with `git.diff`'s errors.
fn comparison(repository: &Repository, scope: &str) -> Result<Comparison, ResourceError> {
    cmux_git::diff::comparison(repository, scope).map_err(|error| match error {
        ScopeError::UnknownScope(other) => {
            ResourceError::validation_invalid(Some("scope"), format!("unknown scope {other:?}"))
        }
        ScopeError::NoBaseBranch => ResourceError::operation_failed(
            OPERATION,
            "no base branch: origin's default branch, main and master are all missing",
            json!({"code":"no_base_branch"}),
        ),
        ScopeError::NoMergeBase { base } => ResourceError::operation_failed(
            OPERATION,
            format!("HEAD and {base} have no common commit"),
            json!({"code":"no_merge_base","base":base}),
        ),
        ScopeError::Git(failure) => git_failed(OPERATION, &failure),
    })
}

/// The tracked files the comparison changes, with their counts.
fn tracked(
    repository: &Repository,
    comparison: &Comparison,
    operation: &'static str,
    paths: &[String],
) -> Result<Vec<ChangedFile>, ResourceError> {
    if comparison.revisions.is_none() {
        return Ok(Vec::new());
    }
    let statuses =
        listing(repository, operation, &diff_args(comparison, &["--name-status", "-z"], paths))?;
    let counts =
        listing(repository, operation, &diff_args(comparison, &["--numstat", "-z"], paths))?;
    let counts = parse::numstat(&counts.stdout);
    // An unmerged path is listed once per side; keep its first entry.
    let mut seen = HashSet::new();
    Ok(parse::name_status(&statuses.stdout)
        .into_iter()
        .filter(|entry| seen.insert(entry.path.clone()))
        .map(|entry| {
            let mut file = ChangedFile::new(entry.path, entry.status);
            file.previous_path = entry.previous_path;
            match counts.get(&file.path) {
                Some(Some(lines)) => {
                    file.additions = lines.additions;
                    file.deletions = lines.deletions;
                }
                Some(None) => file.binary = true,
                None => {}
            }
            file
        })
        .collect())
}

/// A file listing, which must be complete to pair its entries.
fn listing(
    repository: &Repository,
    operation: &'static str,
    arguments: &[&str],
) -> Result<GitOutput, ResourceError> {
    let output = git(repository, operation, arguments, MAX_LISTING_BYTES)?;
    if output.truncated {
        return Err(ResourceError::operation_failed(
            operation,
            "too many changed files to list; narrow the read with paths",
            json!({"code":"too_many_changes"}),
        ));
    }
    Ok(output)
}

fn attach_patches(
    repository: &Repository,
    comparison: &Comparison,
    operation: &'static str,
    batches: &[Vec<String>],
    files: &mut [ChangedFile],
    limits: PatchLimits,
) -> Result<(), ResourceError> {
    let PatchLimits { max_patch_bytes, context_lines } = limits;
    let unified = format!("--unified={context_lines}");
    let mut patches = HashMap::new();
    // Files whose patch may be incomplete: the last one of a cut run.
    let mut cut = HashSet::new();
    // Some run was cut or skipped, so a missing patch may exist.
    let mut incomplete = false;
    let mut collected = 0;
    for batch in batches {
        if collected >= MAX_REPLY_PATCH_BYTES {
            incomplete = true;
            break;
        }
        let arguments = diff_args(comparison, &["--patch", "--full-index", &unified], batch);
        let output = git(repository, operation, &arguments, MAX_PATCH_OUTPUT_BYTES)?;
        let sections = parse::patches(&output.stdout);
        let fingerprints =
            parse::blob_fingerprints(&output.stdout).into_iter().collect::<HashMap<_, _>>();
        for file in files.iter_mut().filter(|file| file.status != "untracked") {
            if let Some(fingerprint) = fingerprints.get(&file.path) {
                file.blob_fingerprint = Some(fingerprint.clone());
            }
        }
        if output.truncated {
            incomplete = true;
            cut.extend(sections.last().map(|(path, _)| path.clone()));
        }
        collected += sections.iter().map(|(_, patch)| patch.len()).sum::<usize>();
        patches.extend(sections);
    }
    let mut budget = MAX_REPLY_PATCH_BYTES;
    for file in files.iter_mut().filter(|file| file.has_patch()) {
        let Some(mut patch) = patches.remove(&file.path) else {
            file.patch_truncated = incomplete && file.additions + file.deletions > 0;
            continue;
        };
        let cut_here = parse::truncate_patch(&mut patch, max_patch_bytes.min(budget));
        file.patch_truncated = cut_here || cut.contains(&file.path);
        budget -= patch.len();
        if !patch.is_empty() {
            file.patch = Some(patch);
        }
    }
    Ok(())
}

/// The returned files' paths, with a rename's old path so git still pairs it.
fn returned_paths(files: &[ChangedFile]) -> Vec<String> {
    files
        .iter()
        .filter(|file| file.status != "untracked")
        .flat_map(|file| std::iter::once(file.path.clone()).chain(file.previous_path.clone()))
        .collect()
}

/// An untracked file counts its lines as additions; a binary, special or
/// large one counts none.
fn untracked(root: &Path, path: String) -> ChangedFile {
    let mut file = ChangedFile::new(path, "untracked");
    let Some(handle) = open_regular(&root.join(&file.path)) else { return file };
    let mut bytes = Vec::new();
    if handle.take(MAX_UNTRACKED_FILE_BYTES).read_to_end(&mut bytes).is_err() {
        return file;
    }
    if bytes[..bytes.len().min(BINARY_PROBE_BYTES)].contains(&0) {
        file.binary = true;
        return file;
    }
    let newlines = bytes.iter().filter(|byte| **byte == b'\n').count() as u64;
    file.additions = newlines + u64::from(!bytes.is_empty() && !bytes.ends_with(b"\n"));
    file
}

/// Opens a regular file without following a link or waiting on a FIFO.
fn open_regular(path: &Path) -> Option<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW);
    }
    let handle = options.open(path).ok()?;
    let metadata = handle.metadata().ok()?;
    (metadata.is_file() && metadata.len() <= MAX_UNTRACKED_FILE_BYTES).then_some(handle)
}

/// The request's paths, which must stay inside the repository.
fn pathspecs(fields: &Map<String, Value>) -> Result<Vec<String>, ResourceError> {
    let Some(paths) = fields.get("paths").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    paths
        .iter()
        .map(|path| {
            let raw = path.as_str().unwrap_or_default();
            let inside = Path::new(raw)
                .components()
                .all(|component| matches!(component, Component::Normal(_) | Component::CurDir));
            if inside {
                let normalized = Path::new(raw)
                    .components()
                    .filter_map(|part| match part {
                        Component::Normal(name) => Some(name.to_string_lossy()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join("/");
                Ok(if normalized.is_empty() && !raw.is_empty() {
                    ".".to_owned()
                } else {
                    normalized
                })
            } else {
                Err(ResourceError::validation_invalid(
                    Some("paths"),
                    format!("{raw:?} must be relative to the repository root and stay inside it"),
                ))
            }
        })
        .collect()
}

fn limit(fields: &Map<String, Value>, name: &str, default: u64) -> usize {
    let value = fields.get(name).and_then(Value::as_u64).unwrap_or(default);
    usize::try_from(value).unwrap_or(usize::MAX)
}

fn git(
    repository: &Repository,
    operation: &'static str,
    arguments: &[&str],
    max_stdout: usize,
) -> Result<GitOutput, ResourceError> {
    repository.run(arguments, max_stdout).map_err(|failure| git_failed(operation, &failure))
}
