//! `cmux chief move …`: moves this Chief to another home or host
//! (plans/cmux-next/chief-migration-DESIGN.md). One implementation:
//! everything after `move` goes to `optchat-chief move` with this Chief's
//! home, so the CLI, the app and MCP share the drain, checkpoint, restore,
//! verify and the moved marker.

use cmux_process::Command;
use std::path::PathBuf;

use super::launch::brain_binary;
use super::{GlobalArgs, Target};

/// Splits `--chief-home DIR` (or `--chief-home=DIR`) out of `args`.
pub(super) fn split_chief_home(args: &[String]) -> (Option<PathBuf>, Vec<String>) {
    let mut home = None;
    let mut rest = Vec::new();
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        if let Some(value) = arg.strip_prefix("--chief-home=") {
            home = Some(PathBuf::from(value));
        } else if arg == "--chief-home" {
            index += 1;
            home = args.get(index).map(PathBuf::from);
        } else {
            rest.push(arg.clone());
        }
        index += 1;
    }
    (home, rest)
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let m = super::messages::messages();
    let (chief_home, rest) = split_chief_home(args);
    let home = match super::target(global, chief_home.as_deref()) {
        Ok(Target::Home(home)) => home,
        Ok(Target::Explicit(..)) => {
            eprintln!("cmux: {}", m.move_needs_home);
            return 2;
        }
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            return code;
        }
    };
    let Some(bin) = brain_binary() else {
        eprintln!("cmux: {}", m.move_no_brain);
        return 2;
    };
    match Command::new(bin)
        .arg("move")
        .args(&rest)
        .arg("--home")
        .arg(&home.root)
        .inherit_like_std()
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("cmux: optchat-chief: {error}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::split_chief_home;

    #[test]
    fn relocate_splits_the_chief_home_out_of_the_move_arguments() {
        let args: Vec<String> =
            ["--to", "ssh:mini", "--chief-home", "/h", "--dry-run"].map(String::from).to_vec();
        let (home, rest) = split_chief_home(&args);
        assert_eq!(home.as_deref(), Some(std::path::Path::new("/h")));
        assert_eq!(rest, ["--to", "ssh:mini", "--dry-run"]);
        let (home, rest) = split_chief_home(&["--chief-home=/x".to_owned()]);
        assert_eq!(home.as_deref(), Some(std::path::Path::new("/x")));
        assert!(rest.is_empty());
    }
}
