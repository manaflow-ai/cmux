//! The git leg of `cmux link sync pull`: the machine's branch and staged
//! changes come back by the same three-way rule as files, against the git
//! state the push recorded ([`GitBase`]).
//!
//! - HEAD: the machine still at the pushed commit keeps this Mac's; this
//!   Mac still at it moves to the machine's, only as a fast-forward of the
//!   same branch; both moved to different commits, a switched branch or a
//!   rewritten history is a conflict (`.git/HEAD`).
//! - Staged changes (`git ls-files --stage`): the same rule; the machine's
//!   come back as the tree they make (`.git/index` on conflict).
//!
//! Nothing of the machine's `.git` is copied here as it is: no hooks,
//! config, info, alternates or refs files. Its objects (loose ones and pack
//! data, never its pack indexes) go into a quarantine repository this
//! command makes in its staging folder, whose object store borrows this
//! repository's (`objects/info/alternates`); its HEAD and index are read as
//! data. Git itself then fetches only what the new commit and staged tree
//! need from the quarantine, checking every object (`transfer.fsckObjects`),
//! and the branch moves by compare-and-swap (`git update-ref NEW OLD`).

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use super::remote::Remote;
use super::{Manifest, names};

/// Most bytes one object file or pack of the machine may have; streamed to
/// disk, never held in memory.
const MAX_OBJECT_BYTES: u64 = 4 << 30;

/// The git state of a working copy, as a push records it and a pull
/// compares it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct GitBase {
    /// The branch HEAD is on (`refs/heads/...`); None when detached.
    #[serde(default)]
    pub head_ref: Option<String>,
    /// HEAD's commit; None before the first commit.
    #[serde(default)]
    pub head: Option<String>,
    /// SHA-256 of `git ls-files --stage -z`: what is staged.
    pub staged: String,
}

/// The git state of the working copy at `folder`.
pub(super) fn base_of(folder: &Path) -> anyhow::Result<GitBase> {
    let head_ref = output(local(folder).args(["symbolic-ref", "-q", "HEAD"]))?
        .map(|text| text.trim().to_string());
    let head = output(local(folder).args(["rev-parse", "-q", "--verify", "HEAD^{commit}"]))?
        .map(|text| text.trim().to_string());
    let staged = digest(&checked(local(folder).args(["ls-files", "--stage", "-z"]))?);
    Ok(GitBase { head_ref, head, staged })
}

/// This working copy's `core.hooksPath` as its own settings give it; None
/// when unset.
pub(super) fn hooks_path(folder: &Path) -> anyhow::Result<Option<String>> {
    Ok(output(local(folder).args(["config", "--get", "core.hooksPath"]))?
        .map(|text| text.trim_end_matches('\n').to_string())
        .filter(|path| !path.is_empty()))
}

/// What the git leg changes here once no file conflicts.
pub(super) struct GitPlan {
    quarantine: PathBuf,
    local: GitBase,
    /// Move HEAD's branch (or a detached HEAD) to this commit.
    head: Option<String>,
    /// Stage this commit's tree (the machine's staged changes).
    staged: Option<String>,
    /// The base a later pull compares with.
    pub settled: GitBase,
}

/// A conflict of the git leg: `.git/HEAD` or `.git/index`, and why.
pub(super) type GitConflict = (String, String);

/// Where a pull's git leg works: the working copy, its common git folder,
/// and this pull's own folder (the quarantine goes under it).
pub(super) struct Where<'a> {
    pub folder: &'a Path,
    pub common_dir: &'a Path,
    pub staging: &'a Path,
}

/// Compares the machine's git state with the pushed base and this Mac's.
/// A commit or staged tree that would add or change a hook (in `hooks`) or
/// a repository here is a conflict ([`names::carries_repository_or_hook`]):
/// once in the branch or index, any checkout would write it out.
pub(super) fn plan(
    remote: &mut Remote,
    remote_root: &str,
    at: &Where<'_>,
    manifest: &Manifest,
    hooks: &[String],
) -> anyhow::Result<Result<Option<GitPlan>, Vec<GitConflict>>> {
    let Where { folder, common_dir, staging } = *at;
    let here = base_of(folder)?;
    let remote_git = format!("{remote_root}/.git");
    let (vm_ref, vm_head) = machine_head(remote, &remote_git)?;
    // The machine's HEAD and index as the push left them: nothing came back.
    if let Some(base) = &manifest.git
        && base.head_ref == vm_ref
        && base.head == vm_head
    {
        let pushed = manifest.files.get(".git/index").map(|file| file.revision.as_str());
        let stat = remote.stat(&format!("{remote_git}/index"))?;
        let now = stat.as_ref().and_then(|stat| stat["revision"].as_str());
        if pushed.is_some() && pushed == now {
            return Ok(Ok(None));
        }
    }
    let quarantine = staging.join("quarantine.git");
    quarantined(&quarantine, common_dir)?;
    copy_objects(remote, &remote_git, &quarantine, manifest)?;
    let vm_index = quarantine.join("machine-index");
    if let Some(bytes) = remote.read(&format!("{remote_git}/index"))? {
        std::fs::write(&vm_index, bytes)?;
    }
    let vm_staged = quarantine_git(&quarantine)
        .env("GIT_INDEX_FILE", &vm_index)
        .args(["ls-files", "--stage", "-z"])
        .output()
        .context("cannot run git")?;
    if !vm_staged.status.success() {
        let why = "cmux can't read the machine's staged changes";
        return Ok(Err(vec![(".git/index".into(), why.into())]));
    }
    let vm = GitBase { head_ref: vm_ref, head: vm_head, staged: digest(&vm_staged.stdout) };
    // An older push recorded no git state: only an unchanged machine is safe.
    let base = manifest.git.clone().unwrap_or_else(|| here.clone());

    let mut conflicts = Vec::new();
    let mut settled = base.clone();
    let mut head = None;
    let head_of = |state: &GitBase| (state.head_ref.clone(), state.head.clone());
    if head_of(&vm) != head_of(&base) {
        if head_of(&here) == head_of(&vm) {
            settled.head_ref = vm.head_ref.clone();
            settled.head = vm.head.clone();
        } else if head_of(&here) != head_of(&base) {
            conflicts.push(head_conflict("both this Mac and the machine moved the branch"));
        } else if vm.head_ref != base.head_ref {
            let name = vm.head_ref.as_deref().unwrap_or("a detached HEAD");
            conflicts.push(head_conflict(&format!("the machine switched to {name}")));
        } else if let Some(new) = vm.head.clone() {
            let fast_forward = base.head.as_ref().is_none_or(|old| {
                quarantine_git(&quarantine)
                    .args(["merge-base", "--is-ancestor"])
                    .arg(old)
                    .arg(&new)
                    .status()
                    .is_ok_and(|status| status.success())
            });
            if fast_forward {
                settled.head = Some(new.clone());
                head = Some(new);
            } else {
                conflicts.push(head_conflict("the machine rewrote the branch's history"));
            }
        } else {
            conflicts.push(head_conflict("the machine's branch has no commit"));
        }
    }
    let mut staged = None;
    if vm.staged != base.staged {
        if here.staged == vm.staged {
            settled.staged = vm.staged;
        } else if here.staged != base.staged {
            let why = "both this Mac and the machine changed what is staged";
            conflicts.push((".git/index".into(), why.into()));
        } else {
            match staged_commit(&quarantine, &vm_staged.stdout)? {
                Some(commit) => {
                    settled.staged = vm.staged;
                    staged = Some(commit);
                }
                None => {
                    let why = "the machine's staged changes are unmerged or incomplete";
                    conflicts.push((".git/index".into(), why.into()));
                }
            }
        }
    }
    if let Some(why) = carried(&quarantine, base.head.as_deref(), head.as_deref(), hooks)? {
        conflicts.push(head_conflict(&why));
    }
    if staged.is_some() {
        let tree_of = head.as_deref().or(here.head.as_deref());
        if let Some(why) = carried(&quarantine, tree_of, staged.as_deref(), hooks)? {
            conflicts.push((".git/index".into(), why));
        }
    }
    if !conflicts.is_empty() {
        return Ok(Err(conflicts));
    }
    if head.is_none() && staged.is_none() && settled == base && manifest.git.is_some() {
        return Ok(Ok(None));
    }
    Ok(Ok(Some(GitPlan { quarantine, local: here, head, staged, settled })))
}

/// Why the commit `new` can't come back over `old` (None: nothing before):
/// a path it adds or changes carries a hook or a repository here.
fn carried(
    quarantine: &Path,
    old: Option<&str>,
    new: Option<&str>,
    hooks: &[String],
) -> anyhow::Result<Option<String>> {
    let Some(new) = new else { return Ok(None) };
    let mut command = quarantine_git(quarantine);
    match old {
        Some(old) => {
            command.args(["diff-tree", "-r", "-z", "--no-renames", "--name-only"]).arg(old)
        }
        None => command.args(["ls-tree", "-r", "-z", "--name-only"]),
    };
    let paths = checked(command.arg(new))?;
    let hit = paths
        .split(|byte| *byte == 0)
        .map(String::from_utf8_lossy)
        .find(|path| !path.is_empty() && names::carries_repository_or_hook(path, hooks));
    Ok(hit.map(|path| format!("the machine's changes add a hook or a repository: {path}")))
}

fn head_conflict(why: &str) -> GitConflict {
    (".git/HEAD".into(), why.into())
}

impl GitPlan {
    /// Fetches what the plan needs from the quarantine, every object
    /// checked. Only objects arrive: no ref, index or file changes here.
    pub(super) fn fetch(&self, folder: &Path) -> anyhow::Result<()> {
        let mut wanted = Vec::new();
        if let Some(head) = &self.head {
            set_ref(&self.quarantine, "refs/cmux-sync/head", head)?;
            wanted.push("refs/cmux-sync/head");
        }
        if let Some(staged) = &self.staged {
            set_ref(&self.quarantine, "refs/cmux-sync/staged", staged)?;
            wanted.push("refs/cmux-sync/staged");
        }
        if !wanted.is_empty() {
            checked(
                local(folder)
                    .args(["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"])
                    .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head"])
                    .args(["--no-recurse-submodules", "--no-auto-gc"])
                    .arg(&self.quarantine)
                    .args(&wanted),
            )
            .context("cannot fetch the machine's commits")?;
        }
        Ok(())
    }

    /// Moves HEAD's branch, then the staged changes, once this Mac's branch
    /// and index are checked to be still as the plan saw them. The branch
    /// moves by compare-and-swap, and moves back if the index can't follow.
    /// Returns whether the branch moved.
    pub(super) fn commit(&self, folder: &Path) -> anyhow::Result<bool> {
        if base_of(folder)? != self.local {
            bail!("this Mac's branch or staged changes changed during the pull");
        }
        let zero = |id: &str| "0".repeat(id.len());
        let move_ref = |new: &str, old: &str| {
            let mut command = local(folder);
            command.args(["update-ref", "-m", "cmux sync pull: bring back from the machine"]);
            match &self.local.head_ref {
                Some(name) => command.arg(name),
                None => command.args(["--no-deref", "HEAD"]),
            };
            checked(command.args([new, old])).map(drop)
        };
        let old =
            self.head.as_deref().map(|head| self.local.head.clone().unwrap_or_else(|| zero(head)));
        if let (Some(head), Some(old)) = (&self.head, &old) {
            move_ref(head, old).context("cannot move the branch")?;
        }
        if let Some(staged) = &self.staged {
            let read = checked(local(folder).arg("read-tree").arg(format!("{staged}^{{tree}}")));
            if let Err(error) = read {
                if let (Some(head), Some(old)) = (&self.head, &old) {
                    let _ = move_ref(old, head);
                }
                return Err(error.context("cannot stage the machine's changes"));
            }
        }
        Ok(self.head.is_some())
    }
}

/// The machine's HEAD: its branch (None when detached) and commit (None on
/// a branch with no commit).
fn machine_head(
    remote: &mut Remote,
    remote_git: &str,
) -> anyhow::Result<(Option<String>, Option<String>)> {
    let head = remote.read(&format!("{remote_git}/HEAD"))?.context("the machine has no HEAD")?;
    let head = String::from_utf8(head).context("the machine's HEAD is not text")?;
    let head = head.trim();
    let Some(name) = head.strip_prefix("ref:").map(str::trim) else {
        return Ok((None, Some(object_id(head)?)));
    };
    let plain = name.strip_prefix("refs/heads/").is_some_and(|branch| {
        !branch.is_empty()
            && branch.split('/').all(|part| {
                !part.is_empty()
                    && !part.starts_with('.')
                    && !part.ends_with(".lock")
                    && part.chars().all(|c| c.is_ascii_graphic() && !"~^:?*[\\".contains(c))
            })
            && !branch.contains("..")
            && !branch.contains("@{")
    });
    if !plain {
        bail!("the machine's HEAD names {name}, not a branch");
    }
    if let Some(loose) = remote.read(&format!("{remote_git}/{name}"))? {
        let loose = String::from_utf8(loose).context("the machine's branch is not text")?;
        return Ok((Some(name.to_string()), Some(object_id(loose.trim())?)));
    }
    let packed = remote.read(&format!("{remote_git}/packed-refs"))?.unwrap_or_default();
    let packed = String::from_utf8_lossy(&packed);
    let commit = packed.lines().find_map(|line| {
        let (id, listed) = line.split_once(' ')?;
        (listed == name).then(|| id.to_string())
    });
    Ok((Some(name.to_string()), commit.map(|id| object_id(&id)).transpose()?))
}

/// `text` if it is a SHA-1 or SHA-256 object id.
fn object_id(text: &str) -> anyhow::Result<String> {
    let hex = text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if !hex || !matches!(text.len(), 40 | 64) {
        bail!("the machine's HEAD is not an object id");
    }
    Ok(text.to_string())
}

/// Makes the quarantine: an empty bare repository of this command's own,
/// whose object store borrows this repository's.
pub(super) fn quarantined(quarantine: &Path, common_dir: &Path) -> anyhow::Result<()> {
    let format = output(
        Command::new("git").arg("-C").arg(common_dir).args(["rev-parse", "--show-object-format"]),
    )?
    .unwrap_or_else(|| "sha1".into());
    checked(
        clean(Command::new("git"))
            .args(["init", "--quiet", "--bare", "--template="])
            .arg(format!("--object-format={}", format.trim()))
            .arg(quarantine),
    )?;
    let objects = std::fs::canonicalize(common_dir.join("objects"))?;
    let objects = objects.to_str().context("the repository's path is not UTF-8")?;
    std::fs::create_dir_all(quarantine.join("objects/info"))?;
    std::fs::write(quarantine.join("objects/info/alternates"), format!("{objects}\n"))?;
    Ok(())
}

/// Copies the machine's objects this Mac did not push into the quarantine:
/// loose objects, and pack data that git indexes itself. Nothing else of
/// `objects/` (alternates, info, pack indexes) is read.
fn copy_objects(
    remote: &mut Remote,
    remote_git: &str,
    quarantine: &Path,
    manifest: &Manifest,
) -> anyhow::Result<()> {
    let objects = format!("{remote_git}/objects");
    let Some(top) = remote.list(&objects)? else { return Ok(()) };
    let pushed = |relative: &str, revision: &Option<String>| {
        manifest
            .files
            .get(&format!(".git/objects/{relative}"))
            .is_some_and(|file| Some(&file.revision) == revision.as_ref())
    };
    for (name, entry) in top {
        let loose = name.len() == 2 && is_hex(&name);
        if entry.kind != "dir" || !(loose || name == "pack") {
            continue;
        }
        let Some(files) = remote.list(&format!("{objects}/{name}"))? else { continue };
        for (file, found) in files {
            let relative = format!("{name}/{file}");
            let wanted = if loose {
                matches!(file.len(), 38 | 62) && is_hex(&file)
            } else {
                file.strip_prefix("pack-")
                    .and_then(|rest| rest.strip_suffix(".pack"))
                    .is_some_and(|id| matches!(id.len(), 40 | 64) && is_hex(id))
            };
            if found.kind != "file" || !wanted || pushed(&relative, &found.revision) {
                continue;
            }
            let target = quarantine.join("objects").join(&relative);
            std::fs::create_dir_all(target.parent().context("no parent")?)?;
            let mut out = std::fs::File::create(&target)?;
            let source = format!("{objects}/{relative}");
            if remote.read_into(&source, &mut out, MAX_OBJECT_BYTES)?.is_none() {
                drop(out);
                std::fs::remove_file(&target)?;
                continue;
            }
            if !loose {
                checked(quarantine_git(quarantine).arg("index-pack").arg(&target))
                    .with_context(|| format!("the machine's {relative} is not a valid pack"))?;
            }
        }
    }
    Ok(())
}

fn is_hex(text: &str) -> bool {
    text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The tree the machine's staged entries make (`entries`: its index's
/// `ls-files --stage -z`), as a commit of the quarantine; None when it
/// can't make one (unmerged entries, a missing object). The tree is built
/// from the entries in a new index, never from the machine's index's own
/// cached trees, which could name any tree.
fn staged_commit(quarantine: &Path, entries: &[u8]) -> anyhow::Result<Option<String>> {
    let index = quarantine.join("rebuilt-index");
    let _ = std::fs::remove_file(&index);
    let mut child = quarantine_git(quarantine)
        .env("GIT_INDEX_FILE", &index)
        .args(["update-index", "-z", "--index-info"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("cannot run git")?;
    let mut stdin = child.stdin.take().context("no stdin")?;
    let input = entries.to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&input));
    let built = child.wait().context("cannot run git")?;
    let _ = writer.join();
    if !built.success() {
        return Ok(None);
    }
    let tree = quarantine_git(quarantine)
        .env("GIT_INDEX_FILE", &index)
        .arg("write-tree")
        .output()
        .context("cannot run git")?;
    if !tree.status.success() {
        return Ok(None);
    }
    let tree = String::from_utf8_lossy(&tree.stdout).trim().to_string();
    let commit = checked(
        quarantine_git(quarantine)
            .args(["-c", "user.name=cmux", "-c", "user.email=cmux@localhost"])
            .args(["commit-tree", "-m", "cmux sync pull: staged on the machine"])
            .arg(tree),
    )?;
    Ok(Some(String::from_utf8_lossy(&commit).trim().to_string()))
}

fn set_ref(quarantine: &Path, name: &str, id: &str) -> anyhow::Result<()> {
    checked(quarantine_git(quarantine).args(["update-ref", name, id]))?;
    Ok(())
}

/// git in the working copy at `folder`, with the person's own settings.
pub(super) fn local(folder: &Path) -> Command {
    let mut command = Command::new("git");
    command.arg("-C").arg(folder);
    command
}

/// git in the quarantine, with no global or system settings.
pub(super) fn quarantine_git(quarantine: &Path) -> Command {
    let mut command = clean(Command::new("git"));
    command.arg("--git-dir").arg(quarantine);
    command
}

fn clean(mut command: Command) -> Command {
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES");
    command
}

/// The command's stdout, or an error with its stderr.
pub(super) fn checked(command: &mut Command) -> anyhow::Result<Vec<u8>> {
    let output = command.output().context("cannot run git")?;
    if !output.status.success() {
        bail!("git: {}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(output.stdout)
}

/// The command's stdout as text; None when it exits 1 (a question answered
/// "no"); an error otherwise.
fn output(command: &mut Command) -> anyhow::Result<Option<String>> {
    let output = command.output().context("cannot run git")?;
    match output.status.code() {
        Some(0) => Ok(Some(String::from_utf8_lossy(&output.stdout).into_owned())),
        Some(1) => Ok(None),
        _ => bail!("git: {}", String::from_utf8_lossy(&output.stderr).trim()),
    }
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}
