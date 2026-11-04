//! `cmux computer-use`: Computer Use status, the driver's tools, saved app
//! approvals and the machine's permission mode (docs/computer-use-approvals.md,
//! "Controls").
//!
//! - `status`, `approvals list|pending|revoke|deny` and the MCP tools
//!   `cua_status`, `cua_approvals_*` are one code path
//!   (`mcp/computer_use_tools.rs`) to the daemon's `remote-host-call`, which
//!   takes reads and lowering only.
//! - `tools`, `call` and `screenshot` go through the acpmux daemon, which runs
//!   its own `acpmux cua-mcp` bridge (acpmux `cua_v2/cli_bridge.rs`): the
//!   worker's admission (acpmux code under a registered acpmux daemon, the
//!   per-launch secret) and its approvals apply exactly as for an agent, in a
//!   session labelled `cli`.
//! - `approvals approve ID` only shows the question again on this machine's
//!   collector (the cmux app's card on macOS); the person decides there.
//! - `setup` sets the mode as the box owner: on macOS the app's setting
//!   `computerUse.mode` (a raise waits for the person's confirmation in the
//!   app); on Linux and Windows the root- or SYSTEM-owned config, written with
//!   sudo or UAC from a terminal (`computer_use/system_config.rs`).

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, parse_globals};

#[cfg(unix)]
mod driver;
#[cfg(not(target_os = "macos"))]
mod system_config;
#[cfg(test)]
mod tests;

pub(super) const HELP: &str = "\
Usage: cmux computer-use <command>

Computer Use lets agents see and use the apps on this machine. Each agent
session asks the person before it uses an app (mode ask); the person answers
on cmux's card or their phone. Only the person raises trust: these commands
read, lower trust, or ask the person.

  cmux computer-use status                 Mode, sessions and their apps, saved apps, collectors
  cmux computer-use tools                  The driver's tools (the cua_* MCP tools)
  cmux computer-use call TOOL [--args JSON]
                                           Run one driver tool, with the same approvals as an agent
  cmux computer-use screenshot --out FILE [--args JSON]
                                           Save a screenshot (PNG) to FILE
  cmux computer-use approvals list         Apps saved with Always Allow for this cmux client
  cmux computer-use approvals pending      Questions waiting for the person
  cmux computer-use approvals revoke APP   Forget a saved app (bundle id, executable path or name)
  cmux computer-use approvals revoke --all Forget every saved app
  cmux computer-use approvals approve ID   Show question ID again on cmux's card (you answer there)
  cmux computer-use approvals deny ID      Deny question ID
  cmux computer-use setup --mode ask|standard|bounded|unrestricted [--manifest FILE]
                          [--i-understand-unrestricted]
                          [--device-hub URL --hub-token-command PROGRAM [--hub-allow-always]
                           --approver DEVICE_ID...]
                                           Set this machine's mode (macOS: in the cmux app, which
                                           confirms a raise; Linux and Windows: the system config,
                                           with sudo or UAC from a terminal). --approver pins a
                                           Mac or iPhone of your account that may answer this
                                           machine's questions: setup shows its name, platform and
                                           key fingerprint and asks you to confirm

Modes: ask (default; each app is asked for), standard (routine use runs, risky
steps ask), bounded (the apps in --manifest run, others ask), unrestricted
(disposable VMs only: no questions; needs CUA_DRIVER_PERMISSION_MODE=unrestricted,
CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1 and --i-understand-unrestricted).
Add --json for JSON output. Agents use the MCP tools cua_status,
cua_approvals_list and cua_approvals_revoke; no tool can approve.
";

/// The two-part opt-in upstream requires for `unrestricted`.
pub(super) const UNRESTRICTED_ENV: [(&str, &str); 2] = [
    ("CUA_DRIVER_PERMISSION_MODE", "unrestricted"),
    ("CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS", "1"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Mode {
    Ask,
    Standard,
    Bounded,
    Unrestricted,
}

impl Mode {
    fn parse(word: &str) -> Option<Self> {
        match word {
            "ask" => Some(Self::Ask),
            "standard" => Some(Self::Standard),
            "bounded" => Some(Self::Bounded),
            "unrestricted" => Some(Self::Unrestricted),
            _ => None,
        }
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Standard => "standard",
            Self::Bounded => "bounded",
            Self::Unrestricted => "unrestricted",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
// The device hub fields are read by the Linux and Windows setup only.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub(super) struct Setup {
    pub mode: Mode,
    pub manifest: Option<std::path::PathBuf>,
    pub understand_unrestricted: bool,
    /// The elevated run of `setup` (sudo or UAC started it): write the system
    /// config and nothing else. Never typed by a person.
    pub elevated: bool,
    /// The device hub this machine asks through (`https://`).
    pub device_hub: Option<String>,
    /// The program that prints the account's access token for the hub.
    pub hub_token_command: Option<std::path::PathBuf>,
    /// Whether a pinned phone or Mac may answer Always for this machine.
    pub hub_allow_always: bool,
    /// `--approver ID`: devices to look up on the hub and confirm on the terminal.
    pub approvers: Vec<String>,
    /// `--approver-pin JSON`: pins already confirmed (the elevated run) or
    /// given by root's provisioning. Linux and Windows only.
    #[cfg(not(target_os = "macos"))]
    pub approver_pins: Vec<system_config::Pin>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Command {
    Help,
    Status,
    Tools,
    Call { tool: String, arguments: Value },
    Screenshot { out: std::path::PathBuf, arguments: Value },
    List,
    Pending,
    Revoke { app: Option<String> },
    Approve { id: String },
    Deny { id: String },
    Setup(Setup),
}

/// The hidden flag of the elevated `setup` run.
pub(super) const ELEVATED_FLAG: &str = "--write-system-config";

/// Parses the words after `computer-use`.
pub(super) fn parse(args: &[String]) -> Result<Command, String> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    Ok(match words.as_slice() {
        [] | ["help" | "--help" | "-h"] => Command::Help,
        ["status"] => Command::Status,
        ["tools"] => Command::Tools,
        ["call", tool, rest @ ..] if !tool.starts_with('-') => {
            let flags = Flags::parse(rest, &["--args"], &[])?;
            Command::Call { tool: (*tool).to_owned(), arguments: flags.arguments()? }
        }
        ["screenshot", rest @ ..] => {
            let flags = Flags::parse(rest, &["--args", "--out"], &[])?;
            let out = flags.value("--out").ok_or("screenshot needs --out FILE")?;
            Command::Screenshot { out: out.into(), arguments: flags.arguments()? }
        }
        ["approvals", "list"] => Command::List,
        ["approvals", "pending"] => Command::Pending,
        ["approvals", "revoke", "--all"] => Command::Revoke { app: None },
        ["approvals", "revoke", app] if !app.starts_with('-') => {
            Command::Revoke { app: Some((*app).to_owned()) }
        }
        ["approvals", "approve", id] if !id.starts_with('-') => {
            Command::Approve { id: (*id).to_owned() }
        }
        ["approvals", "deny", id] if !id.starts_with('-') => Command::Deny { id: (*id).to_owned() },
        ["setup", rest @ ..] => Command::Setup(parse_setup(rest)?),
        _ => return Err(format!("unknown computer-use command: {}", words.join(" "))),
    })
}

fn parse_setup(rest: &[&str]) -> Result<Setup, String> {
    let flags = Flags::parse(
        rest,
        &["--mode", "--manifest", "--device-hub", "--hub-token-command", "--approver", "--approver-pin"],
        &["--i-understand-unrestricted", "--hub-allow-always", ELEVATED_FLAG],
    )?;
    let word =
        flags.value("--mode").ok_or("setup needs --mode ask|standard|bounded|unrestricted")?;
    let mode = Mode::parse(word).ok_or_else(|| {
        format!("unknown mode {word}: use ask, standard, bounded or unrestricted")
    })?;
    let manifest = flags.value("--manifest").map(std::path::PathBuf::from);
    if manifest.is_some() && mode != Mode::Bounded {
        return Err("--manifest goes with --mode bounded only".into());
    }
    let device_hub = flags.value("--device-hub").map(str::to_owned);
    if device_hub.as_deref().is_some_and(|url| !url.starts_with("https://")) {
        return Err("--device-hub takes an https:// URL".into());
    }
    let hub_token_command = flags.value("--hub-token-command").map(std::path::PathBuf::from);
    if hub_token_command.as_deref().is_some_and(|program| !program.is_absolute()) {
        return Err("--hub-token-command takes the program's absolute path".into());
    }
    if device_hub.is_some() != hub_token_command.is_some() {
        return Err("--device-hub and --hub-token-command go together".into());
    }
    let approvers: Vec<String> = flags.values("--approver").into_iter().map(str::to_owned).collect();
    let pin_words = flags.values("--approver-pin");
    if (!approvers.is_empty() || !pin_words.is_empty()) && device_hub.is_none() {
        return Err("--approver needs --device-hub URL and --hub-token-command PROGRAM".into());
    }
    if flags.has("--hub-allow-always") && device_hub.is_none() {
        return Err("--hub-allow-always goes with --device-hub".into());
    }
    #[cfg(not(target_os = "macos"))]
    let approver_pins =
        pin_words.iter().map(|text| system_config::Pin::parse(text)).collect::<Result<Vec<_>, _>>()?;
    if cfg!(target_os = "macos") && (device_hub.is_some() || !pin_words.is_empty()) {
        return Err("device hub approvers are pinned on Linux and Windows; the Mac pairs in the app".into());
    }
    Ok(Setup {
        mode,
        manifest,
        understand_unrestricted: flags.has("--i-understand-unrestricted"),
        elevated: flags.has(ELEVATED_FLAG),
        device_hub,
        hub_token_command,
        hub_allow_always: flags.has("--hub-allow-always"),
        approvers,
        #[cfg(not(target_os = "macos"))]
        approver_pins,
    })
}

/// Flags that may be given more than once.
const REPEATABLE: [&str; 2] = ["--approver", "--approver-pin"];

/// `--flag VALUE` options and bare switches, each at most once, in any order.
struct Flags<'a> {
    values: Vec<(&'a str, &'a str)>,
    switches: Vec<&'a str>,
}

impl<'a> Flags<'a> {
    fn parse(words: &[&'a str], valued: &[&str], switches: &[&str]) -> Result<Self, String> {
        let mut flags = Flags { values: Vec::new(), switches: Vec::new() };
        let mut index = 0;
        while let Some(word) = words.get(index).copied() {
            let seen = (flags.values.iter().any(|(k, _)| *k == word) && !REPEATABLE.contains(&word))
                || flags.switches.contains(&word);
            if seen {
                return Err(format!("{word} is given twice"));
            }
            if valued.contains(&word) {
                let value =
                    words.get(index + 1).copied().ok_or_else(|| format!("{word} needs a value"))?;
                flags.values.push((word, value));
                index += 2;
            } else if switches.contains(&word) {
                flags.switches.push(word);
                index += 1;
            } else {
                return Err(format!("unexpected word: {word}"));
            }
        }
        Ok(flags)
    }

    fn value(&self, flag: &str) -> Option<&'a str> {
        self.values.iter().find(|(k, _)| *k == flag).map(|(_, v)| *v)
    }

    /// Every value of a repeatable flag, in order.
    fn values(&self, flag: &str) -> Vec<&'a str> {
        self.values.iter().filter(|(k, _)| *k == flag).map(|(_, v)| *v).collect()
    }

    fn has(&self, flag: &str) -> bool {
        self.switches.contains(&flag)
    }

    /// `--args`: a JSON object, `{}` without it.
    fn arguments(&self) -> Result<Value, String> {
        match self.value("--args") {
            None => Ok(json!({})),
            Some(text) => match serde_json::from_str::<Value>(text) {
                Ok(value @ Value::Object(_)) => Ok(value),
                _ => Err("--args takes a JSON object, such as '{\"pid\": 42}'".into()),
            },
        }
    }
}

/// Why `setup` refuses `unrestricted`, if it does: upstream's two env vars
/// and the explicit flag, all three.
pub(super) fn unrestricted_refusal(
    setup: &Setup,
    env: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    if setup.mode != Mode::Unrestricted {
        return None;
    }
    let missing: Vec<String> = UNRESTRICTED_ENV
        .iter()
        .filter(|(key, value)| env(key).as_deref() != Some(*value))
        .map(|(key, value)| format!("{key}={value}"))
        .collect();
    if missing.is_empty() && setup.understand_unrestricted {
        return None;
    }
    let needed: Vec<String> = UNRESTRICTED_ENV.iter().map(|(k, v)| format!("{k}={v}")).collect();
    Some(format!(
        "unrestricted runs every agent action with no question, for disposable VMs only. Set {} \
         and pass --i-understand-unrestricted to choose it",
        needed.join(" and ")
    ))
}

/// Handles `cmux computer-use` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("computer-use") {
        return None;
    }
    Some(run(&global, &command_args[1..]))
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let command = match parse(args) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("cmux computer-use: {message}\n");
            eprint!("{HELP}");
            return 2;
        }
    };
    match command {
        Command::Help => {
            print!("{HELP}");
            0
        }
        Command::Setup(setup) => setup_mode(global, &setup),
        #[cfg(unix)]
        other => driver::run(global, other),
        #[cfg(not(unix))]
        _ => fail(
            global.output,
            "computer_use.unavailable",
            "on Windows, `cmux computer-use` sets the mode (setup); status, tools and approvals \
             come with the Windows host",
        ),
    }
}

fn setup_mode(global: &GlobalArgs, setup: &Setup) -> i32 {
    if let Some(why) = unrestricted_refusal(setup, |key| std::env::var(key).ok()) {
        return fail(global.output, "computer_use.unrestricted_needs_opt_in", &why);
    }
    #[cfg(target_os = "macos")]
    {
        driver::set_app_mode(global, setup)
    }
    #[cfg(not(target_os = "macos"))]
    {
        match system_config::apply(setup) {
            Ok(value) => super::wire::print_local_success(&value, global.output),
            Err(error) => super::wire::print_local_error(&error, global.output, 1),
        }
    }
}

/// Prints a local refusal.
pub(super) fn fail(output: OutputMode, code: &str, message: &str) -> i32 {
    super::wire::print_local_error(&json!({"code": code, "message": message}), output, 1)
}
