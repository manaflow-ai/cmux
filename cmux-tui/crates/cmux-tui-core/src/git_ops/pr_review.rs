//! `git.review.start|comment|post`: review a GitHub pull request from its
//! link, with the diff page's comments as the review's drafts.
//!
//! - `start` checks the pull request out into a worktree of its own
//!   (`git.worktree.create`'s folder and `cmux/review-<n>` branch) at its
//!   head, and records the merge-base with its base branch as the branch's
//!   `cmuxBase`, so the diff page's branch scope shows exactly the pull
//!   request's change. The pull request is recorded with the worktree's
//!   comments (`diff_comments`), which is how the page knows where they go.
//!   A worktree already on that head is reused, with its drafts.
//! - `comment` saves one draft on lines of that diff, as the diff page saves
//!   a comment, for an agent reviewing the worktree. A line GitHub would not
//!   take a comment on is refused with the lines it would.
//! - `post` sends the drafts the page names to GitHub as one review with the
//!   person's own `gh`, then clears those still unchanged. The app calls it
//!   only on the person's click (`DiffPageProvider+Comments.swift`).
//!
//! `gh` and `git fetch` run in the user's environment (`user_run`), never
//! prompting, bounded by one deadline.

mod github;

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use serde_json::{Map, Value, json};

use self::github::{Hunks, PullRef, Side};
use super::checkpoint::ledger;
use super::diff_comments::{self, Store};
use super::mutation::{Target, key, normalized, output_extra, refused, run_failed};
use super::user_run::{UserGit, deadline};
use super::{Repository, open_repository, worktree};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

const START: &str = "git.review.start";
const COMMENT: &str = "git.review.comment";
pub(crate) const POST: &str = "git.review.post";

/// Advertised in identify: the session host owns `git.review.*`.
pub(crate) const CAPABILITY: &str = "git-review-v1";

/// The whole pull request diff `comment` and `post` read for its hunks.
const MAX_DIFF_BYTES: usize = 16 * 1024 * 1024;
/// A file `comment` reads one line of.
const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 16 * 1024;
const MAX_FILE_PATH_BYTES: usize = 4096;

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitReviewStart
            | ResourceOperation::GitReviewComment
            | ResourceOperation::GitReviewPost
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::GitReviewStart => start(mux, request),
        ResourceOperation::GitReviewComment => comment(mux, request),
        ResourceOperation::GitReviewPost => post(mux, request),
        // Dispatched only for the operations `handles` names; any other is refused, never a panic.
        _ => Err(ResourceError::operation_failed(
            request.envelope.operation.wire_name(),
            "unsupported",
            json!({"message": "pr_review does not handle this operation"}),
        )),
    }
}

/// What `gh pr view` says of the pull request.
struct Pull {
    title: String,
    head: String,
    base: String,
    base_branch: String,
}

fn start(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let url = request.fields.get("url").and_then(Value::as_str).unwrap_or_default();
    let Some(pull) = PullRef::parse(url) else {
        let message = "url must be a pull request's link, https://github.com/OWNER/REPO/pull/N";
        return Err(ResourceError::validation_invalid(Some("url"), message));
    };
    let key = key(request);
    let target = Target::resolve(mux, request, START)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(START, || {
        if let Some(replayed) = ledger::prior(mux, &key, START, &fingerprint)? {
            return Ok(replayed);
        }
        let repository = &target.repository;
        let git = UserGit { root: &repository.root, deadline: deadline() };
        let view = view(&git, &pull)?;
        let remote = remote(repository, &pull)?;
        let pulled = format!("refs/pull/{}/head", pull.number);
        let base_branch = format!("refs/heads/{}", view.base_branch);
        let arguments = ["fetch", "--no-tags", "--quiet", &remote, &pulled, &base_branch];
        // Untrusted, like the checkout: the fetch writes refs, and a hook
        // (`reference-transaction`) of a checkout made from a pull request
        // would run that pull request's code.
        let untrusted = worktree::untrusted(&repository.root)?;
        let run = git
            .run_with(&arguments, &worktree::borrowed(&untrusted))
            .map_err(|failure| run_failed(START, &failure))?;
        if !run.success {
            let message = format!("git fetch {remote} {pulled} failed");
            return Err(refused(START, "fetch_failed", message, output_extra(&run.output())));
        }
        if repository.commit(&view.head).is_none() || repository.commit(&view.base).is_none() {
            let message = "the pull request moved while it was fetched; start the review again";
            return Err(refused(START, "pull_request_moved", message, Value::Null));
        }
        let base = merge_base(repository, &view.base, &view.head)?;
        let (folder, branch, reused) = worktree(&target, &git, &pull, &view.head)?;
        for (setting, value) in [("cmuxBase", base.as_str()), ("cmuxReview", &pull.url())] {
            let setting = format!("branch.{branch}.{setting}");
            let run = git
                .run(&["config", setting.as_str(), value])
                .map_err(|failure| run_failed(START, &failure))?;
            if !run.success {
                let message = "the worktree was made, but recording its pull request failed";
                return Err(refused(START, "git_failed", message, output_extra(&run.output())));
            }
        }
        // The diff page keys comments by the root `git.status` names, which
        // is git's own top level of the folder.
        let root = open_repository(&folder, START).map_err(normalized)?.root;
        let root = root.to_string_lossy().into_owned();
        let review = json!({
            "url": pull.url(),
            "repo": pull.repository(),
            "number": pull.number,
            "title": view.title,
            "head": view.head,
            "base": base,
        });
        Store::open(mux, START)?
            .set_review(&root, review)
            .map_err(|error| diff_comments::io_failed(START, &error))?;
        let value = json!({
            "root": root,
            "branch": branch,
            "url": pull.url(),
            "repo": pull.repository(),
            "number": pull.number,
            "title": view.title,
            "head": view.head,
            "base": base,
            // No diff or textconv driver: one can run a script the pull
            // request changes.
            "diff": format!("git diff --no-ext-diff --no-textconv {base} HEAD"),
            // A review never runs the worktree's setup recipe: the recipe
            // (or a script it names) is the pull request's code, run with
            // the person's environment before anyone read it.
            "setup": {"state": "none"},
            "reused": reused,
        });
        ledger::commit(mux, &key, START, &fingerprint, &value, false, &request.actor)
    })
}

/// `gh pr view`: the pull request's title, head and base.
fn view(git: &UserGit<'_>, pull: &PullRef) -> Result<Pull, ResourceError> {
    let fields = "title,headRefOid,baseRefOid,baseRefName";
    let url = pull.url();
    let run = gh(git, &["pr", "view", url.as_str(), "--json", fields], None, START)?;
    let view: Value = serde_json::from_slice(&run.stdout).unwrap_or(Value::Null);
    let text = |name: &str| view.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
    let pulled = Pull {
        title: text("title"),
        head: text("headRefOid"),
        base: text("baseRefOid"),
        base_branch: text("baseRefName"),
    };
    let commit = |sha: &str| sha.len() >= 40 && sha.bytes().all(|byte| byte.is_ascii_hexdigit());
    let branch = &pulled.base_branch;
    if !commit(&pulled.head)
        || !commit(&pulled.base)
        || branch.is_empty()
        || branch.starts_with('-')
        || branch.contains(char::is_whitespace)
    {
        let message = "gh pr view did not name the pull request's head and base";
        return Err(refused(START, "gh_failed", message, output_extra(&run.output())));
    }
    Ok(pulled)
}

/// The remote of this checkout that is the pull request's repository, by
/// the URL its config names (before any `insteadOf` rewrite, which may point
/// at a mirror).
fn remote(repository: &Repository, pull: &PullRef) -> Result<String, ResourceError> {
    let arguments = ["config", "--get-regexp", r"^remote\..*\.url$"];
    // No remote at all is an exit of 1 with nothing printed.
    let listing = repository
        .run(&arguments, 64 * 1024)
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
        .unwrap_or_default();
    listing
        .lines()
        .filter_map(|line| {
            let (setting, url) = line.split_once(' ')?;
            let name = setting.strip_prefix("remote.")?.strip_suffix(".url")?;
            Some((name, url))
        })
        .find(|(name, url)| !name.starts_with('-') && pull.is_remote(url))
        .map(|(name, _)| name.to_string())
        .ok_or_else(|| {
            let message = format!(
                "no remote of this checkout is {}; run the review from a clone of it (gh repo clone {})",
                pull.repository(),
                pull.repository()
            );
            refused(START, "no_remote", message, json!({"repo": pull.repository()}))
        })
}

fn merge_base(repository: &Repository, base: &str, head: &str) -> Result<String, ResourceError> {
    let output = repository
        .run(&["merge-base", base, head], 1024)
        .map_err(|failure| refused(START, "git_failed", failure.reason(), Value::Null))?;
    let merge_base = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if merge_base.is_empty() {
        let message = "the pull request's head and base share no commit";
        return Err(refused(START, "git_failed", message, Value::Null));
    }
    Ok(merge_base)
}

/// The review's worktree: one already on `head` from an earlier review of
/// this pull request (its drafts kept), else a new one at `head`. Answers
/// its folder, branch and whether it was reused.
fn worktree(
    target: &Target,
    git: &UserGit<'_>,
    pull: &PullRef,
    head: &str,
) -> Result<(PathBuf, String, bool), ResourceError> {
    let name = format!("review-{}", pull.number);
    if let Some((folder, branch)) = existing(&target.repository, &name, &pull.url(), head) {
        return Ok((folder, branch, true));
    }
    let fields = Map::from_iter([("name".into(), json!(name)), ("base".into(), json!(head))]);
    let attempt = worktree::plan(&target.repository, target.common_dir(), &fields)?;
    // Untrusted: no hook or filter driver runs, since either could run the
    // pull request's code in its checkout before anyone read it.
    worktree::create(&target.repository, git, &attempt, Some(&pull.url()))?;
    Ok((attempt.root, attempt.branch, false))
}

/// A worktree on `cmux/<name>` or `cmux/<name>-<k>` whose HEAD is `head`
/// and whose branch an earlier review of `url` recorded (`cmuxReview`): an
/// ordinary worktree that happens to have the name keeps its comments.
fn existing(
    repository: &Repository,
    name: &str,
    url: &str,
    head: &str,
) -> Option<(PathBuf, String)> {
    let output = repository.run(&["worktree", "list", "--porcelain"], 1024 * 1024).ok()?;
    let listing = String::from_utf8_lossy(&output.stdout).into_owned();
    let prefix = format!("refs/heads/{}{name}", worktree::BRANCH_PREFIX);
    listing.split("\n\n").find_map(|block| {
        let line = |key: &str| block.lines().find_map(|line| line.strip_prefix(key));
        let (folder, at, branch) = (line("worktree ")?, line("HEAD ")?, line("branch ")?);
        let suffix = branch.strip_prefix(&prefix)?;
        let ours = suffix.is_empty()
            || suffix.strip_prefix('-').is_some_and(|k| k.bytes().all(|b| b.is_ascii_digit()));
        let branch = branch.trim_start_matches("refs/heads/");
        let setting = format!("branch.{branch}.cmuxReview");
        let reviews = || {
            let output = repository.run(&["config", "--get", setting.as_str()], 4096).ok()?;
            (String::from_utf8_lossy(&output.stdout).trim() == url).then_some(())
        };
        (ours && at == head && Path::new(folder).is_dir() && reviews().is_some())
            .then(|| (PathBuf::from(folder), branch.to_string()))
    })
}

fn comment(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let fields = &request.fields;
    let message = fields.get("message").and_then(Value::as_str).unwrap_or_default().trim();
    if message.is_empty() || message.len() > MAX_MESSAGE_BYTES {
        let text = format!("message must be 1 to {MAX_MESSAGE_BYTES} bytes");
        return Err(ResourceError::validation_invalid(Some("message"), text));
    }
    let line =
        |name: &str| fields.get(name).and_then(Value::as_u64).and_then(|v| u32::try_from(v).ok());
    let Some(end) = line("line").filter(|line| *line > 0) else {
        return Err(ResourceError::validation_invalid(Some("line"), "line must be at least 1"));
    };
    let start = line("start_line").unwrap_or(end);
    if start == 0 || start > end {
        let text = "start_line must be at least 1 and at most line";
        return Err(ResourceError::validation_invalid(Some("start_line"), text));
    }
    let side = match fields.get("side").and_then(Value::as_str) {
        None => Side::Additions,
        Some(side) => Side::parse(side).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("side"),
                "side is new (additions) or old (deletions)",
            )
        })?,
    };
    let directory = super::target::directory(mux, request, COMMENT).map_err(normalized)?;
    let repository = open_repository(&directory, COMMENT).map_err(normalized)?;
    let root = repository.root.to_string_lossy().into_owned();
    let file = file_path(fields.get("file").and_then(Value::as_str), &repository.root)?;
    let store = Store::open(mux, COMMENT)?;
    let stored = store.read(&root).map_err(|error| diff_comments::io_failed(COMMENT, &error))?;
    let base = stored.review.as_ref().and_then(|review| review.get("base")?.as_str());
    let Some(base) = base else {
        let message = format!(
            "{root} is not a pull request review's worktree; run cmux git review start <url> and comment in the folder it prints"
        );
        return Err(refused(COMMENT, "not_a_review", message, Value::Null));
    };
    // The reviewed head, not the worktree's HEAD now: drafts are on the
    // commit the review is posted on.
    let head = stored.review.as_ref().and_then(|review| review.get("head")?.as_str());
    let head = head.unwrap_or("HEAD");
    let hunks = hunks(&repository, base, head, COMMENT)?.remove(&file).unwrap_or_default();
    if !hunks.covers(side, start, end) {
        let lines = if start < end { format!("{start}-{end}") } else { end.to_string() };
        let shown = hunks.describe(side);
        let (version, extra) = match side {
            Side::Additions => ("new", json!({"new_lines": shown})),
            Side::Deletions => ("old", json!({"old_lines": shown})),
        };
        let message = if shown.is_empty() {
            format!("the pull request's diff shows no {version} lines of {file}")
        } else {
            format!(
                "{file}:{lines} is not in the pull request's diff; its {version} lines there are {shown}"
            )
        };
        return Err(refused(COMMENT, "not_in_diff", message, extra));
    }
    // The base's text of a renamed file is under its old name.
    let (revision, path) = match side {
        Side::Additions => (head, file.as_str()),
        Side::Deletions => (base, hunks.old_path.as_deref().unwrap_or(&file)),
    };
    let line_text = line_text(&repository, revision, path, end)?;
    let comment = Map::from_iter([
        ("filePath".into(), json!(file)),
        ("side".into(), json!(side.page_name())),
        ("startLine".into(), json!(start)),
        ("endLine".into(), json!(end)),
        ("lineText".into(), json!(line_text)),
        ("message".into(), json!(message)),
    ]);
    diff_comments::mutate(mux, &store, request, &root, |file, key| {
        diff_comments::save(file, &root, key, comment)
    })
}

/// The file a comment names, relative to the worktree's root: a relative
/// path inside it, or an absolute one under it.
fn file_path(file: Option<&str>, root: &Path) -> Result<String, ResourceError> {
    let invalid = || {
        let message = "file must be a path inside the worktree";
        ResourceError::validation_invalid(Some("file"), message)
    };
    let file = file.filter(|file| !file.is_empty() && file.len() <= MAX_FILE_PATH_BYTES);
    let file = Path::new(file.ok_or_else(invalid)?);
    let relative =
        if file.is_absolute() { file.strip_prefix(root).map_err(|_| invalid())? } else { file };
    let parts: Option<Vec<&str>> = relative
        .components()
        .filter(|part| *part != Component::CurDir)
        .map(|part| match part {
            Component::Normal(part) => part.to_str(),
            _ => None,
        })
        .collect();
    parts.filter(|parts| !parts.is_empty()).map(|parts| parts.join("/")).ok_or_else(invalid)
}

/// Each file's hunks in the pull request's diff, as GitHub shows it: from
/// the merge-base to the reviewed head, renames found, three lines of
/// context.
fn hunks(
    repository: &Repository,
    base: &str,
    head: &str,
    operation: &str,
) -> Result<BTreeMap<String, Hunks>, ResourceError> {
    let arguments = [
        "-c",
        "core.quotePath=false",
        "diff",
        "--no-color",
        "--no-ext-diff",
        // A textconv driver can name a script the pull request itself
        // changes: reading its diff must never run its code.
        "--no-textconv",
        // The hunk reader needs `a/` and `b/`, whatever `diff.noprefix` or
        // `diff.mnemonicPrefix` the person set.
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "-M",
        github::CONTEXT_LINES,
        // GitHub's hunks: a `diff.interHunkContext` the person set would join
        // two of them, and a line between them would pass as in the diff.
        "--inter-hunk-context=0",
        base,
        head,
    ];
    let output = repository
        .run(&arguments, MAX_DIFF_BYTES)
        .map_err(|failure| refused(operation, "git_failed", failure.reason(), Value::Null))?;
    if output.truncated {
        let message = format!("the pull request's diff is over {MAX_DIFF_BYTES} bytes");
        return Err(refused(operation, "too_large", message, Value::Null));
    }
    Ok(github::file_hunks(&String::from_utf8_lossy(&output.stdout)))
}

/// Line `line` of `file` at `revision`, without its line ending: the blob
/// as stored, with no filter or textconv run.
fn line_text(
    repository: &Repository,
    revision: &str,
    file: &str,
    line: u32,
) -> Result<String, ResourceError> {
    let object = format!("{revision}:{file}");
    let output = repository
        .run(&["cat-file", "blob", object.as_str()], MAX_FILE_BYTES)
        .map_err(|failure| refused(COMMENT, "git_failed", failure.reason(), Value::Null))?;
    if output.truncated {
        let message = format!("{file} is over {MAX_FILE_BYTES} bytes at {revision}");
        return Err(refused(COMMENT, "too_large", message, Value::Null));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let index = usize::try_from(line).unwrap_or(usize::MAX).saturating_sub(1);
    text.lines().nth(index).map(|line| line.trim_end_matches('\r').to_string()).ok_or_else(|| {
        let message = format!("{file} has no line {line} at {revision}");
        refused(COMMENT, "not_in_diff", message, Value::Null)
    })
}

fn post(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, &request.selectors)?;
    let root = diff_comments::root(&request.fields)?;
    let ids = diff_comments::ids(&request.fields)?;
    let versions = diff_comments::versions(&request.fields)?;
    // Every draft's version: a retry that finds its review already posted
    // clears only drafts unchanged since, so an edit made after a lost reply
    // stays for the next post instead of being cleared unposted.
    if let Some(id) = ids.iter().find(|id| !versions.contains_key(id.as_str())) {
        let message = format!("versions must name every id's updatedAt; {id} has none");
        return Err(ResourceError::validation_invalid(Some("versions"), message));
    }
    let store = Store::open(mux, POST)?;
    diff_comments::mutate(mux, &store, request, root, |file, key| {
        let review = file.review.clone().unwrap_or(Value::Null);
        let text =
            |name: &str| review.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
        let (Some(pull), head, base) = (PullRef::parse(&text("url")), text("head"), text("base"))
        else {
            let message = format!("{root} is not a pull request review's worktree");
            return Err(refused(POST, "not_a_review", message, Value::Null));
        };
        // The drafts the page named, as it last read them: one edited since
        // waits for the next post.
        let chosen: Vec<&Map<String, Value>> = file
            .sorted()
            .into_iter()
            .filter(|comment| {
                let id = comment.get("id").and_then(Value::as_str).unwrap_or_default();
                ids.iter().any(|named| named == id)
                    && versions
                        .get(id)
                        .is_none_or(|version| comment.get("updatedAt") == Some(version))
            })
            .collect();
        let repository = open_repository(Path::new(root), POST).map_err(normalized)?;
        let marker = github::marker(key);
        let drafted =
            github::review(&head, &chosen, &hunks(&repository, &base, &head, POST)?, &marker);
        let git = UserGit { root: &repository.root, deadline: deadline() };
        let path = format!("repos/{}/pulls/{}/reviews", pull.repository(), pull.number);
        // A post whose answer was lost may still have reached GitHub: its
        // retry (the same key) finds the review by the key's marker in its
        // body before it posts, so the person never gets it twice, even when
        // every draft it carried was edited since.
        let url = match posted_review(&git, &path, &marker)? {
            Some(url) => url,
            None if drafted.ids.is_empty() => {
                let message = "none of the named drafts is still listed unchanged";
                return Err(refused(POST, "nothing_to_post", message, Value::Null));
            }
            None => {
                let input = serde_json::to_vec(&drafted.payload).unwrap_or_default();
                let arguments = ["api", "--method", "POST", path.as_str(), "--input", "-"];
                let run = gh(&git, &arguments, Some(input), POST)?;
                let posted: Value = serde_json::from_slice(&run.stdout).unwrap_or(Value::Null);
                posted
                    .get("html_url")
                    .and_then(Value::as_str)
                    .map_or_else(|| pull.url(), str::to_string)
            }
        };
        // Posted: the drafts leave, except one edited while it was on its way.
        let (deleted, changed) = diff_comments::delete(file, &drafted.ids, &versions);
        let value = json!({
            "url": url,
            "posted": drafted.inline,
            "in_body": drafted.in_body,
            "cleared": deleted.get("ids").cloned().unwrap_or_default(),
        });
        Ok((value, changed))
    })
}

/// The link of a review on the pull request whose body carries `marker`.
fn posted_review(
    git: &UserGit<'_>,
    path: &str,
    marker: &str,
) -> Result<Option<String>, ResourceError> {
    let filter = format!(".[] | select((.body // \"\") | contains({})) | .html_url", json!(marker));
    let arguments = ["api", "--paginate", path, "--jq", filter.as_str()];
    let run = gh(git, &arguments, None, POST)?;
    let listed = String::from_utf8_lossy(&run.stdout);
    Ok(listed.lines().map(str::trim).find(|line| !line.is_empty()).map(str::to_string))
}

/// Runs the person's `gh`; a run that fails is `gh_failed` with what gh
/// printed, and no `gh` at all is `gh_unavailable`.
fn gh(
    git: &UserGit<'_>,
    arguments: &[&str],
    input: Option<Vec<u8>>,
    operation: &str,
) -> Result<super::user_run::UserRun, ResourceError> {
    let Some(program) = gh_program() else {
        let message =
            "gh (GitHub's command line tool) is not installed; install it and run gh auth login";
        return Err(refused(operation, "gh_unavailable", message, Value::Null));
    };
    let extra = [("GH_PROMPT_DISABLED", "1"), ("GH_NO_UPDATE_NOTIFIER", "1"), ("NO_COLOR", "1")];
    let run = git
        .run_program(program.as_os_str(), arguments, &extra, input)
        .map_err(|failure| run_failed(operation, &failure))?;
    if !run.success {
        // gh's own last words (a login to renew, a line GitHub refused) say
        // what to fix.
        let said = run.stderr.lines().map(str::trim).rfind(|line| !line.is_empty());
        let said: String = said.unwrap_or_default().chars().take(300).collect();
        let message = format!(
            "gh {} failed{}{said}",
            arguments.iter().take(2).copied().collect::<Vec<_>>().join(" "),
            if said.is_empty() { "" } else { ": " }
        );
        return Err(refused(operation, "gh_failed", message, output_extra(&run.output())));
    }
    Ok(run)
}

/// `gh` on the daemon's PATH, else where Homebrew and installers put it: an
/// app started from the Dock has a PATH without them. Absolute folders
/// only, so a relative entry never runs a file planted in a project.
fn gh_program() -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let home = crate::platform::home_dir();
    std::env::split_paths(&path)
        .chain(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from))
        .chain(home.map(|home| home.join(".local/bin")))
        .filter(|folder| folder.is_absolute())
        .map(|folder| folder.join("gh"))
        .find(|program| program.is_file())
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use super::*;

    #[test]
    fn file_paths_stay_inside_the_worktree() {
        let root = Path::new("/w/review-1");
        assert_eq!(file_path(Some("./src/a.rs"), root).unwrap(), "src/a.rs");
        assert_eq!(file_path(Some("/w/review-1/src/a.rs"), root).unwrap(), "src/a.rs");
        for refused in ["", "../a.rs", "/elsewhere/a.rs", "src/../../a.rs", "."] {
            assert!(file_path(Some(refused), root).is_err(), "{refused}");
        }
        assert!(file_path(None, root).is_err());
    }

    #[test]
    fn gh_is_looked_up_by_absolute_path() {
        if let Some(program) = gh_program() {
            assert!(program.is_absolute());
            assert_eq!(program.file_name(), Some(OsStr::new("gh")));
        }
    }
}
