//! A patch (a unified diff, as `git diff` writes it) applied to a [`Remote`] with nothing cloned:
//! only the files it touches are projected, `git apply` runs on them in a temporary folder, and
//! what it wrote comes back as the chat's edits. The folder is deleted before this returns.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::time::Duration;

use anyhow::{Context as _, bail};
use cmux_process::{Command, Stdio};

use crate::remote::{Remote, check_path};

/// `git apply` on the touched files alone.
const APPLY_TIMEOUT: Duration = Duration::from_secs(60);

/// The paths a patch reads (`before`) and writes (`after`).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Touched {
    pub before: BTreeSet<String>,
    pub after: BTreeSet<String>,
}

fn strip(side: &str, prefix: &str) -> anyhow::Result<Option<String>> {
    // A plain diff may follow the name with a tab and a time.
    let name = side.split('\t').next().unwrap_or_default().trim_end();
    if name == "/dev/null" {
        return Ok(None);
    }
    if name.starts_with('"') {
        bail!(
            "the patch quotes a path ({name}); write it with `git diff --no-ext-diff` and plain names"
        );
    }
    let path = name.strip_prefix(prefix).unwrap_or(name).to_owned();
    check_path(&path)?;
    Ok(Some(path))
}

/// What `patch` touches, from its `---`, `+++`, `rename` and `copy` lines.
pub fn touched(patch: &str) -> anyhow::Result<Touched> {
    let mut out = Touched::default();
    for line in patch.lines() {
        if line.starts_with("GIT binary patch") {
            bail!("the patch changes a binary file; write that file with `cmux repo commit --put`");
        }
        let (side, prefix, before) = if let Some(rest) = line.strip_prefix("--- ") {
            (rest, "a/", true)
        } else if let Some(rest) = line.strip_prefix("+++ ") {
            (rest, "b/", false)
        } else if let Some(rest) =
            line.strip_prefix("rename from ").or_else(|| line.strip_prefix("copy from "))
        {
            (rest, "", true)
        } else if let Some(rest) =
            line.strip_prefix("rename to ").or_else(|| line.strip_prefix("copy to "))
        {
            (rest, "", false)
        } else {
            continue;
        };
        if let Some(path) = strip(side, prefix)? {
            if before {
                out.before.insert(path)
            } else {
                out.after.insert(path)
            };
        }
    }
    if out.before.is_empty() && out.after.is_empty() {
        bail!("the patch changes no file");
    }
    Ok(out)
}

/// Applies `patch` to `remote`'s files as edits. Answers the paths it changed.
pub async fn apply(remote: &mut Remote, patch: &str) -> anyhow::Result<Vec<String>> {
    let touched = touched(patch)?;
    let all: BTreeSet<String> = touched.before.union(&touched.after).cloned().collect();
    let patterns: Vec<String> = all.iter().cloned().collect();
    let projected = remote.project(&patterns).await?;
    let dir = projected.path().to_owned();
    let patch = patch.to_owned();
    let applied = tokio::task::spawn_blocking(move || git_apply(&dir, &patch)).await?;
    applied?;
    let mut changed = Vec::new();
    for path in &all {
        let at = projected.path().join(path);
        match std::fs::symlink_metadata(&at) {
            Ok(meta) if meta.is_file() => {
                use std::os::unix::fs::PermissionsExt as _;
                let mode = if meta.permissions().mode() & 0o111 != 0 { "100755" } else { "100644" };
                let bytes = std::fs::read(&at)?;
                remote.write_mode(path, bytes, mode)?;
            }
            Ok(_) => bail!("{path}: the patch left something that is not a file"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if touched.before.contains(path) {
                    remote.delete(path).await?;
                } else {
                    continue;
                }
            }
            Err(e) => return Err(e.into()),
        }
        changed.push(path.clone());
    }
    projected.close()?;
    Ok(changed)
}

/// `git apply` in `dir`, which is in no repository (`GIT_CEILING_DIRECTORIES` stops git finding
/// one above it, so the paths stay the patch's own).
fn git_apply(dir: &std::path::Path, patch: &str) -> anyhow::Result<()> {
    let ceiling = dir.parent().unwrap_or(dir);
    // The patch and git's errors go through files, so no pipe can fill while git runs.
    let mut file = tempfile::NamedTempFile::new()?;
    file.write_all(patch.as_bytes())?;
    let errors = tempfile::tempfile()?;
    let mut child = Command::new("git")
        .current_dir(dir)
        .env("GIT_CEILING_DIRECTORIES", ceiling)
        .args(["apply", "--whitespace=nowarn"])
        .arg(file.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(errors.try_clone()?)
        .spawn()
        .context("cannot run git apply")?;
    let Some(status) = child.wait_timeout(APPLY_TIMEOUT)? else {
        let _ = child.kill();
        let _ = child.wait();
        bail!("git apply took over {} s", APPLY_TIMEOUT.as_secs());
    };
    if !status.success() {
        use std::io::{Read as _, Seek as _};
        let mut errors = errors;
        let mut text = String::new();
        errors.rewind()?;
        let _ = errors.take(16 * 1024).read_to_string(&mut text);
        bail!("the patch does not apply to the base: {}", text.trim());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_git_diff_names_what_it_reads_and_writes() {
        let patch = "diff --git a/src/a.py b/src/a.py\nindex 1..2 100644\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n\
diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+n\n\
diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-o\n\
diff --git a/r1 b/r2\nsimilarity index 100%\nrename from r1\nrename to r2\n";
        let t = touched(patch).unwrap();
        let set = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<BTreeSet<_>>();
        assert_eq!(t.before, set(&["old.txt", "r1", "src/a.py"]));
        assert_eq!(t.after, set(&["new.txt", "r2", "src/a.py"]));
    }

    #[test]
    fn a_patch_that_leaves_the_repository_or_is_binary_or_empty_is_refused() {
        assert!(touched("--- a/../x\n+++ b/../x\n").is_err());
        assert!(touched("--- a/.git/config\n+++ b/.git/config\n").is_err());
        assert!(touched("--- \"a/q\\tx\"\n").is_err());
        assert!(touched("GIT binary patch\nliteral 3\n").is_err());
        assert!(touched("hello\n").is_err());
        // A plain diff's names with times.
        let t = touched("--- a/x.c\t2026-11-17 10:00\n+++ b/x.c\t2026-11-17 10:01\n").unwrap();
        assert!(t.after.contains("x.c"));
    }
}
