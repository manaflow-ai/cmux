use crate::errors::{SandboxError, SandboxResult};
use crate::ip_pool::{IpLease, IpPool};
use crate::models::{
    CreateSandboxRequest, EnvVar, ExecRequest, ExecResponse, HostEvent, MuxClientMessage,
    MuxServerMessage, PtySessionId, SandboxNetwork, SandboxStatus, SandboxSummary,
};
use crate::service::SandboxService;
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
use tokio::sync::{mpsc, Mutex};
use tokio::time::sleep;
use tracing::{debug, info, warn};
use uuid::Uuid;
use which::which;

const NETWORK_BASE: Ipv4Addr = Ipv4Addr::new(10, 201, 0, 0);
const HOST_IF_PREFIX: &str = "vethh";
const NS_IF_PREFIX: &str = "vethn";
const DOCKER_CONTAINER_SOCKET: &str = "/run/docker.sock";

/// Handle for a multiplexed PTY session.
struct PtySessionHandle {
    input_tx: mpsc::UnboundedSender<Vec<u8>>,
    master: Box<dyn MasterPty + Send>,
    #[allow(dead_code)]
    child: Box<dyn portable_pty::Child + Send + Sync>,
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
            "/workspace",
            "--chdir",
            "/workspace",
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

        // Make common credential-helper paths resolve to cmux-bridge symlinks inside the sandbox
        for path_str in ["/opt", "/home/linuxbrew/.linuxbrew", "/snap"] {
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

    async fn configure_network(
        &self,
        pid: u32,
        lease: &IpLease,
        id: &Uuid,
    ) -> SandboxResult<SandboxNetwork> {
        let formatted_pid = pid.to_string();
        let (host_if, ns_if) = make_interface_names(id);
        let host_cidr = format!("{}/{}", lease.host, lease.cidr);
        let sandbox_cidr = format!("{}/{}", lease.sandbox, lease.cidr);

        run_command(
            &self.ip_path,
            &[
                "link", "add", &host_if, "type", "veth", "peer", "name", &ns_if,
            ],
        )
        .await?;
        run_command(&self.ip_path, &["addr", "add", &host_cidr, "dev", &host_if]).await?;
        run_command(&self.ip_path, &["link", "set", &host_if, "up"]).await?;
        run_command(
            &self.ip_path,
            &["link", "set", &ns_if, "netns", &formatted_pid],
        )
        .await?;

        run_command(
            &self.nsenter_path,
            &[
                "--target",
                &formatted_pid,
                "--net",
                "--",
                "ip",
                "addr",
                "add",
                &sandbox_cidr,
                "dev",
                &ns_if,
            ],
        )
        .await?;

        run_command(
            &self.nsenter_path,
            &[
                "--target",
                &formatted_pid,
                "--net",
                "--",
                "ip",
                "link",
                "set",
                &ns_if,
                "up",
            ],
        )
        .await?;
        run_command(
            &self.nsenter_path,
            &[
                "--target",
                &formatted_pid,
                "--net",
                "--",
                "ip",
                "link",
                "set",
                "lo",
                "up",
            ],
        )
        .await?;
        run_command(
            &self.nsenter_path,
            &[
                "--target",
                &formatted_pid,
                "--net",
                "--",
                "ip",
                "route",
                "replace",
                "default",
                "via",
                &lease.host.to_string(),
            ],
        )
        .await?;

        Ok(SandboxNetwork {
            host_interface: host_if,
            sandbox_interface: ns_if,
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
        cmd.env("TERM", "xterm-256color");
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

        // Reader thread: PTY -> output channel
        let session_id_clone = session_id.clone();
        let output_tx_clone = output_tx.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
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
                        if output_tx_clone
                            .send(MuxServerMessage::Output {
                                session_id: session_id_clone.clone(),
                                data: buf[..n].to_vec(),
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
            master: pair.master,
            child,
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
        let index = self.next_index.fetch_add(1, Ordering::Relaxed);
        let name = request
            .name
            .clone()
            .unwrap_or_else(|| Self::default_name(&id));
        let workspace = self.resolve_workspace(&request, &id);
        fs::create_dir_all(&workspace).await?;

        let system_dir = self.workspace_root.join(id.to_string()).join("system");

        let lease = {
            let mut pool = self.ip_pool.lock().await;
            pool.allocate()?
        };

        let effective_env = build_effective_env(
            &request.env,
            &lease,
            self.port,
            &id,
            &request.tab_id,
            self.docker.docker_host_env(),
        );

        let (mut child, inner_pid) = match self
            .spawn_bubblewrap(
                &request,
                &effective_env,
                &workspace,
                &system_dir,
                &id,
                &lease,
                index,
            )
            .await
        {
            Ok(res) => res,
            Err(error) => {
                cleanup_overlays(&system_dir).await;
                let mut pool = self.ip_pool.lock().await;
                pool.release(&lease);
                return Err(error);
            }
        };

        let network = match self.configure_network(inner_pid, &lease, &id).await {
            Ok(net) => net,
            Err(error) => {
                let _ = child.kill().await;
                cleanup_overlays(&system_dir).await;
                {
                    let mut pool = self.ip_pool.lock().await;
                    pool.release(&lease);
                }
                return Err(error);
            }
        };

        let handle = SandboxHandle {
            id,
            index,
            name,
            workspace,
            network,
            created_at: Utc::now(),
            lease,
        };

        let entry = SandboxEntry {
            handle,
            child: Arc::new(Mutex::new(child)),
            inner_pid,
            env: effective_env,
        };

        let summary = {
            let mut child = entry.child.lock().await;
            Self::workspace_summary(&entry, &mut child).await?
        };

        let mut sandboxes = self.sandboxes.lock().await;
        sandboxes.insert(id, entry);
        info!("created sandbox {id}");
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

            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                loop {
                    match stdout.read(&mut buf).await {
                        Ok(0) => {
                            info!("Stdout EOF");
                            break;
                        }
                        Ok(n) => {
                            info!("Read from stdout: {:?}", String::from_utf8_lossy(&buf[..n]));
                            if tx_out.send(buf[..n].to_vec()).await.is_err() {
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
                loop {
                    match stderr.read(&mut buf).await {
                        Ok(0) => {
                            info!("Stderr EOF");
                            break;
                        }
                        Ok(n) => {
                            info!("Read from stderr: {:?}", String::from_utf8_lossy(&buf[..n]));
                            if tx_err.send(buf[..n].to_vec()).await.is_err() {
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

        // PTY Path (existing implementation)
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
        cmd.env("TERM", "xterm-256color");
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

        // Writer thread
        std::thread::spawn(move || {
            while let Some(data) = rx_in.blocking_recv() {
                if writer.write_all(&data).is_err() {
                    break;
                }
                let _ = writer.flush();
            }
        });

        let mut ticker = tokio::time::interval(std::time::Duration::from_millis(100));

        // WebSocket bridge
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
                            if socket.send(Message::Binary(d.into())).await.is_err() {
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
                                let _ = handle.master.resize(PtySize {
                                    rows,
                                    cols,
                                    pixel_width: 0,
                                    pixel_height: 0,
                                });
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
