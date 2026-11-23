//! A VM's guest over the VM API, for a caller that drives it step by step: wait for a VM to run,
//! write a file into it, run a command in it. The cmux CLI's headless `cmux vm new --bootstrap`
//! makes a machine bootstrap's writes and execs with these (cmux-tui `cli/vm_bootstrap.rs`), the
//! same plan the cmux app makes over the Cloud API. Credentials resolve as for every verb: flags,
//! `CMUX_VM_API_KEY`, the config file, the stored token.

use std::io::Write;
use std::path::Path;

use cmux_vm_client::raw::{Client, types};
use serde_json::json;

use crate::error::CliError;

/// A failed call: the exit code the CLI gives it ([`crate::exit`]) and its message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GuestError {
    pub code: i32,
    pub message: String,
}

impl std::fmt::Display for GuestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<CliError> for GuestError {
    fn from(error: CliError) -> Self {
        Self {
            code: error.exit_code(),
            message: error.message().to_owned(),
        }
    }
}

/// One exec's answer. `exit_code` is none when the command was killed at its timeout.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ExecOutput {
    pub exit_code: Option<i64>,
    pub stdout: String,
    pub stderr: String,
}

/// An authenticated VM API client for guest calls.
pub struct Guest {
    client: Client,
}

impl Guest {
    /// The client the verbs would use with these global options (`--base-url`, `--team`,
    /// `--config`); the settings' warnings go to `stderr`.
    pub fn connect(
        base_url: Option<&str>,
        team: Option<&str>,
        config: Option<&Path>,
        env: &dyn Fn(&str) -> Option<String>,
        stderr: &mut dyn Write,
    ) -> Result<Self, GuestError> {
        let stored = crate::stored_token(config.is_some(), env, false, stderr)?;
        let (client, _) =
            crate::authenticated(base_url, team, config, env, stored.as_ref(), false, stderr)?;
        Ok(Self { client })
    }

    /// Until `vm_id` runs (five minutes at most); a VM that stops or fails meanwhile is an error.
    pub async fn wait_running(&self, vm_id: &str) -> Result<(), GuestError> {
        Ok(crate::run::wait_running_id(&self.client, vm_id).await?)
    }

    /// Runs `command` in the guest's shell. Not retried but on a 429 (an exec may have started).
    pub async fn exec(
        &self,
        vm_id: &str,
        command: &str,
        timeout_ms: u64,
    ) -> Result<ExecOutput, GuestError> {
        let body: types::ExecRequest =
            crate::request_body(json!({ "command": command, "timeoutMs": timeout_ms }))?;
        let ran = crate::run::send_exec(&self.client, vm_id, &body)
            .await
            .map_err(|e| e.for_vm(vm_id, "exec"))?;
        Ok(ExecOutput {
            exit_code: ran.code.map(i64::from),
            stdout: String::from_utf8_lossy(&ran.stdout).into_owned(),
            stderr: ran.stderr,
        })
    }

    /// Writes `bytes` to `path` with permission bits `mode`, replacing the file atomically.
    /// Retried on a 429 or 503: the same write twice leaves the same file.
    pub async fn write_file(
        &self,
        vm_id: &str,
        path: &str,
        bytes: &[u8],
        mode: u32,
    ) -> Result<(), GuestError> {
        let guest_path = path
            .parse::<types::GuestPath>()
            .map_err(|e| CliError::usage(format!("invalid guest path {path:?}: {e}")))?;
        let length = bytes
            .len()
            .to_string()
            .parse::<types::FilesWriteFileContentLength>()
            .map_err(|e| CliError::usage(format!("invalid length: {e}")))?;
        // The API reads the mode as a decimal integer (493 is 0755).
        let mode = mode.to_string();
        crate::run::retrying(|| {
            crate::call(self.client.files_write_file(
                vm_id,
                Some(&mode),
                &guest_path,
                Some(&length),
                None,
                bytes.to_vec(),
            ))
        })
        .await
        .map_err(|e| GuestError::from(e.for_vm(vm_id, "file write")))
    }
}
