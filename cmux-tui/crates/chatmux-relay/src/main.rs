//! `chatmux-relay` (npm `cmux-relay`) entry point. Behavior port of
//! `packages/relay/bin/cmux-relay.mjs` in the chatmux repo — slice 1:
//! config, pairing ceremony (URL + `--code`), hello/heartbeat, trust
//! policy, managed enrollment. Later slices: PTY bridge, exec verbs,
//! wire-v6 pane verbs, autostart (see the crate README).

use std::io::IsTerminal as _;
use std::path::{Path, PathBuf};

use chatmux_relay::cli::{Command, parse_cli_args};
use chatmux_relay::config::{Config, default_config_path, load_config, save_config};
use chatmux_relay::enrollment::load_managed_enrollment_file;
use chatmux_relay::error::RelayError;
use chatmux_relay::pairing::{CeremonyMode, PairedOutcome, await_ceremony, start_pairing};
use chatmux_relay::prompt::prompt_line;
use chatmux_relay::session::{SessionState, stay_online};
use chatmux_relay::trust::{
    DEFAULT_RELAY_TRUST, Trust, clear_invalid_yolo_confirmation, effective_local_trust,
    has_yolo_confirmation, relay_trust, yolo_confirmation_receipt,
};
use chatmux_relay::wire::CLI_VERSION;

/// The production Worker baked into the published package: plain
/// `npx cmux-relay@latest` needs no environment at all. Staging/dev override
/// with `--backend <url>` or `CHATMUX_BACKEND_URL`.
const DEFAULT_BACKEND: &str = "https://api.chatmux.dev";

fn trust_description(trust: Trust) -> &'static str {
    match trust {
        Trust::Observe => {
            "chatmux agents can watch sessions on this machine but never run anything."
        }
        Trust::Supervised => {
            "every command waits for your approval on your phone before it runs. (default)"
        }
        Trust::Autonomous => {
            "YOLO (autonomous / unattended): approved agents may run ordinary file and command \
             actions without per-command approval. The machine owner must confirm it at the \
             keyboard; secrets, billing, identity, trust changes, Coderouter grants, destructive \
             environment deletion, and unsupported relay actions keep their own authority."
        }
    }
}

fn env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn node_platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "darwin",
        "windows" => "win32",
        other => match other {
            "linux" => "linux",
            "freebsd" => "freebsd",
            "openbsd" => "openbsd",
            _ => "linux",
        },
    }
}

fn hostname() -> String {
    #[cfg(unix)]
    {
        let mut buffer = [0_u8; 256];
        // SAFETY: buffer and length describe the same owned stack array.
        let result =
            unsafe { libc::gethostname(buffer.as_mut_ptr().cast::<libc::c_char>(), buffer.len()) };
        if result == 0 {
            let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
            if let Ok(name) = std::str::from_utf8(&buffer[..end])
                && !name.is_empty()
            {
                return name.to_owned();
            }
        }
    }
    #[cfg(windows)]
    {
        if let Some(name) = env_string("COMPUTERNAME") {
            return name;
        }
    }
    "machine".to_owned()
}

fn machine_name() -> String {
    env_string("CHATMUX_RELAY_MACHINE_NAME")
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(hostname)
}

fn requested_trust_from_environment() -> Option<Trust> {
    let value = std::env::var("CHATMUX_RELAY_TRUST").unwrap_or_default();
    let value = value.trim().to_ascii_lowercase();
    if value.is_empty() {
        return None;
    }
    match Trust::parse(&value) {
        Some(trust) => Some(trust),
        None => {
            eprintln!(
                "Ignoring invalid CHATMUX_RELAY_TRUST (expected observe, supervised, or \
                 autonomous)."
            );
            None
        }
    }
}

/// The one owner-at-keyboard confirmation path used by URL onboarding, the
/// fallback code ceremony, and later local trust changes. A valid receipt
/// can replay only for the exact same device id, credential, and policy
/// version.
async fn apply_requested_trust(config: &mut Config, requested: Trust, interactive: bool) -> Trust {
    clear_invalid_yolo_confirmation(config);
    if requested != Trust::Autonomous {
        config.yolo_confirmed_at = None;
        config.pending_trust = Some(requested.as_str().to_owned());
        return requested;
    }
    if has_yolo_confirmation(config) {
        config.pending_trust = Some(requested.as_str().to_owned());
        return requested;
    }
    if !interactive {
        eprintln!(
            "YOLO was not enabled: autonomous trust needs one local TTY confirmation. Run \
             cmux-relay interactively on this machine and type YOLO once."
        );
        config.pending_trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
        return DEFAULT_RELAY_TRUST;
    }
    let answer = prompt_line(
        "YOLO lets ordinary machine file/command actions run without per-command approval. \
         Type YOLO to confirm on this machine: ",
    )
    .await;
    if !answer.trim().eq_ignore_ascii_case("yolo") {
        config.pending_trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
        return DEFAULT_RELAY_TRUST;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default();
    match yolo_confirmation_receipt(config, now) {
        Some(receipt) => {
            config.yolo_confirmed_at = Some(receipt);
            config.pending_trust = Some(Trust::Autonomous.as_str().to_owned());
            Trust::Autonomous
        }
        None => {
            eprintln!("YOLO was not enabled because this pairing identity is incomplete.");
            config.pending_trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
            DEFAULT_RELAY_TRUST
        }
    }
}

/// Existing config is fail-closed before any network connection is opened.
async fn prepare_existing_trust(config: &mut Config, config_path: &Path, interactive: bool) {
    let had_receipt = config.yolo_confirmed_at.is_some();
    clear_invalid_yolo_confirmation(config);
    if let Some(requested) = requested_trust_from_environment() {
        apply_requested_trust(config, requested, interactive).await;
        persist(config, config_path);
        return;
    }
    let candidate = relay_trust(config.pending_trust.as_deref().or(config.trust.as_deref()));
    let effective = effective_local_trust(config);
    if candidate != effective || (had_receipt && config.yolo_confirmed_at.is_none()) {
        config.pending_trust = Some(effective.as_str().to_owned());
        persist(config, config_path);
    }
}

/// Path scoping: `--allow-root <path>` (repeatable) or
/// `CHATMUX_RELAY_ALLOWED_ROOTS` (colon-separated; empty string clears).
/// Persisted in the local config and advertised in the hello so the server
/// records it on the machine.
fn apply_allowed_roots(config: &mut Config, allow_root_args: &[String], config_path: &Path) {
    let from_env = std::env::var("CHATMUX_RELAY_ALLOWED_ROOTS").ok();
    if allow_root_args.is_empty() && from_env.is_none() {
        return;
    }
    let mut roots: Vec<String> = if allow_root_args.is_empty() {
        from_env
            .unwrap_or_default()
            .split(':')
            .filter(|root| !root.is_empty())
            .map(str::to_owned)
            .collect()
    } else {
        allow_root_args.to_vec()
    };
    if roots.is_empty() {
        config.allowed_roots = None;
        println!("Agent path scoping cleared (unscoped).");
    } else {
        roots.truncate(16);
        println!("Agent access on this machine is limited to: {}", roots.join(", "));
        config.allowed_roots = Some(roots);
    }
    persist(config, config_path);
}

fn persist(config: &Config, config_path: &Path) {
    if let Err(error) = save_config(config_path, config) {
        eprintln!("Could not save the relay config: {error}");
    }
}

fn offer_autostart(code_mode: bool) {
    let env = env_string("CHATMUX_RELAY_AUTOSTART").or_else(|| env_string("CMUX_RELAY_AUTOSTART"));
    if env.as_deref() == Some("0") {
        return;
    }
    if env.as_deref() == Some("1") {
        // Autostart install is a later slice (README: port plan).
        eprintln!(
            "Autostart install is not implemented in this relay build yet; run `npx cmux-relay \
             --autostart` (npm build) to install it meanwhile."
        );
        return;
    }
    if !code_mode {
        println!("Tip: `npx cmux-relay --autostart` keeps this machine online after reboots.");
    }
}

fn fatal_exit(error: &RelayError) -> ! {
    eprintln!("{error}");
    let code = match error {
        RelayError::Fatal { exit_code, .. } => *exit_code,
        _ => 1,
    };
    std::process::exit(code)
}

struct Runtime {
    backend: String,
    web_base: String,
    config_path: PathBuf,
    interactive: bool,
    http: reqwest::Client,
}

// ---------------------------------------------------------------------------
// Onboarding, URL flow (primary): print one approval link + a cute
// verification code, wait for the click. No prompts, no code typing.
// ---------------------------------------------------------------------------

async fn onboard_with_url(runtime: &Runtime) -> Result<Config, RelayError> {
    println!("\ncmux-relay {CLI_VERSION} — connect this computer to chatmux.");
    let name = machine_name();
    // The 10-minute approval window can lapse; issue a fresh link and keep
    // waiting rather than dying on a slow first setup.
    loop {
        match pair_via_url(runtime, &name).await {
            Ok(paired) => {
                let mut config = paired.config;
                let requested = requested_trust_from_environment().or(paired.requested_trust);
                apply_requested_trust(
                    &mut config,
                    requested.unwrap_or(DEFAULT_RELAY_TRUST),
                    runtime.interactive,
                )
                .await;
                persist(&config, &runtime.config_path);
                offer_autostart(false);
                return Ok(config);
            }
            Err(RelayError::PairingExpired { .. }) => {
                println!("\nThat approval link expired. Here is a fresh one:");
            }
            Err(error) => return Err(error),
        }
    }
}

async fn pair_via_url(runtime: &Runtime, name: &str) -> Result<PairedOutcome, RelayError> {
    let started = start_pairing(&runtime.http, &runtime.backend, name, node_platform()).await?;
    let pair_url = format!("{}/pair/{}#{}", runtime.web_base, started.pair_id, started.secret);
    let backend_note = if runtime.backend == DEFAULT_BACKEND {
        String::new()
    } else {
        format!(
            "\n(Backend override: {} — the page must belong to a deployment using it.)",
            runtime.backend
        )
    };
    println!(
        "\nVerification code for this machine:\n\n    >>>  {}  <<<\n\nApprove it here (opens \
         the chatmux Machines page):\n\n    {pair_url}\n\nThe page must show the machine \
         \"{name}\" with exactly the code above.\nIf the code differs, click \
         Deny.{backend_note}\n\nWaiting for approval…",
        started.cute_code,
    );
    let outcome =
        await_ceremony(&runtime.backend, &started, CeremonyMode::Url, name, node_platform())
            .await?;
    persist(&outcome.config, &runtime.config_path);
    println!("Paired securely.");
    Ok(outcome)
}

// ---------------------------------------------------------------------------
// Onboarding, --code fallback (QR + SAS mutual ceremony; kept for setups
// where clicking a link printed in this terminal is not possible)
// ---------------------------------------------------------------------------

async fn onboard_with_code(runtime: &Runtime) -> Result<Config, RelayError> {
    println!("\ncmux-relay {CLI_VERSION} — connect this computer to chatmux.\n");

    // 1. machine name (env > prompt > hostname)
    let mut name = env_string("CHATMUX_RELAY_MACHINE_NAME")
        .map(|value| value.trim().to_owned())
        .unwrap_or_default();
    if name.is_empty() && runtime.interactive {
        name = prompt_line(&format!("Machine name [{}]: ", hostname())).await.trim().to_owned();
    }
    if name.is_empty() {
        name = hostname();
    }

    // 2. QR + chatmux:// link + SAS ceremony
    let paired = pair_with_code(runtime, &name).await?;
    let mut config = paired.config;

    // 3. trust level (env > pairing hint > prompt > supervised)
    let trust = pick_trust(runtime, &mut config, paired.requested_trust).await;
    println!("Trust level: {trust} — {}", trust_description(trust).replace(" (default)", ""));

    // 4. org scope (pairing registers personal scope today)
    println!("Scope: personal — only your chatmux account can see or use this machine.\n");
    persist(&config, &runtime.config_path);

    // 5. autostart (opt-in)
    offer_autostart(true);
    Ok(config)
}

async fn pair_with_code(runtime: &Runtime, name: &str) -> Result<PairedOutcome, RelayError> {
    let started = start_pairing(&runtime.http, &runtime.backend, name, node_platform()).await?;

    let mut qr = url::Url::parse("chatmux://pair")
        .map_err(|error| RelayError::fatal(format!("could not build the pairing URL: {error}")))?;
    qr.query_pairs_mut()
        .append_pair("v", "1")
        .append_pair("backend", &runtime.backend)
        .append_pair("pairId", &started.pair_id)
        .append_pair("secret", &started.secret)
        .append_pair("relayPublicKey", &started.relay_public_key);

    println!("\nScan this QR code in chatmux:\n");
    // QR rendering is a later slice; the link is the same payload the JS
    // relay encodes into its terminal QR.
    println!("Or open: {qr}");
    if let Some(expires_at) = &started.expires_at {
        println!("Pairing expires at {}.\n", expires_at.as_str().unwrap_or_default());
    }

    let sas_auto_approve = std::env::var("CHATMUX_RELAY_SAS_APPROVE").ok().as_deref() == Some("1");
    let outcome = await_ceremony(
        &runtime.backend,
        &started,
        CeremonyMode::Code { sas_auto_approve },
        name,
        node_platform(),
    )
    .await?;
    persist(&outcome.config, &runtime.config_path);
    println!("Paired securely.");
    Ok(outcome)
}

async fn pick_trust(
    runtime: &Runtime,
    config: &mut Config,
    requested_hint: Option<Trust>,
) -> Trust {
    if let Some(from_env) = requested_trust_from_environment() {
        return apply_requested_trust(config, from_env, runtime.interactive).await;
    }
    if let Some(hint) = requested_hint {
        return apply_requested_trust(config, hint, runtime.interactive).await;
    }
    if !runtime.interactive {
        return apply_requested_trust(config, DEFAULT_RELAY_TRUST, runtime.interactive).await;
    }
    let levels = [Trust::Observe, Trust::Supervised, Trust::Autonomous];
    println!("\nChoose how much this machine trusts chatmux agents:");
    for (index, level) in levels.iter().enumerate() {
        println!("  {}. {:<11} {}", index + 1, level.as_str(), trust_description(*level));
    }
    let answer = prompt_line("Trust level [2]: ").await.trim().to_ascii_lowercase();
    let requested = Trust::parse(&answer)
        .or_else(|| {
            answer
                .parse::<usize>()
                .ok()
                .and_then(|number| number.checked_sub(1))
                .and_then(|index| levels.get(index).copied())
        })
        .unwrap_or(DEFAULT_RELAY_TRUST);
    apply_requested_trust(config, requested, runtime.interactive).await
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn print_help(config_path: &Path) {
    let advertised = chatmux_relay::wire::advertised_protocol();
    println!(
        "cmux-relay {CLI_VERSION} (chatmux, relay protocol v{advertised})

Pairs this computer with your chatmux account and keeps it online as a
target. chatmux agents can then read files and run commands here, gated by
the local trust level for this pairing: observe = read-only, supervised =
every action waits for your approval in the chatmux app, autonomous =
YOLO (autonomous / unattended) for ordinary file and command actions. The
owner at the machine must confirm YOLO; sensitive account actions keep their
own authority.

Usage:
  npx cmux-relay               First run: prints an approval link + a short
                               verification code; approve it in the chatmux
                               web app, then this stays online.
                               Later runs: skip straight to connected.
  npx cmux-relay --pair        Replace the current pairing (fresh link)
  npx cmux-relay --code        Offline fallback: QR + chatmux:// link and a
                               6-digit mutual verification ceremony
  npx cmux-relay --status      Show local pairing state
  npx cmux-relay --autostart   Install autostart (reconnect on sign-in)
  npx cmux-relay --uninstall   Remove autostart files (keeps pairing)
  npx cmux-relay --no-onboard  Scripted use: no prompts; answers come from
                               the environment or defaults
  npx cmux-relay --backend <url>  Worker base URL (staging/dev)
  npx cmux-relay --allow-root <path>  Limit agent file access and command
                               working directories to this path prefix
                               (repeatable; persisted; run with none to
                               keep, CHATMUX_RELAY_ALLOWED_ROOTS=\"\" clears)

Environment:
  CHATMUX_BACKEND_URL          Worker base URL (default {DEFAULT_BACKEND})
  CHATMUX_WEB_URL              Web app for the approval page (default
                               https://chatmux.dev)
  CHATMUX_RELAY_CONFIG         Config file path (default {config_path})
  CHATMUX_RELAY_MACHINE_NAME   Machine name (default: hostname)
  CHATMUX_RELAY_TRUST          Trust answer: observe|supervised|autonomous
                               Autonomous also needs one local TTY confirmation;
                               later unattended starts use its bound receipt
  CHATMUX_RELAY_AUTOSTART      1 installs autostart, 0 skips the offer
  CHATMUX_RELAY_SAS_APPROVE    1 auto-approves the --code pairing (scripted
                               setup only; you skip the mutual verification)

Coderouter commands are not available in this version.
",
        config_path = config_path.display(),
    );
}

fn print_status(config_path: &Path) -> ! {
    let Some(config) = load_config(config_path) else {
        println!("Not paired");
        std::process::exit(1);
    };
    let trust = effective_local_trust(&config);
    let pending_note = config
        .pending_trust
        .as_deref()
        .filter(|pending| *pending != trust.as_str())
        .map(|pending| format!(" (refused pending value: {pending})"))
        .unwrap_or_default();
    let roots = config
        .allowed_roots
        .as_ref()
        .filter(|roots| !roots.is_empty())
        .map(|roots| roots.join(", "))
        .unwrap_or_else(|| "(unscoped)".to_owned());
    println!("Paired as {} ({})", config.name.as_deref().unwrap_or_default(), config.device_id);
    println!("  backend  {}", config.backend);
    println!("  trust    {trust}{pending_note}");
    println!("  scope    {}", config.scope.as_deref().unwrap_or("personal"));
    println!("  roots    {roots}");
    println!("  protocol v{} (cli {CLI_VERSION})", chatmux_relay::wire::advertised_protocol());
    std::process::exit(0);
}

#[tokio::main]
async fn main() {
    // The workspace pins rustls to the ring provider (tungstenite does the
    // same); reqwest's rustls-no-provider build needs it installed as the
    // process default before any TLS client is built.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let parsed = match parse_cli_args(std::env::args().skip(1)) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("{}", error.message);
            eprintln!("Run `cmux-relay --help` for usage.");
            std::process::exit(2);
        }
    };

    let backend = parsed
        .backend
        .clone()
        .or_else(|| env_string("CHATMUX_BACKEND_URL"))
        .or_else(|| env_string("CMUX_RELAY_BACKEND_URL"))
        .unwrap_or_else(|| DEFAULT_BACKEND.to_owned())
        .trim_end_matches('/')
        .to_owned();
    let web_base = env_string("CHATMUX_WEB_URL")
        .unwrap_or_else(|| "https://chatmux.dev".to_owned())
        .trim_end_matches('/')
        .to_owned();
    let config_path =
        env_string("CHATMUX_RELAY_CONFIG").map(PathBuf::from).unwrap_or_else(default_config_path);
    // Legacy QR/SAS ceremony prompts only run on a real terminal.
    let interactive =
        !parsed.no_onboard && std::io::stdout().is_terminal() && std::io::stdin().is_terminal();

    match parsed.command {
        Some(Command::Help) => {
            print_help(&config_path);
            std::process::exit(0);
        }
        Some(Command::Version) => {
            println!("{CLI_VERSION}");
            std::process::exit(0);
        }
        Some(Command::Status) => print_status(&config_path),
        Some(Command::Uninstall) | Some(Command::Autostart) => {
            // Autostart install/uninstall is a later slice (README: port
            // plan). The npm build still owns this surface.
            eprintln!(
                "Autostart is not implemented in this relay build yet; use the npm cmux-relay \
                 for --autostart/--uninstall."
            );
            std::process::exit(1);
        }
        Some(Command::Pair) | None => {}
    }

    let runtime =
        Runtime { backend, web_base, config_path, interactive, http: reqwest::Client::new() };

    if parsed.managed_mode {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
            .unwrap_or_default();
        let managed = match load_managed_enrollment_file(
            parsed.enrollment_file.as_deref().unwrap_or_default(),
            now,
        ) {
            Ok(managed) => managed,
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        };
        stay_online(
            managed,
            &runtime.config_path,
            SessionState { first_connect: true, first_run: false, managed: true },
        )
        .await;
    }

    let existing = if parsed.command == Some(Command::Pair) {
        None
    } else {
        load_config(&runtime.config_path)
    };
    let first_run = existing.is_none();
    let mut config = match existing {
        Some(mut config) => {
            prepare_existing_trust(&mut config, &runtime.config_path, runtime.interactive).await;
            config
        }
        None => {
            let onboarded = if parsed.code_mode {
                onboard_with_code(&runtime).await
            } else {
                onboard_with_url(&runtime).await
            };
            match onboarded {
                Ok(config) => config,
                Err(error) => fatal_exit(&error),
            }
        }
    };
    apply_allowed_roots(&mut config, &parsed.allow_root, &runtime.config_path);
    stay_online(
        config,
        &runtime.config_path,
        SessionState { first_connect: true, first_run, managed: false },
    )
    .await;
}
