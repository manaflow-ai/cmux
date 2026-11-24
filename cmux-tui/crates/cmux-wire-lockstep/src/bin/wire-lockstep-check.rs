//! CI: every wire manifest under `cmux-tui/spec/wire/` at the head against the same file at the
//! base revision (`cmux_wire_lockstep::check`). Fails on a message one side would send that the
//! other never said it knows.
//!
//! Run from the repository root (or pass `--root`):
//!
//! ```text
//! cargo run -p cmux-wire-lockstep --bin wire-lockstep-check --locked -- --base HEAD^1
//! cargo run -p cmux-wire-lockstep --bin wire-lockstep-check --locked -- --base REF --export-base DIR
//! ```
//!
//! `--export-base DIR` also writes the base's manifests to DIR, for the protocols' old-against-new
//! tests (`CMUX_WIRE_BASE_DIR=DIR`).
//!
//! `--against REF` (repeatable) also checks the head against another open change built on the same
//! base (`origin/lane/x`): a wire number both newly claim for different kinds or tags fails, the
//! collision each passes alone and the second to land breaks.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use cmux_wire_lockstep::{Manifest, check, collisions};

const DIR: &str = "cmux-tui/spec/wire";

fn git_show(root: &Path, rev: &str, path: &str) -> Result<Option<String>, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["show", &format!("{rev}:{path}")])
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        return Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()));
    }
    let err = String::from_utf8_lossy(&out.stderr);
    // The base has no such file yet: the first revision that records this protocol.
    if err.contains("does not exist") || err.contains("exists on disk, but not in") {
        return Ok(None);
    }
    Err(format!("git show {rev}:{path}: {}", err.trim()))
}

fn main() -> ExitCode {
    let mut root = PathBuf::from(".");
    let mut base = String::from("HEAD^1");
    let mut export: Option<PathBuf> = None;
    let mut against: Vec<String> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from).unwrap_or(root),
            "--base" => base = args.next().unwrap_or(base),
            "--export-base" => export = args.next().map(PathBuf::from),
            "--against" => against.extend(args.next()),
            other => {
                eprintln!(
                    "unknown argument {other}; usage: wire-lockstep-check [--root DIR] [--base REV] [--export-base DIR] [--against REF]..."
                );
                return ExitCode::from(2);
            }
        }
    }
    let dir = root.join(DIR);
    let mut paths: Vec<PathBuf> = match std::fs::read_dir(&dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .collect(),
        Err(e) => {
            eprintln!("{}: {e}", dir.display());
            return ExitCode::FAILURE;
        }
    };
    paths.sort();
    if let Some(export) = &export
        && let Err(e) = std::fs::create_dir_all(export)
    {
        eprintln!("{}: {e}", export.display());
        return ExitCode::FAILURE;
    }

    let mut failed = false;
    for path in paths {
        let Some(file) = path.file_name().and_then(|f| f.to_str()) else { continue };
        let rel = format!("{DIR}/{file}");
        let head = match std::fs::read_to_string(&path)
            .map_err(|e| e.to_string())
            .and_then(|t| Manifest::from_json(&t))
        {
            Ok(m) => m,
            Err(e) => {
                eprintln!("::error file={rel}::{rel}: {e}");
                failed = true;
                continue;
            }
        };
        let base_manifest = match git_show(&root, &base, &rel) {
            Ok(Some(text)) => {
                if let Some(export) = &export
                    && let Err(e) = std::fs::write(export.join(file), &text)
                {
                    eprintln!("{}: {e}", export.display());
                    failed = true;
                }
                match Manifest::from_json(&text) {
                    Ok(m) => Some(m),
                    Err(e) => {
                        // A base in an older format: compare nothing rather than guess.
                        println!(
                            "{rel}: base manifest unreadable ({e}); checking the head's shape only"
                        );
                        None
                    }
                }
            }
            Ok(None) => {
                println!("{rel}: new at this revision; nothing to compare against");
                None
            }
            Err(e) => {
                eprintln!("::error::{e}");
                failed = true;
                continue;
            }
        };
        let mut findings = check(base_manifest.as_ref(), &head);
        for other in &against {
            match git_show(&root, other, &rel) {
                Ok(Some(text)) => match Manifest::from_json(&text) {
                    Ok(theirs) => {
                        findings.extend(collisions(base_manifest.as_ref(), &head, &theirs, other));
                    }
                    Err(e) => println!("{rel} at {other}: unreadable ({e}); not compared"),
                },
                Ok(None) => {}
                Err(e) => {
                    eprintln!("::error::{e}");
                    failed = true;
                }
            }
        }
        let names = head.names().len();
        let caps = head.capabilities.len();
        if findings.is_empty() {
            println!("{rel}: ok ({names} wire names, {caps} capabilities, against {base})");
            continue;
        }
        failed = true;
        for finding in &findings {
            println!("::error file={rel}::{finding}");
        }
    }
    if failed {
        eprintln!(
            "\nA transport change must move both ends in lockstep: every new message behind a new capability id, \
             advertised in the handshake, sent only to a peer that listed it. Regenerate a stale manifest with \
             the protocol's snapshot test under CMUX_UPDATE_WIRE_MANIFEST=1."
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
