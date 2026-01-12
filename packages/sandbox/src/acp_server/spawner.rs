//! CLI spawner with bubblewrap isolation support.

use anyhow::{Context, Result};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::{Child, Command};
use tracing::{debug, info};

/// ACP provider types matching the shared provider enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AcpProvider {
    /// OpenAI Codex CLI ACP
    Codex,
    /// OpenCode ACP
    Opencode,
    /// Claude Code ACP
    Claude,
    /// Gemini CLI ACP
    Gemini,
}

impl AcpProvider {
    /// Get the command to execute for this provider.
    pub fn command(&self) -> &'static str {
        match self {
            AcpProvider::Codex => "codex-acp",
            AcpProvider::Opencode => "opencode",
            AcpProvider::Claude => "claude-code-acp",
            AcpProvider::Gemini => "gemini",
        }
    }

    /// Get the full command with arguments for this provider.
    pub fn command_args(&self) -> Vec<&'static str> {
        match self {
            AcpProvider::Codex => vec![
                "codex-acp",
                "-c",
                "approval_policy=\"never\"",
                "-c",
                "sandbox_mode=\"danger-full-access\"",
            ],
            AcpProvider::Opencode => vec!["opencode", "acp"],
            AcpProvider::Claude => vec!["claude-code-acp"],
            AcpProvider::Gemini => vec!["gemini", "--experimental-acp"],
        }
    }

    /// Get display name for this provider.
    pub fn display_name(&self) -> &'static str {
        match self {
            AcpProvider::Codex => "Codex CLI",
            AcpProvider::Opencode => "OpenCode",
            AcpProvider::Claude => "Claude Code",
            AcpProvider::Gemini => "Gemini CLI",
        }
    }

    /// Parse from string identifier.
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "codex" => Some(AcpProvider::Codex),
            "opencode" => Some(AcpProvider::Opencode),
            "claude" => Some(AcpProvider::Claude),
            "gemini" => Some(AcpProvider::Gemini),
            _ => None,
        }
    }
}

/// Isolation mode for CLI execution.
#[derive(Debug, Clone)]
pub enum IsolationMode {
    /// No isolation, run directly in container.
    None,
    /// Bubblewrap with shared namespace - multiple conversations share filesystem.
    SharedNamespace { namespace_id: String },
    /// Bubblewrap with dedicated namespace - full isolation per conversation.
    DedicatedNamespace,
}

/// Spawned CLI process handle.
pub struct SpawnedCli {
    pub child: Child,
    pub stdin: Option<tokio::process::ChildStdin>,
    pub stdout: Option<tokio::process::ChildStdout>,
}

/// CLI spawner with bubblewrap support.
pub struct CliSpawner {
    provider: AcpProvider,
    isolation: IsolationMode,
    cwd: PathBuf,
    env_vars: Vec<(String, String)>,
    bubblewrap_path: Option<String>,
}

impl CliSpawner {
    /// Create a new CLI spawner.
    pub fn new(provider: AcpProvider, cwd: PathBuf, isolation: IsolationMode) -> Self {
        Self {
            provider,
            isolation,
            cwd,
            env_vars: Vec::new(),
            bubblewrap_path: None,
        }
    }

    /// Set the path to bubblewrap binary.
    pub fn with_bubblewrap_path(mut self, path: String) -> Self {
        self.bubblewrap_path = Some(path);
        self
    }

    /// Add environment variables for the CLI process.
    pub fn with_env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env_vars.push((key.into(), value.into()));
        self
    }

    /// Spawn the CLI process with configured isolation.
    pub async fn spawn(&self) -> Result<SpawnedCli> {
        match &self.isolation {
            IsolationMode::None => self.spawn_direct().await,
            IsolationMode::SharedNamespace { namespace_id } => {
                self.spawn_bubblewrap(Some(namespace_id)).await
            }
            IsolationMode::DedicatedNamespace => self.spawn_bubblewrap(None).await,
        }
    }

    /// Spawn CLI directly without isolation.
    async fn spawn_direct(&self) -> Result<SpawnedCli> {
        let args = self.provider.command_args();
        let (cmd, cmd_args) = args
            .split_first()
            .context("Provider command args cannot be empty")?;

        info!(
            provider = %self.provider.display_name(),
            cwd = %self.cwd.display(),
            "Spawning CLI directly (no isolation)"
        );

        let mut command = Command::new(cmd);
        command
            .args(cmd_args)
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());

        // Add environment variables
        for (key, value) in &self.env_vars {
            command.env(key, value);
        }

        // Use stdbuf for unbuffered I/O if available
        let mut child = command
            .spawn()
            .with_context(|| format!("Failed to spawn {}", self.provider.display_name()))?;

        let stdin = child.stdin.take();
        let stdout = child.stdout.take();

        if stdin.is_none() || stdout.is_none() {
            anyhow::bail!("Failed to get stdin/stdout handles");
        }

        Ok(SpawnedCli {
            child,
            stdin,
            stdout,
        })
    }

    /// Spawn CLI in bubblewrap sandbox.
    async fn spawn_bubblewrap(&self, namespace_id: Option<&str>) -> Result<SpawnedCli> {
        let bwrap_path = self.bubblewrap_path.as_deref().unwrap_or("/usr/bin/bwrap");

        let args = self.provider.command_args();
        let (cmd, cmd_args) = args
            .split_first()
            .context("Provider command args cannot be empty")?;

        // Determine workspace directory based on namespace
        let workspace_dir = if let Some(ns_id) = namespace_id {
            // Shared namespace: use persistent directory that can be reused
            let ns_dir = PathBuf::from("/var/lib/cmux/namespaces").join(ns_id);
            // Create namespace directory if it doesn't exist
            if !ns_dir.exists() {
                std::fs::create_dir_all(&ns_dir).with_context(|| {
                    format!("Failed to create namespace directory: {}", ns_dir.display())
                })?;
            }
            info!(
                provider = %self.provider.display_name(),
                namespace_id = %ns_id,
                workspace = %ns_dir.display(),
                "Spawning CLI in shared bubblewrap namespace"
            );
            ns_dir
        } else {
            // Dedicated namespace: use the provided cwd (typically unique per conversation)
            info!(
                provider = %self.provider.display_name(),
                cwd = %self.cwd.display(),
                "Spawning CLI in dedicated bubblewrap sandbox"
            );
            self.cwd.clone()
        };

        let workspace_str = workspace_dir
            .to_str()
            .context("Workspace directory path is not valid UTF-8")?;

        let cwd_str = self
            .cwd
            .to_str()
            .context("Working directory path is not valid UTF-8")?;

        // Build bubblewrap arguments
        let mut bwrap_args = vec![
            // Unshare namespaces for isolation
            "--unshare-net",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            // Die with parent to prevent orphaned processes
            "--die-with-parent",
            // Mount root filesystem read-only
            "--ro-bind",
            "/",
            "/",
            // Bind workspace directory read-write (shared or dedicated)
            "--bind",
            workspace_str,
            workspace_str,
        ];

        // If cwd is different from workspace, also bind it
        if workspace_str != cwd_str {
            bwrap_args.extend_from_slice(&["--bind", cwd_str, cwd_str]);
        }

        // Standard mounts
        bwrap_args.extend_from_slice(&[
            "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
            // Set working directory
            "--chdir", cwd_str, // Separator before command
            "--",
        ]);

        // Add the CLI command and args
        bwrap_args.push(cmd);
        for arg in cmd_args {
            bwrap_args.push(arg);
        }

        debug!(
            bwrap_path = %bwrap_path,
            args = ?bwrap_args,
            namespace_id = ?namespace_id,
            "Bubblewrap command"
        );

        let mut command = Command::new(bwrap_path);
        command
            .args(&bwrap_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());

        // Add environment variables
        for (key, value) in &self.env_vars {
            command.env(key, value);
        }

        let mut child = command.spawn().with_context(|| {
            format!(
                "Failed to spawn bubblewrap with {}",
                self.provider.display_name()
            )
        })?;

        let stdin = child.stdin.take();
        let stdout = child.stdout.take();

        if stdin.is_none() || stdout.is_none() {
            anyhow::bail!("Failed to get stdin/stdout handles");
        }

        Ok(SpawnedCli {
            child,
            stdin,
            stdout,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_provider_from_str() {
        assert_eq!(AcpProvider::from_str("claude"), Some(AcpProvider::Claude));
        assert_eq!(AcpProvider::from_str("CODEX"), Some(AcpProvider::Codex));
        assert_eq!(AcpProvider::from_str("unknown"), None);
    }

    #[test]
    fn test_provider_command() {
        assert_eq!(AcpProvider::Claude.command(), "claude-code-acp");
        assert_eq!(AcpProvider::Codex.command(), "codex-acp");
    }
}
