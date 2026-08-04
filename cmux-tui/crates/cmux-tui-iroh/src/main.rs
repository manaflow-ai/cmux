//! cmux-tui-iroh: the broker-registered iroh transport sidecar for cmux-tui.
//!
//! Roles:
//! - `enroll`: exchange a one-use provisioning token for a device credential.
//! - `listen`: serve the local cmux-tui session over iroh to admitted peers.
//! - `provider control|stream`: machine-provider v1 provider over stdio for
//!   `cmux-tui --machine-provider-command cmux-tui-iroh provider --`.
//!
//! Design: docs/iroh-tui-transport-stage1.md (constraint mapping against
//! docs/iroh-app-transport-architecture.md).

mod broker;
mod endpoint;
mod enroll;
mod files;
mod grant;
mod identity;
mod listen;
mod provider;
mod relays;
mod timefmt;

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = args.first().map(String::as_str) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let result = match command {
        "enroll" => run_async(run_enroll(&args[1..])),
        "listen" => run_async(run_listen(&args[1..])),
        "provider" => run_async(run_provider(&args[1..])),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        other => {
            eprintln!("unknown command {other:?}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-iroh: {error:#}");
            ExitCode::FAILURE
        }
    }
}

const USAGE: &str = "\
cmux-tui-iroh <command>

Commands:
  enroll   --token <t> | --token-file <path>   Exchange a one-use enrollment
           [--tag <tag>] [--server]            token for a device credential
           [--state <dir>] [--broker <url>]    and register this device.
  listen   [--session <name>] [--socket <p>]   Serve the local cmux-tui session
           [--state <dir>] [--broker <url>]    over iroh to admitted same-
           [--tag <tag>]                       account peers.
  provider control|stream                      Machine-provider v1 provider
           [--state <dir>] [--broker <url>]    (spawned by cmux-tui via
           [--tag <tag>]                       --machine-provider-command).

Environment: CMUX_TUI_IROH_BROKER, CMUX_TUI_IROH_ENROLL_TOKEN, CMUX_TUI_STATE_DIR.";

fn run_async<F: Future<Output = anyhow::Result<()>>>(future: F) -> anyhow::Result<()> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("building tokio runtime")
        .block_on(future)
}

struct Flags {
    values: Vec<(String, Option<String>)>,
    positional: Vec<String>,
}

impl Flags {
    fn parse(args: &[String], value_flags: &[&str], bool_flags: &[&str]) -> anyhow::Result<Self> {
        let mut values = Vec::new();
        let mut positional = Vec::new();
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            if arg == "--" {
                // Separator: everything after it is positional (wrapper
                // invocations may append it before the provider role).
                positional.extend(args[index + 1..].iter().cloned());
                break;
            }
            if value_flags.contains(&arg.as_str()) {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| anyhow::anyhow!("missing value for {arg}"))?;
                values.push((arg.clone(), Some(value.clone())));
                index += 2;
            } else if bool_flags.contains(&arg.as_str()) {
                values.push((arg.clone(), None));
                index += 1;
            } else if arg.starts_with('-') {
                anyhow::bail!("unknown flag {arg}");
            } else {
                positional.push(arg.clone());
                index += 1;
            }
        }
        Ok(Self { values, positional })
    }

    fn value(&self, flag: &str) -> Option<String> {
        self.values.iter().rev().find(|(name, _)| name == flag).and_then(|(_, value)| value.clone())
    }

    fn has(&self, flag: &str) -> bool {
        self.values.iter().any(|(name, _)| name == flag)
    }
}

async fn run_enroll(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(
        args,
        &["--token", "--token-file", "--tag", "--state", "--broker"],
        &["--server"],
    )?;
    anyhow::ensure!(flags.positional.is_empty(), "enroll takes no positional arguments");
    enroll::run(enroll::EnrollArgs {
        state: flags.value("--state").map(PathBuf::from),
        broker: flags.value("--broker"),
        tag: flags.value("--tag"),
        token: flags.value("--token"),
        token_file: flags.value("--token-file").map(PathBuf::from),
        pairing_enabled: flags.has("--server"),
    })
    .await
}

async fn run_listen(args: &[String]) -> anyhow::Result<()> {
    let flags =
        Flags::parse(args, &["--session", "--socket", "--state", "--broker", "--tag"], &[])?;
    anyhow::ensure!(flags.positional.is_empty(), "listen takes no positional arguments");
    listen::run(listen::ListenArgs {
        state: flags.value("--state").map(PathBuf::from),
        session: flags.value("--session").unwrap_or_else(|| "main".to_string()),
        socket: flags.value("--socket").map(PathBuf::from),
        broker: flags.value("--broker"),
        tag: flags.value("--tag"),
    })
    .await
}

async fn run_provider(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["--state", "--broker", "--tag"], &[])?;
    let role = flags
        .positional
        .first()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("provider requires a role (control or stream)"))?;
    anyhow::ensure!(flags.positional.len() == 1, "provider takes exactly one role argument");
    provider::run(provider::ProviderArgs {
        state: flags.value("--state").map(PathBuf::from),
        broker: flags.value("--broker"),
        tag: flags.value("--tag"),
        role,
    })
    .await
}
