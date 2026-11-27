//! Ported from CloudCodexBrokerTargetTests.swift and the Worker-machine case of
//! CloudWorkerMachineFilesTests.swift.

use super::*;
use std::sync::Mutex;

#[derive(Default)]
struct Calls {
    seen: Mutex<Vec<(Option<String>, String)>>,
    stdout: String,
}

#[async_trait]
impl Machines for Calls {
    async fn exec(
        &self,
        team: Option<&str>,
        _: &str,
        command: &str,
        _: u64,
    ) -> Result<ExecResult, VmError> {
        self.seen.lock().unwrap().push((team.map(str::to_owned), command.to_owned()));
        let exit_code = if command.starts_with("if [") { 1 } else { 0 };
        Ok(ExecResult { exit_code, stdout: self.stdout.clone() })
    }
    async fn read(&self, _: Option<&str>, _: &str, path: &str) -> Result<Vec<u8>, VmError> {
        Err(VmError { status: 404, code: Some("vm_file_not_found".into()), message: path.into() })
    }
    async fn write(
        &self,
        _: Option<&str>,
        _: &str,
        _: &str,
        _: &[u8],
        _: Option<u32>,
    ) -> Result<(), VmError> {
        Ok(())
    }
    async fn mkdir(&self, _: Option<&str>, _: &str, _: &str) -> Result<(), VmError> {
        Ok(())
    }
    async fn remove(&self, _: Option<&str>, _: &str, _: &str) -> Result<(), VmError> {
        Err(VmError { status: 403, code: Some("vm_forbidden".into()), message: "refused".into() })
    }
}

struct Owner(Result<bool, Error>);

#[async_trait]
impl Questions for Owner {
    async fn owns(&self, _: &str) -> Result<bool, Error> {
        self.0.clone()
    }
    async fn live(&self, _: &str) -> Result<bool, Error> {
        Ok(true)
    }
}

fn target(stdout: &str, owns: Result<bool, Error>) -> (MachineTarget, Arc<Calls>) {
    let calls = Arc::new(Calls { stdout: stdout.into(), ..Calls::default() });
    let target = MachineTarget {
        machine: "vm_aaaaaaaaaaaaaaaaaaaa".into(),
        team: Some("pinned-team".into()),
        machines: calls.clone(),
        questions: Arc::new(Owner(owns)),
    };
    (target, calls)
}

const READY: &str = r#"{"capabilities":["codex-external-access-v1"]}"#;

#[test]
fn reads_pretty_printed_running_daemon_capabilities() {
    assert!(supports_external_access(
        "{\n  \"capabilities\": [\n    \"codex-external-access-v1\"\n  ]\n}"
    ));
    assert!(!supports_external_access("{\"capabilities\":[]}"));
    assert!(!supports_external_access("not json"));
}

/// A machine the caller does not own is refused before anything runs on it.
#[tokio::test]
async fn a_machine_the_caller_does_not_own_is_refused_before_guest_execution() {
    let (target, calls) = target(READY, Ok(false));
    let capability = target.capability().await.unwrap();
    assert_eq!(
        capability,
        Capability { owner_vm: false, protocol_version: 0, codex_external_access_token: false }
    );
    assert!(calls.seen.lock().unwrap().is_empty());
    assert!(target.is_live().await.unwrap());
}

#[tokio::test]
async fn an_authoritative_owner_still_requires_the_running_bridge_capability() {
    let (ready, calls) = target(READY, Ok(true));
    assert_eq!(
        ready.capability().await.unwrap(),
        Capability { owner_vm: true, protocol_version: 1, codex_external_access_token: true }
    );
    let seen = calls.seen.lock().unwrap().clone();
    assert_eq!(
        seen,
        vec![(Some("pinned-team".to_owned()), STATUS_COMMAND.to_owned())],
        "the scope's team, pinned"
    );
    let (unsupported, _) = target(r#"{"capabilities":[]}"#, Ok(true));
    assert_eq!(
        unsupported.capability().await.unwrap(),
        Capability { owner_vm: true, protocol_version: 0, codex_external_access_token: false }
    );
}

/// An owner answer that fails fails the capability: it never falls back to guest files.
#[tokio::test]
async fn ownership_failures_never_fall_back_to_guest_files() {
    let (target, calls) = target(READY, Err(Error::Other("refused".into())));
    assert!(target.capability().await.is_err());
    assert!(calls.seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_missing_file_reads_as_none_and_a_failed_commit_is_a_delivery_failure() {
    let (target, _) = target(READY, Ok(true));
    assert_eq!(target.read_file(ACCESS_PATH).await, Ok(None));
    assert_eq!(target.remove_file(ACCESS_PATH).await, Err(Error::Other("refused".into())));
    assert_eq!(
        target.commit_files("/a", ACCESS_PATH, "/m", MODE_PATH).await,
        Err(Error::Broker(BrokerError::RemoteDeliveryFailed))
    );
}

#[test]
fn the_commit_command_quotes_every_path() {
    let command = commit_command("/s/a'b", "/f", "/m", "/n");
    assert!(command.starts_with("if [ \"$(id -u)\" = 0 ]; then /bin/sh -c '"));
    assert!(command.contains("a=") && command.contains(".previous"));
    // The single quote inside a path is closed, escaped and reopened, twice over (path, then script).
    assert!(!command.contains("/s/a'b"));
}
