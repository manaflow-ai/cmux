//! The git commands that fetch a module, as argument lists with no shell.
//! The supervisor runs them under its sandbox with an empty environment plus
//! the variables here: no system or user config, no credential helper, no
//! prompts, no hooks. Trees are read as stored blobs (`ls-tree` then
//! `cat-file`), so no checkout, smudge filter or hook can run.

use super::Refusal;
use super::digest::{MAX_FILES, validate_module_path};
use super::source::{GitSource, Pin, Transport};
use std::path::Path;

/// One git invocation: arguments after the `git` program name, and the
/// environment it runs with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchPlan {
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// One regular file of a commit's tree, as `git ls-tree` names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeEntry {
    pub path: String,
    pub executable: bool,
    pub object: String,
}

/// The lookup that turns a tag pin into a commit (`None` for a commit pin).
pub fn ls_remote_plan(source: &GitSource, pin: &Pin) -> Option<FetchPlan> {
    match pin {
        Pin::Commit(_) => None,
        Pin::Tag(tag) => {
            let mut args = guard_args(Some(source.transport()));
            args.push("ls-remote".to_string());
            args.push("--".to_string());
            args.push(source.clone_url());
            args.push(format!("refs/tags/{tag}"));
            args.push(format!("refs/tags/{tag}^{{}}"));
            Some(FetchPlan { args, env: guard_env() })
        }
    }
}

/// Fetches exactly one commit, shallow, into the staging repository at `dest`.
pub fn fetch_plan(source: &GitSource, commit: &str, dest: &Path) -> Result<FetchPlan, Refusal> {
    check_commit(commit)?;
    let mut args = vec!["-C".to_string(), dest_arg(dest)?];
    args.extend(guard_args(Some(source.transport())));
    args.extend(["fetch", "--depth=1", "--no-tags", "--no-recurse-submodules"].map(str::to_string));
    args.push("--".to_string());
    args.push(source.clone_url());
    args.push(commit.to_string());
    Ok(FetchPlan { args, env: guard_env() })
}

/// Lists the commit's regular files with their modes and object ids.
pub fn ls_tree_plan(commit: &str, dest: &Path) -> Result<FetchPlan, Refusal> {
    check_commit(commit)?;
    let mut args = vec!["-C".to_string(), dest_arg(dest)?];
    args.extend(guard_args(None));
    args.extend(["ls-tree", "-r", "-z", "--full-tree"].map(str::to_string));
    args.push(commit.to_string());
    Ok(FetchPlan { args, env: guard_env() })
}

/// Resolves a tag pin from `git ls-remote` output: the peeled commit of an
/// annotated tag wins over the tag object. A commit pin is its own answer.
pub fn parse_ls_remote(output: &str, pin: &Pin) -> Result<String, Refusal> {
    let tag = match pin {
        Pin::Commit(commit) => return Ok(commit.clone()),
        Pin::Tag(tag) => tag,
    };
    let direct = format!("refs/tags/{tag}");
    let peeled = format!("refs/tags/{tag}^{{}}");
    let mut direct_sha: Option<&str> = None;
    let mut peeled_sha: Option<&str> = None;
    for line in output.lines() {
        let (sha, name) = line.split_once('\t').ok_or_else(|| {
            Refusal::new("resolve.invalid", "ls-remote printed a line without a tab")
        })?;
        if !is_full_sha(sha) {
            return Err(Refusal::new("resolve.invalid", "ls-remote printed a malformed commit id"));
        }
        if name == peeled {
            peeled_sha = Some(sha);
        } else if name == direct {
            direct_sha = Some(sha);
        }
    }
    peeled_sha
        .or(direct_sha)
        .map(str::to_string)
        .ok_or_else(|| Refusal::new("pin.notFound", format!("the source has no tag {tag:?}")))
}

/// Parses `git ls-tree -r -z` output. Only regular blobs (`100644`, `100755`)
/// are accepted; symlinks, submodules and other modes are refused.
pub fn parse_ls_tree(output: &[u8]) -> Result<Vec<TreeEntry>, Refusal> {
    let mut entries = Vec::new();
    for record in output.split(|b| *b == 0) {
        if record.is_empty() {
            continue;
        }
        let text = std::str::from_utf8(record)
            .map_err(|_| Refusal::new("tree.invalid", "ls-tree printed a non-UTF-8 record"))?;
        let (meta, path) = text
            .split_once('\t')
            .ok_or_else(|| Refusal::new("tree.invalid", "an ls-tree record has no path"))?;
        let mut fields = meta.split(' ');
        let mode = fields.next().unwrap_or("");
        let kind = fields.next().unwrap_or("");
        let object = fields.next().unwrap_or("");
        if fields.next().is_some() || !is_full_sha(object) {
            return Err(Refusal::new(
                "tree.invalid",
                format!("a malformed ls-tree record for {path:?}"),
            ));
        }
        let executable = match mode {
            "100644" => false,
            "100755" => true,
            "120000" => {
                return Err(Refusal::new("tree.symlink", format!("{path} is a symbolic link")));
            }
            "160000" => {
                return Err(Refusal::new("tree.submodule", format!("{path} is a submodule")));
            }
            _ => return Err(Refusal::new("tree.mode", format!("{path} has mode {mode}"))),
        };
        if kind != "blob" {
            return Err(Refusal::new("tree.invalid", format!("{path} is not a blob")));
        }
        validate_module_path(path)?;
        if entries.len() >= MAX_FILES {
            return Err(Refusal::new("limit.files", format!("more than {MAX_FILES} files")));
        }
        entries.push(TreeEntry { path: path.to_string(), executable, object: object.to_string() });
    }
    Ok(entries)
}

/// Options that every git call gets. `protocol.allow=never` makes every
/// transport refused except the one named; `--` (added by callers) stops the
/// URL being read as an option; the empty credential helper runs nothing.
fn guard_args(protocol: Option<Transport>) -> Vec<String> {
    let mut pairs = vec![
        "core.hooksPath=/dev/null".to_string(),
        "core.fsmonitor=false".to_string(),
        "credential.helper=".to_string(),
        "fetch.fsckObjects=true".to_string(),
        "transfer.fsckObjects=true".to_string(),
        "gc.auto=0".to_string(),
    ];
    if let Some(transport) = protocol {
        pairs.push("protocol.allow=never".to_string());
        pairs.push(match transport {
            Transport::Https => "protocol.https.allow=always".to_string(),
            Transport::Ssh => "protocol.ssh.allow=always".to_string(),
        });
    }
    pairs.into_iter().flat_map(|p| ["-c".to_string(), p]).collect()
}

fn guard_env() -> Vec<(String, String)> {
    [
        ("GIT_CONFIG_NOSYSTEM", "1"),
        ("GIT_CONFIG_GLOBAL", "/dev/null"),
        ("GIT_TERMINAL_PROMPT", "0"),
        ("GIT_ASKPASS", "/usr/bin/false"),
        ("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"),
        ("GIT_OPTIONAL_LOCKS", "0"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

fn dest_arg(dest: &Path) -> Result<String, Refusal> {
    dest.to_str()
        .map(str::to_string)
        .ok_or_else(|| Refusal::new("path.invalid", "the staging path is not UTF-8"))
}

fn check_commit(commit: &str) -> Result<(), Refusal> {
    if is_full_sha(commit) {
        Ok(())
    } else {
        Err(Refusal::new("commit.invalid", "a commit must be a full lower-case SHA"))
    }
}

/// 40 (SHA-1) or 64 (SHA-256) lower-case hex characters.
pub(crate) fn is_full_sha(s: &str) -> bool {
    matches!(s.len(), 40 | 64)
        && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
