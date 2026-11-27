//! `cmux server install ssh://[USER@]HOST[:PORT]` and `cmux server uninstall
//! ssh://…`: set up (or remove) the cmux server on another machine you can
//! log in to with ssh, from this one.
//!
//! Install runs three steps, each printed before it runs and confirmed unless
//! `--yes` (without a terminal to ask on, `--yes` is required):
//!
//! 1. the cmux installer there, sent on ssh's stdin (the same script as
//!    `curl -fsSL https://cmux.com/tui/install.sh | sh -s -- --server`, built
//!    into this binary so nothing is fetched from a moving URL): it installs
//!    this build's commit (checksum-verified, no sudo) and runs `cmux server
//!    install` there, which keeps the session running as a service;
//! 2. a check that the session answers there;
//! 3. Connect to Machine in the cmux app here, so the machine shows up in
//!    the sidebar (skipped, with the command to run, when no app answers).
//!
//! ssh is the system `ssh`, with your keys and config; its own prompts (a new
//! host key, a password) go to the terminal as always. No host key is
//! accepted on your behalf, and the commands there get no forwarded agent,
//! X11 display or port: a compromised host gets nothing of this machine.
//! Without a terminal, ssh runs in batch mode: it never prompts, and an
//! unknown host key fails the step.

use cmux_process::{Command, Stdio};
use std::io::{BufRead as _, IsTerminal as _, Write as _};

use serde_json::{Value, json};

/// The installer, the same file cmux.com serves as `/tui/install-static.sh`.
const INSTALLER: &str = include_str!("../../../../../web/public/tui/install-static.sh");
/// Where `cmux server install` puts the session daemon's binary there.
const REMOTE_BINARY: &str = "$HOME/.local/bin/cmux-tui";

/// A parsed `ssh://[USER@]HOST[:PORT]`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Endpoint {
    /// `USER@HOST` or `HOST`: one ssh destination word.
    pub destination: String,
    pub port: Option<u16>,
}

/// `Some` for `ssh://…` (valid or not); `None` for anything else.
pub(crate) fn parse_endpoint(text: &str) -> Option<Result<Endpoint, String>> {
    let rest = text.strip_prefix("ssh://")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let bad = || Err(format!("invalid endpoint {text:?}: use ssh://[user@]host[:port]"));
    if rest.is_empty() || rest.contains('/') {
        return Some(bad());
    }
    let (user, host_port) = match rest.rsplit_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, rest),
    };
    // `[v6]` or `[v6]:port`; a bare v6 literal (two or more ':') has no port.
    let (host, port) = if let Some(inner) = host_port.strip_prefix('[') {
        match inner.split_once(']') {
            Some((v6, "")) => (v6, None),
            Some((v6, rest)) => match rest.strip_prefix(':') {
                Some(port) => (v6, Some(port)),
                None => return Some(bad()),
            },
            None => return Some(bad()),
        }
    } else if host_port.matches(':').count() > 1 {
        (host_port, None)
    } else {
        match host_port.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (host_port, None),
        }
    };
    let port = match port {
        None => None,
        Some(p) => match p.parse::<u16>() {
            Ok(p) if p > 0 => Some(p),
            _ => return Some(bad()),
        },
    };
    let word_ok = |w: &str| {
        !w.is_empty()
            && !w.starts_with('-')
            && w.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b':'))
    };
    if !word_ok(host) || user.is_some_and(|u| !word_ok(u) || u.contains(':')) {
        return Some(bad());
    }
    let destination = match user {
        Some(user) => format!("{user}@{host}"),
        None => host.to_owned(),
    };
    Some(Ok(Endpoint { destination, port }))
}

/// The commit to install there: this build's, when it is a published commit
/// (40 lowercase hex); `None` for a development build (the installer then
/// takes the current cmux NIGHTLY build).
pub(crate) fn install_commit(identity: &str) -> Option<&str> {
    (identity.len() == 40
        && identity.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
    .then_some(identity)
}

/// What a remote verb was asked to do, from `cmux_server`'s parsed words.
#[derive(Debug)]
pub(crate) struct Request {
    pub install: bool,
    pub endpoint: Endpoint,
    pub yes: bool,
    pub json: bool,
    /// `--nightly` or `--channel nightly`: the current cmux NIGHTLY build.
    pub nightly: bool,
    /// `--channel stable`: the latest stable build.
    pub stable: bool,
    /// `--user`: the service runs only while you are logged in there;
    /// linger is left as it is.
    pub user: bool,
    /// `--label LABEL`: the machine's name in the cmux app here (the
    /// sidebar), instead of its host name.
    pub label: Option<String>,
}

/// `Some` when `args` (the words after `server`) name an ssh:// endpoint.
pub(crate) fn request(args: &[String]) -> Option<Result<Request, String>> {
    let parsed = match cmux_server::cli::parse(args) {
        Ok(parsed) => parsed,
        Err(_) => return None,
    };
    let install = match parsed.verb.as_slice() {
        [verb] if verb == "install" => true,
        [verb] if verb == "uninstall" => false,
        _ => return None,
    };
    let endpoint = match parse_endpoint(parsed.positionals.first()?)? {
        Ok(endpoint) => endpoint,
        Err(e) => return Some(Err(e)),
    };
    let allowed: &[&str] =
        if install { &["yes", "nightly", "channel", "user", "label"] } else { &["yes", "user"] };
    if let Some(flag) = parsed.flags.keys().find(|f| !allowed.contains(&f.as_str())) {
        return Some(Err(format!("--{flag} does not go with an ssh:// endpoint")));
    }
    let channel = parsed.value("channel");
    let (stable, nightly) = match channel {
        None => (false, parsed.has("nightly")),
        Some("stable") if !parsed.has("nightly") => (true, false),
        Some("nightly") => (false, true),
        Some("stable") => {
            return Some(Err("--channel stable does not go with --nightly".to_owned()));
        }
        Some(other) => {
            return Some(Err(format!("--channel takes stable or nightly, not {other:?}")));
        }
    };
    let label = match parsed.value("label").map(str::trim) {
        None => None,
        Some(label) if label.is_empty() || label.chars().any(char::is_control) => {
            return Some(Err("--label takes a one-line name".to_owned()));
        }
        Some(label) => Some(label.to_owned()),
    };
    Some(Ok(Request {
        install,
        endpoint,
        yes: parsed.has("yes"),
        json: parsed.json,
        nightly,
        stable,
        user: parsed.has("user"),
        label,
    }))
}

/// The ssh argv for one remote command (never a secret: the installer goes
/// on stdin).
/// on stdin). Host key checking stays as the person's ssh config has it
/// (never turned off here); forwarding of the agent, X11 and ports is off,
/// a `RemoteCommand` or `LocalCommand` in the config does not run, and no
/// terminal is allocated. `batch`: no terminal here to answer a prompt, so
/// ssh must not ask (an unknown host key fails instead).
pub(crate) fn ssh_argv(endpoint: &Endpoint, remote: &str, batch: bool) -> Vec<String> {
    let mut argv = vec!["ssh".to_owned(), "-T".to_owned()];
    for option in [
        "ConnectTimeout=20",
        "ForwardAgent=no",
        "ForwardX11=no",
        "ClearAllForwardings=yes",
        "PermitLocalCommand=no",
        "RemoteCommand=none",
    ] {
        argv.extend(["-o".to_owned(), option.to_owned()]);
    }
    if batch {
        argv.extend(["-o".to_owned(), "BatchMode=yes".to_owned()]);
    }
    if let Some(port) = endpoint.port {
        argv.extend(["-p".to_owned(), port.to_string()]);
    }
    argv.extend(["--".to_owned(), endpoint.destination.clone(), remote.to_owned()]);
    argv
}

/// Which build the installer there takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Build<'a> {
    /// A published commit (40 lowercase hex, checked by [`install_commit`]).
    Commit(&'a str),
    Nightly,
    Stable,
}

/// The installer's arguments there. Every word is a fixed flag or a checked
/// commit, so nothing here needs quoting.
pub(crate) fn installer_command(build: Build<'_>, user: bool) -> String {
    let mut command = match build {
        Build::Commit(commit) => format!("sh -s -- --commit {commit} --server"),
        Build::Nightly => "sh -s -- --channel nightly --server".to_owned(),
        Build::Stable => "sh -s -- --channel stable --server".to_owned(),
    };
    if user {
        command.push_str(" --user");
    }
    command
}

/// The cmux binaries the installer and `cmux server install` put there.
const REMOVE_BINARIES: &str =
    "rm -f \"$HOME/.local/bin/cmux-tui\" \"$HOME/.local/bin/cmux\" \"$HOME/.cmux/bin/cmux\"";

pub(crate) fn status_command() -> String {
    format!("\"{REMOTE_BINARY}\" daemon status --session main")
}

/// Runs the `cmux` that `cmux server install` linked there (or the
/// installer's copy) with `server uninstall`.
pub(crate) fn uninstall_command() -> String {
    "for c in \"$HOME/.local/bin/cmux\" \"$HOME/.cmux/bin/cmux\"; do [ -x \"$c\" ] && exec \"$c\" server uninstall; done; echo 'cmux: no cmux on this machine' >&2; exit 3".to_owned()
}

/// The `cmux action run` argv that asks the app to connect to the machine,
/// named `label` in its sidebar when given.
pub(crate) fn connect_action(endpoint: &Endpoint, label: Option<&str>) -> Vec<String> {
    let destination = match endpoint.port {
        Some(port) => format!("ssh://{}:{port}", endpoint.destination),
        None => endpoint.destination.clone(),
    };
    let mut argv: Vec<String> =
        ["action", "run", "remote.connect", "--destination", destination.as_str()]
            .map(str::to_owned)
            .to_vec();
    if let Some(label) = label {
        argv.extend(["--name".to_owned(), label.to_owned()]);
    }
    argv
}

struct Steps {
    json: bool,
    yes: bool,
    interactive: bool,
    log: Vec<Value>,
}

impl Steps {
    fn say(&self, line: &str) {
        // Human progress goes to stderr under --json, so stdout stays one object.
        if self.json {
            eprintln!("{line}");
        } else {
            println!("{line}");
        }
    }

    /// Prints `what` and the command, then asks. `false`: the person said no.
    fn confirm(&self, what: &str, shown: &str) -> bool {
        self.say(&format!("{what}\n  $ {shown}"));
        if self.yes {
            return true;
        }
        eprint!("Run it? [y/N] ");
        let _ = std::io::stderr().flush();
        let mut answer = String::new();
        let _ = std::io::stdin().lock().read_line(&mut answer);
        matches!(answer.trim(), "y" | "Y" | "yes" | "Yes")
    }

    fn record(&mut self, step: &str, command: &str, code: Option<i32>) {
        self.log.push(json!({"step": step, "command": command, "exit": code}));
    }
}

fn shown(argv: &[String]) -> String {
    argv.iter()
        .map(|a| if a.contains([' ', '"', '$', ';']) { format!("'{a}'") } else { a.clone() })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Runs `argv`; its stdout goes to our stderr under --json. `stdin`: bytes to
/// send. Returns the exit code (`None`: killed or not started).
fn run(argv: &[String], stdin: Option<&str>, json: bool) -> Option<i32> {
    let (program, args) = argv.split_first()?;
    let mut cmd = Command::new(program);
    cmd.args(args);
    if json {
        cmd.stdout(to_stderr()?);
    }
    cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::inherit() });
    // Waited on below; a panic in between ends it with the handle.
    let mut child = cmd.spawn().ok()?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        // The pipe closes at the end of this block, so ssh sees the end.
        let _ = pipe.write_all(text.as_bytes());
    }
    child.wait().ok()?.code()
}

/// Our stderr, for a child's stdout under --json (stdout carries the summary).
#[cfg(unix)]
fn to_stderr() -> Option<Stdio> {
    use std::os::fd::AsFd as _;
    Some(Stdio::from(std::io::stderr().as_fd().try_clone_to_owned().ok()?))
}

#[cfg(windows)]
fn to_stderr() -> Option<Stdio> {
    use std::os::windows::io::AsHandle as _;
    let handle = std::io::stderr().as_handle().try_clone_to_owned().ok()?;
    Some(Stdio::from(std::fs::File::from(handle)))
}

/// Exit codes: 0 done, 2 usage, 4 the person said no, 5 ssh or a step
/// failed there.
pub(crate) fn run_request(request: &Request) -> i32 {
    let interactive = std::io::stdin().is_terminal();
    if !request.yes && !interactive {
        eprintln!("cmux server: no terminal to ask on; pass --yes to run every step");
        return 2;
    }
    let mut steps = Steps { json: request.json, yes: request.yes, interactive, log: Vec::new() };
    let ep = &request.endpoint;
    let code =
        if request.install { install(request, &mut steps) } else { uninstall(ep, &mut steps) };
    if request.json {
        let body = json!({
            "endpoint": ep.destination, "port": ep.port, "ok": code == 0,
            "steps": steps.log, "interactive": steps.interactive,
        });
        println!("{body}");
    }
    code
}

fn install(request: &Request, steps: &mut Steps) -> i32 {
    let ep = &request.endpoint;
    let batch = !steps.interactive;
    // cmux-build-identity is a Unix-only dependency (Cargo.toml); a Windows
    // build has no stamped commit, so it installs the current NIGHTLY build.
    #[cfg(unix)]
    let own = crate::build_identity::identity();
    #[cfg(not(unix))]
    let own = "";
    let commit = if request.nightly { None } else { install_commit(own) };
    let target = match (request.stable, commit) {
        (true, _) => Build::Stable,
        (false, Some(commit)) => Build::Commit(commit),
        (false, None) => Build::Nightly,
    };
    let build = match target {
        Build::Commit(commit) => format!("cmux {}", commit.get(..12).unwrap_or(commit)),
        Build::Nightly => "the current cmux NIGHTLY build".to_owned(),
        Build::Stable => "the latest stable cmux build".to_owned(),
    };
    let remote = installer_command(target, request.user);
    let argv = ssh_argv(ep, &remote, batch);
    let what = format!(
        "Install {build} on {} and keep its cmux session running as a service (no sudo; the installer goes on ssh's stdin):",
        ep.destination
    );
    if !steps.confirm(&what, &shown(&argv)) {
        steps.say("cmux server: nothing changed");
        return 4;
    }
    let code = run(&argv, Some(INSTALLER), steps.json);
    steps.record("install", &shown(&argv), code);
    if code != Some(0) {
        let hint = if matches!(target, Build::Commit(_)) {
            " (if this build is not published, run it again with --nightly)"
        } else {
            ""
        };
        eprintln!(
            "cmux server: the install on {} failed (exit {}); nothing else was changed{hint}",
            ep.destination,
            code.map_or("none".to_owned(), |c| c.to_string())
        );
        return 5;
    }
    let argv = ssh_argv(ep, &status_command(), batch);
    steps.say(&format!(
        "Check that the cmux session answers on {}:\n  $ {}",
        ep.destination,
        shown(&argv)
    ));
    let code = run(&argv, None, steps.json);
    steps.record("check", &shown(&argv), code);
    if code != Some(0) {
        eprintln!(
            "cmux server: the service is installed on {} but its session did not answer",
            ep.destination
        );
        return 5;
    }
    let mut argv = vec!["cmux".to_owned()];
    argv.extend(connect_action(ep, request.label.as_deref()));
    let shown_as = request.label.as_deref().map(|l| format!(" as {l}")).unwrap_or_default();
    let what =
        format!("Add {}{shown_as} to the cmux app here (Connect to Machine):", ep.destination);
    if !steps.confirm(&what, &shown(&argv)) {
        steps.say(&format!(
            "cmux server: {} is ready; connect later with: {}",
            ep.destination,
            shown(&argv)
        ));
        return 0;
    }
    let program = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "cmux".to_owned());
    let mut cmd_argv = vec![program];
    cmd_argv.extend(connect_action(ep, request.label.as_deref()));
    let code = run_as_cmux_cli(&cmd_argv, steps.json);
    steps.record("connect", &shown(&argv), code);
    if code == Some(0) {
        steps.say(&format!("cmux server: {} is set up and open in cmux", ep.destination));
    } else {
        steps.say(&format!(
            "cmux server: {} is set up; no cmux app answered here, so open it with Connect to Machine… ({})",
            ep.destination,
            ep.destination
        ));
    }
    0
}

/// Runs this binary as `cmux` (argv[0] picks which command line it answers as).
fn run_as_cmux_cli(argv: &[String], json: bool) -> Option<i32> {
    let (program, args) = argv.split_first()?;
    let mut cmd = Command::new(program);
    cmd.arg0("cmux");
    cmd.args(args).stdin(Stdio::null());
    if json {
        cmd.stdout(to_stderr()?);
    }
    cmd.status().ok()?.code()
}

fn uninstall(ep: &Endpoint, steps: &mut Steps) -> i32 {
    let argv = ssh_argv(ep, &uninstall_command(), !steps.interactive);
    let what = format!(
        "Stop and remove the cmux server service on {} (this ends the programs in its sessions; cmux stays installed there):",
        ep.destination
    );
    if !steps.confirm(&what, &shown(&argv)) {
        steps.say("cmux server: nothing changed");
        return 4;
    }
    let code = run(&argv, None, steps.json);
    steps.record("uninstall", &shown(&argv), code);
    if code != Some(0) {
        eprintln!("cmux server: the uninstall on {} failed", ep.destination);
        return 5;
    }
    let rm = ssh_argv(ep, REMOVE_BINARIES, false);
    steps.say(&format!(
        "cmux server: removed the service on {}. cmux stays installed there (the lines above say what else stays and how to remove it). To remove cmux there too: {}. To remove the machine from cmux here: right-click it in the sidebar and choose Forget Machine…",
        ep.destination,
        shown(&rm)
    ));
    0
}

#[cfg(test)]
#[path = "server_remote_tests.rs"]
mod tests;
