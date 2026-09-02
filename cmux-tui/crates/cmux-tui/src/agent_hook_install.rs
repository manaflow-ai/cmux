#[cfg(test)]
use std::cell::Cell;
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
use std::sync::{Arc, Mutex};
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
/// codex caps SessionEnd hook timeouts at 3s and warns on every session exit
/// when hooks.json asks for more (`clamping SessionEnd hook timeout to 3s`),
/// so the installer writes the cap instead of the generic 5s.
const CODEX_SESSION_END_TIMEOUT_SECONDS: u64 = 3;
const GEMINI_HOOK_TIMEOUT_MILLISECONDS: u64 = 5_000;
const HERMES_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const HERMES_COMMAND_OUTPUT_BYTES: u64 = 4 * 1024 * 1024;

#[cfg(test)]
std::thread_local! {
    static FORCE_HERMES_REAPER_SPAWN_FAILURE: Cell<bool> = const { Cell::new(false) };
}

#[cfg(test)]
fn hermes_reaper_spawn_should_fail() -> bool {
    FORCE_HERMES_REAPER_SPAWN_FAILURE.with(Cell::get)
}

#[cfg(not(test))]
fn hermes_reaper_spawn_should_fail() -> bool {
    false
}

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

    /// Whether `provider_path` came from the provider's environment override.
    /// codex canonicalizes an explicit `CODEX_HOME` but not the default
    /// `~/.codex`, and its hook trust keys embed the resolved path.
    fn provider_path_from_env_override(&self, provider: Provider) -> bool {
        provider
            .override_env
            .and_then(|name| self.environment.get(name))
            .filter(|value| !value.is_empty())
            .is_some()
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
            let from_env_override = context.provider_path_from_env_override(provider);
            let outcome = if provider.id == "hermes-agent" {
                run_hermes_provider(plan.action, provider, &path, context)
            } else {
                match plan.action {
                    Action::Install => install_provider(provider, &path, from_env_override),
                    Action::Uninstall => uninstall_provider(provider, &path, from_env_override),
                    Action::Status => provider_status(provider, &path, from_env_override),
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
            let (_, files_changed) = install_provider(provider, path, false)?;
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
            let (_, files_changed) = uninstall_provider(provider, path, false)?;
            Ok(("absent", files_changed || enabled))
        }
        Action::Status => {
            let (files, _) = provider_status(provider, path, false)?;
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

struct HermesReapState {
    child: Mutex<Option<Child>>,
    #[cfg(unix)]
    child_exit: Mutex<Option<UnixChildExitSignal>>,
}

impl HermesReapState {
    fn new(child: Child, #[cfg(unix)] child_exit: Option<UnixChildExitSignal>) -> Self {
        Self {
            child: Mutex::new(Some(child)),
            #[cfg(unix)]
            child_exit: Mutex::new(child_exit),
        }
    }

    fn reap(&self) {
        #[cfg(unix)]
        if let Some(child_exit) =
            self.child_exit.lock().expect("Hermes exit observer mutex poisoned").take()
        {
            child_exit.finish();
        }
        let child = self.child.lock().expect("Hermes reaper mutex poisoned").take();
        if let Some(mut child) = child {
            let _ = child.wait();
        }
    }

    fn handoff_reap(&self) {
        #[cfg(unix)]
        let child_exit =
            self.child_exit.lock().expect("Hermes exit observer mutex poisoned").take();
        let child = self.child.lock().expect("Hermes reaper mutex poisoned").take();

        #[cfg(unix)]
        if let Some(child_exit) = child_exit {
            // The exit observer already owns the child's PID wait path. It
            // can block in waitpid without extending this timeout caller.
            child_exit.reap();
            drop(child);
            return;
        }

        // This is only a defensive path. Unix commands install an exit
        // observer before reaching the timeout branch. On Windows, closing
        // the process handle after a nonblocking probe leaves termination to
        // the kernel without making the timeout caller wait.
        if let Some(mut child) = child {
            let _ = child.try_wait();
        }
    }
}

fn spawn_hermes_reaper(state: Arc<HermesReapState>) -> io::Result<()> {
    let reaper_state = Arc::clone(&state);
    if hermes_reaper_spawn_should_fail() {
        drop(reaper_state);
        return Err(io::Error::other("forced Hermes reaper spawn failure"));
    }
    std::thread::Builder::new()
        .name("hermes-command-reaper".into())
        .spawn(move || reaper_state.reap())
        .map(|_| ())
}

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
        // Keep normal reaping detached so it does not extend the command's
        // absolute deadline. The process scope or Windows job has already
        // issued exact termination. If the OS cannot create that thread, the
        // state below keeps ownership for a nonblocking fallback handoff.
        #[cfg(unix)]
        let reap_state = Arc::new(HermesReapState::new(child, child_exit.take()));
        #[cfg(not(unix))]
        let reap_state = Arc::new(HermesReapState::new(child));
        if spawn_hermes_reaper(Arc::clone(&reap_state)).is_err() {
            // Keep the already-running Unix observer as the owner when the
            // OS cannot create the detached reaper. The handoff is
            // nonblocking, so thread exhaustion cannot extend the deadline.
            reap_state.handoff_reap();
        }
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

fn install_provider(
    provider: Provider,
    path: &Path,
    from_env_override: bool,
) -> anyhow::Result<(&'static str, bool)> {
    match provider.format {
        Format::Nested { timeout, .. } | Format::Flat { timeout } => {
            ensure_replaceable_target(path)?;
            let nested = matches!(provider.format, Format::Nested { .. });
            let mut root = read_json_object(path)?;
            let previous_root = root.clone();
            let before = serde_json::to_vec(&root)?;
            rewrite_json_hooks(&mut root, provider, nested, timeout, true)?;
            if provider.id == "cursor" && !root.contains_key("version") {
                root.insert("version".into(), Value::from(1));
            }
            let after = serde_json::to_vec(&root)?;
            let files_changed = !(before == after && path.exists());
            // codex refuses to execute the hooks.json entries until config.toml
            // trusts each one, so installing means keeping both files in sync.
            // Preflight that edit completely BEFORE touching hooks.json: a
            // malformed or unwritable config must fail the install while
            // hooks.json stays byte-identical to its pre-install state.
            let trust = if provider.id == "codex" {
                prepare_codex_trust_state(
                    path,
                    from_env_override,
                    &root,
                    &previous_root,
                    /*install*/ true,
                )?
            } else {
                None
            };
            let previous_hooks = if files_changed { Some(snapshot_file(path)?) } else { None };
            if files_changed {
                let mut encoded = serde_json::to_vec_pretty(&Value::Object(root))?;
                encoded.push(b'\n');
                atomic_write(path, &encoded, Some(0o600))?;
            }
            let trust_changed = match &trust {
                Some(write) => {
                    commit_codex_trust_state_or_rollback(write, path, previous_hooks)?;
                    true
                }
                None => false,
            };
            Ok(("installed", files_changed || trust_changed))
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

fn uninstall_provider(
    provider: Provider,
    path: &Path,
    from_env_override: bool,
) -> anyhow::Result<(&'static str, bool)> {
    match provider.format {
        Format::Nested { .. } | Format::Flat { .. } => {
            ensure_replaceable_target(path)?;
            // Render the cleaned hooks.json without writing it yet, keeping
            // the pre-rewrite content: the trust entries of exactly the hooks
            // being removed are deleted by positional key, whatever hash a
            // codex re-review may have stored for them.
            let mut previous_root = Map::new();
            let pending_hooks = if path.exists() {
                let nested = matches!(provider.format, Format::Nested { .. });
                let mut root = read_json_object(path)?;
                previous_root = root.clone();
                let before = serde_json::to_vec(&root)?;
                rewrite_json_hooks(&mut root, provider, nested, 0, false)?;
                let after = serde_json::to_vec(&root)?;
                if before == after {
                    None
                } else {
                    let mut encoded = serde_json::to_vec_pretty(&Value::Object(root))?;
                    encoded.push(b'\n');
                    Some(encoded)
                }
            } else {
                None
            };
            // Preflight the trust-state cleanup BEFORE touching hooks.json so a
            // malformed config fails the uninstall with hooks.json intact
            // instead of removing hooks while their trust entries linger.
            let trust = if provider.id == "codex" {
                prepare_codex_trust_state(
                    path,
                    from_env_override,
                    &Map::new(),
                    &previous_root,
                    /*install*/ false,
                )?
            } else {
                None
            };
            let files_changed = pending_hooks.is_some();
            let previous_hooks = if files_changed { Some(snapshot_file(path)?) } else { None };
            if let Some(encoded) = &pending_hooks {
                atomic_write(path, encoded, Some(0o600))?;
            }
            let trust_changed = match &trust {
                Some(write) => {
                    commit_codex_trust_state_or_rollback(write, path, previous_hooks)?;
                    true
                }
                None => false,
            };
            Ok(("absent", files_changed || trust_changed))
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

fn provider_status(
    provider: Provider,
    path: &Path,
    from_env_override: bool,
) -> anyhow::Result<(&'static str, bool)> {
    let state = match provider.format {
        Format::Nested { .. } | Format::Flat { .. } => {
            if !path.exists() {
                "absent"
            } else {
                let root = read_json_object(path)?;
                let mut state = json_hook_state(&root, provider);
                // hooks.json alone is inert for codex; report partial until the
                // sibling config.toml trusts every installed handler.
                if provider.id == "codex"
                    && state == "installed"
                    && !codex_trust_state_verified(path, from_env_override, &root)
                {
                    state = "partial";
                }
                state
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
        let timeout = installed_hook_timeout(provider, event, timeout);
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

/// Per-event override of the provider-wide timeout. Only codex SessionEnd
/// differs: codex clamps it to 3s, so writing more only produces a warning.
fn installed_hook_timeout(provider: Provider, event: &str, timeout: u64) -> u64 {
    if provider.id == "codex" { codex_hook_timeout(event) } else { timeout }
}

fn codex_hook_timeout(event: &str) -> u64 {
    if event == "SessionEnd" {
        CODEX_SESSION_END_TIMEOUT_SECONDS
    } else {
        COMMAND_HOOK_TIMEOUT_SECONDS
    }
}

fn hook_command(provider: &str, event: &str) -> String {
    format!(
        "\"${{CMUX_TUI_HOOK:-:}}\" {} {} 2>/dev/null||:;echo {{}};#{COMMAND_MARKER}",
        shell_quote(provider),
        shell_quote(event),
    )
}

/// codex 0.150 executes an unmanaged hooks.json handler only when the user
/// config layer carries `hooks.state."<hooks.json path>:<event>:<group>:<handler>"`
/// whose `trusted_hash` equals codex's normalized-identity hash; otherwise it
/// parses the file and silently skips every handler (codex-rs/hooks/src/engine/
/// discovery.rs). The installer therefore mirrors that hash and writes the
/// trust state into `$CODEX_HOME/config.toml` alongside hooks.json.
const CODEX_CONFIG_FILE: &str = "config.toml";

/// Hook-state event label used in codex's persisted trust keys
/// (codex-rs/hooks/src/lib.rs `hook_event_key_label`).
fn codex_event_state_label(event: &str) -> anyhow::Result<&'static str> {
    Ok(match event {
        "PreToolUse" => "pre_tool_use",
        "PermissionRequest" => "permission_request",
        "PostToolUse" => "post_tool_use",
        "PreCompact" => "pre_compact",
        "PostCompact" => "post_compact",
        "SessionStart" => "session_start",
        "SessionEnd" => "session_end",
        "UserPromptSubmit" => "user_prompt_submit",
        "SubagentStart" => "subagent_start",
        "SubagentStop" => "subagent_stop",
        "Stop" => "stop",
        other => anyhow::bail!("codex hook event {other:?} has no trust-state label"),
    })
}

/// codex clamps SessionEnd timeouts (default 1s, cap 3s) and floors all other
/// timeouts (default 600s) before hashing, so the trusted hash must cover the
/// normalized value, not the configured one
/// (codex-rs/hooks/src/engine/discovery.rs `normalize_command_hook`).
fn codex_normalized_timeout(state_label: &str, timeout: Option<u64>) -> u64 {
    if state_label == "session_end" {
        timeout.unwrap_or(1).clamp(1, 3)
    } else {
        timeout.unwrap_or(600).max(1)
    }
}

/// codex forces the matcher to None for events that do not support one
/// (codex-rs/hooks/src/events/common.rs `matcher_pattern_for_event`).
fn codex_normalized_matcher<'a>(state_label: &str, matcher: Option<&'a str>) -> Option<&'a str> {
    match state_label {
        "user_prompt_submit" | "stop" => None,
        _ => matcher,
    }
}

/// codex keeps `additionalContextLimit` only for events that can emit
/// additional context, and drops the explicit default before hashing
/// (codex-rs/hooks/src/engine/discovery.rs, DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT
/// in codex-rs/hooks/src/output_spill.rs).
fn codex_normalized_context_limit(state_label: &str, limit: Option<u64>) -> Option<u64> {
    const DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT: u64 = 2_500;
    match state_label {
        "pre_tool_use" | "post_tool_use" | "session_start" | "user_prompt_submit"
        | "subagent_start" => limit.filter(|limit| *limit != DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT),
        _ => None,
    }
}

/// Reproduces codex's per-hook trust hash: sha256 over sorted-key compact JSON
/// of the normalized hook identity (codex-rs/hooks/src/engine/discovery.rs
/// `hook_hash` plus codex-rs/config/src/fingerprint.rs `version_for_toml`).
/// Absent optional fields (matcher, commandWindows, statusMessage,
/// additionalContextLimit) are omitted, exactly as codex's TOML round trip
/// omits them. Keys are inserted in sorted order to match the canonical form.
fn codex_identity_trust_hash(
    state_label: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u64>,
    asynchronous: bool,
    status_message: Option<&str>,
    additional_context_limit: Option<u64>,
) -> String {
    use sha2::Digest as _;
    let mut handler = Map::new();
    if let Some(limit) = codex_normalized_context_limit(state_label, additional_context_limit) {
        handler.insert("additionalContextLimit".into(), Value::from(limit));
    }
    handler.insert("async".into(), Value::Bool(asynchronous));
    handler.insert("command".into(), Value::String(command.into()));
    if let Some(message) = status_message {
        handler.insert("statusMessage".into(), Value::String(message.into()));
    }
    handler.insert("timeout".into(), Value::from(codex_normalized_timeout(state_label, timeout)));
    handler.insert("type".into(), Value::String("command".into()));
    let mut identity = Map::new();
    identity.insert("event_name".into(), Value::String(state_label.into()));
    identity.insert("hooks".into(), Value::Array(vec![Value::Object(handler)]));
    if let Some(matcher) = codex_normalized_matcher(state_label, matcher) {
        identity.insert("matcher".into(), Value::String(matcher.into()));
    }
    let encoded = serde_json::to_vec(&Value::Object(identity))
        .expect("codex hook identity serializes to JSON");
    format!("sha256:{:x}", sha2::Sha256::digest(encoded))
}

/// Trust hash of the canonical hook shape the installer writes.
fn codex_trust_hash(state_label: &str, command: &str, timeout: u64) -> String {
    codex_identity_trust_hash(state_label, None, command, Some(timeout), false, None, None)
}

/// codex canonicalizes `CODEX_HOME` when the environment variable is set and
/// uses `~/.codex` verbatim otherwise (codex-rs/utils/home-dir/src/lib.rs
/// `find_codex_home`), and its trust keys embed that resolved path. Mirror the
/// resolution so the keys match what the codex process computes.
fn codex_state_key_hooks_path(path: &Path, from_env_override: bool) -> PathBuf {
    if !from_env_override {
        return path.to_path_buf();
    }
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return path.to_path_buf();
    };
    match fs::canonicalize(parent) {
        Ok(parent) => parent.join(name),
        Err(_) => path.to_path_buf(),
    }
}

/// The cmux-owned handler as (group index, hook index, group, handler). codex
/// keys trust by BOTH positions, so a foreign entry before ours in the same
/// group shifts the key just like a preceding group does.
fn codex_owned_hook_entry<'a>(
    root: &'a Map<String, Value>,
    event: &str,
) -> Option<(usize, usize, &'a Value, &'a Value)> {
    let groups = root.get("hooks")?.get(event)?.as_array()?;
    groups.iter().enumerate().find_map(|(group_index, group)| {
        let hooks = group.get("hooks").and_then(Value::as_array)?;
        let handler_index = hooks.iter().position(|hook| {
            hook.get("command").and_then(Value::as_str).is_some_and(is_owned_command)
        })?;
        Some((group_index, handler_index, group, &hooks[handler_index]))
    })
}

#[cfg(test)]
fn codex_owned_hook_position(root: &Map<String, Value>, event: &str) -> Option<(usize, usize)> {
    codex_owned_hook_entry(root, event)
        .map(|(group_index, handler_index, _, _)| (group_index, handler_index))
}

/// The trust entries codex requires for the hooks ACTUALLY present in `root`:
/// keyed by the owned handler's real position and hashed over that handler's
/// real fields. For a freshly rewritten install this equals the canonical
/// shape; for status it reflects any hand edits, so a user-modified command
/// or timeout (which codex would hash differently and skip) fails to verify.
fn codex_expected_trust_entries(
    key_hooks_path: &Path,
    root: &Map<String, Value>,
) -> anyhow::Result<BTreeMap<String, String>> {
    let mut entries = BTreeMap::new();
    for event in CODEX_EVENTS {
        let label = codex_event_state_label(event)?;
        let (group_index, handler_index, group, handler) = codex_owned_hook_entry(root, event)
            .with_context(|| format!("installed codex hook for {event} is missing"))?;
        let key = format!("{}:{label}:{group_index}:{handler_index}", key_hooks_path.display());
        let command = if cfg!(windows) {
            handler
                .get("commandWindows")
                .and_then(Value::as_str)
                .or_else(|| handler.get("command").and_then(Value::as_str))
        } else {
            handler.get("command").and_then(Value::as_str)
        }
        .with_context(|| format!("installed codex hook for {event} has no command"))?;
        let hash = codex_identity_trust_hash(
            label,
            group.get("matcher").and_then(Value::as_str),
            command,
            handler.get("timeout").and_then(Value::as_u64),
            handler.get("async").and_then(Value::as_bool).unwrap_or(false),
            handler.get("statusMessage").and_then(Value::as_str),
            handler.get("additionalContextLimit").and_then(Value::as_u64),
        );
        entries.insert(key, hash);
    }
    Ok(entries)
}

/// Every trust hash the current installer shape can produce. Entries carrying
/// one of these hashes are cmux-owned regardless of their positional key.
fn codex_owned_trust_hashes() -> anyhow::Result<BTreeSet<String>> {
    CODEX_EVENTS
        .iter()
        .map(|event| {
            let label = codex_event_state_label(event)?;
            Ok(codex_trust_hash(label, &hook_command("codex", event), codex_hook_timeout(event)))
        })
        .collect()
}

/// Dotfile managers commonly symlink `config.toml`; the atomic rename must
/// land in the link's TARGET so the link survives and codex keeps editing the
/// same file. A link that cannot be resolved is refused instead of replaced.
fn resolve_codex_config_path(config_path: PathBuf) -> anyhow::Result<PathBuf> {
    match fs::symlink_metadata(&config_path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(config_path),
        Err(error) => Err(error).with_context(|| format!("inspect {}", config_path.display())),
        Ok(metadata) if !metadata.file_type().is_symlink() => Ok(config_path),
        Ok(_) => fs::canonicalize(&config_path).with_context(|| {
            format!(
                "{} is a symlink that does not resolve; refusing to replace it",
                config_path.display()
            )
        }),
    }
}

/// The ONE way every config.toml consumer (status, preflight, commit re-read)
/// loads the file. A separate stat-then-read would race a concurrent
/// replacement with a FIFO or huge file, so this opens the file once, fstats
/// the OPENED descriptor (regular file, size cap), and does a bounded read
/// from that same descriptor. The open itself is safe: `O_NONBLOCK` is a
/// no-op for regular files and stops a FIFO open from blocking on a missing
/// writer, and a FIFO descriptor opened that way is rejected by the fstat
/// before anything reads it.
fn read_codex_config_text(config_path: &Path) -> anyhow::Result<Option<String>> {
    let mut options = fs::File::options();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = match options.open(config_path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("open {}", config_path.display()));
        }
    };
    let metadata = file.metadata().with_context(|| format!("inspect {}", config_path.display()))?;
    anyhow::ensure!(
        metadata.is_file(),
        "{} is not a regular file; refusing to read it",
        config_path.display()
    );
    anyhow::ensure!(metadata.len() <= MAX_CONFIG_BYTES, "{} exceeds 16 MiB", config_path.display());
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("read {}", config_path.display()))?;
    anyhow::ensure!(
        bytes.len() as u64 <= MAX_CONFIG_BYTES,
        "{} exceeds 16 MiB",
        config_path.display()
    );
    Ok(Some(
        String::from_utf8(bytes)
            .with_context(|| format!("{} is not valid UTF-8", config_path.display()))?,
    ))
}

fn read_codex_config_document(
    config_path: &Path,
) -> anyhow::Result<(Option<String>, toml_edit::DocumentMut)> {
    let original = read_codex_config_text(config_path)?;
    let document = original
        .as_deref()
        .unwrap_or_default()
        .parse::<toml_edit::DocumentMut>()
        .with_context(|| format!("{} is not valid TOML", config_path.display()))?;
    Ok((original, document))
}

fn codex_state_table_mut<'a>(
    document: &'a mut toml_edit::DocumentMut,
    config_path: &Path,
    create: bool,
) -> anyhow::Result<Option<&'a mut dyn toml_edit::TableLike>> {
    let root = document.as_table_mut();
    let hooks_is_inline = match root.get("hooks") {
        Some(hooks) if hooks.as_table_like().is_none() => {
            // A scalar `hooks` key (for example `hooks = true`) makes
            // `hooks.state` unreachable for codex itself; installing over it
            // would corrupt the config, so surface it instead.
            anyhow::ensure!(
                !create,
                "hooks key in {} is not a table, so codex cannot read hook trust state; remove it and reinstall",
                config_path.display()
            );
            return Ok(None);
        }
        Some(hooks) => hooks.as_value().is_some(),
        None if create => {
            let mut table = toml_edit::Table::new();
            table.set_implicit(true);
            root.insert("hooks", toml_edit::Item::Table(table));
            false
        }
        None => return Ok(None),
    };
    let hooks = root
        .get_mut("hooks")
        .and_then(toml_edit::Item::as_table_like_mut)
        .with_context(|| format!("hooks table in {} is unusable", config_path.display()))?;
    match hooks.get("state") {
        Some(state) if state.as_table_like().is_none() => {
            anyhow::ensure!(
                !create,
                "hooks.state in {} is not a table; remove it and reinstall",
                config_path.display()
            );
            return Ok(None);
        }
        Some(_) => {}
        None if create => {
            // Match the parent's representation: a subtable dropped into an
            // inline `hooks = { ... }` must itself be an inline value, or
            // TableLike::insert silently discards it.
            let state = if hooks_is_inline {
                toml_edit::Item::Value(toml_edit::InlineTable::new().into())
            } else {
                toml_edit::Item::Table(toml_edit::Table::new())
            };
            hooks.insert("state", state);
        }
        None => return Ok(None),
    }
    hooks
        .get_mut("state")
        .and_then(toml_edit::Item::as_table_like_mut)
        .with_context(|| format!("hooks.state in {} could not be created", config_path.display()))
        .map(Some)
}

/// The validated inputs of one trust-state edit, kept alongside the rendered
/// document so the commit can re-render against fresh file content when
/// config.toml changed between the preflight and the commit.
struct CodexTrustEdit {
    config_path: PathBuf,
    key_prefix: String,
    desired: BTreeMap<String, String>,
    /// Positional keys of the cmux-owned hooks in hooks.json BEFORE this
    /// operation rewrote it. These entries are deleted regardless of their
    /// hash value: codex persists a NEW hash when a user reviews and accepts
    /// a modified cmux hook, so hash matching alone would leave that entry
    /// behind to pollute a later hook at the same positional key.
    removal_keys: BTreeSet<String>,
    owned_hashes: BTreeSet<String>,
    install: bool,
}

/// Positional trust keys of every cmux-owned handler occurrence in `root`.
fn codex_owned_entry_keys(key_hooks_path: &Path, root: &Map<String, Value>) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object) else {
        return keys;
    };
    for (event, groups) in hooks {
        let Ok(label) = codex_event_state_label(event) else {
            continue;
        };
        let Some(groups) = groups.as_array() else {
            continue;
        };
        for (group_index, group) in groups.iter().enumerate() {
            let Some(handlers) = group.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for (handler_index, handler) in handlers.iter().enumerate() {
                if handler.get("command").and_then(Value::as_str).is_some_and(is_owned_command) {
                    keys.insert(format!(
                        "{}:{label}:{group_index}:{handler_index}",
                        key_hooks_path.display()
                    ));
                }
            }
        }
    }
    keys
}

/// A fully validated, pre-rendered config.toml trust-state write. Producing
/// one performs every step that can fail for content reasons (read, parse,
/// shape validation, rendering, target-directory writability), so the caller
/// can sequence it BEFORE mutating hooks.json and commit it afterwards.
struct PreparedCodexTrustWrite {
    edit: CodexTrustEdit,
    original: Option<String>,
    updated: String,
    mode: u32,
}

/// Reads the config and renders the trust edit against its current content,
/// preserving unrelated keys, comments, and formatting. Returns the file's
/// current text plus the rendered replacement, or `None` when the current
/// content already satisfies the edit.
fn render_codex_trust_document(
    edit: &CodexTrustEdit,
) -> anyhow::Result<(Option<String>, Option<String>)> {
    let (original, mut document) = read_codex_config_document(&edit.config_path)?;

    if let Some(state) = codex_state_table_mut(&mut document, &edit.config_path, edit.install)? {
        let stale: Vec<String> = state
            .iter()
            .filter(|(key, entry)| {
                // Primary removal follows the hooks this operation removes
                // from hooks.json: their exact positional keys are deleted
                // regardless of hash, covering entries codex re-trusted after
                // a user edit. The canonical-hash sweep stays as secondary
                // cleanup for orphaned keys from prior layouts.
                key.starts_with(&edit.key_prefix)
                    && !edit.desired.contains_key(*key)
                    && (edit.removal_keys.contains(*key)
                        || entry
                            .as_table_like()
                            .and_then(|entry| entry.get("trusted_hash"))
                            .and_then(toml_edit::Item::as_str)
                            .is_some_and(|hash| edit.owned_hashes.contains(hash)))
            })
            .map(|(key, _)| key.to_string())
            .collect();
        for key in stale {
            state.remove(&key);
        }
        for (key, hash) in &edit.desired {
            match state.get_mut(key).and_then(toml_edit::Item::as_table_like_mut) {
                Some(entry) => {
                    entry.insert("trusted_hash", toml_edit::value(hash.clone()));
                }
                None => {
                    let mut entry = toml_edit::InlineTable::new();
                    entry.insert("trusted_hash", toml_edit::Value::from(hash.clone()));
                    state.insert(key, toml_edit::Item::Value(entry.into()));
                }
            }
        }
        // Uninstall NEVER removes tables, only the trust entries whose hashes
        // prove cmux ownership. Empty-and-undecorated cannot distinguish an
        // installer-created table from a user-created placeholder across
        // processes, so an empty [hooks]/[hooks.state] skeleton is left
        // behind instead of guessing; it is harmless to codex.
    }

    let updated = document.to_string();
    if Some(updated.as_str()) == original.as_deref() || (original.is_none() && updated.is_empty()) {
        return Ok((original, None));
    }
    Ok((original, Some(updated)))
}

/// Preflights the cmux-owned `hooks.state` trust-entry edit of the codex user
/// config next to `hooks_path`. Returns `None` when the config already
/// matches.
fn prepare_codex_trust_state(
    hooks_path: &Path,
    from_env_override: bool,
    root: &Map<String, Value>,
    previous_root: &Map<String, Value>,
    install: bool,
) -> anyhow::Result<Option<PreparedCodexTrustWrite>> {
    let parent = hooks_path.parent().context("codex hooks path has no parent")?;
    // Resolve a symlinked config.toml to its target so the later atomic
    // rename edits the real file instead of detaching the link.
    let config_path = resolve_codex_config_path(parent.join(CODEX_CONFIG_FILE))?;
    let key_hooks_path = codex_state_key_hooks_path(hooks_path, from_env_override);
    let desired = if install {
        codex_expected_trust_entries(&key_hooks_path, root)?
    } else {
        BTreeMap::new()
    };
    if !install && !config_path.exists() {
        return Ok(None);
    }
    let edit = CodexTrustEdit {
        key_prefix: format!("{}:", key_hooks_path.display()),
        removal_keys: codex_owned_entry_keys(&key_hooks_path, previous_root),
        owned_hashes: codex_owned_trust_hashes()?,
        config_path,
        desired,
        install,
    };
    let (original, updated) = render_codex_trust_document(&edit)?;
    let Some(updated) = updated else {
        return Ok(None);
    };
    // Probe where the rename will actually land: the resolved target's
    // directory, not necessarily the codex home.
    let target_parent =
        edit.config_path.parent().context("codex config path has no parent")?.to_path_buf();
    ensure_writable_directory(&target_parent)?;
    Ok(Some(PreparedCodexTrustWrite {
        mode: existing_file_mode(&edit.config_path).unwrap_or(0o600),
        edit,
        original,
        updated,
    }))
}

fn commit_codex_trust_state(write: &PreparedCodexTrustWrite) -> anyhow::Result<()> {
    // Close the preflight-to-commit window: if config.toml changed in between
    // (codex's own trust review or a user edit), re-render against the fresh
    // content instead of clobbering the concurrent edit with the stale
    // preflight document. A re-render failure propagates, so the caller's
    // rollback restores hooks.json.
    let current = read_codex_config_text(&write.edit.config_path)?;
    if current == write.original {
        return atomic_write(&write.edit.config_path, write.updated.as_bytes(), Some(write.mode));
    }
    match render_codex_trust_document(&write.edit)? {
        (_, Some(updated)) => {
            let mode = existing_file_mode(&write.edit.config_path).unwrap_or(0o600);
            atomic_write(&write.edit.config_path, updated.as_bytes(), Some(mode))
        }
        // The concurrent edit already satisfies the trust entries.
        (_, None) => Ok(()),
    }
}

/// Captures a file's rollback snapshot (bytes and mode) before mutation.
/// Only a genuine NotFound maps to None; any other read error fails the whole
/// operation up front, because rolling back against a false None would delete
/// a pre-existing file as if it had been absent.
fn snapshot_file(path: &Path) -> anyhow::Result<Option<(Vec<u8>, u32)>> {
    match fs::read(path) {
        Ok(bytes) => {
            let mode = existing_file_mode(path).unwrap_or(0o600);
            Ok(Some((bytes, mode)))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("snapshot {} for rollback", path.display()))
        }
    }
}

/// Restores hooks.json to its pre-operation content (or absence) after a
/// failed trust-state commit, so a config.toml write failure cannot leave a
/// half-applied install or uninstall behind.
fn restore_hooks_file(path: &Path, previous: Option<(Vec<u8>, u32)>) -> anyhow::Result<()> {
    match previous {
        Some((bytes, mode)) => atomic_write(path, &bytes, Some(mode)),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
        },
    }
}

/// Applies a preflighted trust write after hooks.json was already updated,
/// rolling hooks.json back (best effort) if the commit itself still fails.
fn commit_codex_trust_state_or_rollback(
    write: &PreparedCodexTrustWrite,
    hooks_path: &Path,
    previous_hooks: Option<Option<(Vec<u8>, u32)>>,
) -> anyhow::Result<()> {
    let Err(commit_error) = commit_codex_trust_state(write) else {
        return Ok(());
    };
    if let Some(previous) = previous_hooks
        && let Err(rollback_error) = restore_hooks_file(hooks_path, previous)
    {
        return Err(commit_error.context(format!(
            "additionally, restoring {} failed: {rollback_error:#}",
            hooks_path.display()
        )));
    }
    Err(commit_error)
}

/// Verifies the directory accepts new files before any mutation happens, so
/// preflight failures surface while both target files are still untouched.
fn ensure_writable_directory(parent: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    let mut random = [0_u8; 8];
    getrandom::fill(&mut random).context("allocate preflight file identity")?;
    let suffix = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let probe = parent.join(format!(".cmux-tui-preflight-{suffix}"));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .with_context(|| format!("preflight write access to {}", parent.display()))?;
    fs::remove_file(&probe).with_context(|| format!("remove {}", probe.display()))?;
    Ok(())
}

fn existing_file_mode(path: &Path) -> Option<u32> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::metadata(path).ok().map(|metadata| metadata.permissions().mode() & 0o777)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Whether every installed codex hook is trusted by the sibling config.toml.
/// Read-only; parse failures and absent files report as unverified.
fn codex_trust_state_verified(
    hooks_path: &Path,
    from_env_override: bool,
    root: &Map<String, Value>,
) -> bool {
    let Some(parent) = hooks_path.parent() else {
        return false;
    };
    let key_hooks_path = codex_state_key_hooks_path(hooks_path, from_env_override);
    let Ok(expected) = codex_expected_trust_entries(&key_hooks_path, root) else {
        return false;
    };
    let config_path = parent.join(CODEX_CONFIG_FILE);
    // The shared open-once/fstat/bounded-read helper, so status can never be
    // stalled by a FIFO or oversized file, even one swapped in concurrently.
    let Ok(Some(text)) = read_codex_config_text(&config_path) else {
        return false;
    };
    let Ok(config) = text.parse::<toml_edit::DocumentMut>() else {
        return false;
    };
    let Some(state) = config
        .as_table()
        .get("hooks")
        .and_then(toml_edit::Item::as_table_like)
        .and_then(|hooks| hooks.get("state"))
        .and_then(toml_edit::Item::as_table_like)
    else {
        return false;
    };
    expected.iter().all(|(key, hash)| {
        state
            .get(key)
            .and_then(toml_edit::Item::as_table_like)
            .and_then(|entry| entry.get("trusted_hash"))
            .and_then(toml_edit::Item::as_str)
            == Some(hash.as_str())
    })
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

    #[cfg(unix)]
    #[test]
    fn hermes_command_reaps_child_when_reaper_spawn_fails() {
        let root = tempfile::tempdir().unwrap();
        let pid_path = root.path().join("hermes.pid");
        let continue_path = root.path().join("hermes.continue");
        let script = format!(
            "printf '%s' $$ > {}; while [ ! -f {} ]; do sleep 0.01; done; sleep 30",
            shell_quote(pid_path.to_string_lossy().as_ref()),
            shell_quote(continue_path.to_string_lossy().as_ref())
        );

        let (result_sender, result_receiver) = std::sync::mpsc::sync_channel(1);
        let started = Instant::now();
        let worker = std::thread::spawn(move || {
            FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(true));
            let result = run_hermes_command_with_timeout(
                Path::new("/bin/sh"),
                &["-c", &script],
                Duration::from_secs(2),
            );
            result_sender.send(result).unwrap();
        });

        let startup_deadline = Instant::now() + Duration::from_secs(1);
        let pid = loop {
            if let Ok(contents) = fs::read_to_string(&pid_path)
                && let Ok(pid) = contents.trim().parse::<libc::pid_t>()
            {
                break pid;
            }
            assert!(Instant::now() < startup_deadline, "Hermes child did not complete startup");
            std::thread::sleep(Duration::from_millis(5));
        };
        fs::write(&continue_path, b"continue\n").unwrap();

        let error = result_receiver
            .recv_timeout(Duration::from_secs(4))
            .expect("Hermes timeout worker did not return")
            .unwrap_err();
        worker.join().unwrap();
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(4));

        let reap_deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
            // SAFETY: `pid` was written by the direct child started above, and
            // WNOWAIT keeps this assertion from consuming its exit status.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    status.as_mut_ptr(),
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result < 0 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::ECHILD) {
                    break;
                }
                panic!("waitid failed while checking Hermes reaper: {error}");
            }
            assert!(
                Instant::now() < reap_deadline,
                "Hermes child was not reaped after timeout returned"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[cfg(unix)]
    #[test]
    fn hermes_reaper_spawn_failure_does_not_wait_for_a_live_child() {
        struct ReaperFailureGuard;

        impl Drop for ReaperFailureGuard {
            fn drop(&mut self) {
                FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(false));
            }
        }

        struct ChildGuard(libc::pid_t);

        impl Drop for ChildGuard {
            fn drop(&mut self) {
                // SAFETY: this is the direct child created by the test.
                unsafe {
                    libc::kill(self.0, libc::SIGKILL);
                    let mut status = 0;
                    libc::waitpid(self.0, &mut status, 0);
                }
            }
        }

        let child = std::process::Command::new("/bin/sh").args(["-c", "sleep 30"]).spawn().unwrap();
        let pid = libc::pid_t::try_from(child.id()).unwrap();
        let _child_guard = ChildGuard(pid);
        let child_exit = UnixChildExitSignal::observe(child.id()).unwrap();
        let state = Arc::new(HermesReapState::new(child, Some(child_exit)));
        FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(true));
        let _failure_guard = ReaperFailureGuard;

        let started = Instant::now();
        assert!(spawn_hermes_reaper(Arc::clone(&state)).is_err());
        state.handoff_reap();
        assert!(
            started.elapsed() < Duration::from_millis(200),
            "reaper fallback waited for a live child"
        );

        // The handoff deliberately leaves the live child to make the
        // nonblocking property observable. The guard terminates it after the
        // assertion and consumes any status the detached observer did not yet
        // consume.
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

    /// Trust hashes verified against the real codex 0.150.1 binary: with these
    /// exact `hooks.state` values in `config.toml`, codex executes the installed
    /// hooks.json commands; without them it parses hooks.json (it even warns
    /// about clamping the SessionEnd timeout) and silently skips every handler,
    /// so codex sessions never reach the cmux-tui agents view
    /// (https://github.com/manaflow-ai/cmux/issues/11040).
    const CODEX_TRUSTED_HASHES: &[(&str, &str)] = &[
        (
            "session_start",
            "sha256:397d7ce9e0c6367e34771a4293777ff95415b595bf77e2aa420425adc75d70ae",
        ),
        (
            "user_prompt_submit",
            "sha256:07ddfc92c131019a0f7099cf68bfbcd34749f112ce56105f544c9a826070db37",
        ),
        ("stop", "sha256:8150babcaace7dd374a53671af15022040cb1f48fea365beacdecff744161348"),
        (
            "permission_request",
            "sha256:def8faccd7926451435a173f6b392150e425fd369e221674a6b7741d69158c5c",
        ),
        ("pre_tool_use", "sha256:2f90e5824bf1d244ed7fd88f0f545dd3bc896050df56efc12dab3d021efe3d8f"),
        (
            "post_tool_use",
            "sha256:a10109f22d9a6ca69c88a0989d208d1323e2894eea3965a42883d5167457e8b4",
        ),
        ("pre_compact", "sha256:a5939da92131e5397df18219e069c0fa59494d832f77ec37d985286aeacca1ec"),
        ("post_compact", "sha256:609234714e7a0ddf9fbc32c049f2651e732c2f27f12cca21954907df0434e1e8"),
        (
            "subagent_start",
            "sha256:fb16a1107f5a630d93d50e448ad1b20bf677d94d0ade1a5ec3216cb2b8bf53dc",
        ),
        (
            "subagent_stop",
            "sha256:37436a4778c90ed5ab0e207b2922d3e1151dedfa26c33489c9faef7c990e8866",
        ),
        // SessionEnd is installed at codex's 3s cap; the hash is identical to
        // the one codex computed for a clamped 5s, so older installs stay trusted.
        ("session_end", "sha256:8366ef19df8ee745ecc7acbd8f72f7109478a583dfd5d06b61537b8e8d19e088"),
    ];

    fn codex_state_table(context: &Context) -> toml::value::Table {
        let text = fs::read_to_string(context.home.join(".codex/config.toml"))
            .expect("codex trust state must be written to $CODEX_HOME/config.toml");
        let config: toml::Value = toml::from_str(&text).expect("config.toml must stay valid TOML");
        config
            .get("hooks")
            .and_then(|hooks| hooks.get("state"))
            .and_then(toml::Value::as_table)
            .cloned()
            .expect("config.toml must contain a hooks.state table")
    }

    #[test]
    fn codex_install_writes_matching_trust_state_into_config_toml() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let hooks_path = context.home.join(".codex/hooks.json");
        let state = codex_state_table(&context);
        for (event, hash) in CODEX_TRUSTED_HASHES {
            let key = format!("{}:{event}:0:0", hooks_path.display());
            let entry =
                state.get(&key).unwrap_or_else(|| panic!("missing hooks.state entry {key}"));
            assert_eq!(
                entry.get("trusted_hash").and_then(toml::Value::as_str),
                Some(*hash),
                "{key}"
            );
        }
        assert_eq!(state.len(), CODEX_EVENTS.len());
    }

    #[test]
    fn codex_session_end_hook_timeout_stays_within_the_codex_cap() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let hooks: Value =
            serde_json::from_slice(&fs::read(context.home.join(".codex/hooks.json")).unwrap())
                .unwrap();
        for event in CODEX_EVENTS {
            let timeout = hooks["hooks"][*event][0]["hooks"][0]["timeout"].as_u64().unwrap();
            let label = codex_event_state_label(event).unwrap();
            assert_eq!(
                timeout,
                codex_normalized_timeout(label, Some(timeout)),
                "{event}: codex must not clamp or floor the installed timeout"
            );
            if *event == "SessionEnd" {
                assert_eq!(timeout, CODEX_SESSION_END_TIMEOUT_SECONDS);
            } else {
                assert_eq!(timeout, COMMAND_HOOK_TIMEOUT_SECONDS, "{event}");
            }
        }
        // A pre-existing install written with the generic 5s stays owned: codex
        // hashed the clamped value, which is what the installer now writes.
        assert_eq!(
            codex_trust_hash("session_end", &hook_command("codex", "SessionEnd"), 5),
            codex_trust_hash("session_end", &hook_command("codex", "SessionEnd"), 3),
        );
    }

    #[test]
    fn codex_trust_keys_use_the_installed_group_position() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let hooks_path = context.home.join(".codex/hooks.json");
        atomic_write(
            &hooks_path,
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]}]}}"#,
            Some(0o600),
        )
        .unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let state = codex_state_table(&context);
        // The custom Stop group keeps position 0, so the cmux-owned handler is
        // group 1 and its trust key must say so; codex keys trust by position.
        let stop_key = format!("{}:stop:1:0", hooks_path.display());
        let stop_hash =
            CODEX_TRUSTED_HASHES.iter().find(|(event, _)| *event == "stop").map(|(_, hash)| *hash);
        assert_eq!(
            state
                .get(&stop_key)
                .and_then(|entry| entry.get("trusted_hash"))
                .and_then(toml::Value::as_str),
            stop_hash,
            "{stop_key}"
        );
        assert!(!state.contains_key(&format!("{}:stop:0:0", hooks_path.display())));
    }

    #[test]
    fn codex_trust_keys_use_the_owned_hook_index_within_a_group() {
        // Unit: a foreign hook before ours in the same group shifts the
        // handler index; codex keys trust by group AND handler position.
        let owned = hook_command("codex", "Stop");
        let mixed = json!({"hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "foreign-first", "timeout": 5},
            {"type": "command", "command": owned, "timeout": 5},
        ]}]}});
        let mixed = mixed.as_object().unwrap().clone();
        assert_eq!(codex_owned_hook_position(&mixed, "Stop"), Some((0, 1)));

        // End to end: after a hand-edit inserts a foreign hook before ours,
        // codex would look up key ...:stop:0:1 and skip the untrusted cmux
        // hook, so status must stop claiming installed; a reinstall re-appends
        // our handler as its own group and mints the key for that position.
        let tmp = tempfile::tempdir().unwrap();
        let context = context(tmp.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let hooks_path = context.home.join(".codex/hooks.json");
        let mut edited: Value = serde_json::from_slice(&fs::read(&hooks_path).unwrap()).unwrap();
        edited["hooks"]["Stop"][0]["hooks"]
            .as_array_mut()
            .unwrap()
            .insert(0, json!({"type": "command", "command": "foreign-first", "timeout": 5}));
        atomic_write(&hooks_path, &serde_json::to_vec_pretty(&edited).unwrap(), Some(0o600))
            .unwrap();

        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);

        assert!(!run_with_context(&install, &context).failed);
        let state = codex_state_table(&context);
        assert!(
            state.contains_key(&format!("{}:stop:1:0", hooks_path.display())),
            "reinstall must key trust by the hook's new position: {state:?}"
        );
        assert!(!state.contains_key(&format!("{}:stop:0:0", hooks_path.display())));
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
    }

    #[test]
    fn codex_status_detects_a_user_edited_hook_entry() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

        // A user edit to the installed entry changes codex's normalized
        // identity hash, so codex marks the hook Modified and skips it.
        // Status must hash the entry ACTUALLY on disk, not the canonical
        // shape, or it would keep claiming installed here.
        let hooks_path = context.home.join(".codex/hooks.json");
        let mut edited: Value = serde_json::from_slice(&fs::read(&hooks_path).unwrap()).unwrap();
        edited["hooks"]["Stop"][0]["hooks"][0]["timeout"] = json!(60);
        atomic_write(&hooks_path, &serde_json::to_vec_pretty(&edited).unwrap(), Some(0o600))
            .unwrap();
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);

        // Reinstall rewrites the canonical entry, whose hash matches the
        // stored trust state again.
        assert!(!run_with_context(&install, &context).failed);
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
    }

    #[test]
    fn snapshot_file_propagates_non_notfound_read_errors() {
        let root = tempfile::tempdir().unwrap();
        // A directory in place of the file is a read error that is NOT
        // NotFound; mapping it to None would make a later rollback delete a
        // pre-existing hooks.json as if it had been absent.
        let dir = root.path().join("hooks.json");
        fs::create_dir_all(&dir).unwrap();
        let error = snapshot_file(&dir).unwrap_err();
        assert!(error.to_string().contains("snapshot"), "{error:#}");

        assert!(snapshot_file(&root.path().join("absent.json")).unwrap().is_none());
        let file = root.path().join("present.json");
        atomic_write(&file, b"{}", Some(0o600)).unwrap();
        assert_eq!(snapshot_file(&file).unwrap().unwrap().0, b"{}");
    }

    #[cfg(unix)]
    #[test]
    fn codex_operations_fail_closed_on_a_fifo_config_toml() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt as _;

        let root = tempfile::tempdir().unwrap();
        let worker_context = context(root.path());
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let hooks_path = context.home.join(".codex/hooks.json");
        let installed = fs::read(&hooks_path).unwrap();
        let config_path = context.home.join(".codex/config.toml");
        fs::remove_file(&config_path).unwrap();
        let fifo = CString::new(config_path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);

        // The FIFO has no writer, so merely opening it would block forever;
        // every operation must gate on metadata instead. Run them on a worker
        // thread with a bounded wait so a regression fails fast as a timeout
        // panic instead of hanging the suite.
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
            let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
            let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
            let _ = sender.send((
                run_with_context(&status, &worker_context),
                run_with_context(&install, &worker_context),
                run_with_context(&uninstall, &worker_context),
            ));
        });
        let (status_result, install_result, uninstall_result) = receiver
            .recv_timeout(Duration::from_secs(60))
            .expect("codex operations must fail closed on a FIFO config instead of blocking");

        assert_eq!(
            status_result.value["providers"][0]["state"], "partial",
            "{}",
            status_result.value
        );
        assert!(install_result.failed, "{}", install_result.value);
        assert!(
            install_result.value["errors"][0].as_str().unwrap().contains("not a regular file"),
            "{}",
            install_result.value
        );
        assert!(uninstall_result.failed, "{}", uninstall_result.value);
        // Both mutating operations failed in preflight: hooks.json untouched.
        assert_eq!(fs::read(&hooks_path).unwrap(), installed);
    }

    #[test]
    fn codex_install_supports_an_inline_hooks_table() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        // `hooks = { enabled = true }` is a valid inline table; inserting the
        // state subtable into it used to be silently discarded and then panic.
        atomic_write(&config_path, b"hooks = { enabled = true }\n", Some(0o600)).unwrap();
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&install, &context);
        assert!(!result.failed, "{}", result.value);
        let state = codex_state_table(&context);
        assert_eq!(state.len(), CODEX_EVENTS.len());
        let text = fs::read_to_string(&config_path).unwrap();
        assert!(text.contains("enabled = true"), "{text}");

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(&config_path).unwrap();
        assert!(text.contains("enabled = true"), "{text}");
        assert!(!text.contains("trusted_hash"), "{text}");
    }

    #[test]
    fn codex_uninstall_keeps_a_commented_user_state_table_byte_identical() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        let original = "# reserved for my hook overrides\n[hooks.state]\n";
        atomic_write(&config_path, original.as_bytes(), Some(0o600)).unwrap();

        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        assert!(fs::read_to_string(&config_path).unwrap().contains("trusted_hash"));
        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        assert!(!run_with_context(&uninstall, &context).failed);
        // The table is empty again but carries the user's comment; deleting
        // it would destroy their content, so the cycle must round-trip.
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn codex_trust_commit_re_renders_after_a_concurrent_config_edit() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let hooks_path = context.home.join(".codex/hooks.json");
        let config_path = context.home.join(".codex/config.toml");

        // Reset the trust state so a fresh edit is pending, then preflight it.
        atomic_write(&config_path, b"model = \"gpt-5.6\"\n", Some(0o600)).unwrap();
        let hooks_root = read_json_object(&hooks_path).unwrap();
        let prepared =
            prepare_codex_trust_state(&hooks_path, false, &hooks_root, &hooks_root, true)
                .unwrap()
                .expect("trust entries are missing, so an edit must be pending");

        // A concurrent writer (codex's own trust review or the user) edits
        // config.toml between the preflight and the commit; the commit must
        // fold that edit in rather than clobber it with the stale render.
        atomic_write(&config_path, b"model = \"gpt-5.6\"\nconcurrent = \"edit\"\n", Some(0o600))
            .unwrap();
        commit_codex_trust_state(&prepared).unwrap();
        let text = fs::read_to_string(&config_path).unwrap();
        assert!(text.contains("concurrent = \"edit\""), "{text}");
        assert!(text.contains("model = \"gpt-5.6\""), "{text}");
        assert_eq!(codex_state_table(&context).len(), CODEX_EVENTS.len());

        // If the fresh content no longer validates, the commit must fail and
        // the rollback path must restore hooks.json.
        atomic_write(&config_path, b"model = \"gpt-5.6\"\n", Some(0o600)).unwrap();
        let hooks_root = read_json_object(&hooks_path).unwrap();
        let prepared =
            prepare_codex_trust_state(&hooks_path, false, &hooks_root, &hooks_root, true)
                .unwrap()
                .unwrap();
        let installed_hooks = fs::read(&hooks_path).unwrap();
        atomic_write(&config_path, b"hooks = true\n", Some(0o600)).unwrap();
        atomic_write(&hooks_path, b"{}\n", Some(0o600)).unwrap();
        let error = commit_codex_trust_state_or_rollback(
            &prepared,
            &hooks_path,
            Some(Some((installed_hooks.clone(), 0o600))),
        )
        .unwrap_err();
        assert!(format!("{error:#}").contains("hooks key"), "{error:#}");
        assert_eq!(fs::read(&hooks_path).unwrap(), installed_hooks);
        assert_eq!(fs::read_to_string(&config_path).unwrap(), "hooks = true\n");
    }

    #[test]
    fn codex_trust_sync_preserves_user_config_and_is_idempotent_and_reversible() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        let user_key = "manual/hooks.json:stop:0:0";
        atomic_write(
            &config_path,
            format!(
                "# personal codex config\nmodel = \"gpt-5.6\"\n\n[hooks.state.\"{user_key}\"]\nenabled = false\ntrusted_hash = \"sha256:user\"\n"
            )
            .as_bytes(),
            Some(0o600),
        )
        .unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let first = run_with_context(&plan, &context);
        assert!(!first.failed, "{}", first.value);
        assert_eq!(first.value["providers"][0]["changed"], Value::Bool(true));
        let text = fs::read_to_string(&config_path).unwrap();
        assert!(text.contains("# personal codex config"));
        assert!(text.contains("model = \"gpt-5.6\""));
        assert!(text.contains("sha256:user"));

        let second = run_with_context(&plan, &context);
        assert!(!second.failed, "{}", second.value);
        assert_eq!(second.value["providers"][0]["changed"], Value::Bool(false));
        assert_eq!(fs::read_to_string(&config_path).unwrap(), text);

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        let state = codex_state_table(&context);
        assert_eq!(state.len(), 1, "only the user's own trust entry survives");
        assert!(state.contains_key(user_key));
        let text = fs::read_to_string(&config_path).unwrap();
        assert!(text.contains("# personal codex config"));
        assert!(!text.contains(&format!("{}", context.home.join(".codex/hooks.json").display())));
    }

    #[test]
    fn codex_uninstall_removes_entries_but_never_tables() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        assert!(!run_with_context(&uninstall, &context).failed);
        // Ownership of an empty table cannot be proven across processes, so
        // uninstall deletes only hash-proven trust entries and leaves the
        // empty [hooks.state] skeleton behind; codex ignores it.
        let state = codex_state_table(&context);
        assert!(state.is_empty(), "only the empty skeleton may remain: {state:?}");
        let text = fs::read_to_string(context.home.join(".codex/config.toml")).unwrap();
        assert!(!text.contains("trusted_hash"), "{text}");
    }

    #[test]
    fn codex_uninstall_removes_a_re_accepted_trust_entry() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let hooks_path = context.home.join(".codex/hooks.json");
        let config_path = context.home.join(".codex/config.toml");

        // Simulate codex re-accepting a user-edited cmux hook: the entry
        // keeps the cmux hook's positional key but carries a NEW hash that
        // no canonical command shape produces. Add a user-owned entry at
        // another key that must survive.
        let mut doc: toml_edit::DocumentMut =
            fs::read_to_string(&config_path).unwrap().parse().unwrap();
        let state = doc["hooks"]["state"].as_table_like_mut().unwrap();
        let stop_key = format!("{}:stop:0:0", hooks_path.display());
        state
            .get_mut(&stop_key)
            .unwrap()
            .as_table_like_mut()
            .unwrap()
            .insert("trusted_hash", toml_edit::value("sha256:re-accepted-after-user-edit"));
        let mut user_entry = toml_edit::InlineTable::new();
        user_entry.insert("trusted_hash", toml_edit::Value::from("sha256:user"));
        let user_key = "manual/hooks.json:stop:0:0";
        state.insert(user_key, toml_edit::Item::Value(user_entry.into()));
        atomic_write(&config_path, doc.to_string().as_bytes(), Some(0o600)).unwrap();

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        // The hook left hooks.json, so its trust entry must go with it by
        // positional key, regardless of the re-accepted hash value.
        assert!(!fs::read_to_string(&hooks_path).unwrap().contains(COMMAND_MARKER));
        let state = codex_state_table(&context);
        assert!(!state.contains_key(&stop_key), "{state:?}");
        assert_eq!(state.len(), 1, "{state:?}");
        assert!(state.contains_key(user_key));
    }

    #[test]
    fn codex_install_refuses_to_clobber_invalid_or_scalar_hooks_config() {
        for broken in ["not = valid = toml\n", "hooks = true\n"] {
            let root = tempfile::tempdir().unwrap();
            let context = context(root.path());
            let config_path = context.home.join(".codex/config.toml");
            atomic_write(&config_path, broken.as_bytes(), Some(0o600)).unwrap();
            let hooks_path = context.home.join(".codex/hooks.json");
            let custom =
                br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]}]}}"#;
            atomic_write(&hooks_path, custom, Some(0o600)).unwrap();
            let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
            let result = run_with_context(&plan, &context);
            assert!(result.failed, "{broken:?}: {}", result.value);
            assert_eq!(fs::read_to_string(&config_path).unwrap(), broken);
            // The config preflight runs before hooks.json is touched, so a
            // failed install must not leave new untrusted hooks behind.
            assert_eq!(fs::read(&hooks_path).unwrap(), custom, "{broken:?}");
        }
    }

    #[test]
    fn codex_install_preflight_failure_leaves_an_absent_hooks_json_absent() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        atomic_write(&config_path, b"hooks = true\n", Some(0o600)).unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(result.failed, "{}", result.value);
        assert!(!context.home.join(".codex/hooks.json").exists());
    }

    #[test]
    fn codex_uninstall_preflight_failure_leaves_hooks_json_untouched() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let hooks_path = context.home.join(".codex/hooks.json");
        let installed = fs::read(&hooks_path).unwrap();
        let config_path = context.home.join(".codex/config.toml");
        atomic_write(&config_path, b"not = valid = toml\n", Some(0o600)).unwrap();

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(result.failed, "{}", result.value);
        // Removing the hooks while their stale trust entries linger would be a
        // half-applied uninstall; the config preflight must fail first.
        assert_eq!(fs::read(&hooks_path).unwrap(), installed);
        assert_eq!(fs::read_to_string(&config_path).unwrap(), "not = valid = toml\n");
    }

    #[cfg(unix)]
    #[test]
    fn codex_install_edits_the_target_of_a_symlinked_config_toml() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let real = root.path().join("dotfiles/codex-config.toml");
        atomic_write(&real, b"# managed by dotfiles\nmodel = \"gpt-5.6\"\n", Some(0o600)).unwrap();
        let config_path = context.home.join(".codex/config.toml");
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        symlink(&real, &config_path).unwrap();

        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let first = run_with_context(&install, &context);
        assert!(!first.failed, "{}", first.value);
        // The symlink must survive; the trust entries land in its target so
        // codex and the dotfile manager keep seeing one file.
        assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
        let text = fs::read_to_string(&real).unwrap();
        assert!(text.contains("# managed by dotfiles"));
        assert!(text.contains("trusted_hash"));
        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
        let second = run_with_context(&install, &context);
        assert_eq!(second.value["providers"][0]["changed"], Value::Bool(false));

        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let result = run_with_context(&uninstall, &context);
        assert!(!result.failed, "{}", result.value);
        assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
        let text = fs::read_to_string(&real).unwrap();
        assert!(text.contains("# managed by dotfiles"));
        assert!(!text.contains("trusted_hash"));
    }

    #[cfg(unix)]
    #[test]
    fn codex_install_refuses_a_dangling_config_symlink() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        symlink(root.path().join("missing-target.toml"), &config_path).unwrap();

        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(result.failed, "{}", result.value);
        assert!(result.value["errors"][0].as_str().unwrap().contains("does not resolve"));
        // Preflight runs first: no hooks were installed and the link survives.
        assert!(!context.home.join(".codex/hooks.json").exists());
        assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
    }

    #[test]
    fn codex_status_reports_partial_for_an_oversized_config_toml() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

        // Grow config.toml past the cap without writing real data; the status
        // path must reject it from metadata instead of reading it.
        let config_path = context.home.join(".codex/config.toml");
        let file = OpenOptions::new().write(true).open(&config_path).unwrap();
        file.set_len(MAX_CONFIG_BYTES + 1).unwrap();
        drop(file);
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);
    }

    #[test]
    fn codex_status_reports_partial_until_config_toml_trusts_the_hooks() {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

        // codex ignores hooks.json without matching trust state, so a wiped
        // config.toml must demote the report even though hooks.json is intact.
        fs::remove_file(context.home.join(".codex/config.toml")).unwrap();
        let result = run_with_context(&status, &context);
        assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);
    }

    #[cfg(unix)]
    #[test]
    fn codex_home_override_trust_keys_use_the_canonicalized_path() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let mut context = context(root.path());
        let real = root.path().join("codex-home");
        fs::create_dir_all(&real).unwrap();
        let link = root.path().join("codex-home-link");
        symlink(&real, &link).unwrap();
        context.environment.insert("CODEX_HOME".into(), link.clone().into());
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        assert!(link.join("hooks.json").is_file());
        let text = fs::read_to_string(link.join("config.toml")).unwrap();
        let config: toml::Value = toml::from_str(&text).unwrap();
        let state = config["hooks"]["state"].as_table().unwrap();
        // codex canonicalizes an explicit CODEX_HOME before building trust
        // keys, so keys minted against the symlink path would never match.
        let canonical_key = format!(
            "{}:session_start:0:0",
            fs::canonicalize(&real).unwrap().join("hooks.json").display()
        );
        assert!(state.contains_key(&canonical_key), "{text}");
        assert!(!state.keys().any(|key| key.starts_with(&format!("{}", link.display()))), "{text}");
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
        assert_eq!(provider_status(cursor, &config, false).unwrap().0, "partial");
        let plan = Plan { action: Action::Install, providers: vec!["cursor".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(&config).unwrap();
        assert!(text.contains("custom-hook"));
        assert!(!text.contains("cmux-tui-agent-hook"));
        assert_eq!(text.matches(COMMAND_MARKER).count(), CURSOR_EVENTS.len());
        assert_eq!(provider_status(cursor, &config, false).unwrap().0, "installed");
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
        assert_eq!(provider_status(amp, &path, false).unwrap().0, "partial");
        let plan = Plan { action: Action::Install, providers: vec!["amp".into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}", result.value);
        let text = fs::read_to_string(path).unwrap();
        assert!(text.contains(PLUGIN_MARKER));
        assert!(!text.contains("cmux-tui-agent-hook"));
        assert_eq!(
            provider_status(
                amp,
                &context.home.join(".config/amp/plugins/cmux-tui-journal.ts"),
                false
            )
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
        assert_eq!(install_provider(hermes, &path, false).unwrap(), ("installed", true));
        assert!(migrate_hermes_cmux_irc_tee(&path).unwrap());
        assert!(!fs::read_to_string(&irc).unwrap().contains("cmux-tui-cmux-irc"));
        assert!(!migrate_hermes_cmux_irc_tee(&path).unwrap());
        assert_eq!(provider_status(hermes, &path, false).unwrap().0, "installed");
        assert_eq!(install_provider(hermes, &path, false).unwrap(), ("installed", false));
        assert_eq!(uninstall_provider(hermes, &path, false).unwrap(), ("absent", true));
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
