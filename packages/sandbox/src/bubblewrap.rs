use crate::errors::{SandboxError, SandboxResult};
use crate::ip_pool::{IpLease, IpPool};
use crate::models::{
    AwaitReadyRequest, AwaitReadyResponse, CreateSandboxRequest, EnvVar, ExecRequest, ExecResponse,
    HostEvent, MuxClientMessage, MuxServerMessage, PruneRequest, PruneResponse, PrunedItem,
    PtySessionId, SandboxDisplay, SandboxNetwork, SandboxStatus, SandboxSummary, ServiceReadiness,
};
use crate::mux::terminal::{DaFilter, VirtualTerminal};
use crate::service::SandboxService;
use crate::timing::TimingReport;
use async_trait::async_trait;
use axum::body::Body;
use axum::extract::ws::{Message, WebSocket};
use chrono::{DateTime, Utc};
use futures::{SinkExt, StreamExt};
use portable_pty::{CommandBuilder, MasterPty, NativePtySystem, PtySize, PtySystem};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::{env, time::Duration};
use tokio::fs;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, watch, Mutex};
use tokio::time::sleep;
use tracing::{debug, info, warn};
use uuid::Uuid;
use which::which;

const NETWORK_BASE: Ipv4Addr = Ipv4Addr::new(10, 201, 0, 0);
const HOST_IF_PREFIX: &str = "vethh";
const NS_IF_PREFIX: &str = "vethn";
const DOCKER_CONTAINER_SOCKET: &str = "/run/docker.sock";
const SANDBOX_WORKSPACE_MOUNT: &str = "/workspace";

/// Handle for a multiplexed PTY session.
struct PtySessionHandle {
    input_tx: mpsc::UnboundedSender<Vec<u8>>,
    /// Channel to send resize events to the reader thread's VirtualTerminal
    resize_tx: std::sync::mpsc::Sender<(u16, u16)>,
    master: Box<dyn MasterPty + Send>,
    #[allow(dead_code)]
    child: Box<dyn portable_pty::Child + Send + Sync>,
    /// Child process ID for signal forwarding
    child_pid: Option<u32>,
}

#[derive(Deserialize)]
struct BwrapStatus {
    #[serde(rename = "child-pid")]
    child_pid: u32,
}

#[derive(Clone, Debug)]
struct SandboxHandle {
    id: Uuid,
    index: usize,
    name: String,
    workspace: PathBuf,
    network: SandboxNetwork,
    created_at: DateTime<Utc>,
    lease: IpLease,
    /// Correlation ID for matching placeholders to created sandboxes (from tab_id)
    correlation_id: Option<String>,
    /// Display configuration for isolated X11/VNC desktop
    display: Option<SandboxDisplay>,
}

#[derive(Clone)]
struct SandboxEntry {
    handle: SandboxHandle,
    child: Arc<Mutex<Child>>,
    inner_pid: u32,
    env: Vec<EnvVar>,
}

#[derive(Clone)]
struct DockerConfig {
    host_socket: PathBuf,
    docker_host_env: String,
}

impl DockerConfig {
    fn from_env() -> SandboxResult<Self> {
        let raw =
            env::var("CMUX_DOCKER_SOCKET").unwrap_or_else(|_| "/var/run/docker.sock".to_string());
        let host_socket = normalize_docker_socket(&raw)?;

        Ok(Self {
            host_socket,
            docker_host_env: format!("unix://{DOCKER_CONTAINER_SOCKET}"),
        })
    }

    fn host_socket(&self) -> &Path {
        &self.host_socket
    }

    fn docker_host_env(&self) -> &str {
        &self.docker_host_env
    }
}

/// Watch channel for service readiness updates.
/// Subscribers can wait for specific services to become ready.
type ReadinessWatch = watch::Sender<ServiceReadiness>;

pub struct BubblewrapService {
    sandboxes: Mutex<HashMap<Uuid, SandboxEntry>>,
    workspace_root: PathBuf,
    ip_pool: Mutex<IpPool>,
    bubblewrap_path: String,
    ip_path: String,
    iptables_path: String,
    nsenter_path: String,
    port: u16,
    next_index: AtomicUsize,
    docker: DockerConfig,
    /// Service readiness tracking per sandbox.
    /// Uses watch channels so multiple waiters can subscribe efficiently.
    readiness: Mutex<HashMap<Uuid, ReadinessWatch>>,
}

fn nsenter_args(pid: u32, workdir: Option<&str>, command: &[String]) -> Vec<String> {
    let mut args = vec![
        "--target".to_string(),
        pid.to_string(),
        "--mount".to_string(),
        "--uts".to_string(),
        "--ipc".to_string(),
        "--net".to_string(),
        "--pid".to_string(),
    ];

    if let Some(dir) = workdir {
        args.push(format!("--wd={}", dir));
    } else {
        args.push("--wd".to_string());
    }

    args.push("--".to_string());
    args.extend_from_slice(command);

    args
}

/// Start X11 stack in background (standalone function for use in spawned tasks).
/// This is a non-blocking version of start_x11_stack that doesn't require &self.
async fn start_x11_stack_background(
    nsenter_path: &str,
    inner_pid: u32,
    display_number: u16,
    vnc_port: u16,
    cdp_port: u16,
) -> Result<(), String> {
    use tokio::time::timeout;
    let cmd_timeout = Duration::from_secs(5);
    let x11_display = format!(":{}", display_number);

    // Helper to run nsenter command with timeout
    async fn run_nsenter(
        nsenter_path: &str,
        pid: u32,
        cmd: &[String],
        timeout_duration: Duration,
        name: &str,
    ) -> Result<(), String> {
        let result = timeout(
            timeout_duration,
            Command::new(nsenter_path)
                .args(nsenter_args(pid, None, cmd))
                .output(),
        )
        .await;

        match result {
            Ok(Ok(output)) => {
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    debug!("{} start warning: {}", name, stderr);
                }
                Ok(())
            }
            Ok(Err(e)) => Err(format!("{} command error: {}", name, e)),
            Err(_) => {
                debug!(
                    "{} command timed out (expected for backgrounded process)",
                    name
                );
                Ok(())
            }
        }
    }

    // Start Xvnc (TigerVNC)
    let xvnc_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!(
            "Xvnc {} -geometry 1920x1080 -depth 24 -rfbport {} -SecurityTypes None -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents &",
            x11_display, vnc_port
        ),
    ];
    run_nsenter(nsenter_path, inner_pid, &xvnc_cmd, cmd_timeout, "Xvnc").await?;

    // Wait for Xvnc to start
    sleep(Duration::from_millis(300)).await;

    // Verify Xvnc is running
    let verify_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!("pgrep -f 'Xvnc {}'", x11_display),
    ];
    let verify_result = timeout(
        cmd_timeout,
        Command::new(nsenter_path)
            .args(nsenter_args(inner_pid, None, &verify_cmd))
            .output(),
    )
    .await;

    let xvnc_running = matches!(verify_result, Ok(Ok(ref output)) if output.status.success());
    if !xvnc_running {
        return Err(format!(
            "Xvnc failed to start on display {} port {}",
            x11_display, vnc_port
        ));
    }

    // Start openbox (non-critical)
    let openbox_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!("DISPLAY={} openbox &", x11_display),
    ];
    if let Err(e) = run_nsenter(
        nsenter_path,
        inner_pid,
        &openbox_cmd,
        cmd_timeout,
        "openbox",
    )
    .await
    {
        warn!("openbox failed to start (non-critical): {}", e);
    }

    // Start Chrome with CDP (non-critical)
    let chrome_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!(
            concat!(
                "DISPLAY={} google-chrome --no-sandbox --disable-gpu ",
                "--remote-debugging-port={} --remote-debugging-address=0.0.0.0 ",
                "--user-data-dir=/tmp/chrome-sandbox-{} ",
                "--disable-background-networking --disable-default-apps ",
                "--disable-extensions --disable-sync --no-first-run ",
                "--start-maximized &"
            ),
            x11_display, cdp_port, display_number
        ),
    ];
    if let Err(e) = run_nsenter(nsenter_path, inner_pid, &chrome_cmd, cmd_timeout, "Chrome").await {
        debug!("Chrome failed to start (non-critical): {}", e);
    }

    info!(
        x11_display = %x11_display,
        vnc_port = vnc_port,
        "X11 stack ready (background)"
    );
    Ok(())
}

/// Start cmux-code (VS Code server) in background.
/// This is a non-blocking function that starts the VS Code web server inside a sandbox.
async fn start_vscode_background(
    nsenter_path: &str,
    inner_pid: u32,
    vscode_port: u16,
    workspace_path: &str,
) -> Result<(), String> {
    use tokio::time::timeout;
    let cmd_timeout = Duration::from_secs(10);

    // Start cmux-code server
    // --host 0.0.0.0: Listen on all interfaces (needed for proxy access)
    // --port: The port to listen on
    // --without-connection-token: Disable auth (sandbox is already isolated)
    // --disable-workspace-trust: Don't prompt for trust
    // --disable-telemetry: No telemetry
    // Use nohup to prevent SIGHUP when nsenter shell exits
    let vscode_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!(
            concat!(
                "nohup /app/cmux-code/bin/code-server-oss ",
                "--host 0.0.0.0 --port {} ",
                "--without-connection-token ",
                "--disable-workspace-trust ",
                "--disable-telemetry ",
                "--telemetry-level off ",
                "{} ",
                "> /tmp/cmux-code.log 2>&1 &"
            ),
            vscode_port, workspace_path
        ),
    ];

    let result = timeout(
        cmd_timeout,
        Command::new(nsenter_path)
            .args(nsenter_args(inner_pid, None, &vscode_cmd))
            .output(),
    )
    .await;

    match result {
        Ok(Ok(output)) => {
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                debug!("cmux-code start warning: {}", stderr);
            }
        }
        Ok(Err(e)) => return Err(format!("cmux-code command error: {}", e)),
        Err(_) => {
            debug!("cmux-code command timed out (expected for backgrounded process)");
        }
    }

    // Wait for cmux-code to start listening
    sleep(Duration::from_millis(500)).await;

    // Verify cmux-code is running by checking if it's listening on the port
    let verify_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!("pgrep -f 'code-server-oss.*--port {}'", vscode_port),
    ];
    let verify_result = timeout(
        Duration::from_secs(5),
        Command::new(nsenter_path)
            .args(nsenter_args(inner_pid, None, &verify_cmd))
            .output(),
    )
    .await;

    let vscode_running = matches!(verify_result, Ok(Ok(ref output)) if output.status.success());
    if !vscode_running {
        return Err(format!("cmux-code failed to start on port {}", vscode_port));
    }

    info!(
        vscode_port = vscode_port,
        workspace = %workspace_path,
        "cmux-code started"
    );
    Ok(())
}

/// Start cmux-pty server inside the sandbox (background process).
/// This is the unified PTY server that handles terminal sessions.
async fn start_cmux_pty_background(
    nsenter_path: &str,
    inner_pid: u32,
    pty_port: u16,
) -> Result<(), String> {
    use tokio::time::timeout;
    let cmd_timeout = Duration::from_secs(10);

    // Start cmux-pty server
    // --host 0.0.0.0: Listen on all interfaces (needed for proxy access)
    // --port: The port to listen on
    // Use nohup to prevent SIGHUP when nsenter shell exits
    let pty_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!(
            "nohup /usr/local/bin/cmux-pty server --host 0.0.0.0 --port {} > /tmp/cmux-pty.log 2>&1 &",
            pty_port
        ),
    ];

    let result = timeout(
        cmd_timeout,
        Command::new(nsenter_path)
            .args(nsenter_args(inner_pid, None, &pty_cmd))
            .output(),
    )
    .await;

    match result {
        Ok(Ok(output)) => {
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                debug!("cmux-pty start warning: {}", stderr);
            }
        }
        Ok(Err(e)) => return Err(format!("cmux-pty command error: {}", e)),
        Err(_) => {
            debug!("cmux-pty command timed out (expected for backgrounded process)");
        }
    }

    // Wait for cmux-pty to start listening
    sleep(Duration::from_millis(300)).await;

    // Verify cmux-pty is running by checking if it's listening on the port
    let verify_cmd = vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        format!("pgrep -f 'cmux-pty.*--port {}'", pty_port),
    ];
    let verify_result = timeout(
        Duration::from_secs(5),
        Command::new(nsenter_path)
            .args(nsenter_args(inner_pid, None, &verify_cmd))
            .output(),
    )
    .await;

    let pty_running = matches!(verify_result, Ok(Ok(ref output)) if output.status.success());
    if !pty_running {
        return Err(format!("cmux-pty failed to start on port {}", pty_port));
    }

    info!(pty_port = pty_port, "cmux-pty started");
    Ok(())
}

impl BubblewrapService {
    pub async fn new(workspace_root: PathBuf, port: u16) -> SandboxResult<Self> {
        if !workspace_root.exists() {
            fs::create_dir_all(&workspace_root).await?;
        }

        let bubblewrap_path = find_binary("bwrap")?;
        let ip_path = find_binary("ip")?;
        let iptables_path = find_binary("iptables")?;
        let nsenter_path = find_binary("nsenter")?;
        let docker = DockerConfig::from_env()?;

        let service = Self {
            sandboxes: Mutex::new(HashMap::new()),
            workspace_root,
            ip_pool: Mutex::new(IpPool::new(NETWORK_BASE)),
            bubblewrap_path,
            ip_path,
            iptables_path,
            nsenter_path,
            port,
            next_index: AtomicUsize::new(0),
            docker,
            readiness: Mutex::new(HashMap::new()),
        };

        service.setup_host_network().await?;
        Ok(service)
    }

    async fn setup_host_network(&self) -> SandboxResult<()> {
        // Enable IP forwarding
        if let Err(e) = run_command("sysctl", &["-w", "net.ipv4.ip_forward=1"]).await {
            warn!("failed to enable ip forwarding (might be already enabled or permission denied): {}", e);
        }

        // Add MASQUERADE rule for sandbox subnet if it doesn't exist
        let subnet = format!("{}/16", NETWORK_BASE);

        // Check existence
        let check = run_command(
            &self.iptables_path,
            &[
                "-t",
                "nat",
                "-C",
                "POSTROUTING",
                "-s",
                &subnet,
                "!",
                "-d",
                &subnet,
                "-j",
                "MASQUERADE",
            ],
        )
        .await;

        if check.is_err() {
            run_command(
                &self.iptables_path,
                &[
                    "-t",
                    "nat",
                    "-A",
                    "POSTROUTING",
                    "-s",
                    &subnet,
                    "!",
                    "-d",
                    &subnet,
                    "-j",
                    "MASQUERADE",
                ],
            )
            .await?;
        }

        Ok(())
    }

    async fn ensure_docker_socket(&self) -> SandboxResult<()> {
        for _ in 0..10 {
            if self.docker.host_socket().exists() {
                return Ok(());
            }
            sleep(Duration::from_millis(200)).await;
        }

        Err(SandboxError::Internal(format!(
            "docker socket not found at {}. Set CMUX_DOCKER_MODE=dind or mount the host socket (override with CMUX_DOCKER_SOCKET).",
            self.docker.host_socket().display()
        )))
    }

    fn default_name(id: &Uuid) -> String {
        let mut buffer = Uuid::encode_buffer();
        let encoded = id.as_simple().encode_lower(&mut buffer);
        let slug = encoded.get(0..8).unwrap_or("sandbox");
        format!("sandbox-{slug}")
    }

    fn resolve_workspace(&self, request: &CreateSandboxRequest, id: &Uuid) -> PathBuf {
        if let Some(raw) = &request.workspace {
            let path = PathBuf::from(raw);
            if path.is_absolute() {
                return path;
            }

            return self.workspace_root.join(path);
        }

        self.workspace_root.join(id.to_string()).join("workspace")
    }

    async fn resolve_id(&self, id_str: &str) -> SandboxResult<Uuid> {
        // 1. Try parsing as full UUID
        if let Ok(uuid) = Uuid::parse_str(id_str) {
            return Ok(uuid);
        }

        // 2. Try parsing as integer index
        if let Ok(index) = id_str.parse::<usize>() {
            let guard = self.sandboxes.lock().await;
            for (uuid, entry) in guard.iter() {
                if entry.handle.index == index {
                    return Ok(*uuid);
                }
            }
        }

        // 3. Try searching by prefix
        let guard = self.sandboxes.lock().await;
        let mut matched = None;
        for (uuid, _) in guard.iter() {
            let simple = uuid.simple().to_string();
            if simple.starts_with(id_str) {
                if matched.is_some() {
                    return Err(SandboxError::InvalidRequest(format!(
                        "ambiguous short id: {id_str}"
                    )));
                }
                matched = Some(*uuid);
            }
        }

        matched.ok_or_else(|| SandboxError::InvalidRequest(format!("sandbox not found: {id_str}")))
    }

    async fn setup_dns(&self, etc_merged: &Path) -> SandboxResult<()> {
        let resolv_conf_path = etc_merged.join("resolv.conf");

        // Read host's resolv.conf (following symlinks/mounts)
        let content = match fs::read_to_string("/etc/resolv.conf").await {
            Ok(c) => c,
            Err(_) => "nameserver 8.8.8.8\nnameserver 1.1.1.1".to_string(),
        };

        // Filter out local resolvers that won't work in sandbox
        let filtered_lines: Vec<&str> = content
            .lines()
            .filter(|l| !l.contains("127.0.0.53") && !l.contains("127.0.0.1"))
            .collect();

        let final_content = if filtered_lines.is_empty() {
            "nameserver 8.8.8.8\nnameserver 1.1.1.1".to_string()
        } else {
            filtered_lines.join("\n")
        };

        fs::write(&resolv_conf_path, final_content).await?;
        Ok(())
    }

    async fn setup_hosts(&self, etc_merged: &Path, hostname: &str) -> SandboxResult<()> {
        let hosts_path = etc_merged.join("hosts");
        let content = format!("127.0.0.1\tlocalhost\n127.0.0.1\t{}\n", hostname);
        fs::write(&hosts_path, content).await?;
        Ok(())
    }

    async fn setup_apt(&self, etc_merged: &Path) -> SandboxResult<()> {
        let apt_conf_dir = etc_merged.join("apt/apt.conf.d");
        // Ensure directory exists (it might be a new directory in the upper layer if copy-up happens,
        // or we might need to create it if it doesn't exist in lower, though it should)
        fs::create_dir_all(&apt_conf_dir).await?;

        let conf_path = apt_conf_dir.join("99sandbox");
        let content = "Acquire::PrivilegeDrop::User \"root\";\n";
        fs::write(&conf_path, content).await?;
        Ok(())
    }

    async fn setup_bashrc(&self, root_merged: &Path) -> SandboxResult<()> {
        let root_home = root_merged.join("root");
        fs::create_dir_all(&root_home).await?;

        let bashrc = root_home.join(".bashrc");
        let content = r#"
# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]# '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w# '
fi
unset color_prompt force_color_prompt

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

alias g=git
"#;
        fs::write(&bashrc, content).await?;
        Ok(())
    }

    async fn setup_zshrc(&self, root_merged: &Path) -> SandboxResult<()> {
        let root_home = root_merged.join("root");
        fs::create_dir_all(&root_home).await?;

        let zshrc = root_home.join(".zshrc");
        // Only create default .zshrc if user hasn't synced their own
        if zshrc.exists() {
            return Ok(());
        }

        let content = r#"# ~/.zshrc: zsh configuration for cmux sandbox

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY

# Directory navigation
setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS

# Enable colors
autoload -U colors && colors

# Git branch info for prompt
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' %F{magenta}(%b)%f'
zstyle ':vcs_info:*' enable git
setopt PROMPT_SUBST

# Prompt: user@host:path (branch)#
# Green user@host, blue path, magenta git branch
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f${vcs_info_msg_0_}%F{yellow}#%f '

# Add user completion directories to fpath (synced from host)
# These must be added before compinit to be recognized
[[ -d ~/.zfunc ]] && fpath=(~/.zfunc $fpath)
[[ -d ~/.local/share/zsh/completions ]] && fpath=(~/.local/share/zsh/completions $fpath)
[[ -d ~/.zsh/completions ]] && fpath=(~/.zsh/completions $fpath)

# Enable completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# Color support for ls
if [[ -x /usr/bin/dircolors ]]; then
    eval "$(dircolors -b)"
fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias g='git'
alias gs='git status'
alias gd='git diff'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline -20'

# Key bindings
bindkey -e  # emacs mode
bindkey '^[[A' up-line-or-search
bindkey '^[[B' down-line-or-search
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char

# Source zsh-autosuggestions
if [[ -f ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
elif [[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

# Source zsh-syntax-highlighting (must be last)
if [[ -f ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
elif [[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# Source user's custom additions
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
"#;
        fs::write(&zshrc, content).await?;
        Ok(())
    }

    async fn setup_gitconfig(&self, root_merged: &Path) -> SandboxResult<()> {
        let root_home = root_merged.join("root");
        fs::create_dir_all(&root_home).await?;

        let gitconfig = root_home.join(".gitconfig");
        // Only set safe.directory - user's gitconfig is synced from host
        // Users can enable delta via command palette (EnableDeltaPager) for better diff viewing
        let content = r#"[safe]
	directory = *
"#;
        fs::write(&gitconfig, content).await?;
        Ok(())
    }

    /// Setup agent notification hook configurations.
    /// Copies config files from /usr/share/cmux/agent-config/ into the sandbox's /root.
    /// These configure Claude Code, Codex, and OpenCode to send notifications via cmux-bridge.
    async fn setup_agent_configs(&self, root_merged: &Path) -> SandboxResult<()> {
        let root_home = root_merged.join("root");
        let agent_config_dir = Path::new("/usr/share/cmux/agent-config");

        // Claude Code: ~/.claude/settings.json
        let claude_src = agent_config_dir.join("claude/settings.json");
        if claude_src.exists() {
            let claude_dir = root_home.join(".claude");
            fs::create_dir_all(&claude_dir).await?;
            fs::copy(&claude_src, claude_dir.join("settings.json")).await?;
        }

        // Codex: ~/.codex/config.toml
        let codex_src = agent_config_dir.join("codex/config.toml");
        if codex_src.exists() {
            let codex_dir = root_home.join(".codex");
            fs::create_dir_all(&codex_dir).await?;
            fs::copy(&codex_src, codex_dir.join("config.toml")).await?;
        }

        // OpenCode: ~/.config/opencode/plugin/notification.js
        let opencode_src = agent_config_dir.join("opencode/notification.js");
        if opencode_src.exists() {
            let opencode_dir = root_home.join(".config/opencode/plugin");
            fs::create_dir_all(&opencode_dir).await?;
            fs::copy(&opencode_src, opencode_dir.join("notification.js")).await?;
        }

        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn spawn_bubblewrap(
        &self,
        request: &CreateSandboxRequest,
        env: &[EnvVar],
        workspace: &Path,
        system_dir: &Path,
        _id: &Uuid,
        _lease: &IpLease,
        index: usize,
    ) -> SandboxResult<(Child, u32)> {
        // Prepare system directories for the sandbox
        fs::create_dir_all(system_dir).await?;

        // Phase 1: Setup overlays and root directory in parallel
        let root_merged = system_dir.join("root-merged");
        let root_merged_clone = root_merged.clone();
        let (usr_merged, etc_merged, var_merged, _) = tokio::try_join!(
            mount_overlay(system_dir, "usr", "/usr"),
            mount_overlay(system_dir, "etc", "/etc"),
            mount_overlay(system_dir, "var", "/var"),
            async {
                fs::create_dir_all(&root_merged_clone).await?;
                Ok::<_, SandboxError>(())
            },
        )?;

        // Phase 2: Setup all config files in parallel (they write to different paths)
        let hostname = format!("sandbox-{}", index);
        tokio::try_join!(
            // root-merged setups
            self.setup_bashrc(&root_merged),
            self.setup_zshrc(&root_merged),
            self.setup_gitconfig(&root_merged),
            self.setup_agent_configs(&root_merged),
            // etc overlay setups
            self.setup_dns(&etc_merged),
            self.setup_hosts(&etc_merged, &hostname),
            self.setup_apt(&etc_merged),
            // Docker socket can be ensured in parallel too
            self.ensure_docker_socket(),
        )?;

        let workspace_str = workspace
            .to_str()
            .ok_or_else(|| {
                SandboxError::InvalidRequest("workspace path is not valid UTF-8".into())
            })?
            .to_owned();

        let docker_socket_host = path_to_string(self.docker.host_socket(), "docker socket")?;

        let mut command = Command::new(&self.bubblewrap_path);
        command.kill_on_drop(true);
        command.stdout(Stdio::piped());
        command.args([
            "--die-with-parent",
            "--unshare-net",
            "--unshare-pid",
            "--unshare-uts",
            "--unshare-ipc",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--perms",
            "1777",
            "--tmpfs",
            "/tmp",
            "--perms",
            "1777",
            "--tmpfs",
            "/var/tmp",
            "--tmpfs",
            "/run",
            // Bind-mount the cmux socket directory so sandboxes can open URLs
            "--bind",
            "/var/run/cmux",
            "/run/cmux",
            // Bind-mount the Docker socket for Docker-in-Docker support
            "--bind",
            &docker_socket_host,
            DOCKER_CONTAINER_SOCKET,
            "--bind",
            &workspace_str,
            SANDBOX_WORKSPACE_MOUNT,
            "--chdir",
            SANDBOX_WORKSPACE_MOUNT,
            "--hostname",
            &format!("sandbox-{}", index),
            "--json-status-fd",
            "1",
        ]);

        let usr_overlay = path_to_string(&usr_merged, "usr overlay")?;
        let etc_overlay = path_to_string(&etc_merged, "etc overlay")?;
        let var_overlay = path_to_string(&var_merged, "var overlay")?;

        // Bind overlays
        command.args(["--bind", &usr_overlay, "/usr"]);
        command.args(["--bind", &etc_overlay, "/etc"]);
        command.args(["--bind", &var_overlay, "/var"]);

        // Note: setup_bashrc wrote to root-merged/root/.bashrc
        let root_overlay = root_merged.join("root");
        let root_overlay = path_to_string(&root_overlay, "root overlay")?;
        command.args(["--bind", &root_overlay, "/root"]);

        // Mount VS Code extensions from Docker image (read-only for efficiency)
        // This overlays the extensions dir on top of the writable /root
        let vscode_extensions_path = "/root/.vscode-server-oss/extensions";
        if Path::new(vscode_extensions_path).exists() {
            command.args(["--ro-bind", vscode_extensions_path, vscode_extensions_path]);
        }

        // Make common paths available inside the sandbox
        // /opt, /home/linuxbrew, /snap for credential helpers
        // /app for cmux-code (VS Code server)
        for path_str in ["/opt", "/home/linuxbrew/.linuxbrew", "/snap", "/app"] {
            let path = Path::new(path_str);
            if path.exists() {
                command.args(["--ro-bind", path_str, path_str]);
            }
        }

        // Hide sensitive host paths exposed via /var overlay
        command.args(["--tmpfs", "/var/lib/docker"]);
        command.args(["--tmpfs", "/var/lib/cmux"]);

        for path_str in ["/bin", "/sbin", "/lib", "/lib64"] {
            let path = Path::new(path_str);
            if !path.exists() {
                continue;
            }

            match fs::symlink_metadata(path).await {
                Ok(meta) if meta.file_type().is_symlink() => {
                    if let Ok(target) = fs::read_link(path).await {
                        command.args(["--symlink", &target.to_string_lossy(), path_str]);
                    }
                }
                Ok(_) => {
                    command.args(["--ro-bind", path_str, path_str]);
                }
                Err(_) => {}
            }
        }

        for path in &request.read_only_paths {
            command.args(["--ro-bind", path, path]);
        }

        for mount in &request.tmpfs {
            command.args(["--tmpfs", mount]);
        }

        for env in env {
            command.env(&env.key, &env.value);
        }

        command.env("IS_SANDBOX", "1");
        // Docker socket is bind-mounted to /run/docker.sock
        command.env("DOCKER_HOST", self.docker.docker_host_env());
        // Bridge socket path (mapped from /var/run/cmux to /run/cmux inside sandbox)
        command.env("CMUX_BRIDGE_SOCKET", "/run/cmux/bridge.sock");

        // SSH agent forwarding: if the socket exists in the container, bind-mount it into the sandbox
        let ssh_socket_path = Path::new("/ssh-agent.sock");
        if ssh_socket_path.exists() {
            command.args(["--bind", "/ssh-agent.sock", "/ssh-agent.sock"]);
            command.env("SSH_AUTH_SOCK", "/ssh-agent.sock");
        }

        command.args(["--", "/bin/sh", "-c", "ip link set lo up && sleep infinity"]);

        let mut child = command.spawn()?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| SandboxError::Internal("failed to capture bwrap stdout".into()))?;

        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        reader.read_line(&mut line).await?;

        let status: BwrapStatus = serde_json::from_str(&line).map_err(|e| {
            SandboxError::Internal(format!("failed to parse bwrap status: {e}, line: {line}"))
        })?;

        Ok((child, status.child_pid))
    }

    /// Prepare the host side of the network (veth creation + host config).
    /// This can run in parallel with bubblewrap spawn since it doesn't need the child PID.
    async fn prepare_network_host_side(
        &self,
        host_if: &str,
        ns_if: &str,
        host_cidr: &str,
    ) -> SandboxResult<()> {
        // Create veth pair and configure host side in one shell command
        let script = format!(
            "{ip} link add {host} type veth peer name {ns} && \
             {ip} addr add {cidr} dev {host} && \
             {ip} link set {host} up",
            ip = self.ip_path,
            host = host_if,
            ns = ns_if,
            cidr = host_cidr
        );
        run_command("/bin/sh", &["-c", &script]).await
    }

    /// Finish network configuration by moving interface to namespace and configuring sandbox side.
    /// This must run after bubblewrap spawn since it needs the child PID.
    async fn finish_network_sandbox_side(
        &self,
        pid: u32,
        lease: &IpLease,
        host_if: &str,
        ns_if: &str,
        sandbox_cidr: &str,
    ) -> SandboxResult<SandboxNetwork> {
        let formatted_pid = pid.to_string();

        // Move interface to sandbox namespace
        run_command(
            &self.ip_path,
            &["link", "set", ns_if, "netns", &formatted_pid],
        )
        .await?;

        // Configure sandbox side - all in one nsenter call
        let host_ip = lease.host.to_string();
        let script = format!(
            "ip addr add {} dev {} && ip link set {} up && ip link set lo up && ip route replace default via {}",
            sandbox_cidr, ns_if, ns_if, host_ip
        );
        run_command(
            &self.nsenter_path,
            &[
                "--target",
                &formatted_pid,
                "--net",
                "--",
                "/bin/sh",
                "-c",
                &script,
            ],
        )
        .await?;

        Ok(SandboxNetwork {
            host_interface: host_if.to_string(),
            sandbox_interface: ns_if.to_string(),
            host_ip: lease.host.to_string(),
            sandbox_ip: lease.sandbox.to_string(),
            cidr: lease.cidr,
        })
    }

    async fn teardown_network(&self, network: &SandboxNetwork) {
        let delete_result =
            run_command(&self.ip_path, &["link", "del", &network.host_interface]).await;
        if let Err(error) = delete_result {
            warn!(
                "failed to delete interface {}: {error}",
                network.host_interface
            );
        }
    }

    async fn workspace_summary(
        entry: &SandboxEntry,
        child: &mut Child,
    ) -> SandboxResult<SandboxSummary> {
        let status = match child.try_wait()? {
            None => SandboxStatus::Running,
            Some(exit_status) => {
                if exit_status.success() {
                    SandboxStatus::Exited
                } else {
                    SandboxStatus::Failed
                }
            }
        };

        Ok(entry.handle.to_summary(status))
    }

    /// Spawn a PTY session for multiplexed attach.
    #[allow(clippy::too_many_arguments)]
    async fn spawn_mux_pty_session(
        &self,
        session_id: PtySessionId,
        inner_pid: u32,
        command: Vec<String>,
        cols: u16,
        rows: u16,
        env: &[EnvVar],
        tab_id: Option<String>,
        pane_id: Option<String>,
        output_tx: mpsc::UnboundedSender<MuxServerMessage>,
    ) -> SandboxResult<PtySessionHandle> {
        let system = NativePtySystem::default();
        let pair = system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| SandboxError::Internal(format!("failed to open pty: {e}")))?;

        let mut cmd = CommandBuilder::new(&self.nsenter_path);
        cmd.args(nsenter_args(inner_pid, None, &command));
        cmd.env("HOME", "/root");
        cmd.env("SHELL", "/bin/zsh");
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor"); // Enable 24-bit RGB color support
        cmd.env("LANG", "C.UTF-8");
        cmd.env("LC_ALL", "C.UTF-8");
        cmd.env("IS_SANDBOX", "1");
        cmd.env("DOCKER_HOST", self.docker.docker_host_env());
        // SSH agent forwarding
        let ssh_socket_path = Path::new("/ssh-agent.sock");
        if ssh_socket_path.exists() {
            cmd.env("SSH_AUTH_SOCK", "/ssh-agent.sock");
        }
        // Apply sandbox-specific env vars
        let session_env = session_env_with_overrides(env, tab_id, pane_id);
        for e in &session_env {
            cmd.env(&e.key, &e.value);
        }

        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| SandboxError::Internal(format!("failed to spawn pty command: {e}")))?;
        let child_pid = child.process_id();
        // Release slave so it closes when child exits
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| SandboxError::Internal(format!("failed to clone pty reader: {e}")))?;
        let mut writer = pair
            .master
            .take_writer()
            .map_err(|e| SandboxError::Internal(format!("failed to take pty writer: {e}")))?;

        let (input_tx, mut input_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        // Channel for sending resize events to the reader thread's VirtualTerminal
        let (resize_tx, resize_rx) = std::sync::mpsc::channel::<(u16, u16)>();

        // Reader thread: PTY -> output channel
        // Uses a VirtualTerminal to process escape sequences and handle DA queries locally.
        // This avoids the PTY echo issue where responses sent back through the PTY get echoed.
        let session_id_clone = session_id.clone();
        let output_tx_clone = output_tx.clone();
        let input_tx_clone = input_tx.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            // Create a VirtualTerminal for processing escape sequences
            // We use it to detect and respond to terminal queries (DA1, DA2, etc.)
            let mut vterm = VirtualTerminal::new(rows as usize, cols as usize);
            loop {
                // Check for any pending resize events (non-blocking)
                while let Ok((new_rows, new_cols)) = resize_rx.try_recv() {
                    vterm.resize(new_rows as usize, new_cols as usize);
                }

                match reader.read(&mut buf) {
                    Ok(0) => {
                        // PTY closed
                        let _ = output_tx_clone.send(MuxServerMessage::Exited {
                            session_id: session_id_clone,
                            exit_code: None,
                        });
                        break;
                    }
                    Ok(n) => {
                        let data = &buf[..n];

                        // Process through VirtualTerminal to detect queries
                        vterm.process(data);

                        // Send any pending responses (DA1, DA2, DSR, etc.) back to PTY
                        let responses = vterm.drain_responses();
                        for response in responses {
                            let _ = input_tx_clone.send(response);
                        }

                        // Forward original output to WebSocket
                        if output_tx_clone
                            .send(MuxServerMessage::Output {
                                session_id: session_id_clone.clone(),
                                data: data.to_vec(),
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                    Err(_) => {
                        let _ = output_tx_clone.send(MuxServerMessage::Exited {
                            session_id: session_id_clone,
                            exit_code: None,
                        });
                        break;
                    }
                }
            }
        });

        // Writer thread: input channel -> PTY
        std::thread::spawn(move || {
            while let Some(data) = input_rx.blocking_recv() {
                if writer.write_all(&data).is_err() {
                    break;
                }
                let _ = writer.flush();
            }
        });

        Ok(PtySessionHandle {
            input_tx,
            resize_tx,
            master: pair.master,
            child,
            child_pid,
        })
    }
}

fn find_binary(name: &str) -> SandboxResult<String> {
    let binary_path = which(name)
        .map_err(|_| SandboxError::MissingBinary(name.to_owned()))?
        .to_string_lossy()
        .to_string();
    Ok(binary_path)
}

fn normalize_docker_socket(raw: &str) -> SandboxResult<PathBuf> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(SandboxError::Internal(
            "CMUX_DOCKER_SOCKET must not be empty".to_string(),
        ));
    }

    let without_scheme = trimmed.strip_prefix("unix://").unwrap_or(trimmed);
    Ok(PathBuf::from(without_scheme))
}

fn path_to_string(path: &Path, context: &str) -> SandboxResult<String> {
    path.to_str().map(|value| value.to_string()).ok_or_else(|| {
        SandboxError::Internal(format!(
            "{context} path is not valid UTF-8: {}",
            path.display()
        ))
    })
}

fn make_interface_names(id: &Uuid) -> (String, String) {
    let mut buffer = Uuid::encode_buffer();
    let encoded = id.as_simple().encode_lower(&mut buffer);
    let short = encoded.get(0..8).unwrap_or("ns");
    (
        format!("{HOST_IF_PREFIX}-{short}"),
        format!("{NS_IF_PREFIX}-{short}"),
    )
}

fn normalize_optional_field(value: &Option<String>) -> Option<String> {
    value
        .as_ref()
        .map(|item| item.trim())
        .filter(|item| !item.is_empty())
        .map(|item| item.to_string())
}

fn build_effective_env(
    request_env: &[EnvVar],
    lease: &IpLease,
    port: u16,
    sandbox_id: &Uuid,
    tab_id: &Option<String>,
    docker_host: &str,
) -> Vec<EnvVar> {
    let mut merged = BTreeMap::new();
    for env in request_env {
        merged.insert(env.key.clone(), env.value.clone());
    }
    merged.insert("DOCKER_HOST".to_string(), docker_host.to_string());

    merged.insert("CMUX_SANDBOX_ID".to_string(), sandbox_id.to_string());
    merged.insert(
        "CMUX_TAB_ID".to_string(),
        normalize_optional_field(tab_id).unwrap_or_else(|| "unknown".to_string()),
    );
    merged.insert(
        "CMUX_SANDBOX_URL".to_string(),
        format!("http://{}:{}", lease.host, port),
    );

    merged
        .into_iter()
        .map(|(key, value)| EnvVar { key, value })
        .collect()
}

fn session_env_with_overrides(
    base_env: &[EnvVar],
    tab_id: Option<String>,
    pane_id: Option<String>,
) -> Vec<EnvVar> {
    let mut merged: BTreeMap<String, String> = base_env
        .iter()
        .map(|env| (env.key.clone(), env.value.clone()))
        .collect();

    if let Some(id) = tab_id {
        merged.insert("CMUX_TAB_ID".to_string(), id);
    }

    if let Some(id) = pane_id {
        merged.insert("CMUX_PANE_ID".to_string(), id);
    }

    merged
        .into_iter()
        .map(|(key, value)| EnvVar { key, value })
        .collect()
}

#[async_trait]
impl SandboxService for BubblewrapService {
    async fn create(&self, request: CreateSandboxRequest) -> SandboxResult<SandboxSummary> {
        let id = Uuid::new_v4();
        let mut timing = TimingReport::new("sandbox_create", &id.to_string());

        let index = self.next_index.fetch_add(1, Ordering::Relaxed);
        let name = request
            .name
            .clone()
            .unwrap_or_else(|| Self::default_name(&id));

        // Phase: workspace setup
        let workspace = self.resolve_workspace(&request, &id);
        let workspace_timer = crate::timing::Timer::new("workspace_setup");
        fs::create_dir_all(&workspace).await?;
        timing.record_timer("workspace_setup", workspace_timer);

        let system_dir = self.workspace_root.join(id.to_string()).join("system");

        // Phase: IP allocation
        let ip_timer = crate::timing::Timer::new("ip_allocation");
        let lease = {
            let mut pool = self.ip_pool.lock().await;
            pool.allocate()?
        };
        timing.record_timer("ip_allocation", ip_timer);

        let effective_env = build_effective_env(
            &request.env,
            &lease,
            self.port,
            &id,
            &request.tab_id,
            self.docker.docker_host_env(),
        );

        // Phase: spawn bubblewrap AND prepare network in parallel
        // Veth creation + host setup don't need the child PID, so run them concurrently
        let spawn_timer = crate::timing::Timer::new("spawn_and_net_prepare");
        let (host_if, ns_if) = make_interface_names(&id);
        let host_cidr = format!("{}/{}", lease.host, lease.cidr);

        let spawn_fut = self.spawn_bubblewrap(
            &request,
            &effective_env,
            &workspace,
            &system_dir,
            &id,
            &lease,
            index,
        );

        let net_prepare_fut = self.prepare_network_host_side(&host_if, &ns_if, &host_cidr);

        let (spawn_result, net_prepare_result) = tokio::join!(spawn_fut, net_prepare_fut);

        // Handle spawn result
        let (mut child, inner_pid) = match spawn_result {
            Ok(res) => res,
            Err(error) => {
                // Clean up network if it was created
                let _ = run_command(&self.ip_path, &["link", "del", &host_if]).await;
                cleanup_overlays(&system_dir).await;
                let mut pool = self.ip_pool.lock().await;
                pool.release(&lease);
                return Err(error);
            }
        };

        // Handle network prepare result
        if let Err(error) = net_prepare_result {
            let _ = child.kill().await;
            // Clean up veth pair if it was partially created
            let _ = run_command(&self.ip_path, &["link", "del", &host_if]).await;
            cleanup_overlays(&system_dir).await;
            let mut pool = self.ip_pool.lock().await;
            pool.release(&lease);
            return Err(error);
        }
        timing.record_timer("spawn_and_net_prepare", spawn_timer);

        // Phase: finish network configuration (needs PID, must be sequential)
        let net_finish_timer = crate::timing::Timer::new("net_finish");
        let sandbox_cidr = format!("{}/{}", lease.sandbox, lease.cidr);
        let network = match self
            .finish_network_sandbox_side(inner_pid, &lease, &host_if, &ns_if, &sandbox_cidr)
            .await
        {
            Ok(net) => net,
            Err(error) => {
                let _ = child.kill().await;
                let _ = run_command(&self.ip_path, &["link", "del", &host_if]).await;
                cleanup_overlays(&system_dir).await;
                {
                    let mut pool = self.ip_pool.lock().await;
                    pool.release(&lease);
                }
                return Err(error);
            }
        };
        timing.record_timer("net_finish", net_finish_timer);

        // Calculate display configuration for isolated X11/VNC desktop and VS Code
        // Display numbers start at 10 to avoid conflicts with system displays (:0, :1, etc.)
        // All sandboxes use fixed ports internally, accessed via subdomain routing:
        //   {index}-39380.host -> noVNC, {index}-39378.host -> VS Code, {index}-39383.host -> cmux-pty
        let display_number = (10 + index) as u16;
        let vnc_port = 5900 + display_number;
        let novnc_port = 39380_u16; // Fixed port, accessed via subdomain routing
        let cdp_port = 39381_u16; // Fixed port, accessed via subdomain routing
        let vscode_port = 39378_u16; // Fixed port for cmux-code
        let pty_port = 39383_u16; // Fixed port for cmux-pty

        // Display config is set immediately (ports are known upfront)
        // Services start in background - use await_services_ready to wait for VNC/VS Code/PTY
        let display = Some(SandboxDisplay {
            display_number,
            vnc_port,
            novnc_port,
            cdp_port,
            vscode_port,
            pty_port,
        });

        // Create readiness watch channel for this sandbox
        let (readiness_tx, _) = watch::channel(ServiceReadiness::default());
        {
            let mut readiness_map = self.readiness.lock().await;
            readiness_map.insert(id, readiness_tx);
        }

        // Spawn services startup in background (non-blocking)
        // This allows sandbox creation to return immediately
        {
            let nsenter_path = self.nsenter_path.clone();
            let sandbox_id = id;
            let readiness = self.readiness.lock().await.get(&id).cloned();
            let workspace_path = SANDBOX_WORKSPACE_MOUNT;

            tokio::spawn(async move {
                // Start X11/VNC stack
                let vnc_result = start_x11_stack_background(
                    &nsenter_path,
                    inner_pid,
                    display_number,
                    vnc_port,
                    cdp_port,
                )
                .await;

                let vnc_ready = match vnc_result {
                    Ok(()) => {
                        info!(
                            sandbox_id = %sandbox_id,
                            display_number = display_number,
                            vnc_port = vnc_port,
                            "X11 stack ready (background)"
                        );
                        true
                    }
                    Err(e) => {
                        warn!(
                            sandbox_id = %sandbox_id,
                            error = %e,
                            "X11 stack failed in background - VNC will be unavailable"
                        );
                        false
                    }
                };

                // Update readiness with VNC status
                if let Some(ref tx) = readiness {
                    let _ = tx.send(ServiceReadiness {
                        vnc: vnc_ready,
                        vscode: false,
                        pty: false,
                    });
                }

                // Start cmux-pty FIRST (PTY server) - must be ready before VS Code extension activates
                let pty_result =
                    start_cmux_pty_background(&nsenter_path, inner_pid, pty_port).await;

                let pty_ready = match pty_result {
                    Ok(()) => {
                        info!(
                            sandbox_id = %sandbox_id,
                            pty_port = pty_port,
                            "cmux-pty ready (background)"
                        );
                        true
                    }
                    Err(e) => {
                        warn!(
                            sandbox_id = %sandbox_id,
                            error = %e,
                            "cmux-pty failed in background - PTY will be unavailable"
                        );
                        false
                    }
                };

                // Update readiness with VNC and PTY status
                if let Some(ref tx) = readiness {
                    let _ = tx.send(ServiceReadiness {
                        vnc: vnc_ready,
                        vscode: false,
                        pty: pty_ready,
                    });
                }

                // Start cmux-code (VS Code server) AFTER cmux-pty is ready
                let vscode_result =
                    start_vscode_background(&nsenter_path, inner_pid, vscode_port, workspace_path)
                        .await;

                let vscode_ready = match vscode_result {
                    Ok(()) => {
                        info!(
                            sandbox_id = %sandbox_id,
                            vscode_port = vscode_port,
                            "cmux-code ready (background)"
                        );
                        true
                    }
                    Err(e) => {
                        warn!(
                            sandbox_id = %sandbox_id,
                            error = %e,
                            "cmux-code failed in background - VS Code will be unavailable"
                        );
                        false
                    }
                };

                // Update readiness with all service statuses
                if let Some(tx) = readiness {
                    let _ = tx.send(ServiceReadiness {
                        vnc: vnc_ready,
                        vscode: vscode_ready,
                        pty: pty_ready,
                    });
                }
            });
        }

        let handle = SandboxHandle {
            id,
            index,
            name,
            workspace,
            network,
            created_at: Utc::now(),
            lease,
            correlation_id: request.tab_id.clone(),
            display,
        };

        let entry = SandboxEntry {
            handle,
            child: Arc::new(Mutex::new(child)),
            inner_pid,
            env: effective_env,
        };

        // Phase: finalize
        let finalize_timer = crate::timing::Timer::new("finalize");
        let summary = {
            let mut child = entry.child.lock().await;
            Self::workspace_summary(&entry, &mut child).await?
        };

        let mut sandboxes = self.sandboxes.lock().await;
        sandboxes.insert(id, entry);
        timing.record_timer("finalize", finalize_timer);

        info!("created sandbox {id}");
        timing.finish();
        Ok(summary)
    }

    async fn list(&self) -> SandboxResult<Vec<SandboxSummary>> {
        let entries: Vec<SandboxEntry> = {
            let guard = self.sandboxes.lock().await;
            guard.values().cloned().collect()
        };

        let mut results = Vec::with_capacity(entries.len());
        for entry in entries {
            let mut child = entry.child.lock().await;
            results.push(Self::workspace_summary(&entry, &mut child).await?);
        }

        // Sort by index to keep stable order
        results.sort_by_key(|s| s.index);

        Ok(results)
    }

    async fn get(&self, id_str: String) -> SandboxResult<Option<SandboxSummary>> {
        let id = match self.resolve_id(&id_str).await {
            Ok(id) => id,
            Err(_) => return Ok(None),
        };

        let entry = {
            let sandboxes = self.sandboxes.lock().await;
            sandboxes.get(&id).cloned()
        };

        if let Some(entry) = entry {
            let mut child = entry.child.lock().await;
            let summary = Self::workspace_summary(&entry, &mut child).await?;
            return Ok(Some(summary));
        }

        Ok(None)
    }

    async fn exec(&self, id_str: String, exec: ExecRequest) -> SandboxResult<ExecResponse> {
        let id = self.resolve_id(&id_str).await?;

        if exec.command.is_empty() {
            return Err(SandboxError::InvalidRequest(
                "exec.command must not be empty".into(),
            ));
        }

        let entry = {
            let sandboxes = self.sandboxes.lock().await;
            sandboxes.get(&id).cloned()
        }
        .ok_or(SandboxError::NotFound(id))?;

        let mut command = Command::new(&self.nsenter_path);
        for env in &entry.env {
            command.env(&env.key, &env.value);
        }
        for env in &exec.env {
            command.env(&env.key, &env.value);
        }
        command.env("IS_SANDBOX", "1");

        command.args(nsenter_args(
            entry.inner_pid,
            exec.workdir.as_deref(),
            &exec.command,
        ));

        command.kill_on_drop(true);
        let output = command.output().await?;
        let exit_code = output.status.code().unwrap_or_default();
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();

        Ok(ExecResponse {
            exit_code,
            stdout,
            stderr,
        })
    }

    async fn attach(
        &self,
        id_str: String,
        mut socket: WebSocket,
        initial_size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
        tty: bool,
    ) -> SandboxResult<()> {
        let id = self.resolve_id(&id_str).await?;
        let entry = {
            let sandboxes = self.sandboxes.lock().await;
            sandboxes.get(&id).cloned()
        }
        .ok_or(SandboxError::NotFound(id))?;

        let target_command =
            command.unwrap_or_else(|| vec!["/bin/zsh".to_string(), "-i".to_string()]);
        info!(
            "attaching to sandbox {} with command: {:?} (tty={})",
            id_str, target_command, tty
        );

        if !tty {
            // Non-PTY path: Use standard pipes
            let mut cmd = Command::new(&self.nsenter_path);
            cmd.args(nsenter_args(entry.inner_pid, None, &target_command));

            for env in &entry.env {
                cmd.env(&env.key, &env.value);
            }
            cmd.env("IS_SANDBOX", "1");
            cmd.env("SHELL", "/bin/zsh");

            cmd.stdin(Stdio::piped());
            cmd.stdout(Stdio::piped());
            cmd.stderr(Stdio::piped());
            cmd.kill_on_drop(true);

            let mut child = cmd.spawn()?;

            let mut stdin = child
                .stdin
                .take()
                .ok_or(SandboxError::Internal("failed to open stdin".into()))?;
            let mut stdout = child
                .stdout
                .take()
                .ok_or(SandboxError::Internal("failed to open stdout".into()))?;
            let mut stderr = child
                .stderr
                .take()
                .ok_or(SandboxError::Internal("failed to open stderr".into()))?;

            let (tx_in, mut rx_in) = tokio::sync::mpsc::channel::<Vec<u8>>(32);

            // Writer task (WebSocket -> Stdin)
            tokio::spawn(async move {
                while let Some(data) = rx_in.recv().await {
                    info!("Writing to stdin: {:?}", String::from_utf8_lossy(&data));
                    if let Err(e) = stdin.write_all(&data).await {
                        warn!("Failed to write to stdin: {}", e);
                        break;
                    }
                    if let Err(e) = stdin.flush().await {
                        warn!("Failed to flush stdin: {}", e);
                        break;
                    }
                    info!("Wrote and flushed to stdin");
                }
            });

            // Reader tasks (Stdout/Stderr -> WebSocket)
            let (tx_out, mut rx_out) = tokio::sync::mpsc::channel::<Vec<u8>>(32);
            let tx_err = tx_out.clone();
            let tx_in_for_dsr = tx_in.clone();
            let tx_in_for_dsr_err = tx_in.clone();

            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                // DSR cursor position query: ESC [ 6 n
                const DSR_QUERY: &[u8] = b"\x1b[6n";
                // DSR status query: ESC [ 5 n
                const DSR_STATUS_QUERY: &[u8] = b"\x1b[5n";
                loop {
                    match stdout.read(&mut buf).await {
                        Ok(0) => {
                            info!("Stdout EOF");
                            break;
                        }
                        Ok(n) => {
                            let data = &buf[..n];
                            info!("Read from stdout: {:?}", String::from_utf8_lossy(data));

                            // Respond to DSR queries even without a PTY to avoid CLI timeouts.
                            if data.windows(DSR_QUERY.len()).any(|w| w == DSR_QUERY) {
                                let response = b"\x1b[1;1R".to_vec();
                                info!("Detected DSR query, injecting cursor position response");
                                let _ = tx_in_for_dsr.send(response).await;
                            }
                            if data
                                .windows(DSR_STATUS_QUERY.len())
                                .any(|w| w == DSR_STATUS_QUERY)
                            {
                                let response = b"\x1b[0n".to_vec();
                                info!("Detected DSR status query, injecting OK response");
                                let _ = tx_in_for_dsr.send(response).await;
                            }

                            if tx_out.send(data.to_vec()).await.is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            warn!("Stdout read error: {}", e);
                            break;
                        }
                    }
                }
            });

            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                // DSR cursor position query: ESC [ 6 n
                const DSR_QUERY: &[u8] = b"\x1b[6n";
                // DSR status query: ESC [ 5 n
                const DSR_STATUS_QUERY: &[u8] = b"\x1b[5n";
                loop {
                    match stderr.read(&mut buf).await {
                        Ok(0) => {
                            info!("Stderr EOF");
                            break;
                        }
                        Ok(n) => {
                            let data = &buf[..n];
                            info!("Read from stderr: {:?}", String::from_utf8_lossy(data));

                            // Respond to DSR queries even without a PTY to avoid CLI timeouts.
                            if data.windows(DSR_QUERY.len()).any(|w| w == DSR_QUERY) {
                                let response = b"\x1b[1;1R".to_vec();
                                info!("Detected DSR query on stderr, injecting cursor position response");
                                let _ = tx_in_for_dsr_err.send(response).await;
                            }
                            if data
                                .windows(DSR_STATUS_QUERY.len())
                                .any(|w| w == DSR_STATUS_QUERY)
                            {
                                let response = b"\x1b[0n".to_vec();
                                info!("Detected DSR status query on stderr, injecting OK response");
                                let _ = tx_in_for_dsr_err.send(response).await;
                            }

                            if tx_err.send(data.to_vec()).await.is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            warn!("Stderr read error: {}", e);
                            break;
                        }
                    }
                }
            });

            loop {
                tokio::select! {
                    msg = socket.recv() => {
                        match msg {
                            Some(Ok(Message::Binary(data))) => {
                                info!("WebSocket Recv Binary: {} bytes", data.len());
                                if tx_in.send(data.into()).await.is_err() { break; }
                            }
                            Some(Ok(Message::Text(text))) => {
                                info!("WebSocket Recv Text: {:?}", text);
                                if tx_in.send(text.as_bytes().to_vec()).await.is_err() { break; }
                            }
                            Some(Ok(Message::Close(_))) | None => {
                                info!("WebSocket Closed");
                                break;
                            }
                            _ => {}
                        }
                    }
                    data = rx_out.recv() => {
                        match data {
                            Some(d) => {
                                info!("Sending to WebSocket: {} bytes", d.len());
                                if socket.send(Message::Binary(d.into())).await.is_err() { break; }
                            }
                            None => break, // Channels closed (child exited)
                        }
                    }
                }
            }

            let _ = child.kill().await;
            return Ok(());
        }

        // PTY Path with VirtualTerminal layer for escape sequence handling
        let (cols, rows) = initial_size.unwrap_or((80, 24));

        let system = NativePtySystem::default();
        let pair = system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| SandboxError::Internal(format!("failed to open pty: {e}")))?;

        let mut cmd = CommandBuilder::new(&self.nsenter_path);

        cmd.args(nsenter_args(entry.inner_pid, None, &target_command));
        cmd.env("HOME", "/root");
        cmd.env("SHELL", "/bin/zsh");
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor"); // Enable 24-bit RGB color support
        cmd.env("LANG", "C.UTF-8");
        cmd.env("LC_ALL", "C.UTF-8");
        cmd.env("IS_SANDBOX", "1");
        cmd.env("DOCKER_HOST", self.docker.docker_host_env());
        // SSH agent forwarding
        let ssh_socket_path = Path::new("/ssh-agent.sock");
        if ssh_socket_path.exists() {
            cmd.env("SSH_AUTH_SOCK", "/ssh-agent.sock");
        }

        let mut child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| SandboxError::Internal(format!("failed to spawn pty command: {e}")))?;
        // Release slave so it closes when child exits
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| SandboxError::Internal(format!("failed to clone pty reader: {e}")))?;
        let mut writer = pair
            .master
            .take_writer()
            .map_err(|e| SandboxError::Internal(format!("failed to take pty writer: {e}")))?;

        let (tx_out, mut rx_out) = tokio::sync::mpsc::channel::<Vec<u8>>(32);
        let (tx_in, mut rx_in) = tokio::sync::mpsc::channel::<Vec<u8>>(32);

        // Reader thread
        std::thread::spawn(move || {
            let mut buf = [0u8; 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if tx_out.blocking_send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        // Writer thread - receives input from WebSocket AND VirtualTerminal responses
        std::thread::spawn(move || {
            while let Some(data) = rx_in.blocking_recv() {
                if writer.write_all(&data).is_err() {
                    break;
                }
                let _ = writer.flush();
            }
        });

        // Create VirtualTerminal for escape sequence processing
        let mut vterm = VirtualTerminal::new(rows as usize, cols as usize);
        // Stateful DA filter to handle sequences split across chunks
        let mut da_filter = DaFilter::new();

        let mut ticker = tokio::time::interval(std::time::Duration::from_millis(100));

        // WebSocket bridge with VirtualTerminal processing
        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    if let Ok(Some(_)) = child.try_wait() {
                        break;
                    }
                }
                msg = socket.recv() => {
                    match msg {
                        Some(Ok(Message::Text(text))) => {
                            if text.starts_with("resize:") {
                                let parts: Vec<&str> = text.split(':').collect();
                                if parts.len() == 3 {
                                    if let (Ok(rows), Ok(cols)) = (parts[1].parse::<u16>(), parts[2].parse::<u16>()) {
                                        let _ = pair.master.resize(PtySize {
                                            rows,
                                            cols,
                                            pixel_width: 0,
                                            pixel_height: 0,
                                        });
                                        vterm.resize(rows as usize, cols as usize);
                                    }
                                }
                            } else if tx_in.send(text.as_bytes().to_vec()).await.is_err() {
                                break;
                            }
                        }
                        Some(Ok(Message::Binary(data))) => {
                            if tx_in.send(data.into()).await.is_err() {
                                break;
                            }
                        }
                        Some(Ok(Message::Close(_))) | None => break,
                        _ => {}
                    }
                }
                data = rx_out.recv() => {
                    match data {
                        Some(d) => {
                            // Process PTY output through VirtualTerminal
                            vterm.process(&d);

                            // Check for any pending responses from VirtualTerminal
                            // (e.g., CSI 18 t -> CSI 8;rows;cols t)
                            let responses = vterm.drain_responses();
                            for response in responses {
                                // Send responses back to PTY (so application can read them)
                                if tx_in.send(response).await.is_err() {
                                    break;
                                }
                            }

                            // Filter DA queries/responses from output before forwarding to client.
                            // Uses stateful filter to handle sequences split across chunks.
                            // We handle these locally via VirtualTerminal, so we don't want them
                            // reaching the user's terminal (which would respond and cause garbage).
                            let filtered = da_filter.filter(&d);
                            if filtered.is_empty() {
                                continue;
                            }

                            // Forward filtered PTY output to WebSocket
                            if socket.send(Message::Binary(filtered.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
        }

        // Kill child on exit
        let _ = child.kill();
        let _ = child.wait();

        Ok(())
    }

    async fn proxy(&self, id_str: String, port: u16, mut socket: WebSocket) -> SandboxResult<()> {
        let id = self.resolve_id(&id_str).await?;
        let entry = {
            let sandboxes = self.sandboxes.lock().await;
            sandboxes.get(&id).cloned()
        }
        .ok_or(SandboxError::NotFound(id))?;

        let target_address = format!("127.0.0.1:{}", port);

        let mut command = Command::new(&self.nsenter_path);
        command.args(nsenter_args(
            entry.inner_pid,
            None,
            &[
                "cmux".to_string(),
                "_internal-proxy".to_string(),
                target_address,
            ],
        ));

        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::inherit());

        command.kill_on_drop(true);

        let mut child = command.spawn()?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or(SandboxError::Internal("failed to open stdin".into()))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or(SandboxError::Internal("failed to open stdout".into()))?;

        let mut buf = [0u8; 8192];

        loop {
            tokio::select! {
                res = stdout.read(&mut buf) => {
                    match res {
                        Ok(0) => break,
                        Ok(n) => {
                            if socket.send(Message::Binary(buf[..n].to_vec().into())).await.is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                msg = socket.recv() => {
                    match msg {
                        Some(Ok(Message::Binary(data))) => {
                            if stdin.write_all(&data).await.is_err() { break; }
                            if stdin.flush().await.is_err() { break; }
                        }
                        Some(Ok(Message::Text(text))) => {
                            if stdin.write_all(text.as_bytes()).await.is_err() { break; }
                            if stdin.flush().await.is_err() { break; }
                        }
                        Some(Ok(Message::Close(_))) | None => break,
                        _ => {}
                    }
                }
            }
        }

        let _ = child.kill().await;
        Ok(())
    }

    async fn mux_attach(
        &self,
        socket: WebSocket,
        mut host_event_rx: crate::service::HostEventReceiver,
        gh_responses: crate::service::GhResponseRegistry,
        gh_auth_cache: crate::service::GhAuthCache,
    ) -> SandboxResult<()> {
        info!("mux_attach: new multiplexed connection");

        // Channel for PTY output from all sessions -> WebSocket
        let (output_tx, mut output_rx) = mpsc::unbounded_channel::<MuxServerMessage>();

        // Track active PTY sessions: session_id -> (input_tx, master_pty for resize)
        let sessions: Arc<Mutex<HashMap<PtySessionId, PtySessionHandle>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let (mut ws_write, mut ws_read) = socket.split();

        // Task to send output to WebSocket
        let output_task = tokio::spawn(async move {
            while let Some(msg) = output_rx.recv().await {
                let json = match serde_json::to_string(&msg) {
                    Ok(j) => j,
                    Err(e) => {
                        warn!("mux_attach: failed to serialize message: {e}");
                        continue;
                    }
                };
                if ws_write.send(Message::Text(json.into())).await.is_err() {
                    break;
                }
            }
        });

        // Main loop: handle incoming messages and URL broadcasts
        loop {
            let msg = tokio::select! {
                msg = ws_read.next() => msg,
                event = host_event_rx.recv() => {
                    if let Ok(event) = event {
                        match event {
                            HostEvent::OpenUrl(request) => {
                                let _ = output_tx.send(MuxServerMessage::OpenUrl {
                                    url: request.url,
                                    sandbox_id: request.sandbox_id,
                                    tab_id: request.tab_id,
                                });
                            }
                            HostEvent::Notification(notification) => {
                                let _ = output_tx.send(MuxServerMessage::Notification {
                                    message: notification.message,
                                    level: notification.level,
                                    sandbox_id: notification.sandbox_id,
                                    tab_id: notification.tab_id,
                                    pane_id: notification.pane_id,
                                });
                            }
                            HostEvent::GhRequest(request) => {
                                let _ = output_tx.send(MuxServerMessage::GhRequest {
                                    request_id: request.request_id,
                                    args: request.args,
                                    stdin: request.stdin,
                                    sandbox_id: request.sandbox_id,
                                    tab_id: request.tab_id,
                                });
                            }
                        }
                    }
                    continue;
                }
            };
            match msg {
                Some(Ok(Message::Text(text))) => {
                    let client_msg: MuxClientMessage = match serde_json::from_str(&text) {
                        Ok(m) => m,
                        Err(e) => {
                            let _ = output_tx.send(MuxServerMessage::Error {
                                session_id: None,
                                message: format!("Invalid message: {e}"),
                            });
                            continue;
                        }
                    };

                    match client_msg {
                        MuxClientMessage::CreateSandbox { name, env } => {
                            debug!("mux_attach: create sandbox request name={:?}", name);
                            match self
                                .create(CreateSandboxRequest {
                                    name,
                                    workspace: None,
                                    tab_id: None,
                                    read_only_paths: vec![],
                                    tmpfs: vec![],
                                    env,
                                })
                                .await
                            {
                                Ok(summary) => {
                                    let _ =
                                        output_tx.send(MuxServerMessage::SandboxCreated(summary));
                                }
                                Err(e) => {
                                    let _ = output_tx.send(MuxServerMessage::Error {
                                        session_id: None,
                                        message: format!("Failed to create sandbox: {e}"),
                                    });
                                }
                            }
                        }

                        MuxClientMessage::ListSandboxes => {
                            debug!("mux_attach: list sandboxes request");
                            match self.list().await {
                                Ok(sandboxes) => {
                                    let _ =
                                        output_tx.send(MuxServerMessage::SandboxList { sandboxes });
                                }
                                Err(e) => {
                                    let _ = output_tx.send(MuxServerMessage::Error {
                                        session_id: None,
                                        message: format!("Failed to list sandboxes: {e}"),
                                    });
                                }
                            }
                        }

                        MuxClientMessage::Attach {
                            session_id,
                            sandbox_id,
                            cols,
                            rows,
                            command,
                            tty,
                            tab_id,
                            pane_id,
                        } => {
                            debug!(
                                "mux_attach: attach request session={} sandbox={} tty={}",
                                session_id, sandbox_id, tty
                            );

                            // Resolve sandbox
                            let entry = match self.resolve_id(&sandbox_id).await {
                                Ok(id) => {
                                    let sandboxes = self.sandboxes.lock().await;
                                    sandboxes.get(&id).cloned()
                                }
                                Err(e) => {
                                    let _ = output_tx.send(MuxServerMessage::Error {
                                        session_id: Some(session_id),
                                        message: format!("Failed to resolve sandbox: {e}"),
                                    });
                                    continue;
                                }
                            };

                            let entry = match entry {
                                Some(e) => e,
                                None => {
                                    let _ = output_tx.send(MuxServerMessage::Error {
                                        session_id: Some(session_id),
                                        message: "Sandbox not found".to_string(),
                                    });
                                    continue;
                                }
                            };

                            let target_command = command
                                .unwrap_or_else(|| vec!["/bin/zsh".to_string(), "-i".to_string()]);

                            if !tty {
                                // Non-PTY mode: not supported in mux for simplicity
                                let _ = output_tx.send(MuxServerMessage::Error {
                                    session_id: Some(session_id),
                                    message: "Non-TTY mode not supported in multiplexed attach"
                                        .to_string(),
                                });
                                continue;
                            }

                            // Spawn PTY session
                            match self
                                .spawn_mux_pty_session(
                                    session_id.clone(),
                                    entry.inner_pid,
                                    target_command,
                                    cols,
                                    rows,
                                    &entry.env,
                                    tab_id,
                                    pane_id,
                                    output_tx.clone(),
                                )
                                .await
                            {
                                Ok(handle) => {
                                    let mut sessions = sessions.lock().await;
                                    sessions.insert(session_id.clone(), handle);
                                    let _ =
                                        output_tx.send(MuxServerMessage::Attached { session_id });
                                }
                                Err(e) => {
                                    let _ = output_tx.send(MuxServerMessage::Error {
                                        session_id: Some(session_id),
                                        message: format!("Failed to spawn PTY: {e}"),
                                    });
                                }
                            }
                        }

                        MuxClientMessage::Input { session_id, data } => {
                            let sessions = sessions.lock().await;
                            if let Some(handle) = sessions.get(&session_id) {
                                let _ = handle.input_tx.send(data);
                            }
                        }

                        MuxClientMessage::Resize {
                            session_id,
                            cols,
                            rows,
                        } => {
                            let sessions = sessions.lock().await;
                            if let Some(handle) = sessions.get(&session_id) {
                                // Resize the PTY
                                let _ = handle.master.resize(PtySize {
                                    rows,
                                    cols,
                                    pixel_width: 0,
                                    pixel_height: 0,
                                });
                                // Also resize the VirtualTerminal in the reader thread
                                // so window-size queries return correct dimensions
                                let _ = handle.resize_tx.send((rows, cols));
                            }
                        }

                        MuxClientMessage::Detach { session_id } => {
                            debug!("mux_attach: detach request session={}", session_id);
                            let mut sessions = sessions.lock().await;
                            if let Some(handle) = sessions.remove(&session_id) {
                                // Drop handle which will close channels and kill child
                                drop(handle);
                                let _ = output_tx.send(MuxServerMessage::Exited {
                                    session_id,
                                    exit_code: None,
                                });
                            }
                        }

                        MuxClientMessage::Ping { timestamp } => {
                            let _ = output_tx.send(MuxServerMessage::Pong { timestamp });
                        }

                        MuxClientMessage::GhResponse {
                            request_id,
                            exit_code,
                            stdout,
                            stderr,
                        } => {
                            debug!(
                                "mux_attach: gh response request_id={} exit_code={}",
                                request_id, exit_code
                            );
                            // Look up the pending request and send the response
                            let mut registry = gh_responses.lock().await;
                            if let Some(sender) = registry.remove(&request_id) {
                                let response = crate::models::GhResponse {
                                    request_id: request_id.clone(),
                                    exit_code,
                                    stdout,
                                    stderr,
                                };
                                if sender.send(response).is_err() {
                                    warn!(
                                        "mux_attach: failed to send gh response for request_id={}",
                                        request_id
                                    );
                                }
                            } else {
                                warn!(
                                    "mux_attach: no pending request for gh response request_id={}",
                                    request_id
                                );
                            }
                        }

                        MuxClientMessage::GhAuthCache {
                            exit_code,
                            stdout,
                            stderr,
                        } => {
                            debug!("mux_attach: caching gh auth status exit_code={}", exit_code);
                            let mut cache = gh_auth_cache.lock().await;
                            *cache = Some(crate::service::CachedGhAuth {
                                exit_code,
                                stdout,
                                stderr,
                            });
                        }

                        MuxClientMessage::Signal { signum } => {
                            // Forward signal to all PTY child processes
                            let sessions = sessions.lock().await;
                            let mut sent_count = 0;
                            for (_session_id, handle) in sessions.iter() {
                                if let Some(pid) = handle.child_pid {
                                    // Use libc to send the signal
                                    let result = unsafe { libc::kill(pid as i32, signum) };
                                    if result == 0 {
                                        sent_count += 1;
                                    } else {
                                        debug!(
                                            "mux_attach: failed to send signal {} to pid {}: {}",
                                            signum,
                                            pid,
                                            std::io::Error::last_os_error()
                                        );
                                    }
                                }
                            }
                            debug!(
                                "mux_attach: forwarded signal {} to {} processes",
                                signum, sent_count
                            );
                        }
                    }
                }
                Some(Ok(Message::Close(_))) | None => {
                    info!("mux_attach: WebSocket closed");
                    break;
                }
                Some(Err(e)) => {
                    warn!("mux_attach: WebSocket error: {e}");
                    break;
                }
                _ => {}
            }
        }

        // Cleanup: kill all sessions
        {
            let mut sessions = sessions.lock().await;
            sessions.clear();
        }

        output_task.abort();
        Ok(())
    }

    async fn upload_archive(&self, id_str: String, archive: Body) -> SandboxResult<()> {
        let id = self.resolve_id(&id_str).await?;
        let entry = {
            let sandboxes = self.sandboxes.lock().await;
            sandboxes.get(&id).cloned()
        }
        .ok_or(SandboxError::NotFound(id))?;

        let workspace = entry.handle.workspace;

        let tar_path = find_binary("tar")?;

        let mut command = Command::new(tar_path);
        command.args(["-x", "-C"]);
        command.arg(&workspace);
        command.stdin(Stdio::piped());
        command.stdout(Stdio::null());
        command.stderr(Stdio::piped());

        let mut child = command
            .spawn()
            .map_err(|e| SandboxError::Internal(format!("failed to spawn tar: {e}")))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or(SandboxError::Internal("failed to open tar stdin".into()))?;

        let mut stream = archive.into_data_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| SandboxError::Internal(format!("stream error: {e}")))?;
            stdin
                .write_all(&chunk)
                .await
                .map_err(|e| SandboxError::Internal(format!("failed to write to tar: {e}")))?;
        }
        drop(stdin);

        let output = child
            .wait_with_output()
            .await
            .map_err(|e| SandboxError::Internal(format!("failed to wait for tar: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(SandboxError::Internal(format!("tar failed: {stderr}")));
        }

        Ok(())
    }

    async fn delete(&self, id_str: String) -> SandboxResult<Option<SandboxSummary>> {
        let id = self.resolve_id(&id_str).await?;
        let entry = {
            let mut sandboxes = self.sandboxes.lock().await;
            sandboxes.remove(&id)
        };

        // Clean up readiness tracking
        {
            let mut readiness_map = self.readiness.lock().await;
            readiness_map.remove(&id);
        }

        if let Some(entry) = entry {
            {
                let mut pool = self.ip_pool.lock().await;
                pool.release(&entry.handle.lease);
            }

            self.teardown_network(&entry.handle.network).await;

            let mut child = entry.child.lock().await;
            let observed_status = match child.try_wait()? {
                None => {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                    SandboxStatus::Exited
                }
                Some(exit) => {
                    if exit.success() {
                        SandboxStatus::Exited
                    } else {
                        SandboxStatus::Failed
                    }
                }
            };

            let summary = entry.handle.to_summary(observed_status);

            let system_dir = self.workspace_root.join(id.to_string()).join("system");
            cleanup_overlays(&system_dir).await;

            // Remove system dir (always managed by us)
            if let Err(error) = fs::remove_dir_all(&system_dir).await {
                warn!(
                    "failed to remove system dir {}: {error}",
                    system_dir.display()
                );
            }

            if entry.handle.workspace.starts_with(&self.workspace_root) {
                if let Err(error) = fs::remove_dir_all(&entry.handle.workspace).await {
                    warn!(
                        "failed to remove workspace {}: {error}",
                        entry.handle.workspace.display()
                    );
                }
            }

            // Try to remove the sandbox root directory (container for system and optionally workspace)
            let sandbox_root = self.workspace_root.join(id.to_string());
            if let Err(error) = fs::remove_dir(&sandbox_root).await {
                // It might not be empty if workspace removal failed or if there are other files,
                // but usually it should be empty now.
                warn!(
                    "failed to remove sandbox root {}: {error}",
                    sandbox_root.display()
                );
            }

            info!("removed sandbox {id}");
            return Ok(Some(summary));
        }

        Ok(None)
    }

    async fn prune_orphaned(&self, request: PruneRequest) -> SandboxResult<PruneResponse> {
        use std::time::SystemTime;

        let max_age_secs = if request.all {
            0
        } else {
            request.max_age_secs.unwrap_or(86400) // Default: 24 hours
        };

        let mut items = Vec::new();
        let mut deleted_count = 0;
        let mut failed_count = 0;

        // Collect candidate directories first (without holding the lock)
        let mut candidates: Vec<(Uuid, PathBuf, u64)> = Vec::new();

        // Scan workspace_root for UUID-named directories
        let mut entries = match fs::read_dir(&self.workspace_root).await {
            Ok(entries) => entries,
            Err(e) => {
                warn!(
                    "failed to read workspace root {}: {e}",
                    self.workspace_root.display()
                );
                return Ok(PruneResponse {
                    deleted_count: 0,
                    failed_count: 0,
                    items: vec![],
                    dry_run: request.dry_run,
                    bytes_freed: 0,
                });
            }
        };

        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            let file_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue, // Skip non-UTF8 names
            };

            // Try to parse as UUID
            let id = match Uuid::parse_str(&file_name) {
                Ok(id) => id,
                Err(_) => continue, // Not a UUID-named directory, skip
            };

            // Use symlink_metadata to avoid following symlinks (security: prevents
            // malicious symlinks from causing deletion of arbitrary host paths)
            let metadata = match fs::symlink_metadata(&path).await {
                Ok(m) => m,
                Err(_) => continue,
            };

            // Skip symlinks to prevent arbitrary path deletion attacks
            if metadata.file_type().is_symlink() {
                warn!(
                    "skipping symlink in workspace_root during prune: {}",
                    path.display()
                );
                continue;
            }

            // Check if it's a directory
            if !metadata.is_dir() {
                continue;
            }

            // Get modification time and calculate age
            let age_secs = match metadata.modified() {
                Ok(mtime) => match SystemTime::now().duration_since(mtime) {
                    Ok(duration) => duration.as_secs(),
                    Err(_) => 0,
                },
                Err(_) => 0,
            };

            // Skip if not old enough (unless --all)
            if !request.all && age_secs < max_age_secs {
                continue;
            }

            candidates.push((id, path, age_secs));
        }

        let mut bytes_freed: u64 = 0;

        // Now process candidates, re-checking the sandbox map before each deletion
        // to avoid race conditions with concurrent sandbox creation
        for (id, path, age_secs) in candidates {
            // Re-check if this sandbox was created while we were scanning
            // This prevents TOCTOU race conditions with sandbox creation
            {
                let sandboxes = self.sandboxes.lock().await;
                if sandboxes.contains_key(&id) {
                    continue; // Sandbox was created, skip deletion
                }
            }

            // Calculate directory size
            let size_bytes = calculate_dir_size(&path).await;

            let item = PrunedItem {
                id: id.to_string(),
                path: path.to_string_lossy().to_string(),
                age_secs,
                size_bytes,
            };

            if request.dry_run {
                bytes_freed += size_bytes;
                items.push(item);
                deleted_count += 1;
            } else {
                // Clean up any stale overlay mounts first
                let system_dir = path.join("system");
                if system_dir.exists() {
                    cleanup_overlays(&system_dir).await;
                }

                // Remove the directory
                match fs::remove_dir_all(&path).await {
                    Ok(()) => {
                        info!("pruned orphaned sandbox directory: {}", path.display());
                        bytes_freed += size_bytes;
                        items.push(item);
                        deleted_count += 1;
                    }
                    Err(e) => {
                        warn!("failed to prune {}: {e}", path.display());
                        failed_count += 1;
                    }
                }
            }
        }

        Ok(PruneResponse {
            deleted_count,
            failed_count,
            items,
            dry_run: request.dry_run,
            bytes_freed,
        })
    }

    async fn await_services_ready(
        &self,
        id: String,
        request: AwaitReadyRequest,
    ) -> SandboxResult<AwaitReadyResponse> {
        use tokio::time::timeout;

        let sandbox_id = Uuid::parse_str(&id)
            .map_err(|_| SandboxError::InvalidRequest(format!("invalid sandbox id: {}", id)))?;

        // Check if sandbox exists
        {
            let sandboxes = self.sandboxes.lock().await;
            if !sandboxes.contains_key(&sandbox_id) {
                return Err(SandboxError::NotFound(sandbox_id));
            }
        }

        // Get a receiver for the readiness watch channel
        let mut rx = {
            let readiness_map = self.readiness.lock().await;
            match readiness_map.get(&sandbox_id) {
                Some(tx) => tx.subscribe(),
                None => {
                    // No readiness tracking for this sandbox - return current state
                    return Ok(AwaitReadyResponse {
                        ready: false,
                        services: ServiceReadiness::default(),
                        timed_out: vec!["vnc".to_string()],
                    });
                }
            }
        };

        // Determine which services to wait for
        // Empty services list = wait for all configured services (vnc, vscode, pty)
        let wait_for_vnc =
            request.services.is_empty() || request.services.iter().any(|s| s == "vnc");
        let wait_for_vscode =
            request.services.is_empty() || request.services.iter().any(|s| s == "vscode");
        let wait_for_pty =
            request.services.is_empty() || request.services.iter().any(|s| s == "pty");

        let timeout_duration = Duration::from_millis(request.timeout_ms);
        let deadline = tokio::time::Instant::now() + timeout_duration;

        // Poll until services are ready or timeout
        loop {
            let current = rx.borrow().clone();

            // Check if all requested services are ready
            let vnc_ok = !wait_for_vnc || current.vnc;
            let vscode_ok = !wait_for_vscode || current.vscode;
            let pty_ok = !wait_for_pty || current.pty;

            if vnc_ok && vscode_ok && pty_ok {
                return Ok(AwaitReadyResponse {
                    ready: true,
                    services: current,
                    timed_out: vec![],
                });
            }

            // Wait for changes or timeout
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                // Timed out
                let mut timed_out = vec![];
                if wait_for_vnc && !current.vnc {
                    timed_out.push("vnc".to_string());
                }
                if wait_for_vscode && !current.vscode {
                    timed_out.push("vscode".to_string());
                }
                if wait_for_pty && !current.pty {
                    timed_out.push("pty".to_string());
                }
                return Ok(AwaitReadyResponse {
                    ready: false,
                    services: current,
                    timed_out,
                });
            }

            // Wait for next update or timeout
            match timeout(remaining, rx.changed()).await {
                Ok(Ok(())) => {
                    // Got an update, loop to check again
                }
                Ok(Err(_)) => {
                    // Channel closed (sandbox deleted?)
                    return Err(SandboxError::NotFound(sandbox_id));
                }
                Err(_) => {
                    // Timeout
                    let current = rx.borrow().clone();
                    let mut timed_out = vec![];
                    if wait_for_vnc && !current.vnc {
                        timed_out.push("vnc".to_string());
                    }
                    if wait_for_vscode && !current.vscode {
                        timed_out.push("vscode".to_string());
                    }
                    if wait_for_pty && !current.pty {
                        timed_out.push("pty".to_string());
                    }
                    return Ok(AwaitReadyResponse {
                        ready: false,
                        services: current,
                        timed_out,
                    });
                }
            }
        }
    }
}

impl SandboxHandle {
    fn to_summary(&self, status: SandboxStatus) -> SandboxSummary {
        SandboxSummary {
            id: self.id,
            index: self.index,
            name: self.name.clone(),
            created_at: self.created_at,
            workspace: self.workspace.to_string_lossy().to_string(),
            status,
            network: self.network.clone(),
            display: self.display.clone(),
            correlation_id: self.correlation_id.clone(),
        }
    }
}

async fn run_command(binary: &str, args: &[&str]) -> SandboxResult<()> {
    let output = Command::new(binary).args(args).output().await?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    Err(SandboxError::CommandFailed {
        command: format!("{binary} {}", args.join(" ")),
        message: stderr,
    })
}

async fn mount_overlay(system_dir: &Path, name: &str, lower: &str) -> SandboxResult<PathBuf> {
    let upper = system_dir.join(format!("{}-upper", name));
    let work = system_dir.join(format!("{}-work", name));
    let merged = system_dir.join(format!("{}-merged", name));

    fs::create_dir_all(&upper).await?;
    fs::create_dir_all(&work).await?;
    fs::create_dir_all(&merged).await?;

    let opts = format!(
        "lowerdir={},upperdir={},workdir={}",
        lower,
        upper.to_string_lossy(),
        work.to_string_lossy()
    );

    let merged_path = path_to_string(&merged, "merged overlay")?;

    run_command(
        "mount",
        &[
            "-t",
            "overlay",
            "overlay",
            "-o",
            &opts,
            merged_path.as_str(),
        ],
    )
    .await?;

    Ok(merged)
}

async fn cleanup_overlays(system_dir: &Path) {
    let _ = run_command(
        "umount",
        &[system_dir.join("var-merged").to_string_lossy().as_ref()],
    )
    .await;
    let _ = run_command(
        "umount",
        &[system_dir.join("etc-merged").to_string_lossy().as_ref()],
    )
    .await;
    let _ = run_command(
        "umount",
        &[system_dir.join("usr-merged").to_string_lossy().as_ref()],
    )
    .await;
}

/// Calculate the total size of a directory recursively.
async fn calculate_dir_size(path: &Path) -> u64 {
    let mut total: u64 = 0;

    let mut stack = vec![path.to_path_buf()];

    while let Some(current) = stack.pop() {
        let mut entries = match fs::read_dir(&current).await {
            Ok(entries) => entries,
            Err(_) => continue,
        };

        while let Ok(Some(entry)) = entries.next_entry().await {
            let entry_path = entry.path();

            // Use symlink_metadata to not follow symlinks
            let metadata = match fs::symlink_metadata(&entry_path).await {
                Ok(m) => m,
                Err(_) => continue,
            };

            if metadata.is_file() {
                total += metadata.len();
            } else if metadata.is_dir() && !metadata.file_type().is_symlink() {
                stack.push(entry_path);
            }
            // Skip symlinks for size calculation
        }
    }

    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interface_names_are_short() {
        let id = Uuid::new_v4();
        let (host_if, ns_if) = make_interface_names(&id);
        assert!(host_if.len() <= 15);
        assert!(ns_if.len() <= 15);
    }

    #[test]
    fn nsenter_args_defaults() {
        let args = nsenter_args(123, None, &["ls".to_string()]);
        assert!(args.contains(&"--target".to_string()));
        assert!(args.contains(&"123".to_string()));
        assert!(args.contains(&"--wd".to_string()));

        // Verify structure: --target 123 ... --wd -- ls
        let wd_idx = args.iter().position(|s| s == "--wd").unwrap();
        let double_dash_idx = args.iter().position(|s| s == "--").unwrap();
        let ls_idx = args.iter().position(|s| s == "ls").unwrap();

        assert!(wd_idx < double_dash_idx);
        assert!(double_dash_idx < ls_idx);
    }

    #[test]
    fn nsenter_args_custom_workdir() {
        let args = nsenter_args(123, Some("/custom"), &["ls".to_string()]);
        assert!(args.contains(&"--wd=/custom".to_string()));

        let wd_idx = args.iter().position(|s| s == "--wd=/custom").unwrap();
        let double_dash_idx = args.iter().position(|s| s == "--").unwrap();

        assert!(wd_idx < double_dash_idx);
    }

    #[test]
    fn session_env_overrides_tab_and_pane() {
        let base_env = vec![
            EnvVar {
                key: "PATH".to_string(),
                value: "/bin".to_string(),
            },
            EnvVar {
                key: "CMUX_TAB_ID".to_string(),
                value: "old-tab".to_string(),
            },
        ];

        let session_env = session_env_with_overrides(
            &base_env,
            Some("new-tab".to_string()),
            Some("pane-1".to_string()),
        );

        let mut map = std::collections::HashMap::new();
        for env in session_env {
            map.insert(env.key, env.value);
        }

        assert_eq!(map.get("PATH"), Some(&"/bin".to_string()));
        assert_eq!(map.get("CMUX_TAB_ID"), Some(&"new-tab".to_string()));
        assert_eq!(map.get("CMUX_PANE_ID"), Some(&"pane-1".to_string()));
    }
}
