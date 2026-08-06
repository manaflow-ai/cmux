use std::collections::{HashMap, HashSet};
use std::io::Read as _;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail, ensure};
use cmux_remote::secret_file::read_owner_only_string;
use cmux_tui_iroh::broker::{BrokerClient, Platform, unix_time};
use cmux_tui_iroh::identity::{BrokerCredential, IdentityStore};
use cmux_tui_iroh::policy::RelayEnvironment;
use cmux_tui_iroh::transport::{EndpointRuntime, EndpointRuntimeConfig};
use tokio_util::sync::CancellationToken;
use url::Url;
use zeroize::Zeroizing;

const USAGE: &str = "\
cmux-tui-iroh Stage 1 transport

USAGE
  cmux-tui-iroh enroll --state-root PATH --identity NAME --broker URL (--token-file PATH | --token-stdin) [--replace-credential]
  cmux-tui-iroh server --state-root PATH --identity NAME --broker URL --session-socket PATH [--relay-environment production|staging] [--display-name NAME]   (Linux only)
  cmux-tui-iroh provider --state-root PATH --identity NAME --broker URL --socket PATH [--relay-environment production|staging] [--display-name NAME]
  cmux-tui-iroh probe --socket PATH [--machine-id UUID] [--marker-key UUID]
  cmux-tui-iroh status --state-root PATH --identity NAME
";

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("cmux-tui-iroh: {error:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "help".into());
    let parsed = ParsedArgs::parse(args)?;
    match command.as_str() {
        "enroll" => enroll(parsed).await,
        "server" => run_server(parsed).await,
        "provider" => run_provider(parsed).await,
        "probe" => probe(parsed).await,
        "status" => status(parsed),
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            Ok(())
        }
        _ => bail!("unknown command {command:?}\n\n{USAGE}"),
    }
}

async fn enroll(mut args: ParsedArgs) -> Result<()> {
    args.require_only(&[
        "state-root",
        "identity",
        "broker",
        "token-file",
        "token-stdin",
        "replace-credential",
    ])?;
    let state_root = args.path("state-root")?;
    let identity_name = args.value("identity")?.to_string();
    let broker_url = parse_url(args.value("broker")?)?;
    let token_file = args.optional_path("token-file");
    let token_stdin = args.flag("token-stdin");
    ensure!(
        token_file.is_some() ^ token_stdin,
        "choose exactly one of --token-file or --token-stdin"
    );
    let replace = args.flag("replace-credential");
    args.finish()?;

    let mut token = match token_file {
        Some(path) => read_owner_only_string(&path, 16 * 1024)
            .with_context(|| format!("cannot read provisioning token {}", path.display()))?,
        None => read_token_stdin()?,
    };
    while token.ends_with('\n') || token.ends_with('\r') {
        token.pop();
    }
    let store = IdentityStore::open(&state_root, &identity_name)?;
    if store.credential_exists() && !replace {
        bail!("broker credential already exists; pass --replace-credential to replace it");
    }
    let broker = BrokerClient::new(broker_url)?;
    let enrolled = broker.enroll(&token).await?;
    let credential =
        BrokerCredential::new(enrolled.access_token, enrolled.refresh_token, unix_time()?)?;
    store.save_credential(&credential, replace).context(
        "the provisioning token was already consumed by enrollment but the credential could \
         not be persisted; mint a new enrollment token and re-run enroll",
    )?;
    println!(
        "enrolled endpoint={} device={} tag={}",
        store.endpoint_id().fmt_short(),
        store.metadata().device_id,
        store.metadata().tag,
    );
    Ok(())
}

async fn run_server(mut args: ParsedArgs) -> Result<()> {
    args.require_only(&[
        "state-root",
        "identity",
        "broker",
        "session-socket",
        "relay-environment",
        "display-name",
    ])?;
    let common = runtime_args(&mut args)?;
    let session_socket = args.path("session-socket")?;
    args.finish()?;
    // Stage 1 registers the TUI server as a Linux machine; refuse to register
    // that fact from any other host platform instead of publishing it falsely.
    ensure!(
        Platform::current_frontend()? == Platform::Linux,
        "the Stage 1 TUI server registers as a Linux machine and must run on Linux"
    );
    let runtime = Arc::new(
        EndpointRuntime::start(EndpointRuntimeConfig {
            state_root: &common.state_root,
            identity_name: &common.identity,
            broker_url: common.broker,
            relay_environment: common.environment,
            platform: Platform::Linux,
            display_name: common.display_name.as_deref(),
            pairing_enabled: true,
        })
        .await?,
    );
    println!(
        "server ready endpoint={} identity={} binding={} relays={} inbound_ports=0 ip_transports=0",
        runtime.endpoint_id().fmt_short(),
        runtime.identity.identity_fingerprint(),
        runtime.binding.binding_id,
        runtime.relay_count().await,
    );
    let shutdown = signal_cancellation()?;
    cmux_tui_iroh::server::serve(runtime, session_socket, shutdown).await
}

async fn run_provider(mut args: ParsedArgs) -> Result<()> {
    args.require_only(&[
        "state-root",
        "identity",
        "broker",
        "socket",
        "relay-environment",
        "display-name",
    ])?;
    let common = runtime_args(&mut args)?;
    let socket = args.path("socket")?;
    args.finish()?;
    let platform = Platform::current_frontend()?;
    let runtime = Arc::new(
        EndpointRuntime::start(EndpointRuntimeConfig {
            state_root: &common.state_root,
            identity_name: &common.identity,
            broker_url: common.broker,
            relay_environment: common.environment,
            platform,
            display_name: common.display_name.as_deref(),
            pairing_enabled: false,
        })
        .await?,
    );
    println!(
        "provider ready endpoint={} identity={} binding={} relays={} ip_transports=0 socket={}",
        runtime.endpoint_id().fmt_short(),
        runtime.identity.identity_fingerprint(),
        runtime.binding.binding_id,
        runtime.relay_count().await,
        socket.display(),
    );
    let shutdown = signal_cancellation()?;
    cmux_tui_iroh::provider::serve(runtime, socket, shutdown).await
}

async fn probe(mut args: ParsedArgs) -> Result<()> {
    args.require_only(&["socket", "machine-id", "marker-key"])?;
    let socket = args.path("socket")?;
    let machine_id = args.optional_value("machine-id").map(ToOwned::to_owned);
    let marker_key = args
        .optional_value("marker-key")
        .unwrap_or("1f9c9c70-a083-4890-b3b3-336eb1df626b")
        .to_string();
    ensure!(
        uuid::Uuid::parse_str(&marker_key).is_ok_and(|value| value.to_string() == marker_key),
        "marker key must be a canonical UUID"
    );
    args.finish()?;
    cmux_tui_iroh::probe::run(&socket, machine_id.as_deref(), &marker_key).await
}

fn status(mut args: ParsedArgs) -> Result<()> {
    args.require_only(&["state-root", "identity"])?;
    let state_root = args.path("state-root")?;
    let identity = args.value("identity")?.to_string();
    args.finish()?;
    // Read-only and lock-free, so status works while a server or provider
    // process holds the identity open.
    let report = cmux_tui_iroh::identity::read_identity_report(&state_root, &identity)?;
    println!(
        "endpoint={} device={} app_instance={} tag={} generation={} credential={}",
        report.endpoint_id.fmt_short(),
        report.metadata.device_id,
        report.metadata.app_instance_id,
        report.metadata.tag,
        report.metadata.identity_generation,
        if report.credential_present { "present" } else { "absent" },
    );
    Ok(())
}

struct RuntimeArgs {
    state_root: PathBuf,
    identity: String,
    broker: Url,
    environment: RelayEnvironment,
    display_name: Option<String>,
}

fn runtime_args(args: &mut ParsedArgs) -> Result<RuntimeArgs> {
    Ok(RuntimeArgs {
        state_root: args.path("state-root")?,
        identity: args.value("identity")?.to_string(),
        broker: parse_url(args.value("broker")?)?,
        environment: args.optional_value("relay-environment").unwrap_or("production").parse()?,
        display_name: args.optional_value("display-name").map(ToOwned::to_owned),
    })
}

fn parse_url(value: &str) -> Result<Url> {
    Url::parse(value).context("broker URL is invalid")
}

fn read_token_stdin() -> Result<Zeroizing<String>> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(16 * 1024 + 1)
        .read_to_end(&mut bytes)
        .context("cannot read provisioning token from stdin")?;
    ensure!(bytes.len() <= 16 * 1024, "provisioning token is too large");
    String::from_utf8(bytes)
        .map(Zeroizing::new)
        .map_err(|_| anyhow::anyhow!("provisioning token is not UTF-8"))
}

fn signal_cancellation() -> Result<CancellationToken> {
    let cancellation = CancellationToken::new();
    let signal = cancellation.clone();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        signal.cancel();
    });
    Ok(cancellation)
}

struct ParsedArgs {
    values: HashMap<String, String>,
    flags: HashSet<String>,
    seen: HashSet<String>,
}

impl ParsedArgs {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut values = HashMap::new();
        let mut flags = HashSet::new();
        let mut args = args.into_iter().peekable();
        while let Some(argument) = args.next() {
            ensure!(argument.starts_with("--"), "unexpected positional argument {argument:?}");
            let name = argument.trim_start_matches("--").to_string();
            ensure!(!name.is_empty(), "empty option name");
            ensure!(
                !values.contains_key(&name) && !flags.contains(&name),
                "duplicate option --{name}"
            );
            if matches!(name.as_str(), "token-stdin" | "replace-credential") {
                flags.insert(name);
            } else {
                let value = args.next().with_context(|| format!("--{name} needs a value"))?;
                ensure!(!value.starts_with("--"), "--{name} needs a value");
                values.insert(name, value);
            }
        }
        Ok(Self { values, flags, seen: HashSet::new() })
    }

    fn require_only(&self, allowed: &[&str]) -> Result<()> {
        let allowed = allowed.iter().copied().collect::<HashSet<_>>();
        for name in self.values.keys().chain(self.flags.iter()) {
            ensure!(allowed.contains(name.as_str()), "unknown option --{name}");
        }
        Ok(())
    }

    fn value(&mut self, name: &str) -> Result<&str> {
        self.seen.insert(name.to_string());
        self.values.get(name).map(String::as_str).with_context(|| format!("--{name} is required"))
    }

    fn optional_value(&mut self, name: &str) -> Option<&str> {
        self.seen.insert(name.to_string());
        self.values.get(name).map(String::as_str)
    }

    fn path(&mut self, name: &str) -> Result<PathBuf> {
        self.value(name).map(PathBuf::from)
    }

    fn optional_path(&mut self, name: &str) -> Option<PathBuf> {
        self.optional_value(name).map(PathBuf::from)
    }

    fn flag(&mut self, name: &str) -> bool {
        self.seen.insert(name.to_string());
        self.flags.contains(name)
    }

    fn finish(&self) -> Result<()> {
        for name in self.values.keys().chain(self.flags.iter()) {
            ensure!(self.seen.contains(name), "option --{name} was not consumed");
        }
        Ok(())
    }
}
