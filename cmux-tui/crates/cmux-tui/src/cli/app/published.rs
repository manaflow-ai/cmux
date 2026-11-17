//! `cmux app publish|versions|rollback|ls` (the `cmux-apps` crate): an app from this machine's
//! preview, as numbered versions behind one stable URL. They run here, with no app socket: on a
//! Cloud machine the guest `cmux` hands every unclaimed verb to this binary
//! (web/services/vms/guestCli.ts), so an agent's shell reaches them as `cmux app publish`.
//!
//! The platform is reached only through this machine's agent (`apps.call` on its socket, which
//! adds the VM install's credential), and the process on `--port` is the agent's answer too
//! (`apps.listener`): this binary holds no token and reads no other process.

use std::io::Write as _;

use cmux_apps::cli::{Output, Parsed};
use cmux_apps::platform::PlatformClient;
use cmux_apps::publish::Host;
use cmux_apps::system::{AgentSocket, GitCli, LoopbackProbe, RealFs, RealProcs, SystemClock};

use super::super::{GlobalArgs, OutputMode};

/// Whether `rest` (the words after `app`) is one of these verbs.
pub(super) fn owns(rest: &[String]) -> bool {
    rest.first().is_some_and(|verb| cmux_apps::cli::VERBS.contains(&verb.as_str()))
}

pub(super) fn parse(rest: &[String]) -> Result<Parsed, String> {
    cmux_apps::cli::parse(rest)
}

pub(super) fn run(global: &GlobalArgs, parsed: &Parsed) -> i32 {
    let json = parsed.json || matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let parsed = Parsed { command: parsed.command.clone(), json };
    // The versions live under cmux's state root, beside its other state.
    let Some(apps_root) = crate::feature_flags::state_root().map(|root| root.join("apps")) else {
        return print(
            &cmux_apps::cli::usage_output(json, "cmux has no state directory here"),
            global,
        );
    };
    let cwd = std::env::current_dir().unwrap_or_else(|_| apps_root.clone());
    let agent = AgentSocket::default();
    let platform = PlatformClient::new(&agent);
    let procs = RealProcs::new();
    let host = Host {
        fs: &RealFs,
        git: &GitCli,
        procs: &procs,
        clock: &SystemClock,
        probe: &LoopbackProbe,
        platform: &platform,
        listeners: &agent,
        apps_root,
        parent_env: std::env::vars().collect(),
    };
    print(&cmux_apps::cli::run(&host, &parsed, cwd), global)
}

fn print(output: &Output, global: &GlobalArgs) -> i32 {
    if global.output != OutputMode::Quiet || output.code != 0 {
        let _ = std::io::stdout().write_all(output.stdout.as_bytes());
    }
    let _ = std::io::stderr().write_all(output.stderr.as_bytes());
    output.code
}
