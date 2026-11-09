//! A machine the holder delivers to: a capability probe and the few file operations a delivery
//! needs. [`MachineTarget`] is the real one, on a Cloud machine's exec and file routes
//! ([`Machines`]) with the app's own answers for ownership and liveness ([`Questions`]).

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use crate::error::{BrokerError, Error};

pub const ACCESS_PATH: &str = "/home/cmux/.config/cmux/codex-broker/access.json";
pub const MODE_PATH: &str = "/home/cmux/.config/cmux/agent-auth/codex";
pub const PROTOCOL_VERSION: i64 = 1;
pub const BRIDGE: &str = "codex-external-access-v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Capability {
    pub owner_vm: bool,
    pub protocol_version: i64,
    pub codex_external_access_token: bool,
}

/// One machine. `is_live` never wakes a paused machine.
#[async_trait]
pub trait Target: Send + Sync {
    fn machine_id(&self) -> &str;
    async fn is_live(&self) -> Result<bool, Error>;
    async fn capability(&self) -> Result<Capability, Error>;
    async fn make_directory(&self, path: &str) -> Result<(), Error>;
    /// None: no such file.
    async fn read_file(&self, path: &str) -> Result<Option<Vec<u8>>, Error>;
    async fn write_file(&self, path: &str, data: &[u8], mode: u32) -> Result<(), Error>;
    async fn commit_files(
        &self,
        stage_access: &str,
        final_access: &str,
        stage_mode: &str,
        final_mode: &str,
    ) -> Result<(), Error>;
    /// No such file is no error.
    async fn remove_file(&self, path: &str) -> Result<(), Error>;
}

pub type TargetRef = Arc<dyn Target>;

/// A machine route's refusal, as the cmux API answers it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VmError {
    pub status: u16,
    pub code: Option<String>,
    pub message: String,
}

impl VmError {
    fn not_found(&self) -> bool {
        self.status == 404 && self.code.as_deref() == Some("vm_file_not_found")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecResult {
    pub exit_code: i64,
    pub stdout: String,
}

/// A Cloud machine's exec and file routes, in one account team.
#[async_trait]
pub trait Machines: Send + Sync {
    async fn exec(
        &self,
        team: Option<&str>,
        machine: &str,
        command: &str,
        timeout_ms: u64,
    ) -> Result<ExecResult, VmError>;
    async fn read(&self, team: Option<&str>, machine: &str, path: &str)
    -> Result<Vec<u8>, VmError>;
    async fn write(
        &self,
        team: Option<&str>,
        machine: &str,
        path: &str,
        data: &[u8],
        mode: Option<u32>,
    ) -> Result<(), VmError>;
    async fn mkdir(&self, team: Option<&str>, machine: &str, path: &str) -> Result<(), VmError>;
    async fn remove(&self, team: Option<&str>, machine: &str, path: &str) -> Result<(), VmError>;
}

/// The app's own answers about a machine.
#[async_trait]
pub trait Questions: Send + Sync {
    /// The app's link to the machine has its owner answer (a Worker machine's own ownership).
    async fn owns(&self, machine: &str) -> Result<bool, Error>;
    /// The app's record of the machine says it runs.
    async fn live(&self, machine: &str) -> Result<bool, Error>;
}

/// The running bridge's status, as the machine's work user.
pub const STATUS_COMMAND: &str = concat!(
    "set -eu; ",
    r#"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }; "#,
    r#"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }; "#,
    r#"u=cmux; id -u "$u" >/dev/null 2>&1 || u=root; "#,
    r#"h=$(getent passwd "$u" | cut -d: -f6); "#,
    r#"b="$h/.cmux/bin/cmux-tui"; "#,
    r#"[ -x "$b" ] || { echo "cmux: this machine has no cmux-tui" >&2; exit 82; }; "#,
    r#"as_u env HOME="$h" "$b" acp --json status"#,
);

/// Whether a status answer lists the token-delivery capability.
pub fn supports_external_access(output: &str) -> bool {
    serde_json::from_str::<Value>(output)
        .ok()
        .and_then(|object| object.get("capabilities").and_then(Value::as_array).cloned())
        .is_some_and(|list| list.iter().any(|c| c.as_str() == Some(BRIDGE)))
}

fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

/// The fixed install transaction, with privilege because the file API may stage root-owned
/// files while exec runs as the work user. Token bytes travel only through the file API.
pub fn commit_command(
    stage_access: &str,
    final_access: &str,
    stage_mode: &str,
    final_mode: &str,
) -> String {
    let script = [
        "set -eu".to_owned(),
        format!(
            "a={}; f={}; m={}; n={}; b={}",
            quote(stage_access),
            quote(final_access),
            quote(stage_mode),
            quote(final_mode),
            quote(&format!("{stage_mode}.previous"))
        ),
        r#"for p in "$a" "$m"; do test -f "$p"; test ! -L "$p"; test "$(stat -c %a "$p")" = 600; case $(stat -c %u "$p") in 0|$(id -u cmux)) ;; *) exit 83 ;; esac; chown cmux:cmux "$p"; done"#.to_owned(),
        r#"had_mode=0; if test -e "$n"; then test -f "$n"; test ! -L "$n"; cp -p -- "$n" "$b"; had_mode=1; fi"#.to_owned(),
        r#"rollback() { if test "$had_mode" = 1; then mv -f -- "$b" "$n"; else rm -f -- "$n"; fi; }"#.to_owned(),
        r#"trap rollback EXIT; mv -f -- "$m" "$n"; mv -f -- "$a" "$f"; trap - EXIT; rm -f -- "$b" || :"#.to_owned(),
    ]
    .join("; ");
    format!(
        "if [ \"$(id -u)\" = 0 ]; then /bin/sh -c {0}; else sudo -n /bin/sh -c {0}; fi",
        quote(&script)
    )
}

/// A Cloud machine in `team` (the scope's team, pinned): ownership comes from the app's link
/// answer before the running bridge is asked for its capability; guest files never authorize.
pub struct MachineTarget {
    pub machine: String,
    pub team: Option<String>,
    pub machines: Arc<dyn Machines>,
    pub questions: Arc<dyn Questions>,
}

fn other(error: VmError) -> Error {
    Error::Other(error.message)
}

#[async_trait]
impl Target for MachineTarget {
    fn machine_id(&self) -> &str {
        &self.machine
    }

    async fn is_live(&self) -> Result<bool, Error> {
        self.questions.live(&self.machine).await
    }

    async fn capability(&self) -> Result<Capability, Error> {
        if !self.questions.owns(&self.machine).await? {
            return Ok(Capability {
                owner_vm: false,
                protocol_version: 0,
                codex_external_access_token: false,
            });
        }
        let result = self
            .machines
            .exec(self.team.as_deref(), &self.machine, STATUS_COMMAND, 8_000)
            .await
            .map_err(other)?;
        let ready = result.exit_code == 0 && supports_external_access(&result.stdout);
        Ok(Capability {
            owner_vm: true,
            protocol_version: if ready { PROTOCOL_VERSION } else { 0 },
            codex_external_access_token: ready,
        })
    }

    async fn make_directory(&self, path: &str) -> Result<(), Error> {
        self.machines.mkdir(self.team.as_deref(), &self.machine, path).await.map_err(other)
    }

    async fn read_file(&self, path: &str) -> Result<Option<Vec<u8>>, Error> {
        match self.machines.read(self.team.as_deref(), &self.machine, path).await {
            Ok(data) => Ok(Some(data)),
            Err(error) if error.not_found() => Ok(None),
            Err(error) => Err(other(error)),
        }
    }

    async fn write_file(&self, path: &str, data: &[u8], mode: u32) -> Result<(), Error> {
        self.machines
            .write(self.team.as_deref(), &self.machine, path, data, Some(mode))
            .await
            .map_err(other)
    }

    async fn commit_files(&self, a: &str, b: &str, c: &str, d: &str) -> Result<(), Error> {
        let command = commit_command(a, b, c, d);
        let result = self
            .machines
            .exec(self.team.as_deref(), &self.machine, &command, 8_000)
            .await
            .map_err(other)?;
        if result.exit_code != 0 {
            return Err(BrokerError::RemoteDeliveryFailed.into());
        }
        Ok(())
    }

    async fn remove_file(&self, path: &str) -> Result<(), Error> {
        match self.machines.remove(self.team.as_deref(), &self.machine, path).await {
            Err(error) if !error.not_found() => Err(other(error)),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
#[path = "target_tests.rs"]
mod tests;
