use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::process::Command;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use uuid::Uuid;

const CHALLENGE_PROTOCOL: &str = "cmux-relay-auth";
const CHALLENGE_VERSION: u8 = 1;
const MAX_FRAME_BYTES: usize = 16 * 1024;
const MIN_FAILURE_DELAY: Duration = Duration::from_millis(50);

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub(crate) struct RemoteSshRelayConfig {
    pub(crate) destination: String,
    pub(crate) port: Option<u16>,
    pub(crate) identity_file: Option<String>,
    pub(crate) ssh_options: Vec<String>,
    pub(crate) remote_path: String,
    pub(crate) relay_port: u16,
    pub(crate) relay_id: String,
    pub(crate) relay_token: String,
    pub(crate) local_socket_path: String,
}

pub(crate) struct RemoteSshRelayHandle {
    config: RemoteSshRelayConfig,
    stop_tx: watch::Sender<bool>,
    failure_rx: watch::Receiver<Option<String>>,
    accept_task: JoinHandle<()>,
    cleanup_started: Arc<AtomicBool>,
    control_master_forward_spec: Option<String>,
}

impl RemoteSshRelayHandle {
    pub(crate) fn stop(&self) {
        let _ = self.stop_tx.send(true);
        self.accept_task.abort();
        self.spawn_cleanup();
    }

    #[allow(dead_code)]
    pub(crate) fn failure_rx(&self) -> watch::Receiver<Option<String>> {
        self.failure_rx.clone()
    }

    fn spawn_cleanup(&self) {
        if self.cleanup_started.swap(true, Ordering::Relaxed) {
            return;
        }
        let config = self.config.clone();
        let control_master_forward_spec = self.control_master_forward_spec.clone();
        tokio::spawn(async move {
            if let Some(forward_spec) = control_master_forward_spec {
                let _ = cancel_reverse_relay_via_control_master(&config, &forward_spec).await;
            }
            let _ = cleanup_remote_relay_metadata(&config).await;
        });
    }
}

impl Drop for RemoteSshRelayHandle {
    fn drop(&mut self) {
        let _ = self.stop_tx.send(true);
        self.accept_task.abort();
        self.spawn_cleanup();
    }
}

pub(crate) async fn start_remote_ssh_relay(
    config: RemoteSshRelayConfig,
) -> Result<RemoteSshRelayHandle> {
    let relay_token = decode_hex(&config.relay_token).context("invalid relay token")?;
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .context("bind local SSH relay listener")?;
    let local_relay_port = listener
        .local_addr()
        .context("read local SSH relay listener address")?
        .port();

    let (stop_tx, stop_rx) = watch::channel(false);
    let (failure_tx, failure_rx) = watch::channel(None);
    let accept_config = config.clone();
    let accept_stop_rx = stop_rx.clone();
    let accept_failure_tx = failure_tx.clone();
    let accept_task = tokio::spawn(async move {
        accept_loop(
            listener,
            accept_config,
            relay_token,
            accept_stop_rx,
            accept_failure_tx,
        )
        .await;
    });

    let forward_spec = reverse_relay_forward_spec(&config, local_relay_port);
    let control_master_forward_spec =
        if start_reverse_relay_via_control_master(&config, &forward_spec).await? {
            Some(forward_spec.clone())
        } else {
            let mut child = spawn_reverse_relay_process(&config, &forward_spec)
                .await
                .with_context(|| format!("start SSH reverse relay to {}", config.destination))?;
            tokio::time::sleep(Duration::from_millis(500)).await;
            if let Some(status) = child.try_wait().context("poll SSH reverse relay startup")? {
                bail!("SSH reverse relay exited during startup with {status}");
            }

            let mut wait_stop_rx = stop_rx.clone();
            let wait_failure_tx = failure_tx.clone();
            tokio::spawn(async move {
                tokio::select! {
                    changed = wait_stop_rx.changed() => {
                        if changed.is_err() || *wait_stop_rx.borrow() {
                            let _ = child.start_kill();
                            let _ = child.wait().await;
                        }
                    }
                    status = child.wait() => {
                        let detail = match status {
                            Ok(status) => format!("SSH reverse relay exited with {status}"),
                            Err(error) => format!("SSH reverse relay wait failed: {error}"),
                        };
                        wait_failure_tx.send(Some(detail)).ok();
                    }
                }
            });
            None
        };

    if let Err(error) = install_remote_relay_metadata(&config).await {
        if let Some(forward_spec) = &control_master_forward_spec {
            let _ = cancel_reverse_relay_via_control_master(&config, forward_spec).await;
        }
        return Err(error);
    }
    Ok(RemoteSshRelayHandle {
        config,
        stop_tx,
        failure_rx,
        accept_task,
        cleanup_started: Arc::new(AtomicBool::new(false)),
        control_master_forward_spec,
    })
}

async fn accept_loop(
    listener: TcpListener,
    config: RemoteSshRelayConfig,
    relay_token: Vec<u8>,
    mut stop_rx: watch::Receiver<bool>,
    failure_tx: watch::Sender<Option<String>>,
) {
    loop {
        tokio::select! {
            changed = stop_rx.changed() => {
                if changed.is_err() || *stop_rx.borrow() {
                    return;
                }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let config = config.clone();
                        let relay_token = relay_token.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle_relay_session(stream, config, relay_token).await {
                                tracing::debug!(error = %error, "remote SSH relay session ended");
                            }
                        });
                    }
                    Err(error) => {
                        failure_tx.send(Some(format!("local relay accept failed: {error}"))).ok();
                        return;
                    }
                }
            }
        }
    }
}

async fn handle_relay_session(
    stream: TcpStream,
    config: RemoteSshRelayConfig,
    relay_token: Vec<u8>,
) -> Result<()> {
    let started = Instant::now();
    let nonce = Uuid::new_v4().simple().to_string();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let challenge = serde_json::json!({
        "protocol": CHALLENGE_PROTOCOL,
        "version": CHALLENGE_VERSION,
        "relay_id": config.relay_id.clone(),
        "nonce": nonce,
    });
    write_json_line(&mut write_half, &challenge).await?;

    let mut line = String::new();
    read_limited_line(&mut reader, &mut line).await?;
    let auth: Value = serde_json::from_str(line.trim()).context("decode relay auth")?;
    let received_relay_id = auth
        .get("relay_id")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mac_hex = auth.get("mac").and_then(Value::as_str).unwrap_or_default();
    let received_mac = decode_hex(mac_hex).context("decode relay auth mac")?;
    let expected_message = auth_message(&config.relay_id, &nonce);
    let expected_mac = auth_mac(&relay_token, expected_message.as_bytes())?;
    if received_relay_id != config.relay_id || !constant_time_equal(&received_mac, &expected_mac) {
        send_failure_after_min_delay(&mut write_half, started).await?;
        bail!("relay authentication failed");
    }
    write_json_line(&mut write_half, &serde_json::json!({ "ok": true })).await?;

    line.clear();
    read_limited_line(&mut reader, &mut line).await?;
    if line.is_empty() {
        send_failure_after_min_delay(&mut write_half, started).await?;
        bail!("relay command was empty");
    }
    let response = round_trip_unix_socket(&config.local_socket_path, line.as_bytes()).await?;
    write_half.write_all(&response).await?;
    write_half.shutdown().await?;
    Ok(())
}

async fn read_limited_line<R>(reader: &mut R, line: &mut String) -> Result<()>
where
    R: AsyncBufRead + Unpin,
{
    let read = reader.read_line(line).await.context("read relay line")?;
    if read == 0 {
        bail!("relay client closed");
    }
    if line.len() > MAX_FRAME_BYTES {
        bail!("relay frame exceeded {MAX_FRAME_BYTES} bytes");
    }
    Ok(())
}

async fn write_json_line<W>(writer: &mut W, value: &Value) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let encoded = serde_json::to_vec(value).context("encode relay JSON")?;
    writer.write_all(&encoded).await?;
    writer.write_all(b"\n").await?;
    writer.flush().await?;
    Ok(())
}

async fn send_failure_after_min_delay<W>(writer: &mut W, started: Instant) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let elapsed = started.elapsed();
    if elapsed < MIN_FAILURE_DELAY {
        tokio::time::sleep(MIN_FAILURE_DELAY - elapsed).await;
    }
    write_json_line(writer, &serde_json::json!({ "ok": false })).await
}

async fn round_trip_unix_socket(socket_path: &str, request: &[u8]) -> Result<Vec<u8>> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .with_context(|| format!("connect local cmux socket {socket_path}"))?;
    stream.write_all(request).await?;
    stream.shutdown().await?;
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(15), stream.read_to_end(&mut response))
        .await
        .context("timed out waiting for local cmux response")?
        .context("read local cmux response")?;
    Ok(response)
}

async fn spawn_reverse_relay_process(
    config: &RemoteSshRelayConfig,
    forward_spec: &str,
) -> Result<tokio::process::Child> {
    let mut args = vec![
        "-N".to_string(),
        "-T".to_string(),
        "-S".to_string(),
        "none".to_string(),
    ];
    args.extend(ssh_common_arguments(config));
    args.extend([
        "-o".to_string(),
        "ExitOnForwardFailure=yes".to_string(),
        "-o".to_string(),
        "RequestTTY=no".to_string(),
        "-R".to_string(),
        forward_spec.to_string(),
        config.destination.clone(),
    ]);
    let child = Command::new("/usr/bin/ssh")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("launch SSH reverse relay")?;
    Ok(child)
}

fn reverse_relay_forward_spec(config: &RemoteSshRelayConfig, local_relay_port: u16) -> String {
    format!(
        "127.0.0.1:{}:127.0.0.1:{local_relay_port}",
        config.relay_port
    )
}

async fn start_reverse_relay_via_control_master(
    config: &RemoteSshRelayConfig,
    forward_spec: &str,
) -> Result<bool> {
    let Some(arguments) = control_master_forward_arguments(config, "forward", forward_spec) else {
        return Ok(false);
    };
    let Ok(output) = run_ssh_control_master_command(arguments, Duration::from_secs(8)).await else {
        return Ok(false);
    };
    Ok(output.status.success())
}

async fn cancel_reverse_relay_via_control_master(
    config: &RemoteSshRelayConfig,
    forward_spec: &str,
) -> Result<()> {
    let Some(arguments) = control_master_forward_arguments(config, "cancel", forward_spec) else {
        return Ok(());
    };
    let _ = run_ssh_control_master_command(arguments, Duration::from_secs(5)).await?;
    Ok(())
}

fn control_master_forward_arguments(
    config: &RemoteSshRelayConfig,
    control_command: &str,
    forward_spec: &str,
) -> Option<Vec<String>> {
    let control_path = ssh_option_value("ControlPath", &config.ssh_options)?;
    let control_path = control_path.trim();
    if control_path.is_empty() || control_path.eq_ignore_ascii_case("none") {
        return None;
    }

    let mut args = ssh_common_arguments(config);
    args.extend([
        "-O".to_string(),
        control_command.to_string(),
        "-R".to_string(),
        forward_spec.to_string(),
        config.destination.clone(),
    ]);
    Some(args)
}

async fn run_ssh_control_master_command(
    arguments: Vec<String>,
    timeout: Duration,
) -> Result<std::process::Output> {
    let child = Command::new("/usr/bin/ssh")
        .args(arguments)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("launch SSH control master command")?;
    tokio::time::timeout(timeout, child.wait_with_output())
        .await
        .with_context(|| {
            format!(
                "SSH control master command timed out after {}s",
                timeout.as_secs()
            )
        })?
        .context("wait for SSH control master command")
}

async fn install_remote_relay_metadata(config: &RemoteSshRelayConfig) -> Result<()> {
    let result = run_remote_shell_script(
        config,
        &remote_relay_metadata_install_script(config),
        Duration::from_secs(8),
    )
    .await?;
    if !result.status.success() {
        let detail = best_error_line(&result.stderr, &result.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", result.status));
        bail!("failed to install remote relay metadata: {detail}");
    }
    Ok(())
}

pub(crate) async fn run_remote_shell_script(
    config: &RemoteSshRelayConfig,
    script: &str,
    timeout: Duration,
) -> Result<std::process::Output> {
    ssh_exec(config, &[remote_shell_command(script)], timeout).await
}

async fn cleanup_remote_relay_metadata(config: &RemoteSshRelayConfig) -> Result<()> {
    let script = format!(
        r#"relay_socket='127.0.0.1:{relay_port}'
socket_addr_file="$HOME/.cmux/socket_addr"
if [ -r "$socket_addr_file" ] && [ "$(tr -d '\r\n' < "$socket_addr_file")" = "$relay_socket" ]; then
  rm -f "$socket_addr_file"
fi
rm -f "$HOME/.cmux/relay/{relay_port}.auth" "$HOME/.cmux/relay/{relay_port}.daemon_path" "$HOME/.cmux/relay/{relay_port}.tty""#,
        relay_port = config.relay_port,
    );
    let _ = ssh_exec(
        config,
        &[remote_shell_command(&script)],
        Duration::from_secs(8),
    )
    .await;
    Ok(())
}

fn remote_relay_metadata_install_script(config: &RemoteSshRelayConfig) -> String {
    let remote_path = config.remote_path.trim();
    let auth_payload = format!(
        r#"{{"relay_id":"{}","relay_token":"{}"}}"#,
        config.relay_id, config.relay_token
    );
    format!(
        r#"umask 077
mkdir -p "$HOME/.cmux" "$HOME/.cmux/relay"
chmod 700 "$HOME/.cmux/relay"
{wrapper_install}
printf '%s' "$HOME/{remote_path}" > "$HOME/.cmux/relay/{relay_port}.daemon_path"
cat > "$HOME/.cmux/relay/{relay_port}.auth" <<'CMUXRELAYAUTH'
{auth_payload}
CMUXRELAYAUTH
chmod 600 "$HOME/.cmux/relay/{relay_port}.auth"
printf '%s' '127.0.0.1:{relay_port}' > "$HOME/.cmux/socket_addr""#,
        wrapper_install = remote_cli_wrapper_install_script(remote_path),
        relay_port = config.relay_port,
    )
}

fn remote_cli_wrapper_install_script(remote_path: &str) -> String {
    format!(
        r#"mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
ln -sf "$HOME/{remote_path}" "$HOME/.cmux/bin/cmuxd-remote-current"
wrapper_tmp="$HOME/.cmux/bin/.cmux-wrapper.tmp.$$"
cat > "$wrapper_tmp" <<'CMUXWRAPPER'
{wrapper}
CMUXWRAPPER
chmod 755 "$wrapper_tmp"
mv -f "$wrapper_tmp" "$HOME/.cmux/bin/cmux""#,
        wrapper = remote_cli_wrapper_script(),
    )
}

fn remote_cli_wrapper_script() -> &'static str {
    r#"#!/bin/sh
daemon="$HOME/.cmux/bin/cmuxd-remote-current"
socket_path="${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}"
if [ -z "$socket_path" ] && [ -r "$HOME/.cmux/socket_addr" ]; then
  socket_path="$(tr -d '\r\n' < "$HOME/.cmux/socket_addr")"
fi

if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
  relay_port="${socket_path##*:}"
  relay_map="$HOME/.cmux/relay/${relay_port}.daemon_path"
  if [ -r "$relay_map" ]; then
    mapped_daemon="$(tr -d '\r\n' < "$relay_map")"
    if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
      daemon="$mapped_daemon"
    fi
  fi
fi

exec "$daemon" "$@""#
}

async fn ssh_exec(
    config: &RemoteSshRelayConfig,
    remote_args: &[String],
    timeout: Duration,
) -> Result<std::process::Output> {
    let mut args = ssh_common_arguments(config);
    args.extend(remote_args.iter().cloned());
    let child = Command::new("/usr/bin/ssh")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("launch ssh")?;
    tokio::time::timeout(timeout, child.wait_with_output())
        .await
        .with_context(|| format!("ssh timed out after {}s", timeout.as_secs()))?
        .context("wait for ssh")
}

fn ssh_common_arguments(config: &RemoteSshRelayConfig) -> Vec<String> {
    let effective_options = background_ssh_options(&config.ssh_options);
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
    args.extend(["-o".to_string(), "BatchMode=yes".to_string()]);
    args.extend(["-o".to_string(), "ControlMaster=no".to_string()]);
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
    options
        .iter()
        .filter_map(|option| non_empty(option.clone()))
        .filter(|option| {
            ssh_option_key(option)
                .is_none_or(|key| key != "controlmaster" && key != "controlpersist")
        })
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

fn ssh_option_value(key: &str, options: &[String]) -> Option<String> {
    let lowered_key = key.to_ascii_lowercase();
    options.iter().find_map(|option| {
        let option = option.trim();
        if option.is_empty() || ssh_option_key(option).as_deref() != Some(lowered_key.as_str()) {
            return None;
        }
        if let Some((_, value)) = option.split_once('=') {
            return non_empty(value.to_string());
        }
        let mut parts = option.splitn(2, char::is_whitespace);
        let _ = parts.next();
        parts.next().and_then(|value| non_empty(value.to_string()))
    })
}

fn remote_shell_command(script: &str) -> String {
    format!("sh -c {}", shell_single_quoted(script))
}

fn shell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn auth_message(relay_id: &str, nonce: &str) -> String {
    format!("relay_id={relay_id}\nnonce={nonce}\nversion={CHALLENGE_VERSION}")
}

fn auth_mac(token: &[u8], message: &[u8]) -> Result<Vec<u8>> {
    let mut mac = HmacSha256::new_from_slice(token).map_err(|_| anyhow!("invalid HMAC key"))?;
    mac.update(message);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn constant_time_equal(lhs: &[u8], rhs: &[u8]) -> bool {
    if lhs.len() != rhs.len() {
        return false;
    }
    lhs.iter()
        .zip(rhs.iter())
        .fold(0u8, |diff, (lhs, rhs)| diff | (lhs ^ rhs))
        == 0
}

fn decode_hex(value: &str) -> Result<Vec<u8>> {
    let trimmed = value.trim();
    if trimmed.is_empty() || !trimmed.len().is_multiple_of(2) {
        bail!("invalid hex length");
    }
    let mut out = Vec::with_capacity(trimmed.len() / 2);
    for chunk in trimmed.as_bytes().chunks(2) {
        let text = std::str::from_utf8(chunk).context("decode hex bytes")?;
        out.push(u8::from_str_radix(text, 16).context("decode hex byte")?);
    }
    Ok(out)
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
