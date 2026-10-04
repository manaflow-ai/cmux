//! Persist after each turn (section 10: "the reference commits the directory
//! with git"): the chat directory is a git repository, and every turn ends
//! with a commit of its log and tree. One thread commits, in turn order, so
//! the brain never waits on git. The commits are local; pushing them
//! elsewhere (the backup) is the user's choice of remote.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{Sender, channel};

pub struct Persister {
    tx: Sender<String>,
}

impl Persister {
    /// Commits `dir` after each `turn_ended`. Failures are logged; a missing
    /// git is said once.
    pub fn start(dir: PathBuf, log: crate::brain::Log) -> std::io::Result<Persister> {
        let (tx, rx) = channel::<String>();
        std::thread::Builder::new()
            .name("persist".into())
            .spawn(move || {
                let mut told = false;
                for key in rx {
                    if let Err(e) = snapshot(&dir, &key)
                        && !told
                    {
                        told = true;
                        log(&format!(
                            "committing the memory after turn {key} failed: {e} (said once)"
                        ));
                    }
                }
            })?;
        Ok(Persister { tx })
    }

    pub fn turn_ended(&self, key: &str) {
        let _ = self.tx.send(key.to_owned());
    }
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=optchat-chief",
            "-c",
            "user.email=optchat-chief@localhost",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .map_err(|e| format!("running git: {e}"))?;
    let text =
        String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    if out.status.success() {
        Ok(text)
    } else {
        Err(format!("git {}: {}", args.join(" "), text.trim()))
    }
}

/// Commits everything in `dir` (creating the repository on first use) with
/// the turn key as the message. A turn that changed nothing commits nothing.
pub fn snapshot(dir: &Path, key: &str) -> Result<(), String> {
    if !dir.join(".git").exists() {
        git(dir, &["init", "-q"])?;
        // The chat's single-writer lock is process state, not history.
        std::fs::write(dir.join(".gitignore"), "lock\n*.tmp*\n").map_err(|e| e.to_string())?;
    }
    git(dir, &["add", "-A"])?;
    if git(dir, &["diff", "--cached", "--quiet"]).is_ok() {
        return Ok(());
    }
    git(dir, &["commit", "-q", "-m", key]).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_turn_with_changes_is_one_commit() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("lock"), "1").unwrap();
        std::fs::create_dir(dir.path().join("main")).unwrap();
        std::fs::write(dir.path().join("main/a.jsonl"), "{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:0:1").unwrap();
        snapshot(dir.path(), "turn:optchat:0:1").unwrap();
        std::fs::write(dir.path().join("main/a.jsonl"), "{}\n{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:2:3").unwrap();
        let log = git(dir.path(), &["log", "--format=%s"]).unwrap();
        assert_eq!(log, "turn:optchat:2:3\nturn:optchat:0:1\n");
        let tracked = git(dir.path(), &["ls-files"]).unwrap();
        assert!(!tracked.lines().any(|l| l == "lock"), "{tracked}");
    }
}
