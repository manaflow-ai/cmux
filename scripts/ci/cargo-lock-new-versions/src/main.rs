//! cargo-lock-new-versions --base SHA [--head REV]
//!
//! Compares every Cargo.lock the change touches (base..head) against every Cargo.lock at base,
//! and fails when a changed lock has a downloaded (crate, version) none of them has, unless the
//! PR_BODY environment variable (the pull request body) has a `Cargo-Lock-New-Versions: <why>` line.
//! Exit 0: nothing new, or allowed. 1: new versions, not allowed. 2: usage or git error.

use std::process::{Command, ExitCode};

use cargo_lock_new_versions::{allowed, base_set, failure_text, new_versions};

fn git(args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .args(args)
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    String::from_utf8(out.stdout).map_err(|e| format!("git {}: {e}", args.join(" ")))
}

fn is_lock(path: &str) -> bool {
    path == "Cargo.lock" || path.ends_with("/Cargo.lock")
}

fn run() -> Result<ExitCode, String> {
    let mut base = None;
    let mut head = "HEAD".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--base" => base = args.next(),
            "--head" => head = args.next().ok_or("--head needs a revision")?,
            _ => {
                return Err(format!(
                "unknown argument {arg}; usage: cargo-lock-new-versions --base SHA [--head REV]"
            ))
            }
        }
    }
    let base = base
        .filter(|b| !b.is_empty())
        .ok_or("--base SHA is required")?;

    let changed_paths: Vec<String> = git(&[
        "diff",
        "--name-only",
        "--no-renames",
        "--diff-filter=AM",
        &base,
        &head,
        "--",
        "*Cargo.lock",
    ])?
    .lines()
    .filter(|p| is_lock(p))
    .map(str::to_string)
    .collect();
    if changed_paths.is_empty() {
        println!("no Cargo.lock changed");
        return Ok(ExitCode::SUCCESS);
    }

    let base_locks: Vec<String> = git(&["ls-tree", "-r", "--name-only", &base])?
        .lines()
        .filter(|p| is_lock(p))
        .map(|p| git(&["show", &format!("{base}:{p}")]))
        .collect::<Result<_, _>>()?;
    let known = base_set(base_locks.iter().map(String::as_str));

    let changed: Vec<(String, String)> = changed_paths
        .into_iter()
        .map(|p| git(&["show", &format!("{head}:{p}")]).map(|text| (p, text)))
        .collect::<Result<_, _>>()?;

    let findings = new_versions(&known, &changed);
    if findings.is_empty() {
        println!(
            "{} changed Cargo.lock(s): every (crate, version) is already in a base Cargo.lock",
            changed.len()
        );
        return Ok(ExitCode::SUCCESS);
    }
    let text = failure_text(&findings);
    if let Some(reason) = allowed(&std::env::var("PR_BODY").unwrap_or_default()) {
        println!("allowed by the pull request body (Cargo-Lock-New-Versions: {reason}):\n{text}");
        return Ok(ExitCode::SUCCESS);
    }
    for f in &findings {
        println!(
            "::error file={}::{} {} is in no base Cargo.lock",
            f.lock, f.name, f.version
        );
    }
    print!("{text}");
    Ok(ExitCode::from(1))
}

fn main() -> ExitCode {
    run().unwrap_or_else(|e| {
        eprintln!("cargo-lock-new-versions: {e}");
        ExitCode::from(2)
    })
}
