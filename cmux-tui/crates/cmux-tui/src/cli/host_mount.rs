//! `cmux host …`: the machine supervisor (crate `cmux-host`; plans/cmux-next
//! server.md 5.1, vm-image.md 6), mounted on the `cmux` surface only. The
//! frozen unit command is `<current>/bin/cmux host run`. `main` routes it
//! before installing the mux's signal handlers: the supervisor owns
//! SIGTERM, SIGINT and SIGHUP itself. Global options do not apply.

use super::Surface;

/// Whether `raw_args` is `cmux host …` on the `cmux` surface.
pub(crate) fn requested(raw_args: &[String]) -> bool {
    applies(raw_args, Surface::current())
}

fn applies(raw_args: &[String], surface: Surface) -> bool {
    surface == Surface::Cmux && raw_args.first().is_some_and(|first| first == "host")
}

/// The scopes `main` runs before the mux's signal handlers, without the
/// provider credentials: `cmux link …`, `cmux host …` (the supervisor
/// owns SIGTERM, SIGINT and SIGHUP itself), and the team VM's own
/// `cmux team restricted-shell|whoami` (crate `cmux-host`; the agent
/// certificates' force-command, team-vm-plan.md S5). The function takes
/// the words after the scope.
pub(crate) fn early_unix_scope(raw_args: &[String]) -> Option<fn(&[String]) -> i32> {
    if raw_args.first().is_some_and(|first| first == "link") {
        Some(crate::link::run)
    } else if requested(raw_args) {
        Some(run)
    } else if team_vm_verb(raw_args, Surface::current()) {
        Some(run_team)
    } else {
        None
    }
}

/// Only these two `team` verbs run here; every other `cmux team …` path
/// stays with the catalog CLI.
fn team_vm_verb(raw_args: &[String], surface: Surface) -> bool {
    surface == Surface::Cmux
        && raw_args.first().is_some_and(|first| first == "team")
        && matches!(raw_args.get(1).map(String::as_str), Some("restricted-shell" | "whoami"))
}

/// Runs `cmux team <rest>` on the team VM and returns its exit code.
fn run_team(rest: &[String]) -> i32 {
    i32::from(cmux_host::team_ssh::team_cli::run(rest))
}

/// Runs `cmux host <rest>` and returns its exit code.
pub(crate) fn run(rest: &[String]) -> i32 {
    let argv0 = std::env::args_os().next();
    let self_argv = self_argv_for(argv0.as_deref(), std::env::current_exe().ok());
    i32::from(cmux_host::cli::run(rest, self_argv))
}

/// How the supervisor runs `cmux host …` again (its `rekey` job). The verb
/// exists only on the `cmux` surface, which argv[0]'s name selects, so an
/// absolute argv[0] named `cmux` (the image's `cmux` link into the store)
/// wins over the resolved executable, whose name is `cmux-tui` there.
fn self_argv_for(argv0: Option<&std::ffi::OsStr>, exe: Option<std::path::PathBuf>) -> Vec<String> {
    let named_cmux = argv0.filter(|a| {
        std::path::Path::new(a).is_absolute() && Surface::for_program(Some(a)) == Surface::Cmux
    });
    let program = match named_cmux {
        Some(a) => Some(std::path::PathBuf::from(a)),
        None => exe,
    };
    program.map(|p| vec![p.display().to_string(), "host".to_owned()]).unwrap_or_default()
}
