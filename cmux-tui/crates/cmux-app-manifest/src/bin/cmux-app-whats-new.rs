//! `cmux-app-whats-new [--repo DIR] [--check] APP...`: writes each
//! first-party app's `first-party-apps/<APP>/catalog/whats-new.json` from the
//! repository's git history (`cmux_app_manifest::whats_new`). APP is a folder
//! name under `first-party-apps/` or a repository-relative folder. `--check`
//! writes nothing and fails when a file is not what it would write. It reads
//! only the local history, so it runs with no network and no token.

use std::path::PathBuf;
use std::process::ExitCode;

use cmux_app_manifest::whats_new;

const USAGE: &str = "usage: cmux-app-whats-new [--repo DIR] [--check] APP...";

fn main() -> ExitCode {
    let mut repo = PathBuf::from(".");
    let mut check = false;
    let mut apps = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo" => match args.next() {
                Some(dir) => repo = PathBuf::from(dir),
                None => return usage("--repo needs a directory"),
            },
            "--check" => check = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            flag if flag.starts_with('-') => return usage(&format!("unknown flag {flag}")),
            _ => apps.push(arg),
        }
    }
    if apps.is_empty() {
        return usage("name at least one app");
    }
    let mut failed = false;
    for app in apps {
        let dir = if app.contains('/') { app } else { format!("first-party-apps/{app}") };
        let result = if check {
            whats_new::generate(&repo, &dir).map(|file| {
                let path = repo.join(&dir).join(whats_new::WHATS_NEW_FILE);
                let fresh =
                    std::fs::read_to_string(&path).is_ok_and(|old| old == file.to_file_text());
                (path, !fresh)
            })
        } else {
            whats_new::write(&repo, &dir)
        };
        match result {
            Ok((path, false)) => println!("{}: up to date", path.display()),
            Ok((path, true)) if check => {
                eprintln!("{}: stale; run cmux-app-whats-new without --check", path.display());
                failed = true;
            }
            Ok((path, true)) => println!("{}: written", path.display()),
            Err(message) => {
                eprintln!("{dir}: {message}");
                failed = true;
            }
        }
    }
    if failed { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

fn usage(message: &str) -> ExitCode {
    eprintln!("cmux-app-whats-new: {message}\n{USAGE}");
    ExitCode::from(2)
}
