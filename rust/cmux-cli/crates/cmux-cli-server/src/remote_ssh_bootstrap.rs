use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use tokio::process::Command;

use crate::remote_daemon_manifest::RemoteDaemonMetadata;

const REMOTE_OS_MARKER: &str = "__CMUX_REMOTE_OS__=";
const REMOTE_ARCH_MARKER: &str = "__CMUX_REMOTE_ARCH__=";
const REMOTE_EXISTS_MARKER: &str = "__CMUX_REMOTE_EXISTS__=";

#[derive(Debug, Clone)]
pub(crate) struct RemoteSshBootstrapConfig {
    pub(crate) destination: String,
    pub(crate) port: Option<u16>,
    pub(crate) identity_file: Option<String>,
    pub(crate) ssh_options: Vec<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteSshBootstrapResult {
    pub(crate) version: String,
    pub(crate) target_goos: String,
    pub(crate) target_goarch: String,
    pub(crate) local_binary_path: String,
    pub(crate) remote_path: String,
    pub(crate) uploaded: bool,
    pub(crate) hello: RemoteDaemonHello,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonHello {
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) capabilities: Vec<String>,
}

struct RemoteBootstrapState {
    go_os: String,
    go_arch: String,
    binary_exists: bool,
}

pub(crate) async fn bootstrap_remote_daemon(
    metadata: &RemoteDaemonMetadata,
    config: &RemoteSshBootstrapConfig,
) -> Result<RemoteSshBootstrapResult> {
    let version = metadata.bootstrap_version();
    let bootstrap_state = probe_remote_bootstrap_state(config, &version).await?;
    let remote_path = RemoteDaemonMetadata::remote_path(
        &version,
        &bootstrap_state.go_os,
        &bootstrap_state.go_arch,
    );
    let local_binary_path = metadata
        .bootstrap_plan(Some(&bootstrap_state.go_os), Some(&bootstrap_state.go_arch))
        .local_binary_path;

    let mut uploaded = false;
    let had_existing_binary = bootstrap_state.binary_exists;
    if !had_existing_binary {
        let local_binary = metadata
            .local_binary_for_platform(&bootstrap_state.go_os, &bootstrap_state.go_arch, &version)
            .await?;
        upload_remote_daemon_binary(config, &local_binary, &remote_path).await?;
        uploaded = true;
    }

    let mut hello = match hello_remote_daemon(config, &remote_path).await {
        Ok(hello) => hello,
        Err(_error) if had_existing_binary => {
            let local_binary = metadata
                .local_binary_for_platform(
                    &bootstrap_state.go_os,
                    &bootstrap_state.go_arch,
                    &version,
                )
                .await?;
            upload_remote_daemon_binary(config, &local_binary, &remote_path).await?;
            uploaded = true;
            hello_remote_daemon(config, &remote_path)
                .await
                .with_context(|| format!("hello after reinstalling {remote_path}"))?
        }
        Err(error) => return Err(error),
    };

    if had_existing_binary
        && !hello
            .capabilities
            .iter()
            .any(|cap| cap == "proxy.stream.push")
    {
        let local_binary = metadata
            .local_binary_for_platform(&bootstrap_state.go_os, &bootstrap_state.go_arch, &version)
            .await?;
        upload_remote_daemon_binary(config, &local_binary, &remote_path).await?;
        uploaded = true;
        hello = hello_remote_daemon(config, &remote_path)
            .await
            .with_context(|| format!("hello after capability reinstall for {remote_path}"))?;
    }

    Ok(RemoteSshBootstrapResult {
        version,
        target_goos: bootstrap_state.go_os,
        target_goarch: bootstrap_state.go_arch,
        local_binary_path,
        remote_path,
        uploaded,
        hello,
    })
}

async fn probe_remote_bootstrap_state(
    config: &RemoteSshBootstrapConfig,
    version: &str,
) -> Result<RemoteBootstrapState> {
    let script = format!(
        r#"cmux_uname_os="$(uname -s)"
cmux_uname_arch="$(uname -m)"
printf '%s%s\n' '{REMOTE_OS_MARKER}' "$cmux_uname_os"
printf '%s%s\n' '{REMOTE_ARCH_MARKER}' "$cmux_uname_arch"
case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
  linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
  *) exit 70 ;;
esac
case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
  x86_64|amd64) cmux_go_arch=amd64 ;;
  aarch64|arm64) cmux_go_arch=arm64 ;;
  armv7l) cmux_go_arch=arm ;;
  *) exit 71 ;;
esac
cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/{version}/${{cmux_go_os}}-${{cmux_go_arch}}/cmuxd-remote"
if [ -x "$cmux_remote_path" ]; then
  printf '%syes\n' '{REMOTE_EXISTS_MARKER}'
else
  printf '%sno\n' '{REMOTE_EXISTS_MARKER}'
fi"#
    );
    let result = ssh_exec(
        config,
        &[remote_shell_command(&script)],
        Duration::from_secs(20),
    )
    .await?;
    let stdout = String::from_utf8_lossy(&result.stdout);
    let lines = stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    let raw_os =
        marker_value(&lines, REMOTE_OS_MARKER).context("failed to query remote platform")?;
    let raw_arch =
        marker_value(&lines, REMOTE_ARCH_MARKER).context("failed to query remote architecture")?;
    let go_os =
        map_uname_os(raw_os).with_context(|| format!("unsupported remote platform {raw_os}"))?;
    let go_arch = map_uname_arch(raw_arch)
        .with_context(|| format!("unsupported remote architecture {raw_arch}"))?;
    let binary_exists = marker_value(&lines, REMOTE_EXISTS_MARKER)
        .map(|value| value == "yes")
        .unwrap_or(false);
    if !result.status.success() && marker_value(&lines, REMOTE_EXISTS_MARKER).is_none() {
        let detail = best_error_line(&result.stderr, &result.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", result.status));
        bail!("failed to query remote daemon state: {detail}");
    }
    Ok(RemoteBootstrapState {
        go_os,
        go_arch,
        binary_exists,
    })
}

async fn upload_remote_daemon_binary(
    config: &RemoteSshBootstrapConfig,
    local_binary: &Path,
    remote_path: &str,
) -> Result<()> {
    let remote_directory = remote_path
        .rsplit_once('/')
        .map(|(directory, _)| directory)
        .context("remote daemon path has no directory")?;
    let remote_temp_path = format!("{remote_path}.tmp-{}", uuid::Uuid::new_v4().simple());

    let mkdir_script = format!("mkdir -p {}", shell_single_quoted(remote_directory));
    let mkdir_result = ssh_exec(
        config,
        &[remote_shell_command(&mkdir_script)],
        Duration::from_secs(12),
    )
    .await?;
    if !mkdir_result.status.success() {
        let detail = best_error_line(&mkdir_result.stderr, &mkdir_result.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", mkdir_result.status));
        bail!("failed to create remote daemon directory: {detail}");
    }

    let scp_result = scp_upload(
        config,
        local_binary,
        &remote_temp_path,
        Duration::from_secs(45),
    )
    .await?;
    if !scp_result.status.success() {
        let detail = best_error_line(&scp_result.stderr, &scp_result.stdout)
            .unwrap_or_else(|| format!("scp exited {}", scp_result.status));
        bail!("failed to upload cmuxd-remote: {detail}");
    }

    let finalize_script = format!(
        "chmod 755 {} && mv {} {}",
        shell_single_quoted(&remote_temp_path),
        shell_single_quoted(&remote_temp_path),
        shell_single_quoted(remote_path)
    );
    let finalize_result = ssh_exec(
        config,
        &[remote_shell_command(&finalize_script)],
        Duration::from_secs(12),
    )
    .await?;
    if !finalize_result.status.success() {
        let detail = best_error_line(&finalize_result.stderr, &finalize_result.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", finalize_result.status));
        bail!("failed to install remote daemon binary: {detail}");
    }
    Ok(())
}

async fn hello_remote_daemon(
    config: &RemoteSshBootstrapConfig,
    remote_path: &str,
) -> Result<RemoteDaemonHello> {
    let request = r#"{"id":1,"method":"hello","params":{}}"#;
    let script = format!(
        "printf '%s\\n' {} | {} serve --stdio",
        shell_single_quoted(request),
        shell_single_quoted(remote_path)
    );
    let result = ssh_exec(
        config,
        &[remote_shell_command(&script)],
        Duration::from_secs(12),
    )
    .await?;
    if !result.status.success() {
        let detail = best_error_line(&result.stderr, &result.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", result.status));
        bail!("failed to start remote daemon: {detail}");
    }
    let stdout = String::from_utf8_lossy(&result.stdout);
    let response_line = stdout
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .context("remote daemon hello returned invalid JSON")?;
    let response: RpcResponse =
        serde_json::from_str(response_line).context("remote daemon hello returned invalid JSON")?;
    if response.ok == Some(false) {
        let message = response
            .error
            .and_then(|error| non_empty(error.message))
            .unwrap_or_else(|| "hello call failed".to_string());
        bail!("remote daemon hello failed: {message}");
    }
    let result = response.result.unwrap_or_default();
    Ok(RemoteDaemonHello {
        name: non_empty(result.name).unwrap_or_else(|| "cmuxd-remote".to_string()),
        version: non_empty(result.version).unwrap_or_else(|| "dev".to_string()),
        capabilities: result.capabilities,
    })
}

#[derive(Debug, Deserialize)]
struct RpcResponse {
    ok: Option<bool>,
    error: Option<RpcError>,
    result: Option<HelloResult>,
}

#[derive(Debug, Deserialize)]
struct RpcError {
    message: String,
}

#[derive(Debug, Default, Deserialize)]
struct HelloResult {
    #[serde(default)]
    name: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    capabilities: Vec<String>,
}

async fn ssh_exec(
    config: &RemoteSshBootstrapConfig,
    remote_args: &[String],
    timeout: Duration,
) -> Result<std::process::Output> {
    let mut args = ssh_common_arguments(config, true);
    args.extend(remote_args.iter().cloned());
    run_process("/usr/bin/ssh", &args, timeout).await
}

async fn scp_upload(
    config: &RemoteSshBootstrapConfig,
    local_binary: &Path,
    remote_path: &str,
    timeout: Duration,
) -> Result<std::process::Output> {
    let effective_options = background_ssh_options(&config.ssh_options);
    let mut args = vec!["-q".to_string()];
    if !has_ssh_option_key(&effective_options, "StrictHostKeyChecking") {
        args.extend([
            "-o".to_string(),
            "StrictHostKeyChecking=accept-new".to_string(),
        ]);
    }
    args.extend(["-o".to_string(), "ControlMaster=no".to_string()]);
    if let Some(port) = config.port {
        args.extend(["-P".to_string(), port.to_string()]);
    }
    if let Some(identity_file) = config
        .identity_file
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-i".to_string(), identity_file]);
    }
    for option in effective_options {
        args.extend(["-o".to_string(), option]);
    }
    args.push(local_binary.display().to_string());
    args.push(format!("{}:{remote_path}", config.destination));
    run_process("/usr/bin/scp", &args, timeout).await
}

async fn run_process(
    executable: &str,
    arguments: &[String],
    timeout: Duration,
) -> Result<std::process::Output> {
    let child = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("launch {}", executable))?;
    tokio::time::timeout(timeout, child.wait_with_output())
        .await
        .with_context(|| format!("{} timed out after {}s", executable, timeout.as_secs()))?
        .with_context(|| format!("wait for {}", executable))
}

fn ssh_common_arguments(config: &RemoteSshBootstrapConfig, batch_mode: bool) -> Vec<String> {
    let effective_options = if batch_mode {
        background_ssh_options(&config.ssh_options)
    } else {
        normalized_ssh_options(&config.ssh_options)
    };
    let mut args = vec![
        "-o".to_string(),
        "ConnectTimeout=6".to_string(),
        "-o".to_string(),
        "ServerAliveInterval=20".to_string(),
        "-o".to_string(),
        "ServerAliveCountMax=2".to_string(),
    ];
    if !has_ssh_option_key(&effective_options, "StrictHostKeyChecking") {
        args.extend([
            "-o".to_string(),
            "StrictHostKeyChecking=accept-new".to_string(),
        ]);
    }
    if batch_mode {
        args.extend(["-o".to_string(), "BatchMode=yes".to_string()]);
        args.extend(["-o".to_string(), "ControlMaster=no".to_string()]);
    }
    if let Some(port) = config.port {
        args.extend(["-p".to_string(), port.to_string()]);
    }
    if let Some(identity_file) = config
        .identity_file
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-i".to_string(), identity_file]);
    }
    for option in effective_options {
        args.extend(["-o".to_string(), option]);
    }
    args
}

fn background_ssh_options(options: &[String]) -> Vec<String> {
    normalized_ssh_options(options)
        .into_iter()
        .filter(|option| {
            ssh_option_key(option)
                .is_none_or(|key| key != "controlmaster" && key != "controlpersist")
        })
        .collect()
}

fn normalized_ssh_options(options: &[String]) -> Vec<String> {
    options
        .iter()
        .filter_map(|option| non_empty(option.clone()))
        .collect()
}

fn has_ssh_option_key(options: &[String], key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    options
        .iter()
        .any(|option| ssh_option_key(option).as_deref() == Some(key.as_str()))
}

fn ssh_option_key(option: &str) -> Option<String> {
    option
        .trim()
        .split(|ch: char| ch == '=' || ch.is_whitespace())
        .next()
        .and_then(|key| non_empty(key.to_string()))
        .map(|key| key.to_ascii_lowercase())
}

fn remote_shell_command(script: &str) -> String {
    format!("sh -c {}", shell_single_quoted(script))
}

fn shell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn marker_value<'a>(lines: &[&'a str], marker: &str) -> Option<&'a str> {
    lines.iter().find_map(|line| line.strip_prefix(marker))
}

fn map_uname_os(raw: &str) -> Option<String> {
    match raw.to_ascii_lowercase().as_str() {
        "linux" => Some("linux".to_string()),
        "darwin" => Some("darwin".to_string()),
        "freebsd" => Some("freebsd".to_string()),
        _ => None,
    }
}

fn map_uname_arch(raw: &str) -> Option<String> {
    match raw.to_ascii_lowercase().as_str() {
        "x86_64" | "amd64" => Some("amd64".to_string()),
        "aarch64" | "arm64" => Some("arm64".to_string()),
        "armv7l" => Some("arm".to_string()),
        _ => None,
    }
}

fn best_error_line(stderr: &[u8], stdout: &[u8]) -> Option<String> {
    meaningful_error_line(stderr).or_else(|| meaningful_error_line(stdout))
}

fn meaningful_error_line(data: &[u8]) -> Option<String> {
    String::from_utf8_lossy(data)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .rev()
        .find(|line| {
            let lower = line.to_ascii_lowercase();
            !lower.contains("warning:") && !lower.contains("debug:")
        })
        .map(str::to_string)
}

fn non_empty(raw: String) -> Option<String> {
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}
