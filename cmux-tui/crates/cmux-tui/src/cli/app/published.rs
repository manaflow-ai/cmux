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
#[cfg(unix)]
use cmux_apps::platform::PlatformClient;
#[cfg(unix)]
use cmux_apps::publish::Host;
#[cfg(unix)]
use cmux_apps::system::{
    AgentSocket, GitCli, HeadlessCapture, LoopbackProbe, RealFs, RealProcs, SystemClock,
};

use super::super::{GlobalArgs, OutputMode};

/// Whether `rest` (the words after `app`) is one of these verbs.
pub(super) fn owns(rest: &[String]) -> bool {
    rest.first().is_some_and(|verb| cmux_apps::cli::VERBS.contains(&verb.as_str()))
}

pub(super) fn parse(rest: &[String]) -> Result<Parsed, String> {
    cmux_apps::cli::parse(rest)
}

/// Published apps run on a Linux Cloud machine; elsewhere every verb says so.
#[cfg(not(unix))]
pub(super) fn run(global: &GlobalArgs, parsed: &Parsed) -> i32 {
    let json = parsed.json || matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let message = "cmux app publish, versions, rollback and ls run on a cmux Cloud machine";
    print(&cmux_apps::cli::usage_output(json, message), global)
}

#[cfg(unix)]
pub(super) fn run(global: &GlobalArgs, parsed: &Parsed) -> i32 {
    let json = parsed.json || matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let parsed = Parsed { command: parsed.command.clone(), json };
    // Off a Cloud machine (a Mac, no agent socket) `ls` and `versions` read the person's apps
    // from the platform through the signed-in cmux app, not this machine's empty version store.
    if !std::path::Path::new(cmux_apps::system::AGENT_SOCKET).exists()
        && let Some(request) = account_request(&parsed.command)
    {
        return print(&account_run(global, &parsed, request), global);
    }
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
    // The agent starts every version as its app user; this process never runs one.
    let procs = RealProcs::new();
    let host = Host {
        fs: &RealFs,
        git: &GitCli,
        procs: &procs,
        clock: &SystemClock,
        probe: &LoopbackProbe,
        platform: &platform,
        listeners: &agent,
        // A first frame renders in a fresh headless profile, as the publisher.
        capture: &HeadlessCapture { browser: None },
        apps_root,
        parent_env: std::env::vars().collect(),
    };
    print(&cmux_apps::cli::run(&host, &parsed, cwd), global)
}

/// The `cloud.apps` request for an account read, when `command` is one.
#[cfg(unix)]
fn account_request(command: &cmux_apps::cli::Command) -> Option<serde_json::Value> {
    use cmux_apps::cli::Command;
    match command {
        Command::Ls => Some(serde_json::json!({"op": "list"})),
        Command::Versions { name } => {
            let slug = cmux_apps::slug::slugify(name).unwrap_or_default();
            Some(serde_json::json!({"op": "get", "slug": slug}))
        }
        _ => None,
    }
}

/// The app's bound on the relay is 25 s; the CLI waits a little longer for its answer.
#[cfg(unix)]
const ACCOUNT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// One `cloud.apps` call to the cmux app (`cmux cloud apps-relay` as the signed-in person),
/// printed the way the Cloud machine's verbs print.
#[cfg(unix)]
fn account_run(global: &GlobalArgs, parsed: &Parsed, request: serde_json::Value) -> Output {
    use serde_json::json;
    let relayed = match super::connect_command(global) {
        Err(error) => json!({"ok": false, "error": error}),
        Ok(mut stream) => match super::request(&mut stream, "cloud.apps", request, ACCOUNT_TIMEOUT)
        {
            Ok(Ok(reply)) => reply,
            Ok(Err(error)) => json!({"ok": false, "error": error}),
            Err(message) => {
                json!({"ok": false, "error": {"code": "app.transport", "message": message}})
            }
        },
    };
    match parsed.command {
        cmux_apps::cli::Command::Ls => cmux_apps::account::ls_output(parsed.json, &relayed),
        _ => cmux_apps::account::versions_output(parsed.json, &relayed),
    }
}

fn print(output: &Output, global: &GlobalArgs) -> i32 {
    if global.output != OutputMode::Quiet || output.code != 0 {
        let _ = std::io::stdout().write_all(output.stdout.as_bytes());
    }
    let _ = std::io::stderr().write_all(output.stderr.as_bytes());
    output.code
}
