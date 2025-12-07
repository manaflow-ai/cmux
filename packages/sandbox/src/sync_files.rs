//! Sync files from host to sandbox.
//!
//! This module handles syncing configuration files (auth tokens, settings, shell config)
//! from the user's home directory on the host to the sandbox environment.

use crate::models::ExecRequest;
use anyhow::anyhow;
use reqwest::Client;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tar::Builder;
use tar::Header;

pub struct SyncFileDef {
    pub name: &'static str,
    pub host_path: &'static str,    // Relative to HOME
    pub sandbox_path: &'static str, // Absolute in sandbox
    pub is_dir: bool,               // Whether this is a directory
}

pub struct SyncFileToUpload {
    pub host_path: PathBuf,
    pub sandbox_path: &'static str,
    pub is_dir: bool,
}

pub const SYNC_FILES: &[SyncFileDef] = &[
    // Claude Code
    SyncFileDef {
        name: "Claude Config",
        host_path: ".claude.json",
        sandbox_path: "/root/.claude.json",
        is_dir: false,
    },
    // Codex
    SyncFileDef {
        name: "Codex Auth",
        host_path: ".codex/auth.json",
        sandbox_path: "/root/.codex/auth.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Codex Instructions",
        host_path: ".codex/instructions.md",
        sandbox_path: "/root/.codex/instructions.md",
        is_dir: false,
    },
    SyncFileDef {
        name: "Codex Config",
        host_path: ".codex/config.toml",
        sandbox_path: "/root/.codex/config.toml",
        is_dir: false,
    },
    // Gemini
    SyncFileDef {
        name: "Gemini Settings",
        host_path: ".gemini/settings.json",
        sandbox_path: "/root/.gemini/settings.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini OAuth",
        host_path: ".gemini/oauth_creds.json",
        sandbox_path: "/root/.gemini/oauth_creds.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini MCP Tokens",
        host_path: ".gemini/mcp-oauth-tokens.json",
        sandbox_path: "/root/.gemini/mcp-oauth-tokens.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini Google Accounts",
        host_path: ".gemini/google_accounts.json",
        sandbox_path: "/root/.gemini/google_accounts.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini Account ID",
        host_path: ".gemini/google_account_id",
        sandbox_path: "/root/.gemini/google_account_id",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini Install ID",
        host_path: ".gemini/installation_id",
        sandbox_path: "/root/.gemini/installation_id",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini User ID",
        host_path: ".gemini/user_id",
        sandbox_path: "/root/.gemini/user_id",
        is_dir: false,
    },
    SyncFileDef {
        name: "Gemini Env",
        host_path: ".gemini/.env",
        sandbox_path: "/root/.gemini/.env",
        is_dir: false,
    },
    // General
    SyncFileDef {
        name: "Env",
        host_path: ".env",
        sandbox_path: "/root/.env",
        is_dir: false,
    },
    // Git config
    SyncFileDef {
        name: "Git Config",
        host_path: ".gitconfig",
        sandbox_path: "/root/.gitconfig",
        is_dir: false,
    },
    // SSH keys and config
    SyncFileDef {
        name: "SSH Dir",
        host_path: ".ssh",
        sandbox_path: "/root/.ssh",
        is_dir: true,
    },
    // OpenCode
    SyncFileDef {
        name: "OpenCode Auth",
        host_path: ".local/share/opencode/auth.json",
        sandbox_path: "/root/.local/share/opencode/auth.json",
        is_dir: false,
    },
    // Amp
    SyncFileDef {
        name: "Amp Settings",
        host_path: ".config/amp/settings.json",
        sandbox_path: "/root/.config/amp/settings.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Amp Secrets",
        host_path: ".local/share/amp/secrets.json",
        sandbox_path: "/root/.local/share/amp/secrets.json",
        is_dir: false,
    },
    // Cursor
    SyncFileDef {
        name: "Cursor CLI Config",
        host_path: ".cursor/cli-config.json",
        sandbox_path: "/root/.cursor/cli-config.json",
        is_dir: false,
    },
    SyncFileDef {
        name: "Cursor Auth",
        host_path: ".config/cursor/auth.json",
        sandbox_path: "/root/.config/cursor/auth.json",
        is_dir: false,
    },
    // Qwen
    SyncFileDef {
        name: "Qwen Settings",
        host_path: ".qwen/settings.json",
        sandbox_path: "/root/.qwen/settings.json",
        is_dir: false,
    },
    // Zsh configuration - sync user's zshrc if they have one
    // (sandbox creates a default .zshrc only if user doesn't have their own)
    SyncFileDef {
        name: "Zshrc",
        host_path: ".zshrc",
        sandbox_path: "/root/.zshrc",
        is_dir: false,
    },
    SyncFileDef {
        name: "Zshrc Local",
        host_path: ".zshrc.local",
        sandbox_path: "/root/.zshrc.local",
        is_dir: false,
    },
    // Zsh history - needed for zsh-autosuggestions to work
    SyncFileDef {
        name: "Zsh History",
        host_path: ".zsh_history",
        sandbox_path: "/root/.zsh_history",
        is_dir: false,
    },
    SyncFileDef {
        name: "Zsh Plugins",
        host_path: ".zsh",
        sandbox_path: "/root/.zsh",
        is_dir: true,
    },
];

pub fn detect_sync_files() -> Vec<SyncFileToUpload> {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let home_path = PathBuf::from(home);
    let mut files_to_upload = Vec::new();

    for def in SYNC_FILES {
        let path = home_path.join(def.host_path);
        if path.exists() {
            // For directories, verify it's actually a directory
            if def.is_dir && !path.is_dir() {
                continue;
            }
            // For files, verify it's actually a file
            if !def.is_dir && !path.is_file() {
                continue;
            }
            files_to_upload.push(SyncFileToUpload {
                host_path: path,
                sandbox_path: def.sandbox_path,
                is_dir: def.is_dir,
            });
        }
    }

    files_to_upload
}

pub async fn upload_sync_files(
    client: &Client,
    base_url: &str,
    id: &str,
    log_progress: bool,
) -> anyhow::Result<()> {
    let files_to_upload = detect_sync_files();
    upload_sync_files_with_list(client, base_url, id, files_to_upload, log_progress).await
}

pub async fn upload_sync_files_with_list(
    client: &Client,
    base_url: &str,
    id: &str,
    files_to_upload: Vec<SyncFileToUpload>,
    log_progress: bool,
) -> anyhow::Result<()> {
    if files_to_upload.is_empty() {
        return Ok(());
    }

    if log_progress {
        eprintln!("Syncing {} file(s)...", files_to_upload.len());
    }

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(10);

    tokio::task::spawn_blocking(move || {
        let writer = ChunkedWriter { sender: tx.clone() };
        let mut tar = Builder::new(writer);

        let temp_dir_name = "__cmux_sync_temp";

        fn ensure_codex_notify(content: &str) -> String {
            let has_notify = content
                .lines()
                .any(|line| line.trim_start().starts_with("notify"));
            if has_notify {
                return content.to_string();
            }

            let notify_block = r#"notify = [
  "sh",
  "-c",
  "echo \"$1\" | jq -r '.[\"last-assistant-message\"] // \"Awaiting input\"' | xargs -I{} cmux-bridge notify \"Codex: {}\"",
  "--",
]

"#;
            format!("{notify_block}{content}")
        }

        for SyncFileToUpload {
            host_path,
            sandbox_path: sandbox_path_str,
            is_dir,
        } in files_to_upload
        {
            let sandbox_path = Path::new(sandbox_path_str);
            let rel_sandbox_path = sandbox_path.strip_prefix("/").unwrap_or(sandbox_path);

            let tar_path = Path::new(temp_dir_name).join(rel_sandbox_path);

            let result: io::Result<()> = if is_dir {
                // For directories, recursively add all contents
                tar.append_dir_all(&tar_path, &host_path)
            } else if sandbox_path_str == "/root/.codex/config.toml" {
                // Ensure Codex config always has our notify hook
                match fs::read_to_string(&host_path) {
                    Ok(raw) => {
                        let merged = ensure_codex_notify(&raw);
                        let bytes = merged.as_bytes();
                        let mut header = Header::new_gnu();
                        if let Err(e) = header.set_path(&tar_path) {
                            let _ = tx.blocking_send(Err(e));
                            return;
                        }
                        header.set_size(bytes.len() as u64);
                        header.set_mode(0o644);
                        let mtime = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs();
                        header.set_mtime(mtime);
                        header.set_cksum();
                        tar.append_data(&mut header, &tar_path, bytes)
                    }
                    Err(e) => Err(e),
                }
            } else {
                // For files, add with the specified name
                tar.append_path_with_name(&host_path, &tar_path)
            };

            if let Err(e) = result {
                let _ = tx.blocking_send(Err(e));
                return;
            }
        }

        if let Err(e) = tar.finish() {
            let _ = tx.blocking_send(Err(e));
        }
    });

    let body = reqwest::Body::wrap_stream(futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|msg| (msg, rx))
    }));

    let url = format!("{}/sandboxes/{}/files", base_url.trim_end_matches('/'), id);
    let response = client.post(url).body(body).send().await?;
    if !response.status().is_success() {
        return Err(anyhow!(
            "Failed to upload sync files: {}",
            response.status()
        ));
    }

    let move_script = r#"
        if [ -d /workspace/__cmux_sync_temp ]; then
            cp -r /workspace/__cmux_sync_temp/root/. /root/ 2>/dev/null || true
            git config --global --add safe.directory /workspace || true
            rm -rf /workspace/__cmux_sync_temp
            # Fix SSH permissions (SSH is picky about this)
            if [ -d /root/.ssh ]; then
                chmod 700 /root/.ssh
                chmod 600 /root/.ssh/* 2>/dev/null || true
                chmod 644 /root/.ssh/*.pub 2>/dev/null || true
                chmod 644 /root/.ssh/known_hosts 2>/dev/null || true
                chmod 644 /root/.ssh/config 2>/dev/null || true
                # Create authorized_keys from user's public keys for SSH access
                cat /root/.ssh/*.pub > /root/.ssh/authorized_keys 2>/dev/null || true
                chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
            fi
        fi
        # Add container's SSH key to authorized_keys for dmux ssh command
        # This key is generated in the Docker image and allows the container to SSH into sandboxes
        CONTAINER_KEY_FILE="/usr/share/cmux/container-ssh.pub"
        if [ -f "$CONTAINER_KEY_FILE" ]; then
            mkdir -p /root/.ssh
            cat "$CONTAINER_KEY_FILE" >> /root/.ssh/authorized_keys 2>/dev/null || true
            chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
        fi
        # Start sshd for SSH access to sandbox
        mkdir -p /run/sshd
        /usr/sbin/sshd 2>/dev/null || true
    "#;

    let exec_body = ExecRequest {
        command: vec!["/bin/sh".into(), "-c".into(), move_script.into()],
        workdir: None,
        env: Vec::new(),
    };

    let exec_url = format!("{}/sandboxes/{}/exec", base_url.trim_end_matches('/'), id);
    let exec_response = client.post(exec_url).json(&exec_body).send().await?;

    if !exec_response.status().is_success() {
        return Err(anyhow!(
            "Failed to execute move script: {}",
            exec_response.status()
        ));
    }

    Ok(())
}

struct ChunkedWriter {
    sender: tokio::sync::mpsc::Sender<Result<Vec<u8>, std::io::Error>>,
}

impl std::io::Write for ChunkedWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let data = buf.to_vec();
        match self.sender.blocking_send(Ok(data)) {
            Ok(_) => Ok(buf.len()),
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "Channel closed",
            )),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Pre-build the sync files tar archive into a buffer.
/// This can be called before sandbox creation to overlap CPU work with network I/O.
/// Returns Ok(None) if there are no files to sync, Ok(Some(data)) on success,
/// or Err(message) if there was an error reading/packaging files.
pub fn prebuild_sync_files_tar() -> Result<Option<Vec<u8>>, String> {
    let files_to_upload = detect_sync_files();
    if files_to_upload.is_empty() {
        return Ok(None);
    }

    let mut buffer = Vec::new();
    {
        let mut tar = Builder::new(&mut buffer);
        let temp_dir_name = "__cmux_sync_temp";

        fn ensure_codex_notify(content: &str) -> String {
            let has_notify = content
                .lines()
                .any(|line| line.trim_start().starts_with("notify"));
            if has_notify {
                return content.to_string();
            }

            let notify_block = r#"notify = [
  "sh",
  "-c",
  "echo \"$1\" | jq -r '.[\"last-assistant-message\"] // \"Awaiting input\"' | xargs -I{} cmux-bridge notify \"Codex: {}\"",
  "--",
]

"#;
            format!("{notify_block}{content}")
        }

        for SyncFileToUpload {
            host_path,
            sandbox_path: sandbox_path_str,
            is_dir,
        } in files_to_upload
        {
            let sandbox_path = Path::new(sandbox_path_str);
            let rel_sandbox_path = sandbox_path.strip_prefix("/").unwrap_or(sandbox_path);
            let tar_path = Path::new(temp_dir_name).join(rel_sandbox_path);

            let result: io::Result<()> = if is_dir {
                tar.append_dir_all(&tar_path, &host_path)
            } else if sandbox_path_str == "/root/.codex/config.toml" {
                match fs::read_to_string(&host_path) {
                    Ok(raw) => {
                        let merged = ensure_codex_notify(&raw);
                        let bytes = merged.as_bytes();
                        let mut header = Header::new_gnu();
                        if header.set_path(&tar_path).is_err() {
                            return Err(format!(
                                "Failed to set tar path for {}",
                                tar_path.display()
                            ));
                        }
                        header.set_size(bytes.len() as u64);
                        header.set_mode(0o644);
                        let mtime = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs();
                        header.set_mtime(mtime);
                        header.set_cksum();
                        tar.append_data(&mut header, &tar_path, bytes)
                    }
                    Err(e) => Err(e),
                }
            } else {
                tar.append_path_with_name(&host_path, &tar_path)
            };

            if let Err(e) = result {
                return Err(format!(
                    "Failed to add {} to tar: {}",
                    host_path.display(),
                    e
                ));
            }
        }

        if let Err(e) = tar.finish() {
            return Err(format!("Failed to finalize tar archive: {}", e));
        }
    }

    Ok(Some(buffer))
}

/// Upload pre-built sync files tar and execute the move script.
pub async fn upload_prebuilt_sync_files(
    client: &Client,
    base_url: &str,
    id: &str,
    tar_data: Vec<u8>,
    log_progress: bool,
) -> anyhow::Result<()> {
    if log_progress {
        eprintln!("Syncing auth files...");
    }

    let url = format!("{}/sandboxes/{}/files", base_url.trim_end_matches('/'), id);
    let response = client.post(url).body(tar_data).send().await?;
    if !response.status().is_success() {
        return Err(anyhow!(
            "Failed to upload sync files: {}",
            response.status()
        ));
    }

    let move_script = r#"
        if [ -d /workspace/__cmux_sync_temp ]; then
            cp -r /workspace/__cmux_sync_temp/root/. /root/ 2>/dev/null || true
            git config --global --add safe.directory /workspace || true
            rm -rf /workspace/__cmux_sync_temp
            # Fix SSH permissions (SSH is picky about this)
            if [ -d /root/.ssh ]; then
                chmod 700 /root/.ssh
                chmod 600 /root/.ssh/* 2>/dev/null || true
                chmod 644 /root/.ssh/*.pub 2>/dev/null || true
                chmod 644 /root/.ssh/known_hosts 2>/dev/null || true
                chmod 644 /root/.ssh/config 2>/dev/null || true
                # Create authorized_keys from user's public keys for SSH access
                cat /root/.ssh/*.pub > /root/.ssh/authorized_keys 2>/dev/null || true
                chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
            fi
        fi
        # Add container's SSH key to authorized_keys for dmux ssh command
        # This key is generated in the Docker image and allows the container to SSH into sandboxes
        CONTAINER_KEY_FILE="/usr/share/cmux/container-ssh.pub"
        if [ -f "$CONTAINER_KEY_FILE" ]; then
            mkdir -p /root/.ssh
            cat "$CONTAINER_KEY_FILE" >> /root/.ssh/authorized_keys 2>/dev/null || true
            chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
        fi
        # Start sshd for SSH access to sandbox
        mkdir -p /run/sshd
        /usr/sbin/sshd 2>/dev/null || true
    "#;

    let exec_body = ExecRequest {
        command: vec!["/bin/sh".into(), "-c".into(), move_script.into()],
        workdir: None,
        env: Vec::new(),
    };

    let exec_url = format!("{}/sandboxes/{}/exec", base_url.trim_end_matches('/'), id);
    let exec_response = client.post(exec_url).json(&exec_body).send().await?;

    if !exec_response.status().is_success() {
        return Err(anyhow!(
            "Failed to execute move script: {}",
            exec_response.status()
        ));
    }

    Ok(())
}
