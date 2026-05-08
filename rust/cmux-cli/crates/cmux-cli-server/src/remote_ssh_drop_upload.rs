use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::watch;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub(crate) struct RemoteSshDropUploadConfig {
    pub(crate) destination: String,
    pub(crate) port: Option<u16>,
    pub(crate) identity_file: Option<String>,
    pub(crate) config_file: Option<String>,
    pub(crate) jump_host: Option<String>,
    pub(crate) control_path: Option<String>,
    pub(crate) use_ipv4: bool,
    pub(crate) use_ipv6: bool,
    pub(crate) forward_agent: bool,
    pub(crate) compression_enabled: bool,
    pub(crate) ssh_options: Vec<String>,
}

pub(crate) async fn upload_dropped_files(
    config: &RemoteSshDropUploadConfig,
    local_paths: &[PathBuf],
    cancel_rx: &mut watch::Receiver<bool>,
) -> Result<Vec<String>> {
    if local_paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut uploaded_remote_paths = Vec::new();
    let result = async {
        for local_path in local_paths {
            check_cancelled(cancel_rx)?;
            validate_local_file(local_path)
                .await
                .with_context(|| format!("invalid dropped file {}", local_path.display()))?;

            let remote_path = remote_drop_path(local_path);
            uploaded_remote_paths.push(remote_path.clone());
            let output = scp_upload(
                config,
                local_path,
                &remote_path,
                Duration::from_secs(45),
                cancel_rx,
            )
            .await?;
            if !output.status.success() {
                let detail = best_error_line(&output.stderr, &output.stdout)
                    .unwrap_or_else(|| format!("scp exited {}", output.status));
                bail!("failed to upload dropped file: {detail}");
            }
        }

        check_cancelled(cancel_rx)?;
        Ok(())
    }
    .await;

    match result {
        Ok(()) => Ok(uploaded_remote_paths),
        Err(error) => {
            let _ = cleanup_remote_paths(config, &uploaded_remote_paths).await;
            Err(error)
        }
    }
}

pub(crate) async fn cleanup_remote_paths(
    config: &RemoteSshDropUploadConfig,
    remote_paths: &[String],
) -> Result<()> {
    if remote_paths.is_empty() {
        return Ok(());
    }
    let cleanup_script = format!(
        "rm -f -- {}",
        remote_paths
            .iter()
            .map(|path| shell_single_quoted(path))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let output = ssh_exec(
        config,
        &[remote_shell_command(&cleanup_script)],
        Duration::from_secs(8),
    )
    .await?;
    if !output.status.success() {
        let detail = best_error_line(&output.stderr, &output.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", output.status));
        bail!("failed to clean up remote dropped files: {detail}");
    }
    Ok(())
}

async fn validate_local_file(path: &Path) -> Result<()> {
    let metadata = tokio::fs::metadata(path)
        .await
        .with_context(|| format!("stat {}", path.display()))?;
    if !metadata.is_file() {
        bail!("dropped item is not a regular file");
    }
    Ok(())
}

fn remote_drop_path(local_path: &Path) -> String {
    let suffix = local_path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::trim)
        .filter(|extension| !extension.is_empty())
        .map(|extension| format!(".{}", extension.to_ascii_lowercase()))
        .unwrap_or_default();
    format!("/tmp/cmux-drop-{}{suffix}", Uuid::new_v4().hyphenated())
}

async fn ssh_exec(
    config: &RemoteSshDropUploadConfig,
    remote_args: &[String],
    timeout: Duration,
) -> Result<std::process::Output> {
    let mut args = ssh_common_arguments(config, true);
    args.extend(remote_args.iter().cloned());
    run_process("/usr/bin/ssh", &args, timeout, None).await
}

async fn scp_upload(
    config: &RemoteSshDropUploadConfig,
    local_path: &Path,
    remote_path: &str,
    timeout: Duration,
    cancel_rx: &mut watch::Receiver<bool>,
) -> Result<std::process::Output> {
    let effective_options = background_ssh_options(&config.ssh_options);
    let mut args = vec![
        "-q".to_string(),
        "-o".to_string(),
        "ConnectTimeout=6".to_string(),
        "-o".to_string(),
        "ServerAliveInterval=20".to_string(),
        "-o".to_string(),
        "ServerAliveCountMax=2".to_string(),
        "-o".to_string(),
        "BatchMode=yes".to_string(),
    ];
    if config.use_ipv4 {
        args.push("-4".to_string());
    } else if config.use_ipv6 {
        args.push("-6".to_string());
    }
    if config.forward_agent {
        args.push("-A".to_string());
    }
    if config.compression_enabled {
        args.push("-C".to_string());
    }
    if let Some(config_file) = config
        .config_file
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-F".to_string(), config_file]);
    }
    if let Some(jump_host) = config
        .jump_host
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-J".to_string(), jump_host]);
    }
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
    if let Some(control_path) = config
        .control_path
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
        && !has_ssh_option_key(&effective_options, "ControlPath")
    {
        args.extend(["-o".to_string(), format!("ControlPath={control_path}")]);
    }
    for option in effective_options {
        args.extend(["-o".to_string(), option]);
    }
    args.push(local_path.display().to_string());
    args.push(format!(
        "{}:{remote_path}",
        scp_remote_destination(&config.destination)
    ));
    run_process("/usr/bin/scp", &args, timeout, Some(cancel_rx)).await
}

async fn run_process(
    executable: &str,
    arguments: &[String],
    timeout: Duration,
    mut cancel_rx: Option<&mut watch::Receiver<bool>>,
) -> Result<std::process::Output> {
    if let Some(cancel_rx) = cancel_rx.as_deref_mut() {
        check_cancelled(cancel_rx)?;
    }

    let mut child = Command::new(executable)
        .args(arguments)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("launch {executable}"))?;

    let stdout = child.stdout.take().context("capture stdout")?;
    let stderr = child.stderr.take().context("capture stderr")?;
    let stdout_task = tokio::spawn(read_pipe(stdout));
    let stderr_task = tokio::spawn(read_pipe(stderr));

    let timeout_sleep = tokio::time::sleep(timeout);
    tokio::pin!(timeout_sleep);
    let status = if let Some(cancel_rx) = cancel_rx.as_deref_mut() {
        tokio::select! {
            status = child.wait() => {
                status
                    .with_context(|| format!("wait for {executable}"))?
            }
            _ = &mut timeout_sleep => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                bail!("{executable} timed out after {}s", timeout.as_secs());
            }
            changed = cancel_rx.changed() => {
                if changed.is_ok() && !*cancel_rx.borrow() {
                    child.wait()
                        .await
                        .with_context(|| format!("wait for {executable}"))?
                } else {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    bail!("remote drop upload cancelled");
                }
            }
        }
    } else {
        tokio::select! {
            status = child.wait() => {
                status.with_context(|| format!("wait for {executable}"))?
            }
            _ = &mut timeout_sleep => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                bail!("{executable} timed out after {}s", timeout.as_secs());
            }
        }
    };

    let stdout = stdout_task
        .await
        .context("join stdout reader")?
        .context("read stdout")?;
    let stderr = stderr_task
        .await
        .context("join stderr reader")?
        .context("read stderr")?;
    Ok(std::process::Output {
        status,
        stdout,
        stderr,
    })
}

async fn read_pipe<R>(mut reader: R) -> std::io::Result<Vec<u8>>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut data = Vec::new();
    reader.read_to_end(&mut data).await?;
    Ok(data)
}

fn check_cancelled(cancel_rx: &watch::Receiver<bool>) -> Result<()> {
    if *cancel_rx.borrow() {
        bail!("remote drop upload cancelled");
    }
    Ok(())
}

fn ssh_common_arguments(config: &RemoteSshDropUploadConfig, batch_mode: bool) -> Vec<String> {
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
    if config.use_ipv4 {
        args.push("-4".to_string());
    } else if config.use_ipv6 {
        args.push("-6".to_string());
    }
    if config.forward_agent {
        args.push("-A".to_string());
    }
    if config.compression_enabled {
        args.push("-C".to_string());
    }
    if let Some(config_file) = config
        .config_file
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-F".to_string(), config_file]);
    }
    if let Some(jump_host) = config
        .jump_host
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-J".to_string(), jump_host]);
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
    if let Some(control_path) = config
        .control_path
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
        && !has_ssh_option_key(&effective_options, "ControlPath")
    {
        args.extend(["-o".to_string(), format!("ControlPath={control_path}")]);
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

fn scp_remote_destination(destination: &str) -> String {
    let trimmed_destination = destination.trim();
    if trimmed_destination.is_empty() {
        return destination.to_string();
    }

    let (user_part, host_part) = trimmed_destination
        .split_once('@')
        .map(|(user, host)| (Some(user), host))
        .unwrap_or((None, trimmed_destination));
    if !should_bracket_ipv6_literal(host_part) {
        return trimmed_destination.to_string();
    }
    let bracketed_host = format!("[{host_part}]");
    match user_part {
        Some(user) => format!("{user}@{bracketed_host}"),
        None => bracketed_host,
    }
}

fn should_bracket_ipv6_literal(host: &str) -> bool {
    let trimmed_host = host.trim();
    !trimmed_host.is_empty()
        && trimmed_host.contains(':')
        && !trimmed_host.starts_with('[')
        && !trimmed_host.ends_with(']')
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
            !line.starts_with("Warning:")
                && !line.starts_with("debug")
                && !line.starts_with("OpenSSH_")
        })
        .map(ToString::to_string)
}

fn non_empty(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}
