//! `cmux repo hold DIR -- CMD…`: on a Cloud machine, the repository sync barrier
//! (`cmux_git::sync_barrier`) held around a command that finishes a checkout in the
//! background. The repo pick's step (cmux-cloud-start-core `machine_repo/step.sh`) clones
//! only the head of a repository, then runs the rest of its checkout under this, so a
//! Claude start goes ahead at the head while every tool waits for the whole tree
//! (cmuxterm-hq goals/cloud-no-network-wait.md).
//!
//! `hold` starts a detached `cmux repo hold-run` of itself and returns once that process
//! holds the barrier: it reads one line from the child's stdout, so nothing waits on a
//! timer. The child marks the head (`Sync::head_ready`) unless the head holds harness
//! settings that run a command at start, runs CMD with stdout sent to its stderr, and
//! completes the barrier only when CMD exits 0. A CMD that fails, or a child that dies,
//! leaves the barrier incomplete, so no tool runs on a partial checkout.
//!
//! `cmux repo wait DIR SECONDS` waits until the barrier on DIR is open: 0 once it is (or DIR has
//! none), 1 when its sync failed, 124 after SECONDS. The machine-config applier waits on it for a
//! checkout still filling, before its setup runs in it.

use std::io::{BufRead as _, BufReader};
use std::path::{Path, PathBuf};

use cmux_git::sync_barrier::Sync;
use cmux_process::{Command, Stdio};

const USAGE: &str = "usage: cmux repo hold DIR -- CMD [ARG...] | cmux repo wait DIR SECONDS";
/// The child's one stdout line once it holds the barrier.
const HELD: &str = "held";

pub(crate) fn run(args: &[String]) -> i32 {
    match args.split_first() {
        Some((verb, rest)) if verb == "hold" => match parse(rest) {
            Some(_) if rest.first().is_some_and(|a| a == "--help") => help(),
            Some((dir, cmd)) => hold(&dir, cmd),
            None => usage(),
        },
        Some((verb, [dir, seconds])) if verb == "wait" => match seconds.parse::<u64>() {
            Ok(seconds) => wait(Path::new(dir), std::time::Duration::from_secs(seconds)),
            Err(_) => usage(),
        },
        Some((verb, rest)) if verb == "hold-run" => match parse(rest) {
            Some((dir, cmd)) => hold_run(&dir, cmd, || println!("{HELD}")),
            None => usage(),
        },
        Some((verb, _)) if verb == "--help" || verb == "help" => help(),
        _ => usage(),
    }
}

fn help() -> i32 {
    println!("{USAGE}");
    0
}

fn usage() -> i32 {
    eprintln!("{USAGE}");
    2
}

/// `DIR -- CMD [ARG...]`; `--help` alone parses too, so the step can ask for the verb.
fn parse(rest: &[String]) -> Option<(PathBuf, &[String])> {
    if rest.first().is_some_and(|a| a == "--help") {
        return Some((PathBuf::new(), &[]));
    }
    match rest {
        [dir, dash, cmd @ ..] if dash == "--" && !cmd.is_empty() => Some((PathBuf::from(dir), cmd)),
        _ => None,
    }
}

/// Whether the head may be marked ready (`cmux_git::harness_head::head_allowed`): the repo
/// pick's head is the root's files and the harness folders, with no subpath.
pub(crate) fn head_allowed(dir: &Path) -> bool {
    cmux_git::harness_head::head_allowed(dir, &[])
}

/// Waits until the barrier on `dir` is open (`cmux_git::sync_barrier::wait_ready`).
pub(crate) fn wait(dir: &Path, timeout: std::time::Duration) -> i32 {
    match cmux_git::sync_barrier::wait_ready(dir, timeout) {
        Ok(()) => 0,
        Err(error) if error.kind() == std::io::ErrorKind::TimedOut => {
            eprintln!("cmux repo wait: {}: {error}", dir.display());
            124
        }
        Err(error) => {
            eprintln!("cmux repo wait: {}: {error}", dir.display());
            1
        }
    }
}

/// The child holds the barrier past this process; this one returns once it does.
fn hold(dir: &Path, cmd: &[String]) -> i32 {
    let Some(program) = super::host_mount::self_program() else {
        eprintln!("cmux repo hold: cannot find this cmux to run the hold");
        return 1;
    };
    let mut child = Command::new(program);
    child
        .arg("repo")
        .arg("hold-run")
        .arg(dir)
        .arg("--")
        .args(cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        // Its own session: the hold outlives this process and the caller's terminal.
        .new_session();
    let mut child = match child.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("cmux repo hold: cannot start the hold: {error}");
            return 1;
        }
    };
    child.detach("the hold outlives this command and the caller's terminal (its own session)");
    let Some(stdout) = child.stdout.take() else { return 1 };
    let mut line = String::new();
    // One blocking read: the child writes its line once it holds the barrier, or exits.
    match BufReader::new(stdout).read_line(&mut line) {
        Ok(_) if line.trim_end() == HELD => 0,
        _ => {
            // It ended (or never held): its own words are on stderr.
            let _ = child.wait();
            1
        }
    }
}

/// Holds the barrier on `dir` around `cmd`; `held` is called once the barrier is held
/// and the head marked (when it may be).
pub(crate) fn hold_run(dir: &Path, cmd: &[String], held: impl FnOnce()) -> i32 {
    let dir = match dir.canonicalize() {
        Ok(dir) => dir,
        Err(error) => {
            eprintln!("cmux repo hold: {}: {error}", dir.display());
            return 1;
        }
    };
    let mut sync = match Sync::begin(&dir) {
        Ok(sync) => sync,
        Err(error) => {
            eprintln!("cmux repo hold: {}: {error}", dir.display());
            return 1;
        }
    };
    if head_allowed(&dir) {
        sync.head_ready();
    }
    held();
    let Some((program, args)) = cmd.split_first() else { return 2 };
    // CMD's stdout goes to stderr: the reader of this process's stdout is gone by now.
    let stdout = match std::os::fd::AsFd::as_fd(&std::io::stderr()).try_clone_to_owned() {
        Ok(fd) => Stdio::from(fd),
        Err(error) => {
            eprintln!("cmux repo hold: cannot pass stderr to {program}: {error}");
            return 1;
        }
    };
    let status = Command::new(program).args(args).stdin(Stdio::null()).stdout(stdout).status();
    match status {
        Ok(status) if status.success() => match sync.complete() {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("cmux repo hold: cannot open the barrier of {}: {error}", dir.display());
                1
            }
        },
        Ok(status) => {
            eprintln!(
                "cmux repo hold: {program} ended with {status}; the checkout stays incomplete"
            );
            status.code().unwrap_or(1)
        }
        Err(error) => {
            eprintln!("cmux repo hold: cannot run {program}: {error}");
            1
        }
    }
}

#[cfg(test)]
#[path = "repo_hold_tests.rs"]
mod tests;
