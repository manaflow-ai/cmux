//! Vercel agent-browser provider adapter for cmux-browser-owned sessions.
//!
//! The adapter is an out-of-process `agent-browser.plugin.v1` provider. It
//! resolves the invoking terminal's canonical workspace through the trusted
//! local mux socket, then returns a page-scoped CDP URL for one browser tab in
//! that workspace. Browser automation remains entirely in agent-browser.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow};
use cmux_tui_core::SurfaceOptions;
use serde_json::{Value, json};

const PLUGIN_PROTOCOL: &str = "agent-browser.plugin.v1";
const PLUGIN_NAME: &str = "cmux";
const PROVIDER_CAPABILITY: &str = "browser.provider";
const REQUEST_LIMIT: u64 = 1024 * 1024;
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
const RESOLUTION_TIMEOUT: Duration = Duration::from_secs(5);
const SOCKET_TIMEOUT: Duration = Duration::from_secs(2);

const INTEGRATION_MARKER: &str = "CMUX_TUI_AGENT_BROWSER_PROVIDER";
const EXACT_TAB_ENV: [&str; 2] = ["CMUX_TUI_BROWSER_TAB_ID", "CMUX_BROWSER_TAB_ID"];
const WORKSPACE_ENV: [&str; 1] = ["CMUX_TUI_WORKSPACE_ID"];

pub(crate) fn configure_surface_options(options: &mut SurfaceOptions) -> anyhow::Result<()> {
    let executable = std::env::current_exe()
        .context("cannot resolve the cmux-tui executable for agent-browser")?;
    let executable = executable.canonicalize().unwrap_or(executable).to_string_lossy().into_owned();

    let mut plugins = inherited_plugins();
    plugins.retain(|plugin| plugin.get("name").and_then(Value::as_str) != Some(PLUGIN_NAME));
    plugins.push(json!({
        "name": PLUGIN_NAME,
        "command": executable,
        "args": ["__agent-browser-provider"],
        "capabilities": [PROVIDER_CAPABILITY],
    }));

    set_extra_env(options, INTEGRATION_MARKER, "1");
    set_extra_env(options, "AGENT_BROWSER_PROVIDER", PLUGIN_NAME);
    set_extra_env(options, "AGENT_BROWSER_PLUGINS", &serde_json::to_string(&plugins)?);
    Ok(())
}

fn inherited_plugins() -> Vec<Value> {
    std::env::var("AGENT_BROWSER_PLUGINS")
        .ok()
        .and_then(|raw| serde_json::from_str::<Vec<Value>>(&raw).ok())
        .unwrap_or_default()
        .into_iter()
        .filter(Value::is_object)
        .collect()
}

fn set_extra_env(options: &mut SurfaceOptions, key: &str, value: &str) {
    if let Some((_, current)) = options.extra_env.iter_mut().find(|(candidate, _)| candidate == key)
    {
        *current = value.to_string();
    } else {
        options.extra_env.push((key.to_string(), value.to_string()));
    }
}

pub(crate) fn run() -> i32 {
    let response = match read_plugin_request().and_then(handle_plugin_request) {
        Ok(response) => response,
        Err(error) => json!({
            "protocol": PLUGIN_PROTOCOL,
            "success": false,
            "error": error.to_string(),
        }),
    };
    let mut stdout = std::io::stdout().lock();
    if serde_json::to_writer(&mut stdout, &response).is_err() || stdout.flush().is_err() {
        return 1;
    }
    0
}

fn read_plugin_request() -> anyhow::Result<Value> {
    let mut bytes = Vec::new();
    std::io::stdin().lock().take(REQUEST_LIMIT + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= REQUEST_LIMIT, "plugin request exceeds 1 MiB");
    serde_json::from_slice(&bytes).context("plugin request is not valid JSON")
}

fn handle_plugin_request(request: Value) -> anyhow::Result<Value> {
    anyhow::ensure!(
        request.get("protocol").and_then(Value::as_str) == Some(PLUGIN_PROTOCOL),
        "unsupported plugin protocol"
    );
    match request.get("type").and_then(Value::as_str) {
        Some("plugin.manifest") => Ok(json!({
            "protocol": PLUGIN_PROTOCOL,
            "success": true,
            "manifest": {
                "name": PLUGIN_NAME,
                "capabilities": [PROVIDER_CAPABILITY],
                "description": "Attach agent-browser to the caller's cmux-browser workspace",
            },
        })),
        Some("browser.launch") => browser_launch_response(&request),
        Some("browser.close") => Ok(json!({
            "protocol": PLUGIN_PROTOCOL,
            "success": true,
            "data": {},
        })),
        Some(other) => Err(anyhow!("unsupported plugin request type {other:?}")),
        None => Err(anyhow!("plugin request has no type")),
    }
}

fn browser_launch_response(request: &Value) -> anyhow::Result<Value> {
    let socket = resolve_socket()?;
    let scope = ProviderScope::from_request(request);
    let deadline = Instant::now() + RESOLUTION_TIMEOUT;
    let mut last_error = anyhow!("cmux-browser provider is not attached");
    let mut delay = Duration::from_millis(25);
    loop {
        match resolve_page_target(&socket, &scope, deadline) {
            Ok(resolved) => {
                return Ok(json!({
                    "protocol": PLUGIN_PROTOCOL,
                    "success": true,
                    "browser": {
                        "cdpUrl": resolved.page_url,
                        "directPage": true,
                        "metadata": {
                            "providerId": resolved.provider_id,
                            "providerRevision": resolved.provider_revision,
                            "workspaceId": resolved.workspace_id,
                            "tabId": resolved.tab_id,
                            "targetId": resolved.target_id,
                            "selection": resolved.selection,
                        },
                    },
                }));
            }
            Err(error) => last_error = error,
        }
        if Instant::now() >= deadline {
            return Err(last_error);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(last_error);
        }
        std::thread::sleep(delay.min(remaining));
        delay = (delay * 2).min(Duration::from_millis(250));
    }
}

fn resolve_socket() -> anyhow::Result<PathBuf> {
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(value) = std::env::var_os(name).filter(|value| !value.is_empty()) {
            return Ok(PathBuf::from(value));
        }
    }
    Err(anyhow!(
        "no cmux-tui socket is in this environment; run agent-browser inside a cmux terminal"
    ))
}

#[derive(Debug, Default)]
struct ProviderScope {
    exact_tab: Option<String>,
    workspace: Option<String>,
    terminal: Option<String>,
    session_hint: Option<String>,
}

impl ProviderScope {
    fn from_request(request: &Value) -> Self {
        Self {
            exact_tab: first_environment(&EXACT_TAB_ENV),
            workspace: first_environment(&WORKSPACE_ENV),
            terminal: std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|value| !value.is_empty()),
            session_hint: request
                .pointer("/request/session")
                .and_then(Value::as_str)
                .filter(|value| *value != "default" && !value.is_empty())
                .map(str::to_string),
        }
    }
}

fn first_environment(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

struct ResolvedPageTarget {
    page_url: String,
    provider_id: String,
    provider_revision: u64,
    workspace_id: String,
    tab_id: String,
    target_id: String,
    selection: &'static str,
}

fn resolve_page_target(
    socket: &Path,
    scope: &ProviderScope,
    deadline: Instant,
) -> anyhow::Result<ResolvedPageTarget> {
    let mut control = MuxControl::connect(socket, deadline)?;
    let topology = control.request(1, json!({"id":1,"cmd":"list-workspaces"}), deadline)?;
    let provider = control.request(2, json!({"id":2,"cmd":"get-browser-provider"}), deadline)?;
    let confirmed_topology =
        control.request(3, json!({"id":3,"cmd":"list-workspaces"}), deadline)?;
    let confirmed_provider =
        control.request(4, json!({"id":4,"cmd":"get-browser-provider"}), deadline)?;
    ensure_stable_resolution(&topology, &provider, &confirmed_topology, &confirmed_provider)?;
    resolve_page_target_snapshot(&topology, &provider, scope)
}

#[derive(Debug, PartialEq, Eq)]
struct ResolutionFence {
    registry_id: String,
    generation: String,
    workspace_revision: u64,
    pane_revision: u64,
    terminal_revision: u64,
    provider_revision: u64,
}

impl ResolutionFence {
    fn from_snapshots(topology: &Value, provider: &Value) -> anyhow::Result<Self> {
        Ok(Self {
            registry_id: required_string(topology, "registry_id", "workspace snapshot")?,
            generation: required_string(topology, "generation", "workspace snapshot")?,
            workspace_revision: required_u64(topology, "workspace_revision", "workspace snapshot")?,
            pane_revision: required_u64(topology, "pane_revision", "workspace snapshot")?,
            terminal_revision: required_u64(topology, "terminal_revision", "workspace snapshot")?,
            provider_revision: required_u64(provider, "revision", "browser provider snapshot")?,
        })
    }
}

fn ensure_stable_resolution(
    topology: &Value,
    provider: &Value,
    confirmed_topology: &Value,
    confirmed_provider: &Value,
) -> anyhow::Result<()> {
    let first = ResolutionFence::from_snapshots(topology, provider)?;
    let confirmed = ResolutionFence::from_snapshots(confirmed_topology, confirmed_provider)?;
    anyhow::ensure!(
        first == confirmed,
        "cmux topology or browser provider changed during target resolution"
    );
    Ok(())
}

fn required_string(value: &Value, key: &str, source: &str) -> anyhow::Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("{source} omitted {key}"))
}

fn required_u64(value: &Value, key: &str, source: &str) -> anyhow::Result<u64> {
    value.get(key).and_then(Value::as_u64).ok_or_else(|| anyhow!("{source} omitted {key}"))
}

fn resolve_page_target_snapshot(
    topology: &Value,
    provider: &Value,
    scope: &ProviderScope,
) -> anyhow::Result<ResolvedPageTarget> {
    anyhow::ensure!(
        provider.get("available").and_then(Value::as_bool) == Some(true),
        "cmux-browser is not attached to this cmux-tui session"
    );
    anyhow::ensure!(
        provider.get("authentication").and_then(Value::as_str) == Some("none"),
        "agent-browser direct-page mode does not support bearer-authenticated CDP endpoints"
    );

    let targets = provider
        .get("targets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|target| {
            Some((
                target.get("tab_id")?.as_str()?.to_string(),
                target.get("target_id")?.as_str()?.to_string(),
            ))
        })
        .collect::<BTreeMap<_, _>>();
    anyhow::ensure!(!targets.is_empty(), "cmux-browser has not published any browser tabs yet");
    let selected = select_workspace_target(topology, &targets, scope)?;
    let endpoint = provider
        .get("endpoint")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cmux-browser provider omitted its CDP endpoint"))?;
    Ok(ResolvedPageTarget {
        page_url: direct_page_url(endpoint, &selected.target_id)?,
        provider_id: provider
            .get("provider_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        provider_revision: required_u64(provider, "revision", "browser provider snapshot")?,
        workspace_id: selected.workspace_id,
        tab_id: selected.tab_id,
        target_id: selected.target_id,
        selection: selected.selection,
    })
}

struct SelectedTarget {
    workspace_id: String,
    tab_id: String,
    target_id: String,
    selection: &'static str,
}

#[derive(Clone)]
struct Candidate {
    workspace_id: String,
    workspace_keys: Vec<String>,
    screen_index: usize,
    pane_index: usize,
    tab_id: String,
    target_id: String,
}

fn select_workspace_target(
    topology: &Value,
    targets: &BTreeMap<String, String>,
    scope: &ProviderScope,
) -> anyhow::Result<SelectedTarget> {
    let workspaces = topology
        .get("workspaces")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("cmux-tui returned an invalid workspace snapshot"))?;
    let mut candidates = Vec::new();
    let mut terminal_location = None;
    let mut terminal_location_is_ambiguous = false;
    let terminal_workspace_hint = scope.workspace.as_ref();
    for (workspace_index, workspace) in workspaces.iter().enumerate() {
        let workspace_id = stable_string(workspace, "resource_id")
            .or_else(|| stable_string(workspace, "key"))
            .unwrap_or_else(|| workspace_index.to_string());
        let workspace_keys = ["resource_id", "key", "id", "short_id"]
            .into_iter()
            .filter_map(|key| stable_string(workspace, key))
            .collect::<Vec<_>>();
        for (screen_index, screen) in
            workspace.get("screens").and_then(Value::as_array).into_iter().flatten().enumerate()
        {
            for (pane_index, pane) in
                screen.get("panes").and_then(Value::as_array).into_iter().flatten().enumerate()
            {
                for tab in pane.get("tabs").and_then(Value::as_array).into_iter().flatten() {
                    let terminal_ids = [
                        stable_string(tab, "terminal_resource_id"),
                        stable_string(tab, "terminal_id"),
                        stable_string(tab, "content_resource_id"),
                    ]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
                    if scope
                        .terminal
                        .as_ref()
                        .is_some_and(|terminal| terminal_ids.iter().any(|value| value == terminal))
                        && terminal_workspace_hint.is_none_or(|workspace_hint| {
                            workspace_keys.iter().any(|key| key == workspace_hint)
                        })
                    {
                        let location = (workspace_index, screen_index, pane_index);
                        if terminal_location.is_some_and(|existing| existing != location) {
                            terminal_location_is_ambiguous = true;
                        } else {
                            terminal_location = Some(location);
                        }
                    }
                    if tab.get("kind").and_then(Value::as_str) != Some("browser") {
                        continue;
                    }
                    let Some(tab_id) = stable_string(tab, "tab_resource_id") else { continue };
                    let Some(target_id) = targets.get(&tab_id).cloned() else { continue };
                    candidates.push((
                        workspace_index,
                        Candidate {
                            workspace_id: workspace_id.clone(),
                            workspace_keys: workspace_keys.clone(),
                            screen_index,
                            pane_index,
                            tab_id,
                            target_id,
                        },
                    ));
                }
            }
        }
    }

    if let Some(exact_tab) = scope.exact_tab.as_deref() {
        let (_, candidate) = candidates
            .iter()
            .find(|(_, candidate)| candidate.tab_id == exact_tab)
            .ok_or_else(|| anyhow!("requested cmux browser tab {exact_tab:?} is not available"))?;
        return Ok(selected(candidate, "exact-tab"));
    }

    anyhow::ensure!(
        !terminal_location_is_ambiguous,
        "the caller terminal has multiple cmux placements; set CMUX_TUI_WORKSPACE_ID or CMUX_TUI_BROWSER_TAB_ID"
    );

    if let Some((workspace_index, screen_index, pane_index)) = terminal_location {
        let (_, candidate) = candidates
            .iter()
            .find(|(index, candidate)| {
                *index == workspace_index
                    && candidate.screen_index == screen_index
                    && candidate.pane_index == pane_index
            })
            .or_else(|| {
                candidates.iter().find(|(index, candidate)| {
                    *index == workspace_index && candidate.screen_index == screen_index
                })
            })
            .or_else(|| candidates.iter().find(|(index, _)| *index == workspace_index))
            .ok_or_else(|| anyhow!("the caller's cmux workspace has no published browser tab"))?;
        return Ok(selected(candidate, "terminal-workspace"));
    }

    if let Some(workspace_hint) = scope.workspace.as_ref().or(scope.session_hint.as_ref()) {
        let (_, candidate) = candidates
            .iter()
            .find(|(_, candidate)| candidate.workspace_keys.iter().any(|key| key == workspace_hint))
            .ok_or_else(|| {
                anyhow!("cmux workspace {workspace_hint:?} has no published browser tab")
            })?;
        return Ok(selected(candidate, "workspace"));
    }

    if candidates.len() == 1 {
        return Ok(selected(&candidates[0].1, "only-browser-tab"));
    }
    Err(anyhow!(
        "cannot infer a cmux workspace for agent-browser; run it inside a cmux terminal or set CMUX_TUI_BROWSER_TAB_ID"
    ))
}

fn selected(candidate: &Candidate, selection: &'static str) -> SelectedTarget {
    SelectedTarget {
        workspace_id: candidate.workspace_id.clone(),
        tab_id: candidate.tab_id.clone(),
        target_id: candidate.target_id.clone(),
        selection,
    }
}

fn stable_string(value: &Value, key: &str) -> Option<String> {
    match value.get(key)? {
        Value::String(value) if !value.is_empty() => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn direct_page_url(endpoint: &str, target_id: &str) -> anyhow::Result<String> {
    let mut url = url::Url::parse(endpoint).context("cmux-browser returned an invalid CDP URL")?;
    anyhow::ensure!(url.scheme() == "ws", "cmux-browser CDP URL must use ws://");
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| anyhow!("cmux-browser returned a non-hierarchical CDP URL"))?;
        segments.clear().push("devtools").push("page").push(target_id);
    }
    Ok(url.into())
}

struct MuxControl {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl MuxControl {
    fn connect(socket: &Path, deadline: Instant) -> anyhow::Result<Self> {
        let remaining = remaining_resolution_time(deadline)?;
        let socket = socket.to_path_buf();
        let display = socket.display().to_string();
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let connector = std::thread::Builder::new()
            .name("agent-browser-provider-connect".into())
            .spawn(move || {
            let _ = sender.send(UnixStream::connect(socket));
        })?;
        let stream = match receiver.recv_timeout(remaining) {
            Ok(result) => {
                let _ = connector.join();
                result.with_context(|| format!("cannot connect to cmux-tui socket {display}"))?
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = connector.join();
                return Err(anyhow!("cmux-tui socket connector stopped without a result"));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                // This provider is a short-lived process. The outer loop has
                // reached its shared final deadline, so returning ends the
                // process and terminates the blocked connector thread.
                drop(connector);
                return Err(anyhow!("cmux-browser target resolution timed out"));
            }
        };
        let timeout = remaining_socket_timeout(deadline)?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        Ok(Self { writer: stream.try_clone()?, reader: BufReader::new(stream) })
    }

    fn request(&mut self, id: u64, request: Value, deadline: Instant) -> anyhow::Result<Value> {
        let mut encoded = serde_json::to_vec(&request)?;
        encoded.push(b'\n');
        write_control_request(&mut self.writer, &encoded, deadline)?;
        let line = read_control_line(&mut self.reader, deadline, RESPONSE_LIMIT)?;
        let response: Value = serde_json::from_slice(&line).context("invalid cmux-tui response")?;
        anyhow::ensure!(
            response.get("id").and_then(Value::as_u64) == Some(id),
            "cmux-tui response id mismatch"
        );
        anyhow::ensure!(
            response.get("ok").and_then(Value::as_bool) == Some(true),
            "cmux-tui rejected provider lookup: {}",
            response.get("error").and_then(Value::as_str).unwrap_or("unknown error")
        );
        response.get("data").cloned().ok_or_else(|| anyhow!("cmux-tui response omitted data"))
    }
}

fn remaining_socket_timeout(deadline: Instant) -> anyhow::Result<Duration> {
    Ok(remaining_resolution_time(deadline)?.min(SOCKET_TIMEOUT))
}

fn remaining_resolution_time(deadline: Instant) -> anyhow::Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    anyhow::ensure!(!remaining.is_zero(), "cmux-browser target resolution timed out");
    Ok(remaining)
}

fn write_control_request(
    writer: &mut UnixStream,
    encoded: &[u8],
    deadline: Instant,
) -> anyhow::Result<()> {
    let mut offset = 0;
    while offset < encoded.len() {
        writer.set_write_timeout(Some(remaining_socket_timeout(deadline)?))?;
        match writer.write(&encoded[offset..]) {
            Ok(0) => return Err(std::io::Error::from(std::io::ErrorKind::WriteZero).into()),
            Ok(written) => offset += written,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    loop {
        writer.set_write_timeout(Some(remaining_socket_timeout(deadline)?))?;
        match writer.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
}

fn read_control_line(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    limit: usize,
) -> anyhow::Result<Vec<u8>> {
    let mut line = Vec::new();
    loop {
        reader.get_ref().set_read_timeout(Some(remaining_socket_timeout(deadline)?))?;
        let available = reader.fill_buf()?;
        anyhow::ensure!(!available.is_empty(), "cmux-tui closed its control socket");
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |newline| newline + 1);
        anyhow::ensure!(
            line.len().saturating_add(consumed) <= limit,
            "cmux-tui response exceeds 16 MiB"
        );
        let complete = available[consumed - 1] == b'\n';
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if complete {
            return Ok(line);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn topology() -> Value {
        json!({
            "registry_id": "registry-one",
            "generation": "generation-one",
            "workspace_revision": 11,
            "pane_revision": 12,
            "terminal_revision": 13,
            "workspaces": [
                {
                    "resource_id": "ws_one",
                    "key": "workspace-one",
                    "screens": [{"panes": [
                        {"tabs": [
                            {"kind":"pty","terminal_resource_id":"term_one","tab_resource_id":"tab_terminal"},
                            {"kind":"browser","tab_resource_id":"tab_same_pane"}
                        ]},
                        {"tabs": [{"kind":"browser","tab_resource_id":"tab_other_pane"}]}
                    ]}]
                },
                {
                    "resource_id": "ws_two",
                    "key": "workspace-two",
                    "screens": [{"panes": [{"tabs": [
                        {"kind":"pty","terminal_resource_id":"term_two","tab_resource_id":"tab_terminal_two"},
                        {"kind":"browser","tab_resource_id":"tab_two"}
                    ]}]}]
                }
            ]
        })
    }

    fn provider() -> Value {
        json!({
            "available": true,
            "provider_id": "provider-one",
            "endpoint": "ws://127.0.0.1:9222/devtools/browser/browser-one",
            "authentication": "none",
            "revision": 17,
            "targets": [
                {"tab_id":"tab_same_pane","target_id":"target-one"},
                {"tab_id":"tab_other_pane","target_id":"target-other"},
                {"tab_id":"tab_two","target_id":"target-two"}
            ]
        })
    }

    fn targets() -> BTreeMap<String, String> {
        [
            ("tab_same_pane", "target-one"),
            ("tab_other_pane", "target-other"),
            ("tab_two", "target-two"),
        ]
        .into_iter()
        .map(|(tab, target)| (tab.to_string(), target.to_string()))
        .collect()
    }

    #[test]
    fn caller_terminal_selects_same_pane_without_using_active_state() {
        let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };
        let selected = select_workspace_target(&topology(), &targets(), &scope).unwrap();
        assert_eq!(selected.tab_id, "tab_same_pane");
        assert_eq!(selected.selection, "terminal-workspace");
    }

    #[test]
    fn trusted_terminal_is_not_constrained_by_a_session_name() {
        let scope = ProviderScope {
            terminal: Some("term_one".into()),
            session_hint: Some("unrelated-outer-session".into()),
            ..Default::default()
        };

        let selected = select_workspace_target(&topology(), &targets(), &scope).unwrap();

        assert_eq!(selected.tab_id, "tab_same_pane");
        assert_eq!(selected.selection, "terminal-workspace");
    }

    #[test]
    fn workspace_and_exact_tab_scopes_are_deterministic() {
        let workspace =
            ProviderScope { workspace: Some("workspace-two".into()), ..Default::default() };
        assert_eq!(
            select_workspace_target(&topology(), &targets(), &workspace).unwrap().tab_id,
            "tab_two"
        );
        let exact =
            ProviderScope { exact_tab: Some("tab_other_pane".into()), ..Default::default() };
        assert_eq!(
            select_workspace_target(&topology(), &targets(), &exact).unwrap().target_id,
            "target-other"
        );
    }

    #[test]
    fn mirrored_terminal_uses_the_callers_workspace_placement() {
        let mut topology = topology();
        topology["workspaces"][1]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"] =
            json!("term_one");
        let scope = ProviderScope {
            workspace: Some("workspace-one".into()),
            terminal: Some("term_one".into()),
            ..Default::default()
        };

        let selected = select_workspace_target(&topology, &targets(), &scope).unwrap();

        assert_eq!(selected.workspace_id, "ws_one");
        assert_eq!(selected.tab_id, "tab_same_pane");
        assert_eq!(selected.selection, "terminal-workspace");
    }

    #[test]
    fn mirrored_terminal_without_a_workspace_scope_is_rejected() {
        let mut topology = topology();
        topology["workspaces"][1]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"] =
            json!("term_one");
        let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };

        let error = select_workspace_target(&topology, &targets(), &scope)
            .err()
            .expect("an unscoped mirrored terminal must be ambiguous");

        assert!(error.to_string().contains("multiple cmux placements"));
        assert!(error.to_string().contains("CMUX_TUI_BROWSER_TAB_ID"));
    }

    #[test]
    fn stable_topology_and_provider_revisions_allow_target_resolution() {
        ensure_stable_resolution(&topology(), &provider(), &topology(), &provider()).unwrap();
        let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };

        let resolved = resolve_page_target_snapshot(&topology(), &provider(), &scope).unwrap();

        assert_eq!(resolved.tab_id, "tab_same_pane");
        assert_eq!(resolved.provider_revision, 17);
    }

    #[test]
    fn changing_topology_or_provider_revision_retries_resolution() {
        let mut changed_topology = topology();
        changed_topology["pane_revision"] = json!(13);
        let error =
            ensure_stable_resolution(&topology(), &provider(), &changed_topology, &provider())
                .unwrap_err();
        assert!(error.to_string().contains("changed during target resolution"));

        let mut changed_provider = provider();
        changed_provider["revision"] = json!(18);
        let error =
            ensure_stable_resolution(&topology(), &provider(), &topology(), &changed_provider)
                .unwrap_err();
        assert!(error.to_string().contains("changed during target resolution"));
    }

    #[test]
    fn direct_page_url_preserves_gateway_query_and_escapes_target() {
        assert_eq!(
            direct_page_url(
                "ws://127.0.0.1:9222/devtools/browser/browser-id?gateway=one",
                "target/with space"
            )
            .unwrap(),
            "ws://127.0.0.1:9222/devtools/page/target%2Fwith%20space?gateway=one"
        );
    }

    #[test]
    fn control_response_limit_is_enforced_while_streaming() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        let writer = std::thread::spawn(move || writer.write_all(b"12345678\n").unwrap());
        let error = read_control_line(
            &mut BufReader::new(reader),
            Instant::now() + Duration::from_secs(1),
            8,
        )
        .unwrap_err();
        writer.join().unwrap();

        assert!(error.to_string().contains("response exceeds 16 MiB"));
    }

    #[test]
    fn manifest_does_not_touch_the_mux_socket() {
        let response = handle_plugin_request(json!({
            "protocol": PLUGIN_PROTOCOL,
            "type": "plugin.manifest",
            "capability": "plugin.manifest",
            "request": {}
        }))
        .unwrap();
        assert_eq!(response["success"], true);
        assert_eq!(response["manifest"]["name"], PLUGIN_NAME);
    }
}
