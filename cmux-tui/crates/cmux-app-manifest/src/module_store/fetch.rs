//! The git commands that fetch a module, as argument lists with no shell.
//! The supervisor runs them under its sandbox with no inherited config,
//! no credential helper and no prompts. Trees are read as stored blobs (no
//! checkout, no smudge filters, no hooks).

use super::source::{GitSource, Pin};
use super::Refusal;
use std::path::Path;

/// One git invocation: arguments after the `git` program name, and the
/// environment it runs with (on top of an empty one).
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
pub fn ls_remote_plan(_source: &GitSource, _pin: &Pin) -> Option<FetchPlan> {
    None
}

/// Fetches exactly one commit, shallow, into the staging repository at `dest`.
pub fn fetch_plan(_source: &GitSource, _commit: &str, _dest: &Path) -> Result<FetchPlan, Refusal> {
    Err(Refusal::new("not.implemented", "fetch plan"))
}

/// Lists the commit's regular files with their modes and object ids.
pub fn ls_tree_plan(_commit: &str, _dest: &Path) -> Result<FetchPlan, Refusal> {
    Err(Refusal::new("not.implemented", "ls-tree plan"))
}

/// Resolves a tag pin from `git ls-remote` output (peeled commit first).
pub fn parse_ls_remote(_output: &str, _pin: &Pin) -> Result<String, Refusal> {
    Err(Refusal::new("not.implemented", "ls-remote"))
}

/// Parses `git ls-tree -r -z` output. Only regular blobs (`100644`, `100755`)
/// are accepted; symlinks, submodules and other modes are refused.
pub fn parse_ls_tree(_output: &[u8]) -> Result<Vec<TreeEntry>, Refusal> {
    Err(Refusal::new("not.implemented", "ls-tree"))
}
