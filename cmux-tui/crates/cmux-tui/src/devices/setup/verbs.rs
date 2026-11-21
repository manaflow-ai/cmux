//! The `cmux device setup|start` verbs: the asking side, the CLI, the MCP and the daemon's
//! `device-setup` command.

use super::*;

/// This machine as the asking side.
pub(super) struct ThisMachine;

impl Asking for ThisMachine {
    fn feed(&self) -> Result<String, String> {
        http_get(FEED).and_then(|bytes| String::from_utf8(bytes).map_err(|e| e.to_string()))
    }

    fn team_id(&self) -> Option<String> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        let out = cmux_process::Command::new("codesign")
            .args(["-dv", "--verbose=2", APP])
            .stdin(cmux_process::Stdio::null())
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stderr)
            .lines()
            .find_map(|l| l.strip_prefix("TeamIdentifier="))
            .map(|t| t.trim().to_owned())
            .filter(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_alphanumeric()))
    }

    fn mint_handoff(&self) -> Result<String, AskError> {
        let out = super::super::cmux()
            .map_err(|e| AskError::Failed(e.to_string()))?
            .args(["auth", "handoff", "mint", "--json"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| AskError::Failed(e.to_string()))?;
        let text = format!(
            "{}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if !out.status.success() {
            return Err(if out.status.code() == Some(2) || unknown_verb(&text) {
                AskError::Unsupported
            } else {
                AskError::Failed(last_line(&String::from_utf8_lossy(&out.stderr)))
            });
        }
        serde_json::from_slice::<Value>(&out.stdout)
            .ok()
            .and_then(|v| v.get("code").and_then(Value::as_str).map(str::to_owned))
            .filter(|code| !code.is_empty() && !code.contains(['\n', '\r']))
            .ok_or_else(|| AskError::Failed("the sign-in handoff printed no code".into()))
    }

    fn agents_allowed(&self) -> Result<bool, AskError> {
        let value = local_json(&["remote-host", "agents", "status", "--json"])?;
        let value = value.get("data").filter(|d| d.is_object()).unwrap_or(&value);
        ["allowed", "on", "enabled"]
            .iter()
            .find_map(|key| value.get(*key).and_then(Value::as_bool))
            .ok_or_else(|| {
                AskError::Failed("`cmux remote-host agents status` said no state".into())
            })
    }

    #[cfg(unix)]
    fn allow_agents(&self) -> Result<Value, Value> {
        crate::cli::confirm_allow_agents()
    }

    #[cfg(not(unix))]
    fn allow_agents(&self) -> Result<Value, Value> {
        Err(json!({"code": "unavailable", "message": "the cmux app runs on a Mac"}))
    }
}

/// `cmux <args>` on this machine as JSON (stdout may be empty); an unknown verb (exit 2, or a
/// usage or unknown-command answer) is [`AskError::Unsupported`].
pub(super) fn local_json(args: &[&str]) -> Result<Value, AskError> {
    let out = super::super::cmux()
        .map_err(|e| AskError::Failed(e.to_string()))?
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| AskError::Failed(e.to_string()))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() {
        let text = format!("{stdout}\n{stderr}");
        let unknown = out.status.code() == Some(2)
            || unknown_verb(&text)
            || text.to_ascii_lowercase().contains("usage: cmux remote-host");
        return Err(if unknown {
            AskError::Unsupported
        } else {
            let why = last_line(&stderr);
            AskError::Failed(if why.is_empty() { last_line(&stdout) } else { why })
        });
    }
    Ok(serde_json::from_str(stdout.trim()).unwrap_or(Value::Null))
}

/// One GET with a 30 s timeout.
#[cfg(unix)]
pub(super) fn http_get(url: &str) -> Result<Vec<u8>, String> {
    // reqwest's rustls-no-provider build needs the workspace's ring provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("runtime: {error}"))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION"), " device-setup"))
        .build()
        .map_err(|error| format!("http client: {error}"))?;
    runtime.block_on(async {
        let response = client.get(url).send().await.map_err(|error| error.to_string())?;
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }
        response.bytes().await.map(|bytes| bytes.to_vec()).map_err(|error| error.to_string())
    })
}

#[cfg(not(unix))]
pub(super) fn http_get(_url: &str) -> Result<Vec<u8>, String> {
    Err("reading the NIGHTLY feed needs macOS or Linux".into())
}

/// A run's switches.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Options {
    pub dry_run: bool,
    /// `--allow-agents`: turn the agents permission on (never on without it).
    pub allow_agents: bool,
}

/// Where a run finds its devices, its Macs and its asking side: this machine's, or a test's.
pub(crate) trait World {
    /// The device's name and ssh route, or why there is none.
    fn lookup(&self, target: &str) -> Result<(String, String), String>;
    fn remote<'a>(&'a self, route: &'a str) -> Box<dyn Remote + 'a>;
    fn asking(&self) -> &dyn Asking;
    /// Appends to the device audit.
    fn record(&self, event: &str, fields: Value);
}

/// One device's run: what `cmux device setup|start DEVICE`, the MCP tools (through the CLI) and
/// the daemon's `device-setup` all run. `emit` sees each step line, with its device, as it is
/// made.
pub(crate) fn run_one(
    world: &dyn World,
    target: &str,
    mode: Mode,
    options: Options,
    emit: &mut dyn FnMut(&str, &Line),
) -> Run {
    let mut run = match world.lookup(target) {
        Ok((name, route)) => {
            let remote = world.remote(&route);
            run_device(&name, remote.as_ref(), world.asking(), mode, options.dry_run, &mut |line| {
                emit(&name, line);
            })
        }
        Err(why) => {
            let line = Line {
                step: "reach",
                state: StepState::Fail,
                detail: why,
                fix: format!("cmux device add {}", super::super::shell_word(target)),
            };
            emit(target, &line);
            Run { device: target.to_owned(), lines: vec![line], changed: Vec::new() }
        }
    };
    if mode == Mode::Setup {
        let line = share_policy_step(world.asking(), options.allow_agents, options.dry_run);
        if line.state == StepState::Changed {
            run.changed.push("agents allowed".into());
        }
        emit(&run.device, &line);
        run.lines.push(line);
    }
    if !options.dry_run {
        let event = if mode == Mode::Setup { "device.setup" } else { "device.start" };
        world.record(
            event,
            json!({"device": run.device, "changed": run.changed, "failed": run.failed()}),
        );
    }
    run
}

/// The line the CLI prints for a step: its `--json` line, else one human line.
pub(crate) fn cli_line(device: &str, line: &Line, json_out: bool) -> String {
    if json_out { line.json(device).to_string() } else { line.human() }
}

/// The daemon's `device-setup`: each step line goes to `step` (the server sends it as a
/// `device-setup-step` event); the answer is the summary line.
pub(crate) fn serve(
    world: &dyn World,
    request: &cmux_tui_core::device_setup::DeviceSetupRequest,
    step: &mut dyn FnMut(Value),
) -> Value {
    let mode = if request.start_only { Mode::Start } else { Mode::Setup };
    let options = Options { dry_run: request.dry_run, allow_agents: request.allow_agents };
    let run = run_one(world, &request.device, mode, options, &mut |device, line| {
        step(line.json(device));
    });
    run.summary_json()
}

/// What the daemon installs (`cmux_tui_core::device_setup::on_device_setup`).
pub(crate) fn daemon_run(
    request: &cmux_tui_core::device_setup::DeviceSetupRequest,
    step: &mut dyn FnMut(Value),
) -> Result<Value, String> {
    let flags = super::super::Flags::parse(&[], &[], &[]).map_err(|e| e.to_string())?;
    let here = Here::read(&flags).map_err(|e| format!("{e:#}"))?;
    Ok(serve(&here, request, step))
}

/// This machine's devices and routes, as `cmux device list` reads them.
pub(super) struct Here {
    listing: Listing,
    sources: Sources,
}

impl Here {
    pub(super) fn read(flags: &super::super::Flags) -> anyhow::Result<Self> {
        let auth = super::super::JoinAuth::read(flags)?;
        let net = super::super::network::pick(
            super::super::choice(flags)?,
            Box::new(super::super::network::WeftNetwork),
            || Box::new(super::super::network::TailscaleNetwork::read()),
        );
        let mut notes = Vec::new();
        let sources = super::super::read_sources(&auth, &mut notes);
        let listing = model::merge(&sources, net.status(), &net.nodes());
        Ok(Self { listing, sources })
    }
}

impl World for Here {
    fn lookup(&self, target: &str) -> Result<(String, String), String> {
        match model::find(&self.listing, target) {
            Some(device) => route(device, &self.sources).map(|r| (device.name.clone(), r)),
            None => Err(format!("no device named {target}")),
        }
    }

    fn remote<'a>(&'a self, route: &'a str) -> Box<dyn Remote + 'a> {
        Box::new(SshRemote(route))
    }

    fn asking(&self) -> &dyn Asking {
        &ThisMachine
    }

    fn record(&self, event: &str, fields: Value) {
        super::super::record(event, fields);
    }
}

/// `cmux device setup DEVICE|--all [--json] [--dry-run] [--allow-agents]` and
/// `cmux device start DEVICE [--json]`.
pub(crate) fn verb(args: &[String], mode: Mode) -> anyhow::Result<()> {
    let booleans: &[&str] = match mode {
        Mode::Setup => &["json", "dry-run", "all", "allow-agents"],
        Mode::Start => &["json"],
    };
    let flags = super::super::Flags::parse(args, &["network"], booleans)?;
    let json_out = flags.has("json");
    let options =
        Options { dry_run: flags.has("dry-run"), allow_agents: flags.has("allow-agents") };
    let all = flags.has("all");
    let target = match (flags.positional.as_slice(), all) {
        ([], true) => None,
        ([device], false) => Some(device.clone()),
        _ => {
            return Err(super::super::usage(if mode == Mode::Setup {
                "needs one DEVICE, or --all"
            } else {
                "needs one DEVICE"
            }));
        }
    };
    let here = Here::read(&flags)?;
    let print_summary = |run: &Run| {
        if json_out {
            println!("{}", run.summary_json());
        } else {
            println!("{}", run.summary());
        }
    };

    let Some(target) = target else {
        let (mut done, mut skipped, mut failed) = (0, 0, 0);
        for (name, pick) in select(&here.listing, &here.sources) {
            if let Err(why) = pick {
                skipped += 1;
                let line =
                    Line { step: "reach", state: StepState::Skip, detail: why, fix: String::new() };
                if json_out {
                    println!("{}", line.json(&name));
                } else {
                    println!("{name}: skipped, {}", line.detail);
                }
                continue;
            }
            let run = run_one(&here, &name, mode, options, &mut |_, _| {});
            // A device the probe found is not a Mac (an ssh peer with no recorded OS) is
            // skipped, with the probe's reason, never counted as set up.
            if let Some(reach) = run.not_a_mac() {
                skipped += 1;
                if json_out {
                    println!("{}", reach.json(&name));
                } else {
                    println!("{name}: skipped, {}", reach.detail);
                }
                continue;
            }
            if run.failed().is_empty() {
                done += 1;
            } else {
                failed += 1;
            }
            print_summary(&run);
        }
        let summary = format!("{done} set up, {failed} failed, {skipped} skipped");
        if json_out {
            println!(
                "{}",
                json!({"total": {"set_up": done, "failed": failed, "skipped": skipped}, "summary": summary})
            );
        } else {
            println!("{summary}");
        }
        if failed > 0 {
            anyhow::bail!("{failed} device(s) failed; their lines say why");
        }
        return Ok(());
    };

    let run = run_one(&here, &target, mode, options, &mut |device, line| {
        println!("{}", cli_line(device, line, json_out));
    });
    print_summary(&run);
    if !run.failed().is_empty() {
        anyhow::bail!("a step failed on {}; its line says why", run.device);
    }
    Ok(())
}

/// What the MCP tools run: `cmux device <args> --json` as a child (its stdout is not the MCP
/// channel), every JSON line it printed, and whether it exited 0.
pub(crate) fn run_json_lines(args: &[&str]) -> anyhow::Result<(bool, Vec<Value>, String)> {
    let out = super::super::cmux()?
        .arg("device")
        .args(args)
        .arg("--json")
        .stdin(Stdio::null())
        .output()?;
    let lines = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect();
    Ok((out.status.success(), lines, last_line(&String::from_utf8_lossy(&out.stderr))))
}
