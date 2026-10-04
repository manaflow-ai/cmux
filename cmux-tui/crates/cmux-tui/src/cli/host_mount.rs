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

/// Runs `cmux host <rest>` and returns its exit code.
pub(crate) fn run(rest: &[String]) -> i32 {
    let exe = std::env::current_exe().ok().map(|p| p.display().to_string());
    let self_argv = exe.map(|exe| vec![exe, "host".to_owned()]).unwrap_or_default();
    i32::from(cmux_host::cli::run(rest, self_argv))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_is_mounted_on_cmux_only() {
        let args = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert!(applies(&args(&["host", "run"]), Surface::Cmux));
        assert!(!applies(&args(&["host", "run"]), Surface::CmuxTui));
        assert!(!applies(&args(&["workspace", "list"]), Surface::Cmux));
        assert!(!applies(&[], Surface::Cmux));
        assert_eq!(run(&args(&["--help"])), 0);
        assert_eq!(run(&args(&["bogus"])), 2);
    }
}
