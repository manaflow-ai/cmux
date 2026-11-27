//! `cmux team …` verbs that run on the team VM itself (team-vm-plan.md S5):
//! - `restricted-shell`: the agent certificates' force-command
//!   ([`super::restricted_shell`]).
//! - `whoami`: prints `<linux user> <uid>` (the one verb ordinary agents may
//!   run today; later `cmux team …` verbs join [`super::restricted_shell::ALLOWED`]).

const USAGE: &str = "usage: cmux team restricted-shell | cmux team whoami";

/// Entry for `cmux team <args>` (and `cmux-host team <args>`).
pub fn run(args: &[String]) -> u8 {
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["restricted-shell"] => super::restricted_shell::run(),
        ["whoami"] => whoami(),
        ["--help" | "-h" | "help"] => {
            println!("{USAGE}");
            0
        }
        _ => {
            eprintln!("cmux team: unknown arguments\n{USAGE}");
            2
        }
    }
}

#[cfg(target_os = "linux")]
fn whoami() -> u8 {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    match crate::linux::spawn::current_user_name() {
        Some(name) => {
            println!("{name} {uid}");
            0
        }
        None => {
            eprintln!("cmux team whoami: uid {uid} has no user name");
            1
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn whoami() -> u8 {
    eprintln!("cmux team whoami: Linux only");
    1
}
