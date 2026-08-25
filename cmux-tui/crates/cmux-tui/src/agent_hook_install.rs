use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
#[cfg(not(unix))]
use std::process::Command;
use std::process::{Child, Output, Stdio};
use std::time::{Duration, Instant};

use anyhow::Context as _;
#[cfg(unix)]
use cmux_tui_core::unix_process_scope::{UnixChildExitSignal, UnixProcessScope};
use serde_json::{Map, Value, json};
#[cfg(not(unix))]
use wait_timeout::ChildExt;
#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
#[cfg(windows)]
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
#[cfg(windows)]
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, OpenProcess, OpenThread, PROCESS_SET_QUOTA, PROCESS_TERMINATE, ResumeThread,
    THREAD_SUSPEND_RESUME,
};

const COMMAND_MARKER: &str = "cmux-tui-journal-hook";
const PLUGIN_MARKER: &str = "cmux-tui-journal-plugin";
const ACTIVATION_NOTE: &str = "Providers load hooks at process start; launch or restart agents inside a cmux-tui terminal so CMUX_TUI_SOCKET and CMUX_TUI_HOOK are inherited.";
const MAX_CONFIG_BYTES: u64 = 16 * 1024 * 1024;
const MAX_HELPER_BYTES: u64 = 128 * 1024 * 1024;
const COMMAND_HOOK_TIMEOUT_SECONDS: u64 = 5;
const GEMINI_HOOK_TIMEOUT_MILLISECONDS: u64 = 5_000;
const HERMES_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const HERMES_COMMAND_OUTPUT_BYTES: u64 = 4 * 1024 * 1024;

const CODEX_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "PermissionRequest",
    "PreToolUse",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "SessionEnd",
];

const CLAUDE_EVENTS: &[&str] = &[
    "ConfigChange",
    "CwdChanged",
    "Elicitation",
    "ElicitationResult",
    "FileChanged",
    "InstructionsLoaded",
    "SessionStart",
    "Setup",
    "UserPromptSubmit",
    "UserPromptExpansion",
    "Stop",
    "StopFailure",
    "SessionEnd",
    "Notification",
    "PermissionDenied",
    "PermissionRequest",
    "PreToolUse",
    "PostToolBatch",
    "PostToolUse",
    "PostToolUseFailure",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "TaskCreated",
    "TaskCompleted",
    "TeammateIdle",
    "WorktreeCreate",
    "WorktreeRemove",
];

const GEMINI_EVENTS: &[&str] = &[
    "SessionStart",
    "BeforeAgent",
    "AfterAgent",
    "BeforeTool",
    "AfterTool",
    "Notification",
    "PreCompress",
    "SessionEnd",
];

const CURSOR_EVENTS: &[&str] = &[
    "sessionStart",
    "beforeSubmitPrompt",
    "beforeShellExecution",
    "afterShellExecution",
    "beforeMCPExecution",
    "afterMCPExecution",
    "beforeReadFile",
    "afterFileEdit",
    "afterAgentThought",
    "afterAgentResponse",
    "preToolUse",
    "postToolUse",
    "postToolUseFailure",
    "preCompact",
    "subagentStart",
    "subagentStop",
    "stop",
    "sessionEnd",
];

const GROK_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionDenied",
    "Stop",
    "StopFailure",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "SessionEnd",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Action {
    Install,
    Uninstall,
    Status,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Plan {
    pub action: Action,
    pub providers: Vec<String>,
}

#[derive(Debug)]
pub(crate) struct RunResult {
    pub value: Value,
    pub failed: bool,
}

#[derive(Clone, Copy)]
enum Format {
    Nested { timeout: u64, asynchronous: bool },
    Flat { timeout: u64 },
    Plugin { template: &'static str },
    HermesPlugin { module: &'static str, manifest: &'static str },
}

#[derive(Clone, Copy)]
struct Provider {
    id: &'static str,
    binary: &'static str,
    default_path: &'static str,
    override_env: Option<&'static str>,
    override_relative_path: &'static str,
    format: Format,
    events: &'static [&'static str],
}

const PROVIDERS: &[Provider] = &[
    Provider {
        id: "codex",
        binary: "codex",
        default_path: ".codex/hooks.json",
        override_env: Some("CODEX_HOME"),
        override_relative_path: "hooks.json",
        format: Format::Nested { timeout: COMMAND_HOOK_TIMEOUT_SECONDS, asynchronous: false },
        events: CODEX_EVENTS,
    },
    Provider {
        id: "claude",
        binary: "claude",
        default_path: ".claude/settings.json",
        override_env: Some("CLAUDE_CONFIG_DIR"),
        override_relative_path: "settings.json",
        format: Format::Nested { timeout: COMMAND_HOOK_TIMEOUT_SECONDS, asynchronous: true },
        events: CLAUDE_EVENTS,
    },
    Provider {
        id: "gemini",
        binary: "gemini",
        default_path: ".gemini/settings.json",
        override_env: None,
        override_relative_path: "settings.json",
        format: Format::Nested { timeout: GEMINI_HOOK_TIMEOUT_MILLISECONDS, asynchronous: false },
        events: GEMINI_EVENTS,
    },
    Provider {
        id: "cursor",
        binary: "cursor-agent",
        default_path: ".cursor/hooks.json",
        override_env: None,
        override_relative_path: "hooks.json",
        format: Format::Flat { timeout: COMMAND_HOOK_TIMEOUT_SECONDS },
        events: CURSOR_EVENTS,
    },
    Provider {
        id: "grok",
        binary: "grok",
        default_path: ".grok/hooks/cmux-tui-journal.json",
        override_env: Some("GROK_HOME"),
        override_relative_path: "hooks/cmux-tui-journal.json",
        format: Format::Nested { timeout: COMMAND_HOOK_TIMEOUT_SECONDS, asynchronous: false },
        events: GROK_EVENTS,
    },
    Provider {
        id: "hermes-agent",
        binary: "hermes",
        default_path: ".hermes/plugins/cmux-tui-journal",
        override_env: Some("HERMES_HOME"),
        override_relative_path: "plugins/cmux-tui-journal",
        format: Format::HermesPlugin {
            module: include_str!("../assets/agent-hooks/hermes.py"),
            manifest: include_str!("../assets/agent-hooks/hermes.yaml"),
        },
        events: &[],
    },
    Provider {
        id: "opencode",
        binary: "opencode",
        default_path: ".config/opencode/plugins/cmux-tui-journal.js",
        override_env: Some("OPENCODE_CONFIG_DIR"),
        override_relative_path: "plugins/cmux-tui-journal.js",
        format: Format::Plugin { template: include_str!("../assets/agent-hooks/opencode.js") },
        events: &[],
    },
    Provider {
        id: "amp",
        binary: "amp",
        default_path: ".config/amp/plugins/cmux-tui-journal.ts",
        override_env: None,
        override_relative_path: "plugins/cmux-tui-journal.ts",
        format: Format::Plugin { template: include_str!("../assets/agent-hooks/amp.ts") },
        events: &[],
    },
    Provider {
        id: "pi",
        binary: "pi",
        default_path: ".pi/agent/extensions/cmux-tui-journal.ts",
        override_env: Some("PI_CODING_AGENT_DIR"),
        override_relative_path: "extensions/cmux-tui-journal.ts",
        format: Format::Plugin { template: include_str!("../assets/agent-hooks/pi.ts") },
        events: &[],
    },
];

struct Context {
    home: PathBuf,
    data_home: PathBuf,
    helper_source: Option<PathBuf>,
    path: Option<OsString>,
    environment: BTreeMap<String, OsString>,
}

impl Context {
    fn runtime() -> anyhow::Result<Self> {
        let home = std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .context("HOME is required to install coding-agent hooks")?;
        let data_home = runtime_data_home(&home);
        let helper_source = locate_helper_source(std::env::current_exe().ok().as_deref());
        let environment = PROVIDERS
            .iter()
            .filter_map(|provider| provider.override_env)
            .filter_map(|name| std::env::var_os(name).map(|value| (name.to_string(), value)))
            .collect();
        Ok(Self { home, data_home, helper_source, path: std::env::var_os("PATH"), environment })
    }

    fn installed_helper(&self) -> PathBuf {
        self.data_home.join("cmux-tui/bin/cmux-tui-hook")
    }

    fn provider_path(&self, provider: Provider) -> PathBuf {
        if let Some(root) = provider
            .override_env
            .and_then(|name| self.environment.get(name))
            .filter(|value| !value.is_empty())
        {
            return PathBuf::from(root).join(provider.override_relative_path);
        }
        self.home.join(provider.default_path)
    }
}

fn runtime_data_home(home: &Path) -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"))
}

#[cfg(unix)]
pub(crate) fn runtime_helper_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").filter(|value| !value.is_empty()).map(PathBuf::from)?;
    Some(runtime_data_home(&home).join("cmux-tui/bin/cmux-tui-hook"))
}

#[cfg(not(unix))]
pub(crate) fn runtime_helper_path() -> Option<PathBuf> {
    None
}

#[cfg(unix)]
pub(crate) fn run(plan: &Plan) -> RunResult {
    match Context::runtime() {
        Ok(context) => run_with_context(plan, &context),
        Err(error) => RunResult {
            value: json!({"action":action_name(plan.action),"errors":[error.to_string()]}),
            failed: true,
        },
    }
}

#[cfg(not(unix))]
pub(crate) fn run(plan: &Plan) -> RunResult {
    RunResult {
        value: json!({
            "action":action_name(plan.action),
            "errors":[format!(
                "coding-agent hook management is unsupported on {}",
                std::env::consts::OS
            )]
        }),
        failed: true,
    }
}

fn run_with_context(plan: &Plan, context: &Context) -> RunResult {
    let selected = match select_providers(plan, context) {
        Ok(selected) => selected,
        Err(error) => {
            return RunResult {
                value: json!({"action":action_name(plan.action),"errors":[error.to_string()]}),
                failed: true,
            };
        }
    };
    let helper = context.installed_helper();
    let mut results = Vec::new();
    let mut errors = Vec::new();

    if plan.action == Action::Install {
        match context.helper_source.as_deref() {
            Some(source) => {
                if let Err(error) = install_helper(source, &helper) {
                    errors.push(format!("helper: {error:#}"));
                }
            }
            None => {
                errors
                    .push("helper: cmux-tui-hook was not found beside cmux-tui or on PATH".into());
            }
        }
    }

    if errors.is_empty() || plan.action != Action::Install {
        for provider in selected {
            let path = context.provider_path(provider);
            let outcome = if provider.id == "hermes-agent" {
                run_hermes_provider(plan.action, provider, &path, context)
            } else {
                match plan.action {
                    Action::Install => install_provider(provider, &path),
                    Action::Uninstall => uninstall_provider(provider, &path),
                    Action::Status => provider_status(provider, &path),
                }
            };
            match outcome {
                Ok((state, changed)) => results.push(json!({
                    "provider":provider.id,
                    "path":path,
                    "state":state,
                    "changed":changed,
                })),
                Err(error) => errors.push(format!("{}: {error:#}", provider.id)),
            }
        }
    }

    let skipped = if plan.action == Action::Install && plan.providers.is_empty() {
        PROVIDERS
            .iter()
            .filter(|provider| !binary_on_path(provider.binary, context.path.as_deref()))
            .map(|provider| provider.id)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let mut value = json!({
        "action":action_name(plan.action),
        "helper":helper,
        "providers":results,
        "skipped":skipped,
        "errors":errors,
    });
    if plan.action != Action::Uninstall {
        value["activation"] = Value::String(ACTIVATION_NOTE.into());
    }
    RunResult { failed: !errors.is_empty(), value }
}

fn action_name(action: Action) -> &'static str {
    match action {
        Action::Install => "install",
        Action::Uninstall => "uninstall",
        Action::Status => "status",
    }
}

fn select_providers(plan: &Plan, context: &Context) -> anyhow::Result<Vec<Provider>> {
    if plan.providers.is_empty() {
        return Ok(match plan.action {
            Action::Install => PROVIDERS
                .iter()
                .copied()
                .filter(|provider| binary_on_path(provider.binary, context.path.as_deref()))
                .collect(),
            Action::Uninstall | Action::Status => PROVIDERS.to_vec(),
        });
    }
    let mut selected = Vec::new();
    let mut seen = BTreeSet::new();
    for requested in &plan.providers {
        let requested = match requested.as_str() {
            "claude-code" => "claude",
            "hermes" => "hermes-agent",
            value => value,
        };
        let provider = PROVIDERS
            .iter()
            .copied()
            .find(|provider| provider.id == requested)
            .with_context(|| format!("unsupported coding-agent provider {requested:?}"))?;
        if seen.insert(provider.id) {
            selected.push(provider);
        }
    }
    Ok(selected)
}

fn run_hermes_provider(
    action: Action,
    provider: Provider,
    path: &Path,
    context: &Context,
) -> anyhow::Result<(&'static str, bool)> {
    match action {
        Action::Install => {
            let (_, files_changed) = install_provider(provider, path)?;
            let legacy_changed = migrate_hermes_cmux_irc_tee(path)?;
            let enabled = hermes_plugin_enabled(context)?;
            if !enabled {
                set_hermes_plugin_enabled(context, true)?;
            }
            Ok(("installed", files_changed || legacy_changed || !enabled))
        }
        Action::Uninstall => {
            let enabled = hermes_plugin_enabled(context)?;
            if enabled {
                set_hermes_plugin_enabled(context, false)?;
            }
            let (_, files_changed) = uninstall_provider(provider, path)?;
            Ok(("absent", files_changed || enabled))
        }
        Action::Status => {
            let (files, _) = provider_status(provider, path)?;
            if files == "absent" {
                return Ok(("absent", false));
            }
            let enabled = hermes_plugin_enabled(context)?;
            Ok((if files == "installed" && enabled { "installed" } else { "partial" }, false))
        }
    }
}

fn migrate_hermes_cmux_irc_tee(journal_path: &Path) -> anyhow::Result<bool> {
    let plugins = journal_path.parent().context("Hermes journal plugin has no plugin root")?;
    let path = plugins.join("cmux-irc/__init__.py");
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
    };
    let text = String::from_utf8(bytes).context("Hermes cmux-irc plugin is not UTF-8")?;
    if !text.contains("cmux-tui-cmux-irc") {
        return Ok(false);
    }
    anyhow::ensure!(
        text.contains("Generated by cmux-irc"),
        "refusing to migrate an unowned Hermes cmux-irc plugin"
    );
    let migrated = text.replace("cmux-tui-cmux-irc", "cmux-irc");
    atomic_write(&path, migrated.as_bytes(), Some(0o600))?;
    Ok(true)
}

#[cfg(windows)]
struct HermesWindowsJob {
    handle: HANDLE,
}

#[cfg(windows)]
impl HermesWindowsJob {
    fn assign_and_resume(child: &std::process::Child) -> io::Result<Self> {
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self { handle };
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let information_size =
            u32::try_from(std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                .expect("Windows job information fits in u32");
        if unsafe {
            SetInformationJobObject(
                job.handle,
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                information_size,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, child.id()) };
        if process.is_null() {
            return Err(io::Error::last_os_error());
        }
        let assigned = unsafe { AssignProcessToJobObject(job.handle, process) };
        let assign_error = (assigned == 0).then(io::Error::last_os_error);
        unsafe {
            CloseHandle(process);
        }
        if let Some(error) = assign_error {
            return Err(error);
        }
        resume_hermes_child(child)?;
        Ok(job)
    }

    fn terminate(&self) {
        unsafe {
            TerminateJobObject(self.handle, 1);
        }
    }
}

#[cfg(windows)]
impl Drop for HermesWindowsJob {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

#[cfg(windows)]
fn resume_hermes_child(child: &std::process::Child) -> io::Result<()> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let result = (|| {
        let mut entry = THREADENTRY32 {
            dwSize: u32::try_from(std::mem::size_of::<THREADENTRY32>())
                .expect("Windows thread entry size fits in u32"),
            ..THREADENTRY32::default()
        };
        if unsafe { Thread32First(snapshot, &mut entry) } == 0 {
            return Err(io::Error::last_os_error());
        }
        loop {
            if entry.th32OwnerProcessID == child.id() {
                let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if thread.is_null() {
                    return Err(io::Error::last_os_error());
                }
                let resumed = unsafe { ResumeThread(thread) };
                unsafe {
                    CloseHandle(thread);
                }
                if resumed == u32::MAX {
                    return Err(io::Error::last_os_error());
                }
                return Ok(());
            }
            if unsafe { Thread32Next(snapshot, &mut entry) } == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "Hermes child thread not found",
                ));
            }
        }
    })();
    unsafe {
        CloseHandle(snapshot);
    }
    result
}

#[cfg(unix)]
fn read_hermes_output(mut pipe: impl Read + AsRawFd, deadline: Instant) -> io::Result<Vec<u8>> {
    let fd = pipe.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => return Ok(bytes),
            Ok(count) => {
                bytes.extend_from_slice(&chunk[..count]);
                if bytes.len() as u64 > HERMES_COMMAND_OUTPUT_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Hermes output exceeds 4 MiB",
                    ));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Hermes output pipe did not close before the command deadline",
                    ));
                }
                let timeout_ms =
                    remaining.as_millis().max(1).min(libc::c_int::MAX as u128) as libc::c_int;
                let mut descriptor =
                    libc::pollfd { fd, events: libc::POLLIN | libc::POLLHUP, revents: 0 };
                let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
                if ready < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::Interrupted {
                        return Err(error);
                    }
                } else if ready == 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Hermes output pipe did not close before the command deadline",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
    }
}

#[cfg(not(unix))]
fn read_hermes_output(mut pipe: impl Read, _deadline: Instant) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    pipe.by_ref().take(HERMES_COMMAND_OUTPUT_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > HERMES_COMMAND_OUTPUT_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Hermes output exceeds 4 MiB"));
    }
    Ok(bytes)
}

fn run_hermes_command(binary: &Path, args: &[&str]) -> anyhow::Result<Output> {
    run_hermes_command_with_timeout(binary, args, HERMES_COMMAND_TIMEOUT)
}

type HermesOutputReader = std::thread::JoinHandle<io::Result<Vec<u8>>>;

#[cfg(unix)]
fn cleanup_hermes_start_failure(
    child: &mut Child,
    tree: &mut UnixProcessScope,
    child_exit: &mut Option<UnixChildExitSignal>,
    reader: Option<HermesOutputReader>,
) {
    tree.terminate();
    let _ = child.kill();
    if let Some(child_exit) = child_exit.take() {
        child_exit.finish();
    }
    let _ = child.wait();
    if let Some(reader) = reader {
        let _ = reader.join();
    }
}

#[cfg(windows)]
fn cleanup_hermes_start_failure(
    child: &mut Child,
    job: &HermesWindowsJob,
    reader: Option<HermesOutputReader>,
) {
    job.terminate();
    let _ = child.kill();
    let _ = child.wait();
    if let Some(reader) = reader {
        let _ = reader.join();
    }
}

fn run_hermes_command_with_timeout(
    binary: &Path,
    args: &[&str],
    timeout: Duration,
) -> anyhow::Result<Output> {
    let deadline = Instant::now() + timeout;
    #[cfg(unix)]
    let mut tree = UnixProcessScope::prepare().context("prepare Hermes process scope")?;
    #[cfg(unix)]
    let mut command = UnixProcessScope::suspended_command(binary);
    #[cfg(not(unix))]
    let mut command = Command::new(binary);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    #[cfg(windows)]
    command.creation_flags(CREATE_SUSPENDED);
    #[cfg(unix)]
    tree.configure(&mut command);
    let mut child = command.spawn().with_context(|| format!("run {}", binary.display()))?;
    #[cfg(unix)]
    if let Err(error) = tree.bind(child.id()) {
        tree.terminate_until(deadline);
        let _ = child.kill();
        let _ = child.wait();
        return Err(error).context("track Hermes process scope");
    }
    #[cfg(unix)]
    let mut child_exit = match UnixChildExitSignal::observe(child.id()) {
        Ok(child_exit) => Some(child_exit),
        Err(error) => {
            tree.terminate_until(deadline);
            let _ = child.kill();
            let _ = child.wait();
            return Err(error).context("observe Hermes process exit");
        }
    };
    #[cfg(windows)]
    let job = match HermesWindowsJob::assign_and_resume(&child) {
        Ok(job) => job,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error).context("isolate Hermes process tree");
        }
    };
    let stdout_pipe = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            #[cfg(unix)]
            cleanup_hermes_start_failure(&mut child, &mut tree, &mut child_exit, None);
            #[cfg(windows)]
            cleanup_hermes_start_failure(&mut child, &job, None);
            anyhow::bail!("Hermes stdout pipe is unavailable");
        }
    };
    let stderr_pipe = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            #[cfg(unix)]
            cleanup_hermes_start_failure(&mut child, &mut tree, &mut child_exit, None);
            #[cfg(windows)]
            cleanup_hermes_start_failure(&mut child, &job, None);
            anyhow::bail!("Hermes stderr pipe is unavailable");
        }
    };
    let stdout = match std::thread::Builder::new()
        .name("hermes-command-stdout".into())
        .spawn(move || read_hermes_output(stdout_pipe, deadline))
    {
        Ok(stdout) => stdout,
        Err(error) => {
            #[cfg(unix)]
            cleanup_hermes_start_failure(&mut child, &mut tree, &mut child_exit, None);
            #[cfg(windows)]
            cleanup_hermes_start_failure(&mut child, &job, None);
            return Err(error).context("start Hermes stdout reader");
        }
    };
    let stderr = match std::thread::Builder::new()
        .name("hermes-command-stderr".into())
        .spawn(move || read_hermes_output(stderr_pipe, deadline))
    {
        Ok(stderr) => stderr,
        Err(error) => {
            #[cfg(unix)]
            cleanup_hermes_start_failure(&mut child, &mut tree, &mut child_exit, Some(stdout));
            #[cfg(windows)]
            cleanup_hermes_start_failure(&mut child, &job, Some(stdout));
            return Err(error).context("start Hermes stderr reader");
        }
    };
    #[cfg(unix)]
    let status = match child_exit.as_ref().expect("Unix child exit observer").wait_until(deadline) {
        Ok(true) => {
            tree.terminate_until(deadline);
            child_exit.take().expect("Unix child exit observer").finish();
            Some(child.wait()?)
        }
        Ok(false) => {
            tree.terminate_until(deadline);
            None
        }
        Err(error) => {
            tree.terminate_until(deadline);
            let _ = child.kill();
            child_exit.take().expect("Unix child exit observer").finish();
            let _ = child.wait();
            return Err(error).context("wait for Hermes process exit");
        }
    };
    #[cfg(not(unix))]
    let status = {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { None } else { child.wait_timeout(remaining)? }
    };
    #[cfg(windows)]
    job.terminate();
    let timed_out = status.is_none();
    if timed_out {
        let _ = child.kill();
        // Reaping must not extend the command's absolute deadline. The
        // process scope or Windows job has already issued exact termination;
        // a detached reaper owns the blocking wait.
        let _ = std::thread::Builder::new().name("hermes-command-reaper".into()).spawn(move || {
            #[cfg(unix)]
            child_exit.take().expect("Unix child exit observer").finish();
            let _ = child.wait();
        });
    }
    let stdout = stdout.join().map_err(|_| anyhow::anyhow!("Hermes stdout reader panicked"))?;
    let stderr = stderr.join().map_err(|_| anyhow::anyhow!("Hermes stderr reader panicked"))?;
    if timed_out {
        anyhow::bail!("Hermes command timed out after {} ms", timeout.as_millis());
    }
    let status = status.expect("timed-out Hermes command returned above");
    let stdout = stdout?;
    let stderr = stderr?;
    anyhow::ensure!(Instant::now() <= deadline, "Hermes command output timed out");
    Ok(Output { status, stdout, stderr })
}

fn hermes_plugin_enabled(context: &Context) -> anyhow::Result<bool> {
    let binary = find_executable("hermes", context.path.as_deref())
        .context("Hermes Agent executable is unavailable")?;
    let output = run_hermes_command(
        &binary,
        &["plugins", "list", "--enabled", "--user", "--no-bundled", "--json"],
    )?;
    anyhow::ensure!(
        output.status.success(),
        "Hermes plugin status failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let plugins: Value = serde_json::from_slice(&output.stdout).context("decode Hermes plugins")?;
    Ok(plugins.as_array().is_some_and(|plugins| {
        plugins
            .iter()
            .any(|plugin| plugin.get("name").and_then(Value::as_str) == Some("cmux-tui-journal"))
    }))
}

fn set_hermes_plugin_enabled(context: &Context, enabled: bool) -> anyhow::Result<()> {
    let binary = find_executable("hermes", context.path.as_deref())
        .context("Hermes Agent executable is unavailable")?;
    let action = if enabled { "enable" } else { "disable" };
    let output = run_hermes_command(&binary, &["plugins", action, "cmux-tui-journal"])
        .with_context(|| format!("run {} plugins {action}", binary.display()))?;
    anyhow::ensure!(
        output.status.success(),
        "Hermes plugin {action} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

fn locate_helper_source(current_exe: Option<&Path>) -> Option<PathBuf> {
    current_exe
        .and_then(Path::parent)
        .map(|parent| parent.join("cmux-tui-hook"))
        .filter(|path| is_executable_file(path))
        .or_else(|| find_executable("cmux-tui-hook", std::env::var_os("PATH").as_deref()))
}

fn binary_on_path(binary: &str, path: Option<&std::ffi::OsStr>) -> bool {
    find_executable(binary, path).is_some()
}

fn find_executable(binary: &str, path: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    std::env::split_paths(path?)
        .map(|directory| directory.join(binary))
        .find(|candidate| is_executable_file(candidate))
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn install_helper(source: &Path, destination: &Path) -> anyhow::Result<()> {
    let metadata = fs::metadata(source)
        .with_context(|| format!("inspect helper source {}", source.display()))?;
    anyhow::ensure!(metadata.is_file(), "helper source is not a regular file");
    anyhow::ensure!(
        metadata.len() > 0 && metadata.len() <= MAX_HELPER_BYTES,
        "helper source size is invalid"
    );
    let bytes = fs::read(source).with_context(|| format!("read {}", source.display()))?;
    ensure_replaceable_target(destination)?;
    if fs::read(destination).ok().as_deref() == Some(bytes.as_slice()) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            if fs::metadata(destination)?.permissions().mode() & 0o111 != 0 {
                return Ok(());
            }
        }
        #[cfg(not(unix))]
        return Ok(());
    }
    atomic_write(destination, &bytes, Some(0o755))
}

fn install_provider(provider: Provider, path: &Path) -> anyhow::Result<(&'static str, bool)> {
    match provider.format {
        Format::Nested { timeout, .. } | Format::Flat { timeout } => {
            ensure_replaceable_target(path)?;
            let nested = matches!(provider.format, Format::Nested { .. });
            let mut root = read_json_object(path)?;
            let before = serde_json::to_vec(&root)?;
            rewrite_json_hooks(&mut root, provider, nested, timeout, true)?;
            if provider.id == "cursor" && !root.contains_key("version") {
                root.insert("version".into(), Value::from(1));
            }
            let after = serde_json::to_vec(&root)?;
            if before == after && path.exists() {
                return Ok(("installed", false));
            }
            let mut encoded = serde_json::to_vec_pretty(&Value::Object(root))?;
            encoded.push(b'\n');
            atomic_write(path, &encoded, Some(0o600))?;
            Ok(("installed", true))
        }
        Format::Plugin { template } => {
            ensure_replaceable_target(path)?;
            if let Ok(existing) = fs::read(path) {
                anyhow::ensure!(
                    is_owned_plugin(&existing),
                    "{} exists and is not owned by cmux-tui",
                    path.display()
                );
                if existing == template.as_bytes() {
                    return Ok(("installed", false));
                }
            }
            atomic_write(path, template.as_bytes(), Some(0o600))?;
            Ok(("installed", true))
        }
        Format::HermesPlugin { module, manifest } => {
            ensure_owned_plugin_directory(path)?;
            let module_path = path.join("__init__.py");
            let manifest_path = path.join("plugin.yaml");
            let before_module = fs::read(&module_path).ok();
            let before_manifest = fs::read(&manifest_path).ok();
            for existing in [&module_path, &manifest_path] {
                if let Ok(content) = fs::read(existing) {
                    anyhow::ensure!(
                        is_owned_plugin(&content),
                        "{} exists and is not owned by cmux-tui",
                        existing.display()
                    );
                }
            }
            atomic_write(&module_path, module.as_bytes(), Some(0o600))?;
            atomic_write(&manifest_path, manifest.as_bytes(), Some(0o600))?;
            let changed = before_module.as_deref() != Some(module.as_bytes())
                || before_manifest.as_deref() != Some(manifest.as_bytes());
            Ok(("installed", changed))
        }
    }
}

fn uninstall_provider(provider: Provider, path: &Path) -> anyhow::Result<(&'static str, bool)> {
    match provider.format {
        Format::Nested { .. } | Format::Flat { .. } => {
            ensure_replaceable_target(path)?;
            if !path.exists() {
                return Ok(("absent", false));
            }
            let nested = matches!(provider.format, Format::Nested { .. });
            let mut root = read_json_object(path)?;
            let before = serde_json::to_vec(&root)?;
            rewrite_json_hooks(&mut root, provider, nested, 0, false)?;
            let after = serde_json::to_vec(&root)?;
            if before == after {
                return Ok(("absent", false));
            }
            let mut encoded = serde_json::to_vec_pretty(&Value::Object(root))?;
            encoded.push(b'\n');
            atomic_write(path, &encoded, Some(0o600))?;
            Ok(("absent", true))
        }
        Format::Plugin { .. } => {
            ensure_replaceable_target(path)?;
            let Ok(existing) = fs::read(path) else {
                return Ok(("absent", false));
            };
            anyhow::ensure!(
                is_owned_plugin(&existing),
                "{} exists and is not owned by cmux-tui",
                path.display()
            );
            fs::remove_file(path).with_context(|| format!("remove {}", path.display()))?;
            Ok(("absent", true))
        }
        Format::HermesPlugin { .. } => {
            if !path.exists() {
                return Ok(("absent", false));
            }
            remove_owned_plugin_directory(path)?;
            Ok(("absent", true))
        }
    }
}

fn provider_status(provider: Provider, path: &Path) -> anyhow::Result<(&'static str, bool)> {
    let state = match provider.format {
        Format::Nested { .. } | Format::Flat { .. } => {
            if !path.exists() {
                "absent"
            } else {
                let root = read_json_object(path)?;
                json_hook_state(&root, provider)
            }
        }
        Format::Plugin { .. } => match fs::read(path) {
            Ok(content) if is_current_plugin(&content) => "installed",
            Ok(content) if is_owned_plugin(&content) => "partial",
            _ => "absent",
        },
        Format::HermesPlugin { .. } => {
            let module = fs::read(path.join("__init__.py"));
            let manifest = fs::read(path.join("plugin.yaml"));
            match (module, manifest) {
                (Ok(module), Ok(manifest))
                    if [module.as_slice(), manifest.as_slice()]
                        .into_iter()
                        .all(is_current_plugin) =>
                {
                    "installed"
                }
                (Ok(module), Ok(manifest))
                    if is_owned_plugin(&module) || is_owned_plugin(&manifest) =>
                {
                    "partial"
                }
                _ => "absent",
            }
        }
    };
    Ok((state, false))
}

fn read_json_object(path: &Path) -> anyhow::Result<Map<String, Value>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
    };
    anyhow::ensure!(bytes.len() as u64 <= MAX_CONFIG_BYTES, "configuration exceeds 16 MiB");
    let value: Value = serde_json::from_slice(&bytes)
        .with_context(|| format!("{} is not valid JSON", path.display()))?;
    value
        .as_object()
        .cloned()
        .with_context(|| format!("{} must contain a JSON object", path.display()))
}

fn rewrite_json_hooks(
    root: &mut Map<String, Value>,
    provider: Provider,
    nested: bool,
    timeout: u64,
    install: bool,
) -> anyhow::Result<()> {
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().context("agent hooks field must be a JSON object")?;
    for entries in hooks.values_mut() {
        if nested {
            rewrite_nested_entries(entries)?;
        } else {
            rewrite_flat_entries(entries)?;
        }
    }
    hooks.retain(|_, entries| entries.as_array().is_none_or(|entries| !entries.is_empty()));
    if !install {
        return Ok(());
    }
    for event in provider.events {
        let command = hook_command(provider.id, event);
        let entry = if nested {
            let command = if matches!(provider.format, Format::Nested { asynchronous: true, .. }) {
                json!({"type":"command","command":command,"timeout":timeout,"async":true})
            } else {
                json!({"type":"command","command":command,"timeout":timeout})
            };
            json!({"hooks":[command]})
        } else {
            json!({"command":command,"timeout":timeout})
        };
        hooks.entry(*event).or_insert_with(|| json!([]));
        hooks
            .get_mut(*event)
            .and_then(Value::as_array_mut)
            .with_context(|| format!("hook event {event:?} must be an array"))?
            .push(entry);
    }
    Ok(())
}

fn rewrite_nested_entries(value: &mut Value) -> anyhow::Result<()> {
    let Some(groups) = value.as_array_mut() else {
        return Ok(());
    };
    let mut rewritten = Vec::with_capacity(groups.len());
    for mut group in std::mem::take(groups) {
        let Some(group_object) = group.as_object_mut() else {
            rewritten.push(group);
            continue;
        };
        let Some(commands) = group_object.get_mut("hooks").and_then(Value::as_array_mut) else {
            rewritten.push(group);
            continue;
        };
        rewrite_command_entries(commands);
        if !commands.is_empty() {
            rewritten.push(group);
        }
    }
    *groups = rewritten;
    Ok(())
}

fn rewrite_flat_entries(value: &mut Value) -> anyhow::Result<()> {
    if let Some(entries) = value.as_array_mut() {
        rewrite_command_entries(entries);
    }
    Ok(())
}

fn rewrite_command_entries(entries: &mut Vec<Value>) {
    let mut rewritten = Vec::with_capacity(entries.len());
    for mut entry in std::mem::take(entries) {
        let command = entry.get("command").and_then(Value::as_str).map(str::to_owned);
        match command.as_deref() {
            Some(command) if is_owned_command(command) => {}
            Some(command) if command.contains("cmux-tui-cmux-irc") => {
                if let Some(object) = entry.as_object_mut() {
                    object.insert(
                        "command".into(),
                        Value::String(command.replace("cmux-tui-cmux-irc", "cmux-irc")),
                    );
                }
                rewritten.push(entry);
            }
            _ => rewritten.push(entry),
        }
    }
    *entries = rewritten;
}

fn is_owned_command(command: &str) -> bool {
    command.contains(COMMAND_MARKER)
        || command.contains("cmux-tui-agent-hook")
        || (command.contains("cmux-tui-hook") && command.contains("--source"))
}

fn is_owned_plugin(content: &[u8]) -> bool {
    [PLUGIN_MARKER.as_bytes(), b"cmux-tui-agent-hook".as_slice(), b"cmux-tui-cmux-irc".as_slice()]
        .into_iter()
        .any(|needle| content.windows(needle.len()).any(|window| window == needle))
}

fn is_current_plugin(content: &[u8]) -> bool {
    content.windows(PLUGIN_MARKER.len()).any(|window| window == PLUGIN_MARKER.as_bytes())
}

fn ensure_owned_plugin_directory(path: &Path) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    anyhow::ensure!(
        !metadata.file_type().is_symlink() && metadata.is_dir(),
        "refusing to replace non-directory {}",
        path.display()
    );
    for entry in fs::read_dir(path).with_context(|| format!("inspect {}", path.display()))? {
        let entry = entry?;
        let name = entry.file_name();
        anyhow::ensure!(
            matches!(name.to_str(), Some("__init__.py" | "plugin.yaml" | "__pycache__")),
            "{} contains an unowned entry",
            path.display()
        );
    }
    Ok(())
}

fn remove_owned_plugin_directory(path: &Path) -> anyhow::Result<()> {
    ensure_owned_plugin_directory(path)?;
    for file in [path.join("__init__.py"), path.join("plugin.yaml")] {
        let content = match fs::read(&file) {
            Ok(content) => content,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error).with_context(|| format!("read {}", file.display()));
            }
        };
        anyhow::ensure!(is_owned_plugin(&content), "{} is not owned by cmux-tui", file.display());
        fs::remove_file(&file).with_context(|| format!("remove {}", file.display()))?;
    }
    let cache = path.join("__pycache__");
    if cache.exists() {
        let metadata = fs::symlink_metadata(&cache)?;
        anyhow::ensure!(
            !metadata.file_type().is_symlink() && metadata.is_dir(),
            "{} is not an owned cache directory",
            cache.display()
        );
        for entry in fs::read_dir(&cache)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().context("Hermes cache contains a non-UTF-8 entry")?;
            let metadata = entry.metadata()?;
            anyhow::ensure!(
                metadata.is_file() && name.starts_with("__init__.") && name.ends_with(".pyc"),
                "{} contains an unowned entry",
                cache.display()
            );
            fs::remove_file(entry.path())?;
        }
        fs::remove_dir(&cache)?;
    }
    fs::remove_dir(path).with_context(|| format!("remove {}", path.display()))?;
    if let Some(parent) = path.parent() {
        fs::File::open(parent).and_then(|directory| directory.sync_all())?;
    }
    Ok(())
}

fn json_hook_state(root: &Map<String, Value>, provider: Provider) -> &'static str {
    let Some(hooks) = root.get("hooks").and_then(Value::as_object) else {
        return "absent";
    };
    let owned = |value: &Value| {
        visit_strings(value, &mut |value| {
            value.contains(COMMAND_MARKER)
                || value.contains("cmux-tui-agent-hook")
                || value.contains("cmux-tui-cmux-irc")
        })
    };
    let installed =
        provider.events.iter().filter(|event| hooks.get(**event).is_some_and(&owned)).count();
    if installed == provider.events.len() {
        "installed"
    } else if installed == 0 {
        "absent"
    } else {
        "partial"
    }
}

fn visit_strings(value: &Value, predicate: &mut impl FnMut(&str) -> bool) -> bool {
    match value {
        Value::String(value) => predicate(value),
        Value::Array(values) => values.iter().any(|value| visit_strings(value, predicate)),
        Value::Object(values) => values.values().any(|value| visit_strings(value, predicate)),
        _ => false,
    }
}

fn hook_command(provider: &str, event: &str) -> String {
    format!(
        "\"${{CMUX_TUI_HOOK:-:}}\" {} {} 2>/dev/null||:;echo {{}};#{COMMAND_MARKER}",
        shell_quote(provider),
        shell_quote(event),
    )
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn atomic_write(path: &Path, bytes: &[u8], mode: Option<u32>) -> anyhow::Result<()> {
    ensure_replaceable_target(path)?;
    let parent = path.parent().context("installation path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    let mut random = [0_u8; 8];
    getrandom::fill(&mut random).context("allocate atomic file identity")?;
    let suffix = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let name = path.file_name().and_then(|name| name.to_str()).context("invalid file name")?;
    let temporary = parent.join(format!(".{name}.cmux-tui-{suffix}"));
    let result = (|| -> anyhow::Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(mode);
        }
        let mut file =
            options.open(&temporary).with_context(|| format!("create {}", temporary.display()))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt as _;
            fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))?;
        }
        fs::rename(&temporary, path).with_context(|| format!("replace {}", path.display()))?;
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .with_context(|| format!("sync {}", parent.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn ensure_replaceable_target(path: &Path) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    anyhow::ensure!(
        !metadata.file_type().is_symlink(),
        "refusing to replace symlink {}",
        path.display()
    );
    anyhow::ensure!(metadata.is_file(), "refusing to replace non-file {}", path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(root: &Path) -> Context {
        let home = root.join("home");
        let data_home = root.join("data");
        fs::create_dir_all(&home).unwrap();
        let helper = root.join("cmux-tui-hook");
        atomic_write(&helper, b"#!/bin/sh\nexit 0\n", Some(0o755)).unwrap();
        Context {
            home,
            data_home,
            helper_source: Some(helper),
            path: None,
            environment: BTreeMap::new(),
        }
    }

    #[cfg(unix)]
    #[test]
    fn hermes_command_obeys_its_execution_deadline() {
        let started = Instant::now();
        let error = run_hermes_command_with_timeout(
            Path::new("/bin/sh"),
            &["-c", "sleep 30"],
            Duration::from_millis(100),
        )
        .unwrap_err();
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[cfg(not(unix))]
    #[test]
    fn public_hook_operations_are_rejected_on_unsupported_platforms() {
        let result = run(&Plan { action: Action::Status, providers: Vec::new() });
        assert!(result.failed);
        assert!(result.value["errors"][0].as_str().unwrap().contains("unsupported"));
        assert!(runtime_helper_path().is_none());
    }

    #[test]
    fn nested_install_is_idempotent_and_migrates_the_legacy_tee() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config = context.home.join(".codex/hooks.json");
        atomic_write(
            &config,
            br#"{"custom":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]},{"hooks":[{"type":"command","command":"'/tmp/cmux-tui-cmux-irc' hook emit --adapter codex --native-event Stop"}]}]}}"#,
            Some(0o600),
        )
        .unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let first = run_with_context(&plan, &context);
        assert!(!first.failed, "{}", first.value);
        assert_eq!(first.value["activation"], ACTIVATION_NOTE);
        let installed_once = fs::read(&config).unwrap();
        let second = run_with_context(&plan, &context);
        assert!(!second.failed, "{}", second.value);
        assert_eq!(fs::read(&config).unwrap(), installed_once);

        let text = String::from_utf8(installed_once).unwrap();
        assert!(text.contains("custom-hook"));
        assert!(text.contains("/tmp/cmux-irc"));
        assert!(!text.contains("cmux-tui-cmux-irc"));
        assert_eq!(text.matches(COMMAND_MARKER).count(), CODEX_EVENTS.len());
        assert!(!text.contains("CMUX_TUI_SOCKET"));
        assert!(text.contains("CMUX_TUI_HOOK"));
        assert!(!text.contains(&context.installed_helper().to_string_lossy().to_string()));
        let parsed: Value = serde_json::from_str(&text).unwrap();
        assert!(visit_strings(&parsed, &mut |value| value.contains("echo {};")));

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(&config).unwrap();
        assert!(text.contains("custom-hook"));
        assert!(text.contains("/tmp/cmux-irc"));
        assert!(!text.contains(COMMAND_MARKER));
    }

    #[test]
    fn claude_commands_are_async_without_weakening_other_provider_receipts() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install =
            Plan { action: Action::Install, providers: vec!["codex".into(), "claude".into()] };
        let result = run_with_context(&install, &context);
        assert!(!result.failed, "{}", result.value);

        for (provider, config, expected_async) in [
            ("codex", context.home.join(".codex/hooks.json"), None),
            ("claude", context.home.join(".claude/settings.json"), Some(true)),
        ] {
            let root: Value = serde_json::from_slice(&fs::read(config).unwrap()).unwrap();
            let hook = &root["hooks"]["Stop"][0]["hooks"][0];
            assert_eq!(hook.get("async").and_then(Value::as_bool), expected_async, "{provider}");
            assert_eq!(
                hook.get("timeout").and_then(Value::as_u64),
                Some(COMMAND_HOOK_TIMEOUT_SECONDS),
                "{provider} outer timeout must exceed the journal admission window"
            );
        }
    }

    #[test]
    fn every_command_provider_outlives_the_helper_receipt_window() {
        for provider in PROVIDERS {
            match provider.format {
                Format::Nested { timeout, .. } | Format::Flat { timeout }
                    if provider.id == "gemini" =>
                {
                    assert_eq!(timeout, GEMINI_HOOK_TIMEOUT_MILLISECONDS);
                }
                Format::Nested { timeout, .. } | Format::Flat { timeout } => {
                    assert_eq!(timeout, COMMAND_HOOK_TIMEOUT_SECONDS);
                }
                Format::Plugin { .. } | Format::HermesPlugin { .. } => {}
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn command_hook_noops_without_session_helper_and_uses_short_positional_arguments() {
        use std::process::Command;

        let root = tempfile::tempdir().unwrap();
        let mut context = context(root.path());
        let capture = root.path().join("capture");
        let helper_source = context.helper_source.as_ref().unwrap();
        atomic_write(
            helper_source,
            b"#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$CAPTURE\"\n",
            Some(0o755),
        )
        .unwrap();
        context.helper_source = Some(helper_source.clone());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&install, &context);
        assert!(!result.failed, "{}", result.value);
        let root: Value =
            serde_json::from_slice(&fs::read(context.home.join(".codex/hooks.json")).unwrap())
                .unwrap();
        let command = root["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(command.len() <= 90, "hook command is {} bytes: {command}", command.len());
        assert!(!command.contains("CMUX_TUI_SOCKET"));
        assert!(!hook_command("claude", "Stop").contains("GROK_HOOK_EVENT"));

        let output = Command::new("/bin/sh")
            .args(["-c", command])
            .env("CMUX_TUI_SOCKET", "/tmp/cmux-test.sock")
            .env_remove("CMUX_TUI_HOOK")
            .env("CAPTURE", &capture)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"{}\n");
        assert!(!capture.exists(), "missing helper identity must be a process-free no-op");

        let output = Command::new("/bin/sh")
            .args(["-c", command])
            .env_remove("CMUX_TUI_SOCKET")
            .env("CMUX_TUI_HOOK", context.installed_helper())
            .env("CAPTURE", &capture)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"{}\n");
        assert_eq!(fs::read_to_string(capture).unwrap(), "codex Stop\n");
    }

    #[test]
    fn every_command_hook_fits_in_one_hundred_bytes() {
        for provider in PROVIDERS {
            for event in provider.events {
                let command = hook_command(provider.id, event);
                assert!(
                    command.len() <= 100,
                    "{} {event} hook command is {} bytes: {command}",
                    provider.id,
                    command.len()
                );
            }
        }
    }

    #[test]
    fn flat_install_preserves_unrelated_cursor_hooks() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config = context.home.join(".cursor/hooks.json");
        atomic_write(
            &config,
            br#"{"version":1,"hooks":{"stop":[{"command":"custom-hook"},{"command":"'$HOME/.cargo/bin/cmux-tui-agent-hook' cursor stop"}]}}"#,
            Some(0o600),
        )
        .unwrap();
        let cursor = PROVIDERS.iter().copied().find(|provider| provider.id == "cursor").unwrap();
        assert_eq!(provider_status(cursor, &config).unwrap().0, "partial");
        let plan = Plan { action: Action::Install, providers: vec!["cursor".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(&config).unwrap();
        assert!(text.contains("custom-hook"));
        assert!(!text.contains("cmux-tui-agent-hook"));
        assert_eq!(text.matches(COMMAND_MARKER).count(), CURSOR_EVENTS.len());
        assert_eq!(provider_status(cursor, &config).unwrap().0, "installed");
    }

    #[test]
    fn grok_compatibility_deduplication_does_not_expand_hook_commands() {
        for provider in ["claude", "cursor"] {
            let command = hook_command(provider, "Stop");
            assert!(!command.contains("GROK_HOOK_EVENT"), "{provider}: {command}");
        }
        let grok = hook_command("grok", "Stop");
        assert!(!grok.contains("GROK_HOOK_EVENT"), "{grok}");
    }

    #[test]
    fn plugin_installs_are_owned_idempotent_and_reversible() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan {
            action: Action::Install,
            providers: vec!["opencode".into(), "amp".into(), "pi".into()],
        };
        let first = run_with_context(&install, &context);
        assert!(!first.failed, "{}", first.value);
        let snapshots = [
            context.home.join(".config/opencode/plugins/cmux-tui-journal.js"),
            context.home.join(".config/amp/plugins/cmux-tui-journal.ts"),
            context.home.join(".pi/agent/extensions/cmux-tui-journal.ts"),
        ]
        .map(|path| (path.clone(), fs::read(path).unwrap()));
        let second = run_with_context(&install, &context);
        assert!(!second.failed, "{}", second.value);
        for (path, bytes) in &snapshots {
            assert_eq!(&fs::read(path).unwrap(), bytes);
            assert!(String::from_utf8_lossy(bytes).contains(PLUGIN_MARKER));
            assert!(String::from_utf8_lossy(bytes).contains("CMUX_TUI_HOOK"));
            assert!(
                !String::from_utf8_lossy(bytes)
                    .contains(&context.installed_helper().to_string_lossy().to_string())
            );
        }

        let uninstall = Plan { action: Action::Uninstall, providers: install.providers };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        assert!(snapshots.iter().all(|(path, _)| !path.exists()));
    }

    #[test]
    fn plugin_install_migrates_the_owned_legacy_helper() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let path = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
        atomic_write(&path, b"const binary = '/tmp/cmux-tui-agent-hook';\n", Some(0o600)).unwrap();
        let amp = PROVIDERS.iter().copied().find(|provider| provider.id == "amp").unwrap();
        assert_eq!(provider_status(amp, &path).unwrap().0, "partial");
        let plan = Plan { action: Action::Install, providers: vec!["amp".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(path).unwrap();
        assert!(text.contains(PLUGIN_MARKER));
        assert!(!text.contains("cmux-tui-agent-hook"));
        assert_eq!(
            provider_status(amp, &context.home.join(".config/amp/plugins/cmux-tui-journal.ts"))
                .unwrap()
                .0,
            "installed"
        );
    }

    #[test]
    fn hermes_plugin_files_are_owned_idempotent_and_reversible() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let hermes =
            PROVIDERS.iter().copied().find(|provider| provider.id == "hermes-agent").unwrap();
        let path = context.provider_path(hermes);
        let irc = path.parent().unwrap().join("cmux-irc/__init__.py");
        atomic_write(
            &irc,
            b"# Generated by cmux-irc. Reinstall instead of editing this file.\nBINARY = '/tmp/cmux-tui-cmux-irc'\n",
            Some(0o600),
        )
        .unwrap();
        assert_eq!(install_provider(hermes, &path).unwrap(), ("installed", true));
        assert!(migrate_hermes_cmux_irc_tee(&path).unwrap());
        assert!(!fs::read_to_string(&irc).unwrap().contains("cmux-tui-cmux-irc"));
        assert!(!migrate_hermes_cmux_irc_tee(&path).unwrap());
        assert_eq!(provider_status(hermes, &path).unwrap().0, "installed");
        assert_eq!(install_provider(hermes, &path).unwrap(), ("installed", false));
        assert_eq!(uninstall_provider(hermes, &path).unwrap(), ("absent", true));
        assert!(!path.exists());
    }

    #[test]
    fn plugin_install_refuses_to_overwrite_an_unowned_file() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let path = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
        atomic_write(&path, b"export default custom;\n", Some(0o600)).unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["amp".into()] };
        let result = run_with_context(&plan, &context);
        assert!(result.failed);
        assert_eq!(fs::read_to_string(path).unwrap(), "export default custom;\n");
    }

    #[cfg(unix)]
    #[test]
    fn installer_refuses_to_replace_a_config_symlink() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let target = root.path().join("target.json");
        atomic_write(&target, b"{}\n", Some(0o600)).unwrap();
        let path = context.home.join(".codex/hooks.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        symlink(&target, &path).unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(result.failed);
        assert_eq!(fs::read_to_string(target).unwrap(), "{}\n");
    }
}
