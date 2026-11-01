//! What a seeded folder holds now, as the Mac's seed plan would see it: its
//! index as a tree, and its working tree with untracked files that are not
//! ignored as a tree, built in a copy of the index so the real one is not
//! touched. Untracked secrets ([`super::secrets`]) and untracked git
//! repositories nested in the folder are left out, as the Mac leaves them
//! out of its WORK commit, so the same files give the same trees on both
//! sides. A delta seed compares these trees with the last seed's, and an
//! export makes its INDEX and WORK commits from them ([`commit`]).

use std::path::Path;

use super::git::{Credential, Failure, Git};

/// The fixed identity and date of INDEX and WORK commits, the same as the
/// Mac's seed plan (`link/seed/plan.rs`), so the same tree on the same
/// parent always gives the same commit on either side.
const SEED_NAME: &str = "cmux seed";
const SEED_EMAIL: &str = "seed@cmux.invalid";
const SEED_DATE: &str = "946684800 +0000";
/// The messages of the Mac's INDEX and WORK commits.
pub const INDEX_MESSAGE: &str = "cmux seed index";
pub const WORK_MESSAGE: &str = "cmux seed work";

pub struct Snapshot {
    pub index: String,
    pub work: String,
    /// The untracked paths left out of `work` (a nested repository ends in
    /// `/`), for display (a name that is not UTF-8 is shown lossily).
    pub left_out: Vec<String>,
}

impl Snapshot {
    pub fn take(git: &Git, credential: &Credential, folder: &Path) -> Result<Self, Failure> {
        let git_dir =
            text(git.quiet(Some(folder), credential, &["rev-parse", "--absolute-git-dir"])?);
        let git_dir = Path::new(&git_dir);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        let copy = git_dir.join(format!("cmux-seed-index-{}-{nanos}", std::process::id()));
        let list = git_dir.join(format!("cmux-seed-paths-{}-{nanos}", std::process::id()));
        let result = (|| -> Result<Self, Failure> {
            let real = git_dir.join("index");
            if real.is_file() {
                std::fs::copy(&real, &copy).map_err(io_failure)?;
            } else {
                git.run_in(
                    Some(folder),
                    credential,
                    &["read-tree", "HEAD"],
                    Some(&copy),
                    &mut |_| {},
                )?;
            }
            let tree = || -> Result<String, Failure> {
                let out = git.run_in(
                    Some(folder),
                    credential,
                    &["write-tree"],
                    Some(&copy),
                    &mut |_| {},
                )?;
                Ok(text(out))
            };
            let index = tree()?;
            let left_out = left_out(git, credential, folder)?;
            // `.` plus an exclude per path left out: `add -A` never reads a
            // nested repository (one with no commit would fail it).
            let mut pathspecs = b".\0".to_vec();
            // The raw names: a name that is not UTF-8 is excluded as it is,
            // never by a lossy spelling that matches nothing.
            for path in &left_out {
                pathspecs.extend_from_slice(b":(exclude,literal)");
                pathspecs.extend_from_slice(path.strip_suffix(b"/").unwrap_or(path));
                pathspecs.push(0);
            }
            std::fs::write(&list, pathspecs).map_err(io_failure)?;
            let from = format!("--pathspec-from-file={}", list.display());
            git.run_in(
                Some(folder),
                credential,
                &["add", "-A", "--sparse", "--pathspec-file-nul", &from],
                Some(&copy),
                &mut |_| {},
            )?;
            let work = tree()?;
            let left_out =
                left_out.iter().map(|path| String::from_utf8_lossy(path).into_owned()).collect();
            Ok(Self { index, work, left_out })
        })();
        let _ = std::fs::remove_file(&copy);
        let _ = std::fs::remove_file(&list);
        result
    }
}

/// Untracked paths that stay where they are, as git's raw bytes: nested
/// repositories and likely secrets.
fn left_out(git: &Git, credential: &Credential, folder: &Path) -> Result<Vec<Vec<u8>>, Failure> {
    let listed =
        git.quiet(Some(folder), credential, &["ls-files", "-z", "--others", "--exclude-standard"])?;
    Ok(listed
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .filter(|path| path.ends_with(b"/") || super::secrets::reason(folder, path).is_some())
        .map(<[u8]>::to_vec)
        .collect())
}

/// A commit of `tree` on `parent` with the seed's fixed identity and date.
pub fn commit(
    git: &Git,
    credential: &Credential,
    folder: &Path,
    tree: &str,
    parent: &str,
    message: &str,
) -> Result<String, Failure> {
    let env: Vec<(&str, &std::ffi::OsStr)> = [
        ("GIT_AUTHOR_NAME", SEED_NAME),
        ("GIT_AUTHOR_EMAIL", SEED_EMAIL),
        ("GIT_AUTHOR_DATE", SEED_DATE),
        ("GIT_COMMITTER_NAME", SEED_NAME),
        ("GIT_COMMITTER_EMAIL", SEED_EMAIL),
        ("GIT_COMMITTER_DATE", SEED_DATE),
    ]
    .into_iter()
    .map(|(name, value)| (name, std::ffi::OsStr::new(value)))
    .collect();
    let out = git.run_env(
        Some(folder),
        credential,
        &[
            "-c",
            "i18n.commitEncoding=UTF-8",
            "commit-tree",
            "--no-gpg-sign",
            "-p",
            parent,
            "-m",
            message,
            tree,
        ],
        &env,
        &mut |_| {},
    )?;
    Ok(text(out))
}

fn text(out: Vec<u8>) -> String {
    String::from_utf8_lossy(&out).trim().to_owned()
}

fn io_failure(error: std::io::Error) -> Failure {
    Failure::of(format!("fatal: {error}"))
}
