//! `HomeBrainHost` and `ChiefHostStop`: which Chief host may start, how it is launched,
//! what its lock names, and `start`'s order as a step machine.
//!
//! Swift keeps the file checks (`isExecutableFile`), process lookups (`proc_pidpath`),
//! reads, signals and the launch itself.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// `HomeBrainHost.bundledChiefName`.
pub const BUNDLED_CHIEF_NAME: &str = "optchat-chief";
/// `DevTools.nightlyBundleID`.
pub const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";
/// `FilesHost.executableName`.
pub const FILES_HOST_NAME: &str = "cmux-files-host";
/// How long `start` waits for a stopped stale host to exit, in seconds.
pub const STALE_HOST_EXIT_WAIT_SECS: u32 = 15;

/// Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, never newlines.
pub fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

fn is_bundle(bundle: &str, id: &str) -> bool {
    bundle == id || bundle.strip_prefix(id).is_some_and(|rest| rest.starts_with('.'))
}

/// `DevTools.isAvailable(bundleID:isDebugBuild:)`.
pub fn dev_tools_available(bundle_id: Option<&str>, is_debug_build: bool) -> bool {
    if is_debug_build {
        return true;
    }
    bundle_id.is_some_and(|b| is_bundle(trim_ws(b), NIGHTLY_BUNDLE_ID))
}

/// `HomeBrainHost.bundledChiefAllowed(bundleID:isDebugBuild:)`. The caller passes
/// `HomeBrainHost.stableBundleID`: it is Classic's id, which cmux NEXT code names only at
/// its reviewed sites (`check-state-roots.sh`), so Rust takes it rather than spelling it.
pub fn bundled_chief_allowed(
    bundle_id: Option<&str>,
    stable_bundle_id: Option<&str>,
    is_debug_build: bool,
) -> bool {
    if dev_tools_available(bundle_id, is_debug_build) {
        return true;
    }
    match (bundle_id, stable_bundle_id.filter(|s| !s.is_empty())) {
        (Some(b), Some(stable)) => is_bundle(trim_ws(b), stable),
        _ => false,
    }
}

/// `AcpmuxEnvironment.agentLaunchDisabled`.
pub fn agent_launch_disabled(env: &BTreeMap<String, String>) -> bool {
    let launch = env.get("ACPMUX_AGENT_LAUNCH").map(|v| v.trim().to_lowercase());
    let disabled = env.get("CMUX_AGENTS_DISABLED").map(|v| v.trim());
    launch.as_deref() == Some("deny") || disabled == Some("1")
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') { format!("{dir}{name}") } else { format!("{dir}/{name}") }
}

/// The paths `canStart` and `resolve` try, in order; the first executable one is the host.
pub fn host_candidates(
    env: &BTreeMap<String, String>,
    bundled_bin_directory: Option<&str>,
    bundled_chief_allowed: bool,
) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(over) = env.get("CMUX_NEXT_MUX_HOST").filter(|v| !v.is_empty()) {
        out.push(over.clone());
    }
    if bundled_chief_allowed && let Some(bin) = bundled_bin_directory {
        out.push(join(bin, BUNDLED_CHIEF_NAME));
    }
    out
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleRequest {
    pub bundle_id: Option<String>,
    /// `HomeBrainHost.stableBundleID`.
    pub stable_bundle_id: Option<String>,
    #[serde(default)]
    pub is_debug_build: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvRequest {
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentsDisabledReply {
    pub disabled: bool,
    /// `agentsDisabledNotice`: the `HomeStrings.chiefAgentsDisabled` notice to show, by name.
    pub notice: Option<&'static str>,
}

pub fn agents_disabled(r: EnvRequest) -> AgentsDisabledReply {
    let disabled = agent_launch_disabled(&r.environment);
    AgentsDisabledReply { disabled, notice: disabled.then_some("chiefAgentsDisabled") }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvePlanRequest {
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    pub bundled_bin_directory: Option<String>,
    #[serde(default)]
    pub bundled_chief_allowed: bool,
    #[serde(default)]
    pub uses_app_acpmux: bool,
    /// `ChiefHome.acpmuxHome.path`.
    #[serde(default)]
    pub acpmux_home: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ResolvePlanReply {
    /// The kill switch is on: no host (`canStart` false, `resolve` nil).
    pub disabled: bool,
    /// Try these in order; the first executable one is the host. None: no host.
    pub candidates: Vec<String>,
    /// The acpmux environment `resolve` hands `AcpmuxEnvironment.resolve`: set these...
    pub acpmux_set: BTreeMap<String, String>,
    /// ...and drop these.
    pub acpmux_remove: Vec<String>,
}

pub fn resolve_plan(r: ResolvePlanRequest) -> ResolvePlanReply {
    let disabled = agent_launch_disabled(&r.environment);
    let candidates = if disabled {
        Vec::new()
    } else {
        host_candidates(&r.environment, r.bundled_bin_directory.as_deref(), r.bundled_chief_allowed)
    };
    let mut acpmux_set = BTreeMap::new();
    let mut acpmux_remove = Vec::new();
    if !r.uses_app_acpmux {
        acpmux_set.insert("ACPMUX_HOME".to_owned(), r.acpmux_home);
        acpmux_remove.push("ACPMUX_SOCKET".to_owned());
    }
    ResolvePlanReply { disabled, candidates, acpmux_set, acpmux_remove }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArgumentsRequest {
    pub executable: String,
    /// `FilesHost.executable.path` when "cmux Files (dev)" launches the host.
    pub files_host_executable: Option<String>,
    pub daemon_socket: String,
    pub mux_home: String,
}

/// `HomeBrainHost.arguments` (for `/bin/sh`).
pub fn arguments(r: &ArgumentsRequest) -> Vec<String> {
    let mut out: Vec<String> = vec![
        "-c".into(),
        r#"set -m; "$@" >>"$MUX_HOST_LOG" 2>&1 </dev/null & echo "$!""#.into(),
        "mux-host-launch".into(),
    ];
    match &r.files_host_executable {
        Some(files) => out.extend([files.clone(), "run".into(), "--".into(), r.executable.clone()]),
        None => out.push(r.executable.clone()),
    }
    out.extend([
        "host".into(),
        "--daemon-socket".into(),
        r.daemon_socket.clone(),
        "--mux-home".into(),
        r.mux_home.clone(),
    ]);
    out
}

/// `HomeBrainHost.searchPath(home:)`.
pub fn search_path(bundled_bin_directory: Option<&str>, home: &str) -> String {
    let mut parts: Vec<String> = bundled_bin_directory.map(str::to_owned).into_iter().collect();
    parts.extend(["bin", ".local/bin", ".bun/bin", ".cargo/bin"].iter().map(|p| join(home, p)));
    parts.extend(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .iter()
            .map(|p| (*p).to_owned()),
    );
    parts.join(":")
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchPathRequest {
    pub bundled_bin_directory: Option<String>,
    pub home: String,
}

/// The variables `childEnvironment(process:)` copies from the app's own environment.
pub const COPIED_KEYS: &[&str] = &["USER", "TMPDIR", "MUX_HARNESS", "DO_NOT_TRACK"];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentRequest {
    /// The app's process environment.
    #[serde(default)]
    pub process: BTreeMap<String, String>,
    /// The user's home folder.
    pub home: String,
    pub mux_home: String,
    pub bundled_bin_directory: Option<String>,
    /// `HomeChiefName.localUserName`.
    #[serde(default)]
    pub user_name: String,
    /// `HomeStrings.chiefName`.
    #[serde(default)]
    pub chief_title: String,
    /// `ChiefAppLinks.hostEnvironment(...)`.
    #[serde(default)]
    pub app_links: BTreeMap<String, String>,
    /// `acpmux.childEnvironment`, when the host has an acpmux.
    pub acpmux_environment: Option<BTreeMap<String, String>>,
    /// `acpmux.executable.path`.
    pub acpmux_executable: Option<String>,
    #[serde(default)]
    pub uses_app_acpmux: bool,
    /// `DaemonLauncher.buildSpaceKey`.
    pub build_space_key: Option<String>,
    pub bundle_id: Option<String>,
    pub app_version: Option<String>,
}

/// `HomeBrainHost.childEnvironment(process:)`.
pub fn environment(r: EnvironmentRequest) -> BTreeMap<String, String> {
    let mut v = BTreeMap::new();
    v.insert("PATH".to_owned(), search_path(r.bundled_bin_directory.as_deref(), &r.home));
    v.insert("MUX_AGENT_TOKEN_FILE".to_owned(), join(&r.mux_home, "agent-token"));
    v.insert("HOME".to_owned(), r.home.clone());
    v.insert("MUX_HOST_LOG".to_owned(), join(&r.mux_home, "host.log"));
    v.insert("CMUX_CHIEF_HOME".to_owned(), r.mux_home.clone());
    v.insert("MUX_USER_NAME".to_owned(), r.user_name);
    v.insert("MUX_CHIEF_TITLE".to_owned(), r.chief_title);
    v.extend(r.app_links);
    if let Some(acpmux) = r.acpmux_environment {
        v.extend(acpmux);
        if let Some(exe) = r.acpmux_executable {
            v.insert("ACPMUX_BIN".to_owned(), exe);
        }
    }
    if r.uses_app_acpmux {
        v.insert("OPTCHAT_ACPMUX_SUPERVISED".to_owned(), "1".to_owned());
    }
    let copied = COPIED_KEYS.iter().map(|k| (*k).to_owned()).chain(r.build_space_key);
    for key in copied {
        if let Some(value) = r.process.get(&key) {
            v.insert(key, value.clone());
        }
    }
    if let Some(id) = r.bundle_id {
        v.insert("CMUX_CHIEF_APP_BUNDLE_ID".to_owned(), id);
    }
    if let Some(version) = r.app_version {
        v.insert("CMUX_CHIEF_APP_VERSION".to_owned(), version);
    }
    v
}

/// The first line of `state/host.lock` or `state/host.handoff`, as a pid.
pub fn first_line_pid(text: &str) -> Option<i32> {
    let line = text.split('\n').find(|l| !l.is_empty())?;
    trim_ws(line).parse().ok()
}

/// `runningHostPID`'s rule on the lock's text (Swift then checks `isChiefHost(pid)`).
pub fn lock_pid(text: &str) -> Option<i32> {
    first_line_pid(text).filter(|pid| *pid > 1)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LockRequest {
    pub text: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandoffRequest {
    /// `runningHostPID`.
    pub running_pid: Option<i32>,
    /// `state/host.handoff`'s text.
    pub mark: Option<String>,
}

/// `askToHandOffWhenIdle`: the pid to send SIGUSR1, when the mark names the running host.
pub fn handoff_target(r: &HandoffRequest) -> Option<i32> {
    let pid = r.running_pid?;
    (first_line_pid(r.mark.as_deref()?)? == pid).then_some(pid)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessRequest {
    pub path: Option<String>,
    pub process_name: Option<String>,
}

/// `ChiefHostStop.isChiefHost(path:processName:)`.
pub fn is_chief_host(path: Option<&str>, process_name: Option<&str>) -> bool {
    match path {
        Some(path) => path.ends_with(&format!("/{BUNDLED_CHIEF_NAME}")),
        None => process_name == Some(BUNDLED_CHIEF_NAME),
    }
}

/// `ChiefHostStop.isFilesHostLauncher(path:processName:)`.
pub fn is_files_host_launcher(path: Option<&str>, process_name: Option<&str>) -> bool {
    match (path, process_name) {
        (Some(path), Some(_)) => path.ends_with(&format!("/{FILES_HOST_NAME}")),
        _ => false,
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessReply {
    pub is_chief_host: bool,
    pub is_files_host_launcher: bool,
}

/// `AcpmuxQuit.Keep` of `appAcpmuxEndKeep(chiefUsesAppAcpmux:)`.
pub fn app_acpmux_end_keep(chief_uses_app_acpmux: bool) -> &'static str {
    if chief_uses_app_acpmux { "nothing" } else { "chief" }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndKeepRequest {
    #[serde(default)]
    pub chief_uses_app_acpmux: bool,
}

// MARK: start

/// Where `HomeBrainHost.start` is.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StartPhase {
    #[default]
    Idle,
    Adopting,
    EnsuringAppAcpmux,
    MovingToAppAcpmux,
    LeavingAppAcpmux,
    HandingOff,
    StoppingStale,
    WaitingForStaleExit,
    CheckingToken,
    Minting,
    Launching,
    Marking,
    ReadingLock,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeKind {
    ReusedRunningHost,
    Launched,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartOutcome {
    pub kind: OutcomeKind,
    pub pid: Option<i32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StartState {
    pub phase: StartPhase,
    pub uses_app_acpmux: bool,
    /// The host has an `AcpmuxEnvironment`.
    pub has_acpmux: bool,
    /// The outcome `readLock` completes (reused, or the launch's pid to mark).
    pub pending: Option<OutcomeKind>,
    pub launched_pid: Option<i32>,
    pub outcome: Option<StartOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StartEvent {
    #[serde(rename_all = "camelCase")]
    Begin {
        #[serde(default)]
        uses_app_acpmux: bool,
        #[serde(default)]
        has_acpmux: bool,
    },
    /// The last effect finished (`adoptBuildHomes`, `ensureAppAcpmux`, `markPid`).
    Done,
    /// `ChiefAppAcpmuxMove.run()` or `leaveAppAcpmux` answered.
    #[serde(rename_all = "camelCase")]
    Moved { ok: bool },
    /// `handOffIfStale` answered.
    #[serde(rename_all = "camelCase")]
    HandOff { stale: bool },
    /// `ChiefHostStop.stop` answered.
    #[serde(rename_all = "camelCase")]
    Stopped { pid: Option<i32> },
    /// `runningHostHasToken` answered.
    #[serde(rename_all = "camelCase")]
    Token { has_token: bool },
    /// `launch(agentToken:)` answered.
    #[serde(rename_all = "camelCase")]
    Launched { pid: Option<i32> },
    /// `runningHostPID` answered.
    #[serde(rename_all = "camelCase")]
    LockRead { pid: Option<i32> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StartEffect {
    AdoptBuildHomes,
    EnsureAppAcpmux,
    RunAppAcpmuxMove,
    LeaveAppAcpmux,
    /// `AcpmuxChiefHandoff.handOffIfStale(waitFor: askToHandOffWhenIdle != nil)`.
    HandOffIfStale,
    StopHost,
    #[serde(rename_all = "camelCase")]
    WaitForExit {
        pid: i32,
        seconds: u32,
    },
    CheckToken,
    /// `mintToken()` then `launch(agentToken:)`; send `launched`.
    MintAndLaunch,
    ReadLock,
    #[serde(rename_all = "camelCase")]
    MarkPid {
        pid: i32,
    },
    /// `start` returns this.
    #[serde(rename_all = "camelCase")]
    Finish {
        outcome: StartOutcome,
    },
}

fn finish(s: &mut StartState, kind: OutcomeKind, pid: Option<i32>) -> Vec<StartEffect> {
    let outcome = StartOutcome { kind, pid };
    s.phase = StartPhase::Done;
    s.pending = None;
    s.outcome = Some(outcome);
    vec![StartEffect::Finish { outcome }]
}

fn reuse_by_lock(s: &mut StartState) -> Vec<StartEffect> {
    s.phase = StartPhase::ReadingLock;
    s.pending = Some(OutcomeKind::ReusedRunningHost);
    vec![StartEffect::ReadLock]
}

fn check_token(s: &mut StartState) -> Vec<StartEffect> {
    s.phase = StartPhase::CheckingToken;
    vec![StartEffect::CheckToken]
}

fn mark_or_finish(s: &mut StartState, pid: Option<i32>) -> Vec<StartEffect> {
    s.launched_pid = pid;
    if !(s.uses_app_acpmux && s.has_acpmux) {
        return finish(s, OutcomeKind::Launched, pid);
    }
    match pid {
        Some(pid) => {
            s.phase = StartPhase::Marking;
            vec![StartEffect::MarkPid { pid }]
        }
        None => {
            s.phase = StartPhase::ReadingLock;
            s.pending = Some(OutcomeKind::Launched);
            vec![StartEffect::ReadLock]
        }
    }
}

/// One step of `HomeBrainHost.start`. An event that does not fit the phase changes nothing.
pub fn start_step(mut s: StartState, event: StartEvent) -> (StartState, Vec<StartEffect>) {
    use StartPhase as P;
    let fx = match (s.phase, event) {
        (_, StartEvent::Begin { uses_app_acpmux, has_acpmux }) => {
            s = StartState {
                phase: P::Adopting,
                uses_app_acpmux,
                has_acpmux,
                ..StartState::default()
            };
            vec![StartEffect::AdoptBuildHomes]
        }
        (P::Adopting, StartEvent::Done) => {
            if s.uses_app_acpmux && s.has_acpmux {
                s.phase = P::EnsuringAppAcpmux;
                vec![StartEffect::EnsureAppAcpmux]
            } else if s.uses_app_acpmux {
                check_token(&mut s)
            } else {
                s.phase = P::LeavingAppAcpmux;
                vec![StartEffect::LeaveAppAcpmux]
            }
        }
        (P::EnsuringAppAcpmux, StartEvent::Done) => {
            s.phase = P::MovingToAppAcpmux;
            vec![StartEffect::RunAppAcpmuxMove]
        }
        (P::MovingToAppAcpmux | P::LeavingAppAcpmux, StartEvent::Moved { ok: false }) => {
            reuse_by_lock(&mut s)
        }
        (P::MovingToAppAcpmux, StartEvent::Moved { ok: true }) => check_token(&mut s),
        (P::LeavingAppAcpmux, StartEvent::Moved { ok: true }) => {
            if s.has_acpmux {
                s.phase = P::HandingOff;
                vec![StartEffect::HandOffIfStale]
            } else {
                check_token(&mut s)
            }
        }
        (P::HandingOff, StartEvent::HandOff { stale: true }) => {
            s.phase = P::StoppingStale;
            vec![StartEffect::StopHost]
        }
        (P::HandingOff, StartEvent::HandOff { stale: false })
        | (P::StoppingStale, StartEvent::Stopped { pid: None })
        | (P::WaitingForStaleExit, StartEvent::Done) => check_token(&mut s),
        (P::StoppingStale, StartEvent::Stopped { pid: Some(pid) }) => {
            s.phase = P::WaitingForStaleExit;
            vec![StartEffect::WaitForExit { pid, seconds: STALE_HOST_EXIT_WAIT_SECS }]
        }
        (P::CheckingToken, StartEvent::Token { has_token: true }) => reuse_by_lock(&mut s),
        (P::CheckingToken, StartEvent::Token { has_token: false }) => {
            s.phase = P::Minting;
            vec![StartEffect::MintAndLaunch]
        }
        (P::Minting | P::Launching, StartEvent::Launched { pid }) => mark_or_finish(&mut s, pid),
        (P::Marking, StartEvent::Done) => {
            let pid = s.launched_pid;
            finish(&mut s, OutcomeKind::Launched, pid)
        }
        (P::ReadingLock, StartEvent::LockRead { pid }) => match s.pending {
            Some(OutcomeKind::ReusedRunningHost) => {
                finish(&mut s, OutcomeKind::ReusedRunningHost, pid)
            }
            Some(OutcomeKind::Launched) => match pid {
                Some(pid) => {
                    s.phase = P::Marking;
                    s.pending = None;
                    vec![StartEffect::MarkPid { pid }]
                }
                None => finish(&mut s, OutcomeKind::Launched, None),
            },
            None => Vec::new(),
        },
        _ => Vec::new(),
    };
    (s, fx)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartStepRequest {
    #[serde(default)]
    pub state: StartState,
    pub event: StartEvent,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartStepReply {
    pub state: StartState,
    pub effects: Vec<StartEffect>,
}
