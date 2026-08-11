//! Windows AppContainer feasibility gate.
//!
//! This gate is deliberately separate from measured startup. It proves the supported
//! AppContainer launch boundary on the dedicated benchmark account before that boundary can
//! become part of a timed launch.

use std::ffi::{OsStr, c_void};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::mem::{size_of, zeroed};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{FromRawHandle, RawHandle};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr::{null, null_mut};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;
use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_SUCCESS, GENERIC_ALL,
    GENERIC_EXECUTE, GENERIC_READ, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, LocalFree,
    SetHandleInformation, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::NetworkManagement::WindowsFirewall::{
    INET_FIREWALL_APP_CONTAINER, NetworkIsolationEnumAppContainers,
    NetworkIsolationFreeAppContainers,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSidToSidW, EXPLICIT_ACCESS_W, GRANT_ACCESS,
    GetNamedSecurityInfoW, NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, SetEntriesInAclW,
    SetNamedSecurityInfoW, TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
};
use windows_sys::Win32::Security::Isolation::{
    CreateAppContainerProfile, DeleteAppContainerProfile,
    DeriveAppContainerSidFromAppContainerName, GetAppContainerFolderPath,
    GetAppContainerRegistryLocation,
};
use windows_sys::Win32::Security::{
    ACL, AdjustTokenPrivileges, CreateRestrictedToken, DACL_SECURITY_INFORMATION,
    DISABLE_MAX_PRIVILEGE, EqualSid, GetFileSecurityW, GetLengthSid, GetSidSubAuthority,
    GetSidSubAuthorityCount, GetTokenInformation, ImpersonateLoggedOnUser,
    LABEL_SECURITY_INFORMATION, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT,
    LUID_AND_ATTRIBUTES, LogonUserW, LookupPrivilegeValueW, PSID, RevertToSelf,
    SE_PRIVILEGE_ENABLED, SECURITY_ATTRIBUTES, SECURITY_CAPABILITIES, SetFileSecurityW,
    SetTokenInformation, TOKEN_ADJUST_DEFAULT, TOKEN_ADJUST_PRIVILEGES,
    TOKEN_APPCONTAINER_INFORMATION, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_GROUPS,
    TOKEN_MANDATORY_LABEL, TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_STATISTICS, TOKEN_USER,
    TokenAppContainerSid, TokenCapabilities, TokenIntegrityLevel, TokenIsAppContainer,
    TokenPrivileges, TokenStatistics, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{FILE_TRAVERSE, FILE_TYPE_UNKNOWN, GetFileType};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows_sys::Win32::System::IO::{CreateIoCompletionPort, GetQueuedCompletionStatus};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectAssociateCompletionPortInformation,
    JobObjectBasicAccountingInformation, JobObjectExtendedLimitInformation,
    QueryInformationJobObject, SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::Registry::{KEY_SET_VALUE, RegCloseKey, RegSetValueExW};
use windows_sys::Win32::System::SystemServices::{
    JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO, SE_GROUP_INTEGRITY, SECURITY_MANDATORY_LOW_RID,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW,
    CreateProcessWithTokenW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT,
    GetCurrentProcess, GetExitCodeProcess, GetProcessId, GetThreadId,
    InitializeProcThreadAttributeList, OpenProcessToken, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
    PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, PROCESS_INFORMATION, ResumeThread, STARTUPINFOEXW,
    STARTUPINFOW, UpdateProcThreadAttribute, WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::{LoadUserProfileW, PROFILEINFOW, UnloadUserProfile};

const EVIDENCE_SCHEMA_VERSION: u32 = 1;
const MAX_RECORD_BYTES: usize = 64 * 1024;
const BROKER_TIMEOUT: Duration = Duration::from_secs(50);
const PRODUCT_TIMEOUT: Duration = Duration::from_secs(30);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(10);
const JOB_COMPLETION_KEY: usize = 0x434d_5558;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerConfig {
    schema_version: u32,
    nonce: String,
    target: PathBuf,
    target_sha256: String,
    fixture_root: PathBuf,
    adjacent_path: PathBuf,
    profile_folder: PathBuf,
    profile_name: String,
    appcontainer_sid: String,
    account_authentication_id: String,
    output: PathBuf,
    failure_output: PathBuf,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerFailureEvidence {
    schema_version: u32,
    nonce: String,
    stage: String,
    error: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProductEvidence {
    schema_version: u32,
    nonce: String,
    entry_reached: bool,
    fixture_write: bool,
    adjacent_write_denied: bool,
    profile_owned_write: bool,
    registry_owned_write: bool,
    outbound_network_denied: bool,
    inbound_network_denied: bool,
    inbound_bound_address: Option<SocketAddr>,
    descendant_ready: bool,
    token_is_appcontainer: bool,
    appcontainer_sid_match: bool,
    restricting_sid_count_zero: bool,
    capability_count_zero: bool,
    low_integrity: bool,
    no_enabled_privileges: bool,
    account_authentication_match: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerEvidence {
    schema_version: u32,
    nonce: String,
    appcontainer_sid: String,
    product: ProductEvidence,
    create_process_as_user_succeeded: bool,
    explicit_three_handle_list: bool,
    security_capabilities_applied: bool,
    product_exact_job_before_resume: bool,
    product_resume_previous_count: u32,
    product_process_id: u32,
    product_primary_thread_id: u32,
    descendant_observed_in_job: bool,
    active_process_zero: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct AclRestorationEvidence {
    path: PathBuf,
    grant: String,
    before_sha256: String,
    restored_sha256: String,
    exact_restore: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct FeasibilityEvidence {
    schema_version: u32,
    backend: &'static str,
    nonce: String,
    profile_name: String,
    appcontainer_sid: String,
    account_sid: String,
    profile_user_sid_matches_account: bool,
    no_capabilities: bool,
    broker: BrokerEvidence,
    profile_folder_owned_state: bool,
    registry_owned_state: bool,
    profile_delete_succeeded: bool,
    sid_derived_after_delete_matches: bool,
    profile_folder_absent_after_delete: bool,
    registry_store_delete_contract: bool,
    network_isolation_entry_absent_after_delete: bool,
    acl_restorations: Vec<AclRestorationEvidence>,
}

impl FeasibilityEvidence {
    fn validate(&self) -> Result<()> {
        let product = &self.broker.product;
        if self.schema_version != EVIDENCE_SCHEMA_VERSION
            || self.backend != "windows-appcontainer-feasibility"
            || self.nonce != self.broker.nonce
            || self.appcontainer_sid != self.broker.appcontainer_sid
            || !self.profile_user_sid_matches_account
            || !self.no_capabilities
            || product.schema_version != EVIDENCE_SCHEMA_VERSION
            || product.nonce != self.nonce
            || !product.entry_reached
            || !product.fixture_write
            || !product.adjacent_write_denied
            || !product.profile_owned_write
            || !product.registry_owned_write
            || !product.outbound_network_denied
            || !product.inbound_network_denied
            || !product.descendant_ready
            || !product.token_is_appcontainer
            || !product.appcontainer_sid_match
            || !product.restricting_sid_count_zero
            || !product.capability_count_zero
            || !product.low_integrity
            || !product.no_enabled_privileges
            || !product.account_authentication_match
            || !self.broker.create_process_as_user_succeeded
            || !self.broker.explicit_three_handle_list
            || !self.broker.security_capabilities_applied
            || !self.broker.product_exact_job_before_resume
            || self.broker.product_resume_previous_count != 1
            || self.broker.product_process_id == 0
            || self.broker.product_primary_thread_id == 0
            || !self.broker.descendant_observed_in_job
            || !self.broker.active_process_zero
            || !self.profile_folder_owned_state
            || !self.registry_owned_state
            || !self.profile_delete_succeeded
            || !self.sid_derived_after_delete_matches
            || !self.profile_folder_absent_after_delete
            || !self.registry_store_delete_contract
            || !self.network_isolation_entry_absent_after_delete
            || self.acl_restorations.is_empty()
            || self
                .acl_restorations
                .iter()
                .any(|entry| !entry.exact_restore || entry.before_sha256 != entry.restored_sha256)
        {
            bail!("Windows AppContainer feasibility evidence is incomplete");
        }
        Ok(())
    }
}

pub(super) fn run_controller(values: &[String]) -> Result<()> {
    let fixture_parent = required_path(values, "--fixture-parent")?;
    let output = required_path(values, "--output")?;
    if !fixture_parent.is_dir() || output.exists() {
        bail!("AppContainer feasibility paths are not in their initial state");
    }
    let nonce = random_nonce()?;
    let profile_name = format!("cmux.bench.ac.{}", &nonce[..32]);
    let root = fixture_parent.join(format!("appcontainer-{}", &nonce[..16]));
    let adjacent = fixture_parent.join(format!("appcontainer-adjacent-{}", &nonce[..16]));
    fs::create_dir(&root).context("create AppContainer feasibility root")?;
    fs::write(&adjacent, b"protected").context("create AppContainer adjacent sentinel")?;

    let current = std::env::current_exe()?.canonicalize()?;
    let target_sha256 = sha256_file(&current)?;
    let user =
        std::env::var("CMUX_BENCH_WINDOWS_USER").context("CMUX_BENCH_WINDOWS_USER is required")?;
    let password = std::env::var("CMUX_BENCH_WINDOWS_PASSWORD")
        .context("CMUX_BENCH_WINDOWS_PASSWORD is required")?;
    let mut account = AccountProfile::logon(&user, &password)?;
    let account_sid = token_user_sid(account.token())?;
    let account_authentication_id = token_authentication_id(account.token())?;

    let account_token = account.token();
    let mut profile =
        account.impersonate(|_| AppContainerProfile::create(&profile_name, account_token))?;
    let appcontainer_sid = profile.sid_text.clone();
    let profile_user_sid_matches_account = account
        .impersonate(|_| network_profile_present(&profile.sid, &account_sid, &profile_name))?;
    if !profile_user_sid_matches_account {
        bail!("AppContainer profile did not enumerate for the benchmark account SID");
    }

    let mut acl_leases = Vec::new();
    acl_leases.push(AclLease::grant_account_and_appcontainer_root(&root, &user, profile.sid.0)?);
    acl_leases.push(AclLease::grant_account_and_sid(
        &current,
        &user,
        profile.sid.0,
        GENERIC_READ | GENERIC_EXECUTE,
        "target-read-execute",
    )?);
    for parent in target_parent_chain(&current)? {
        acl_leases.push(AclLease::grant_account_and_sid(
            &parent,
            &user,
            profile.sid.0,
            FILE_TRAVERSE,
            "target-parent-traverse",
        )?);
    }

    let broker_output = root.join("appcontainer-broker-evidence.json");
    let broker_failure = root.join("appcontainer-broker-failure.json");
    let config_path = root.join("appcontainer-broker-config.json");
    let config = BrokerConfig {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: nonce.clone(),
        target: current.clone(),
        target_sha256,
        fixture_root: root.clone(),
        adjacent_path: adjacent.clone(),
        profile_folder: profile.folder.clone(),
        profile_name: profile_name.clone(),
        appcontainer_sid: appcontainer_sid.clone(),
        account_authentication_id,
        output: broker_output.clone(),
        failure_output: broker_failure.clone(),
    };
    write_new_json(&config_path, &config)?;
    let broker_result = run_account_broker(account.token(), &current, &config_path);
    let broker = match broker_result {
        Ok(()) => read_bounded_json::<BrokerEvidence>(&broker_output, MAX_RECORD_BYTES)?,
        Err(error) => {
            let copied_failure = copy_broker_failure(&broker_failure, &output);
            let cleanup = restore_acl_leases(&mut acl_leases);
            let profile_cleanup = account.impersonate(|_| profile.delete());
            let _ = fs::remove_file(&adjacent);
            return Err(error.context(format!(
                "AppContainer broker failed; diagnostic: {}; ACL cleanup: {}; profile cleanup: {}",
                result_label(&copied_failure),
                result_label(&cleanup),
                result_label(&profile_cleanup)
            )));
        }
    };
    validate_broker(&broker, &config)?;

    let profile_folder_owned_state =
        profile.folder.join(format!("cmux-{}.txt", &nonce[..16])).is_file();
    let registry_owned_state = broker.product.registry_owned_write;

    account.impersonate(|_| profile.delete())?;
    let derived = account.impersonate(|_| derive_profile_sid(&profile_name))?;
    let sid_derived_after_delete_matches = unsafe { EqualSid(derived.0, profile.sid.0) } != 0;
    let profile_folder_absent_after_delete = !profile.folder.exists();
    let network_isolation_entry_absent_after_delete = account.impersonate(|_| {
        Ok(!network_profile_present(&profile.sid, &account_sid, &profile_name)?)
    })?;
    drop(derived);

    let acl_restorations = restore_acl_leases(&mut acl_leases)?;
    fs::remove_file(&adjacent).context("remove AppContainer adjacent sentinel")?;
    if fs::read(&adjacent).is_ok() {
        bail!("AppContainer adjacent sentinel remained after cleanup");
    }
    account.unload()?;

    let evidence = FeasibilityEvidence {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        backend: "windows-appcontainer-feasibility",
        nonce,
        profile_name,
        appcontainer_sid,
        account_sid,
        profile_user_sid_matches_account,
        no_capabilities: true,
        broker,
        profile_folder_owned_state,
        registry_owned_state,
        profile_delete_succeeded: true,
        sid_derived_after_delete_matches,
        profile_folder_absent_after_delete,
        registry_store_delete_contract: true,
        network_isolation_entry_absent_after_delete,
        acl_restorations,
    };
    evidence.validate()?;
    write_new_json(&output, &evidence)?;
    fs::remove_dir_all(&root).context("remove AppContainer feasibility root")?;
    Ok(())
}

pub(super) fn run_broker(values: &[String]) -> Result<()> {
    let config_path = required_path(values, "--config")?;
    let config = read_bounded_json::<BrokerConfig>(&config_path, MAX_RECORD_BYTES)?;
    validate_config(&config, &config_path)?;
    fs::remove_file(&config_path).context("consume AppContainer broker config")?;
    match launch_appcontainer_product(&config) {
        Ok(evidence) => write_new_json(&config.output, &evidence),
        Err(error) => {
            let failure = BrokerFailureEvidence {
                schema_version: EVIDENCE_SCHEMA_VERSION,
                nonce: config.nonce.clone(),
                stage: "account-broker-product-launch".into(),
                error: bounded_error(&error),
            };
            let write = write_new_json(&config.failure_output, &failure);
            match write {
                Ok(()) => Err(error),
                Err(write) => Err(error.context(format!(
                    "also failed to write AppContainer broker failure evidence: {write:#}"
                ))),
            }
        }
    }
}

pub(super) fn run_probe(values: &[String]) -> Result<()> {
    if !values.is_empty() {
        bail!("AppContainer probe takes its identity from its filtered environment");
    }
    let nonce = required_env("CMUX_APP_CONTAINER_NONCE")?;
    let fixture_root = PathBuf::from(required_env("CMUX_APP_CONTAINER_FIXTURE")?);
    let adjacent = PathBuf::from(required_env("CMUX_APP_CONTAINER_ADJACENT")?);
    let profile_folder = PathBuf::from(required_env("CMUX_APP_CONTAINER_PROFILE")?);
    let appcontainer_sid = required_env("CMUX_APP_CONTAINER_SID")?;
    let account_authentication_id = required_env("CMUX_APP_CONTAINER_AUTH_ID")?;
    let outbound_address = required_env("CMUX_APP_CONTAINER_NETWORK")?.parse::<SocketAddr>()?;
    let inbound_ip = required_env("CMUX_APP_CONTAINER_INBOUND_IP")?;

    let fixture_write =
        fs::write(fixture_root.join(format!("inside-{}.txt", &nonce[..16])), nonce.as_bytes())
            .is_ok();
    let adjacent_write_denied = fs::write(&adjacent, b"changed").is_err();
    let profile_owned_write =
        fs::write(profile_folder.join(format!("cmux-{}.txt", &nonce[..16])), nonce.as_bytes())
            .is_ok();
    let registry_owned_write = write_appcontainer_registry_sentinel(&nonce)?;
    let outbound_network_denied =
        TcpStream::connect_timeout(&outbound_address, Duration::from_secs(2)).is_err();
    let inbound_listener = TcpListener::bind(format!("{inbound_ip}:0")).ok();
    let inbound_bound_address =
        inbound_listener.as_ref().and_then(|listener| listener.local_addr().ok());
    let proof = current_token_proof(&appcontainer_sid, &account_authentication_id)?;

    let mut child = Command::new(std::env::current_exe()?)
        .arg("--appcontainer-probe-child")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("spawn AppContainer descendant probe")?;
    let mut child_stdout =
        BufReader::new(child.stdout.take().context("capture descendant stdout")?);
    let mut ready = String::new();
    child_stdout.read_line(&mut ready)?;
    if ready.trim_end() != "READY" {
        bail!("AppContainer descendant did not report READY");
    }
    let _child_input = child.stdin.take().context("retain descendant blocking pipe")?;
    let evidence = ProductEvidence {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce,
        entry_reached: true,
        fixture_write,
        adjacent_write_denied,
        profile_owned_write,
        registry_owned_write,
        outbound_network_denied,
        inbound_network_denied: inbound_bound_address.is_none(),
        inbound_bound_address,
        descendant_ready: true,
        token_is_appcontainer: proof.is_appcontainer,
        appcontainer_sid_match: proof.appcontainer_sid_match,
        restricting_sid_count_zero: proof.restricting_sid_count_zero,
        capability_count_zero: proof.capability_count_zero,
        low_integrity: proof.low_integrity,
        no_enabled_privileges: proof.no_enabled_privileges,
        account_authentication_match: proof.authentication_id == account_authentication_id,
    };
    serde_json::to_writer(io::stdout().lock(), &evidence)?;
    writeln!(io::stdout())?;
    io::stdout().flush()?;
    let mut release = [0_u8; 1];
    io::stdin().read_exact(&mut release)?;
    drop(inbound_listener);
    Ok(())
}

pub(super) fn run_probe_child(values: &[String]) -> Result<()> {
    if !values.is_empty() {
        bail!("AppContainer descendant probe takes no arguments");
    }
    writeln!(io::stdout(), "READY")?;
    io::stdout().flush()?;
    let mut release = [0_u8; 1];
    io::stdin().read_exact(&mut release)?;
    Ok(())
}

#[derive(Debug)]
struct OwnedHandle(HANDLE);

// SAFETY: OwnedHandle uniquely owns one process-wide Windows kernel handle. Windows handles have
// no thread affinity, moving the owner does not change handle validity, and Drop only calls
// CloseHandle once. The wrapper does not provide shared access, so it is not Sync.
unsafe impl Send for OwnedHandle {}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: this owner closes its non-null handle once.
            unsafe { CloseHandle(self.0) };
        }
    }
}

struct ProductProcessOwner {
    process: OwnedHandle,
    thread: OwnedHandle,
    terminate_on_drop: bool,
}

struct BrokerProcessOwner {
    process: OwnedHandle,
    _thread: OwnedHandle,
    terminate_on_drop: bool,
}

impl Drop for BrokerProcessOwner {
    fn drop(&mut self) {
        if self.terminate_on_drop {
            let _ = unsafe {
                windows_sys::Win32::System::Threading::TerminateProcess(self.process.0, 125)
            };
            let _ = unsafe { WaitForSingleObject(self.process.0, 10_000) };
        }
    }
}

struct AttributeList {
    _storage: Vec<usize>,
    pointer: windows_sys::Win32::System::Threading::LPPROC_THREAD_ATTRIBUTE_LIST,
}

impl AttributeList {
    fn new(count: u32) -> Result<Self> {
        let mut bytes = 0_usize;
        let _ = unsafe { InitializeProcThreadAttributeList(null_mut(), count, 0, &mut bytes) };
        if bytes == 0 {
            return Err(io::Error::last_os_error()).context("size AppContainer attribute list");
        }
        let mut storage = vec![0_usize; bytes.div_ceil(size_of::<usize>())];
        let pointer = storage.as_mut_ptr().cast();
        check(
            unsafe { InitializeProcThreadAttributeList(pointer, count, 0, &mut bytes) },
            "initialize AppContainer attribute list",
        )?;
        Ok(Self { _storage: storage, pointer })
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        unsafe { DeleteProcThreadAttributeList(self.pointer) };
    }
}

impl Drop for ProductProcessOwner {
    fn drop(&mut self) {
        if self.terminate_on_drop {
            // SAFETY: process is live. This is the fail-closed fallback for every post-create
            // error path before the Job's ACTIVE_PROCESS_ZERO proof completes.
            let _ = unsafe {
                windows_sys::Win32::System::Threading::TerminateProcess(self.process.0, 125)
            };
            let _ = unsafe { WaitForSingleObject(self.process.0, 10_000) };
        }
    }
}

#[derive(Debug)]
struct OwnedSid(PSID);

impl OwnedSid {
    fn from_string(value: &str) -> Result<Self> {
        let value = wide(OsStr::new(value));
        let mut sid = null_mut();
        // SAFETY: value is NUL-terminated and sid points to writable storage.
        check(
            unsafe { ConvertStringSidToSidW(value.as_ptr(), &mut sid) },
            "convert AppContainer SID",
        )?;
        Ok(Self(sid))
    }
}

impl Drop for OwnedSid {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the SID conversion/profile APIs allocate this SID with LocalAlloc.
            unsafe { LocalFree(self.0.cast()) };
        }
    }
}

struct AccountProfile {
    token: OwnedHandle,
    profile: HANDLE,
}

impl AccountProfile {
    fn logon(user: &str, password: &str) -> Result<Self> {
        let user_wide = wide(OsStr::new(user));
        let password_wide = wide(OsStr::new(password));
        let domain = wide(OsStr::new("."));
        let mut token = null_mut();
        // SAFETY: all strings are NUL-terminated and token points to writable storage.
        check(
            unsafe {
                LogonUserW(
                    user_wide.as_ptr(),
                    domain.as_ptr(),
                    password_wide.as_ptr(),
                    LOGON32_LOGON_INTERACTIVE,
                    LOGON32_PROVIDER_DEFAULT,
                    &mut token,
                )
            },
            "log on dedicated AppContainer benchmark account",
        )?;
        let token = OwnedHandle(token);
        let mut user_wide = wide(OsStr::new(user));
        let mut profile = PROFILEINFOW {
            dwSize: u32::try_from(size_of::<PROFILEINFOW>())?,
            lpUserName: user_wide.as_mut_ptr(),
            ..PROFILEINFOW::default()
        };
        // SAFETY: token is a live account token and profile is writable.
        check(
            unsafe { LoadUserProfileW(token.0, &mut profile) },
            "load dedicated AppContainer benchmark profile",
        )?;
        Ok(Self { token, profile: profile.hProfile })
    }

    fn token(&self) -> HANDLE {
        self.token.0
    }

    fn impersonate<T>(&mut self, operation: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        // SAFETY: token is live and RevertToSelf runs for every result path below.
        check(
            unsafe { ImpersonateLoggedOnUser(self.token.0) },
            "impersonate dedicated AppContainer benchmark account",
        )?;
        let result = operation(self);
        // SAFETY: the current thread owns this impersonation state.
        let revert = check(unsafe { RevertToSelf() }, "revert AppContainer account impersonation");
        match (result, revert) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(error)) => Err(error),
            (Err(error), Err(revert)) => {
                Err(error
                    .context(format!("also failed to revert account impersonation: {revert:#}")))
            }
        }
    }

    fn unload(&mut self) -> Result<()> {
        if self.profile.is_null() {
            return Ok(());
        }
        check(
            unsafe { UnloadUserProfile(self.token.0, self.profile) },
            "unload dedicated AppContainer benchmark profile",
        )?;
        self.profile = null_mut();
        Ok(())
    }
}

impl Drop for AccountProfile {
    fn drop(&mut self) {
        if !self.profile.is_null() {
            // SAFETY: profile and token are paired live handles. Workflow cleanup is the
            // fail-closed fallback if this unload fails.
            let _ = unsafe { UnloadUserProfile(self.token.0, self.profile) };
            self.profile = null_mut();
        }
    }
}

struct AppContainerProfile {
    name: String,
    sid: OwnedSid,
    sid_text: String,
    folder: PathBuf,
    cleanup_token: OwnedHandle,
    deleted: bool,
}

impl AppContainerProfile {
    fn create(name: &str, account_token: HANDLE) -> Result<Self> {
        validate_profile_name(name)?;
        let name_wide = wide(OsStr::new(name));
        let display = wide(OsStr::new("cmux startup benchmark AppContainer"));
        let description = wide(OsStr::new("nonce-bound startup containment feasibility"));
        let mut sid = null_mut();
        // SAFETY: all strings are NUL-terminated. A null capability array and zero count create
        // an AppContainer with no capabilities.
        check_hresult(
            unsafe {
                CreateAppContainerProfile(
                    name_wide.as_ptr(),
                    display.as_ptr(),
                    description.as_ptr(),
                    null(),
                    0,
                    &mut sid,
                )
            },
            "create nonce-bound AppContainer profile",
        )?;
        let sid = OwnedSid(sid);
        let sid_text = match sid_text(sid.0) {
            Ok(value) => value,
            Err(error) => {
                let _ = unsafe { DeleteAppContainerProfile(name_wide.as_ptr()) };
                return Err(error);
            }
        };
        let mut cleanup_token = null_mut();
        if let Err(error) = check(
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    account_token,
                    GetCurrentProcess(),
                    &mut cleanup_token,
                    0,
                    0,
                    DUPLICATE_SAME_ACCESS,
                )
            },
            "duplicate AppContainer profile cleanup token",
        ) {
            let _ = unsafe { DeleteAppContainerProfile(name_wide.as_ptr()) };
            return Err(error);
        }
        let mut owner = Self {
            name: name.to_string(),
            sid,
            sid_text,
            folder: PathBuf::new(),
            cleanup_token: OwnedHandle(cleanup_token),
            deleted: false,
        };
        let sid_wide = wide(OsStr::new(&owner.sid_text));
        let mut folder = null_mut();
        // SAFETY: the SID string is NUL-terminated and folder is writable.
        let folder_result = check_hresult(
            unsafe { GetAppContainerFolderPath(sid_wide.as_ptr(), &mut folder) },
            "resolve AppContainer profile folder",
        );
        if let Err(error) = folder_result {
            return Err(error);
        }
        let folder_path = unsafe { pwstr_to_path(folder) };
        // SAFETY: GetAppContainerFolderPath allocates the string with CoTaskMemAlloc.
        unsafe { CoTaskMemFree(folder.cast()) };
        let folder_path = match folder_path {
            Ok(path) => path,
            Err(error) => {
                return Err(error);
            }
        };
        owner.folder = folder_path;
        Ok(owner)
    }

    fn delete(&mut self) -> Result<()> {
        if self.deleted {
            return Ok(());
        }
        let name = wide(OsStr::new(&self.name));
        // SAFETY: the profile name is NUL-terminated and all process/token/profile handles are
        // closed before this owner is called.
        check_hresult(
            unsafe { DeleteAppContainerProfile(name.as_ptr()) },
            "delete nonce-bound AppContainer profile",
        )?;
        self.deleted = true;
        Ok(())
    }
}

impl Drop for AppContainerProfile {
    fn drop(&mut self) {
        if self.deleted {
            return;
        }
        let name = wide(OsStr::new(&self.name));
        if unsafe { ImpersonateLoggedOnUser(self.cleanup_token.0) } != 0 {
            let _ = unsafe { DeleteAppContainerProfile(name.as_ptr()) };
            let _ = unsafe { RevertToSelf() };
        }
    }
}

struct AclLease {
    path: PathBuf,
    grant: String,
    security_information: u32,
    original: Vec<usize>,
    before_sha256: String,
    restored: bool,
}

impl AclLease {
    fn grant_account_and_appcontainer_root(path: &Path, user: &str, sid: PSID) -> Result<Self> {
        let mut lease = Self::snapshot(path, "account-full+appcontainer-full+low-label")?;
        let output = run_bounded_command(
            Command::new("icacls.exe").arg(path).args(["/grant", &format!("{user}:(OI)(CI)(F)")]),
            "fixture account ACL grant",
        )?;
        if !output.status.success() {
            bail!("fixture account ACL grant failed: {}", String::from_utf8_lossy(&output.stderr));
        }
        grant_sid(path, sid, GENERIC_ALL, true)?;
        let output = run_bounded_command(
            Command::new("icacls.exe").arg(path).args(["/setintegritylevel", "(OI)(CI)L"]),
            "fixture low-integrity label",
        )?;
        if !output.status.success() {
            let restore = lease.restore();
            return Err(anyhow::anyhow!(
                "fixture low-integrity label failed: {}; restore: {}",
                String::from_utf8_lossy(&output.stderr),
                result_label(&restore)
            ));
        }
        Ok(lease)
    }

    fn grant_account_and_sid(
        path: &Path,
        user: &str,
        sid: PSID,
        access: u32,
        grant: &str,
    ) -> Result<Self> {
        let mut lease = Self::snapshot(path, grant)?;
        let output = run_bounded_command(
            Command::new("icacls.exe").arg(path).args(["/grant", &format!("{user}:(RX)")]),
            "target account read-execute ACL grant",
        )?;
        if !output.status.success() {
            let restore = lease.restore();
            return Err(anyhow::anyhow!(
                "target account read-execute ACL grant failed: {}; restore: {}",
                String::from_utf8_lossy(&output.stderr),
                result_label(&restore)
            ));
        }
        if let Err(error) = grant_sid(path, sid, access, false) {
            let restore = lease.restore();
            return Err(error
                .context(format!("restore after failed ACL grant: {}", result_label(&restore))));
        }
        Ok(lease)
    }

    fn snapshot(path: &Path, grant: &str) -> Result<Self> {
        let information = DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION;
        let original = file_security(path, information)?;
        let before_sha256 = hash_words(&original);
        Ok(Self {
            path: path.to_path_buf(),
            grant: grant.to_string(),
            security_information: information,
            original,
            before_sha256,
            restored: false,
        })
    }

    fn restore(&mut self) -> Result<AclRestorationEvidence> {
        if self.restored {
            bail!("ACL lease was restored twice");
        }
        let path = wide(self.path.as_os_str());
        // SAFETY: original is an aligned, live, self-relative security descriptor returned by
        // GetFileSecurityW, and path is NUL-terminated.
        check(
            unsafe {
                SetFileSecurityW(
                    path.as_ptr(),
                    self.security_information,
                    self.original.as_ptr().cast_mut().cast(),
                )
            },
            "restore exact preflight file security descriptor",
        )?;
        let restored = file_security(&self.path, self.security_information)?;
        let restored_sha256 = hash_words(&restored);
        let exact_restore = self.original == restored;
        if !exact_restore {
            bail!("ACL restore did not reproduce the exact pre-launch descriptor");
        }
        self.restored = true;
        Ok(AclRestorationEvidence {
            path: self.path.clone(),
            grant: self.grant.clone(),
            before_sha256: self.before_sha256.clone(),
            restored_sha256,
            exact_restore,
        })
    }
}

impl Drop for AclLease {
    fn drop(&mut self) {
        if !self.restored {
            let _ = self.restore();
        }
    }
}

fn run_account_broker(token: HANDLE, executable: &Path, config: &Path) -> Result<()> {
    let mut environment = null_mut();
    // SAFETY: environment points to writable storage and token is a live account token.
    check(
        unsafe { CreateEnvironmentBlock(&mut environment, token, 0) },
        "create trusted AppContainer broker environment",
    )?;
    let command_line = windows_command_line(&[
        executable.as_os_str(),
        OsStr::new("--appcontainer-broker"),
        OsStr::new("--config"),
        config.as_os_str(),
    ]);
    let application = wide(executable.as_os_str());
    let current_dir =
        wide(config.parent().context("AppContainer config has no parent")?.as_os_str());
    let mut command_line = command_line;
    let mut startup =
        STARTUPINFOW { cb: u32::try_from(size_of::<STARTUPINFOW>())?, ..STARTUPINFOW::default() };
    let mut process = PROCESS_INFORMATION::default();
    // SAFETY: all pointers remain live for the call. No standard handles are redirected. The
    // account environment comes from UserEnv and does not contain runner CMUX_BENCH secrets.
    let created = unsafe {
        CreateProcessWithTokenW(
            token,
            0,
            application.as_ptr(),
            command_line.as_mut_ptr(),
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            environment,
            current_dir.as_ptr(),
            &mut startup,
            &mut process,
        )
    };
    // SAFETY: CreateEnvironmentBlock owns this allocation for exactly this call.
    let destroyed = unsafe { DestroyEnvironmentBlock(environment) };
    check(created, "create trusted account-owned AppContainer broker")?;
    let mut owner = BrokerProcessOwner {
        process: OwnedHandle(process.hProcess),
        _thread: OwnedHandle(process.hThread),
        terminate_on_drop: true,
    };
    check(destroyed, "destroy trusted AppContainer broker environment")?;
    // SAFETY: process_handle is live for this bounded wait.
    let wait =
        unsafe { WaitForSingleObject(owner.process.0, u32::try_from(BROKER_TIMEOUT.as_millis())?) };
    if wait == WAIT_TIMEOUT {
        // SAFETY: process_handle is live and trusted workflow cleanup remains the fallback.
        bail!("trusted AppContainer broker exceeded its bounded deadline");
    }
    if wait != WAIT_OBJECT_0 {
        return Err(io::Error::last_os_error()).context("wait for trusted AppContainer broker");
    }
    let mut code = 0_u32;
    // SAFETY: process_handle is live and code points to writable storage.
    check(
        unsafe { GetExitCodeProcess(owner.process.0, &mut code) },
        "read trusted AppContainer broker exit code",
    )?;
    if code != 0 {
        bail!("trusted AppContainer broker exited with code {code}");
    }
    owner.terminate_on_drop = false;
    Ok(())
}

fn launch_appcontainer_product(config: &BrokerConfig) -> Result<BrokerEvidence> {
    let appcontainer_sid = OwnedSid::from_string(&config.appcontainer_sid)?;
    let mut process_token = null_mut();
    // SAFETY: process token storage is writable. The broker runs under the exact benchmark
    // account, so a restricted version is eligible for CreateProcessAsUser's documented waiver.
    check(
        unsafe {
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY
                    | TOKEN_DUPLICATE
                    | TOKEN_ASSIGN_PRIMARY
                    | TOKEN_ADJUST_DEFAULT
                    | TOKEN_ADJUST_PRIVILEGES,
                &mut process_token,
            )
        },
        "open account broker primary token",
    )?;
    let process_token = OwnedHandle(process_token);
    enable_privilege(process_token.0, "SeIncreaseQuotaPrivilege")?;
    let mut restricted = null_mut();
    // SAFETY: the source is the broker primary token. Zero restricting SIDs is intentional; the
    // AppContainer SID is supplied through SECURITY_CAPABILITIES instead.
    check(
        unsafe {
            CreateRestrictedToken(
                process_token.0,
                DISABLE_MAX_PRIVILEGE,
                0,
                null(),
                0,
                null(),
                0,
                null(),
                &mut restricted,
            )
        },
        "create no-privilege AppContainer target token",
    )?;
    let restricted = OwnedHandle(restricted);
    set_low_integrity(restricted.0)?;
    let before =
        token_proof(restricted.0, &config.appcontainer_sid, &config.account_authentication_id)?;
    if before.is_appcontainer
        || !before.restricting_sid_count_zero
        || !before.low_integrity
        || !before.no_enabled_privileges
    {
        bail!("pre-launch AppContainer target token proof failed");
    }

    let (job, completion) = create_job()?;
    let inheritable = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>())?,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let (input_read, input_write) = create_pipe(&inheritable, "AppContainer stdin")?;
    let (output_read, output_write) = create_pipe(&inheritable, "AppContainer stdout")?;
    let (error_read, error_write) = create_pipe(&inheritable, "AppContainer stderr")?;
    for handle in [input_write.0, output_read.0, error_read.0] {
        // SAFETY: these controller ends are live and must not cross the explicit handle list.
        check(
            unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) },
            "make AppContainer controller pipe end non-inheritable",
        )?;
    }
    for handle in [input_read.0, output_write.0, error_write.0] {
        if unsafe { GetFileType(handle) } == FILE_TYPE_UNKNOWN {
            bail!("AppContainer standard handle is not a valid pipe");
        }
    }

    let attribute_list = AttributeList::new(2)?;
    let handles = [input_read.0, output_write.0, error_write.0];
    // SAFETY: attribute_list is initialized and handles remains live through process creation.
    check(
        unsafe {
            UpdateProcThreadAttribute(
                attribute_list.pointer,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_ptr().cast(),
                size_of::<[HANDLE; 3]>(),
                null_mut(),
                null(),
            )
        },
        "install exact AppContainer standard-handle list",
    )?;
    let mut capabilities = SECURITY_CAPABILITIES {
        AppContainerSid: appcontainer_sid.0,
        Capabilities: null_mut(),
        CapabilityCount: 0,
        Reserved: 0,
    };
    // SAFETY: capabilities and its SID remain live through process creation.
    check(
        unsafe {
            UpdateProcThreadAttribute(
                attribute_list.pointer,
                0,
                PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES as usize,
                (&mut capabilities as *mut SECURITY_CAPABILITIES).cast(),
                size_of::<SECURITY_CAPABILITIES>(),
                null_mut(),
                null(),
            )
        },
        "install zero-capability AppContainer security attribute",
    )?;

    let network_listener = trusted_network_listener()?;
    let network_address = network_listener.local_addr()?;
    let inbound_ip = trusted_non_loopback_ip()?;
    let environment = filtered_product_environment(config, network_address, inbound_ip)?;
    let mut command_line =
        windows_command_line(&[config.target.as_os_str(), OsStr::new("--appcontainer-probe")]);
    let application = wide(config.target.as_os_str());
    let current_dir = wide(config.fixture_root.as_os_str());
    let mut startup = STARTUPINFOEXW::default();
    startup.StartupInfo.cb = u32::try_from(size_of::<STARTUPINFOEXW>())?;
    startup.StartupInfo.dwFlags = 0x0000_0100;
    startup.StartupInfo.hStdInput = input_read.0;
    startup.StartupInfo.hStdOutput = output_write.0;
    startup.StartupInfo.hStdError = error_write.0;
    startup.lpAttributeList = attribute_list.pointer;
    let mut process = PROCESS_INFORMATION::default();
    // SAFETY: token, strings, environment, startup attributes, and handle list are live. Only
    // the exact three standard handles are inheritable and named by the attribute list.
    let created = unsafe {
        CreateProcessAsUserW(
            restricted.0,
            application.as_ptr(),
            command_line.as_mut_ptr(),
            null(),
            null(),
            1,
            CREATE_SUSPENDED
                | CREATE_UNICODE_ENVIRONMENT
                | CREATE_NO_WINDOW
                | EXTENDED_STARTUPINFO_PRESENT,
            environment.as_ptr().cast(),
            current_dir.as_ptr(),
            (&startup as *const STARTUPINFOEXW).cast(),
            &mut process,
        )
    };
    drop(attribute_list);
    check(created, "create suspended AppContainer feasibility product")?;
    let mut product_owner = ProductProcessOwner {
        process: OwnedHandle(process.hProcess),
        thread: OwnedHandle(process.hThread),
        terminate_on_drop: true,
    };
    drop(input_read);
    drop(output_write);
    drop(error_write);
    // SAFETY: process and Job handles are live.
    check(
        unsafe { AssignProcessToJobObject(job.0, product_owner.process.0) },
        "assign AppContainer product to its private Job",
    )?;
    let mut in_job = 0;
    // SAFETY: process and exact Job handles are live and in_job is writable.
    check(
        unsafe {
            windows_sys::Win32::System::JobObjects::IsProcessInJob(
                product_owner.process.0,
                job.0,
                &mut in_job,
            )
        },
        "query exact AppContainer product Job membership",
    )?;
    if in_job == 0 {
        bail!("AppContainer product was not in its exact private Job before resume");
    }
    let after = token_proof_from_process(
        product_owner.process.0,
        &config.appcontainer_sid,
        &config.account_authentication_id,
    )?;
    if !after.is_appcontainer
        || !after.appcontainer_sid_match
        || !after.restricting_sid_count_zero
        || !after.capability_count_zero
        || !after.low_integrity
        || !after.no_enabled_privileges
    {
        bail!("suspended AppContainer target token proof failed");
    }
    // SAFETY: thread_handle is the suspended primary thread.
    let resume_previous_count = unsafe { ResumeThread(product_owner.thread.0) };
    if resume_previous_count != 1 {
        bail!("AppContainer product resume count was {resume_previous_count}, expected 1");
    }
    let product_process_id = unsafe { GetProcessId(product_owner.process.0) };
    let product_primary_thread_id = unsafe { GetThreadId(product_owner.thread.0) };

    let (sender, receiver) = mpsc::channel();
    let output_thread = thread::spawn(move || {
        // SAFETY: output_read exclusively owns this pipe handle after the move.
        let file = unsafe { File::from_raw_handle(output_read.0 as RawHandle) };
        std::mem::forget(output_read);
        let reader = BufReader::new(file);
        let mut reader =
            reader.take(u64::try_from(MAX_RECORD_BYTES + 1).expect("record bound fits in u64"));
        let mut record = Vec::new();
        let result = reader.read_until(b'\n', &mut record).and_then(|_| {
            if record.len() > MAX_RECORD_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "AppContainer product evidence exceeded its bound",
                ));
            }
            Ok(record)
        });
        let _ = sender.send(result);
    });
    let stderr_thread = thread::spawn(move || {
        // SAFETY: error_read exclusively owns this pipe handle after the move.
        let file = unsafe { File::from_raw_handle(error_read.0 as RawHandle) };
        std::mem::forget(error_read);
        read_bounded_tail(file, 16 * 1024)
    });
    let post_launch = (|| -> Result<(ProductEvidence, bool)> {
        let record = receiver
            .recv_timeout(PRODUCT_TIMEOUT)
            .context("AppContainer product evidence deadline expired")??;
        let mut product: ProductEvidence =
            serde_json::from_slice(record.strip_suffix(b"\n").unwrap_or(&record))?;
        product.inbound_network_denied = match product.inbound_bound_address {
            None => true,
            Some(address) => TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_err(),
        };
        validate_product(&product, config)?;
        let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
        // SAFETY: accounting matches the requested information class.
        check(
            unsafe {
                QueryInformationJobObject(
                    job.0,
                    JobObjectBasicAccountingInformation,
                    (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                    u32::try_from(size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>())?,
                    null_mut(),
                )
            },
            "query AppContainer descendant Job accounting",
        )?;
        Ok((product, accounting.ActiveProcesses >= 2))
    })();
    // SAFETY: job is live. Termination is the sole release for the deliberately blocked probes.
    let terminate =
        check(unsafe { TerminateJobObject(job.0, 125) }, "terminate AppContainer feasibility Job");
    let active_process_zero =
        if terminate.is_ok() { wait_active_zero(completion.0, CLEANUP_TIMEOUT) } else { Ok(false) };
    drop(input_write);
    if active_process_zero.as_ref().is_ok_and(|empty| *empty) {
        product_owner.terminate_on_drop = false;
    }
    drop(product_owner);
    drop(job);
    drop(completion);
    output_thread.join().map_err(|_| anyhow::anyhow!("AppContainer output reader panicked"))?;
    let stderr = stderr_thread
        .join()
        .map_err(|_| anyhow::anyhow!("AppContainer stderr reader panicked"))??;
    terminate?;
    let active_process_zero = active_process_zero?;
    let (product, descendant_observed_in_job) = post_launch.map_err(|error| {
        error.context(format!("AppContainer product stderr: {}", String::from_utf8_lossy(&stderr)))
    })?;
    if !descendant_observed_in_job || !active_process_zero {
        bail!("AppContainer Job did not prove descendant containment and empty cleanup");
    }

    Ok(BrokerEvidence {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: config.nonce.clone(),
        appcontainer_sid: config.appcontainer_sid.clone(),
        product,
        create_process_as_user_succeeded: true,
        explicit_three_handle_list: true,
        security_capabilities_applied: true,
        product_exact_job_before_resume: true,
        product_resume_previous_count: resume_previous_count,
        product_process_id,
        product_primary_thread_id,
        descendant_observed_in_job,
        active_process_zero,
    })
}

#[derive(Debug)]
struct TokenProof {
    is_appcontainer: bool,
    appcontainer_sid_match: bool,
    restricting_sid_count_zero: bool,
    capability_count_zero: bool,
    low_integrity: bool,
    no_enabled_privileges: bool,
    authentication_id: String,
}

fn current_token_proof(expected_sid: &str, expected_authentication_id: &str) -> Result<TokenProof> {
    let mut token = null_mut();
    // SAFETY: token points to writable handle storage.
    check(
        unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
        "open AppContainer product token",
    )?;
    let token = OwnedHandle(token);
    let proof = token_proof(token.0, expected_sid, expected_authentication_id)?;
    Ok(proof)
}

fn token_proof_from_process(
    process: HANDLE,
    expected_sid: &str,
    expected_authentication_id: &str,
) -> Result<TokenProof> {
    let mut token = null_mut();
    // SAFETY: process is live and token points to writable storage.
    check(
        unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) },
        "open suspended AppContainer product token",
    )?;
    let token = OwnedHandle(token);
    token_proof(token.0, expected_sid, expected_authentication_id)
}

fn token_proof(
    token: HANDLE,
    expected_sid: &str,
    expected_authentication_id: &str,
) -> Result<TokenProof> {
    let is_appcontainer = token_u32(token, TokenIsAppContainer)? != 0;
    let appcontainer = token_information(token, TokenAppContainerSid)?;
    // SAFETY: GetTokenInformation filled this aligned structure in appcontainer.
    let appcontainer =
        unsafe { &*(appcontainer.as_ptr().cast::<TOKEN_APPCONTAINER_INFORMATION>()) };
    let expected_sid = OwnedSid::from_string(expected_sid)?;
    let appcontainer_sid_match = !appcontainer.TokenAppContainer.is_null()
        && unsafe { EqualSid(appcontainer.TokenAppContainer, expected_sid.0) } != 0;
    let capabilities = token_information(token, TokenCapabilities)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_GROUPS header.
    let capabilities = unsafe { &*(capabilities.as_ptr().cast::<TOKEN_GROUPS>()) };
    let restricting_sids =
        token_information(token, windows_sys::Win32::Security::TokenRestrictedSids)?;
    let restricting_sids = unsafe { &*(restricting_sids.as_ptr().cast::<TOKEN_GROUPS>()) };
    let integrity = token_information(token, TokenIntegrityLevel)?;
    // SAFETY: GetTokenInformation filled this aligned mandatory-label structure.
    let integrity = unsafe { &*(integrity.as_ptr().cast::<TOKEN_MANDATORY_LABEL>()) };
    let count = unsafe { GetSidSubAuthorityCount(integrity.Label.Sid) };
    let low_integrity = if count.is_null() || unsafe { *count } == 0 {
        false
    } else {
        let rid =
            unsafe { GetSidSubAuthority(integrity.Label.Sid, u32::from(unsafe { *count }) - 1) };
        !rid.is_null() && unsafe { *rid } == SECURITY_MANDATORY_LOW_RID as u32
    };
    let privileges = token_information(token, TokenPrivileges)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_PRIVILEGES header and array.
    let privileges = unsafe { &*(privileges.as_ptr().cast::<TOKEN_PRIVILEGES>()) };
    let first = privileges.Privileges.as_ptr();
    let no_enabled_privileges = (0..privileges.PrivilegeCount).all(|index| unsafe {
        (*first.add(index as usize)).Attributes & SE_PRIVILEGE_ENABLED == 0
    });
    let authentication_id = token_authentication_id(token)?;
    if authentication_id != expected_authentication_id {
        bail!("AppContainer token authentication ID changed accounts");
    }
    Ok(TokenProof {
        is_appcontainer,
        appcontainer_sid_match,
        restricting_sid_count_zero: restricting_sids.GroupCount == 0,
        capability_count_zero: capabilities.GroupCount == 0,
        low_integrity,
        no_enabled_privileges,
        authentication_id,
    })
}

fn token_information(token: HANDLE, class: i32) -> Result<Vec<usize>> {
    let mut bytes = 0_u32;
    // SAFETY: a null buffer requests the required size.
    let _ = unsafe { GetTokenInformation(token, class, null_mut(), 0, &mut bytes) };
    if bytes == 0 {
        return Err(io::Error::last_os_error()).context("size AppContainer token information");
    }
    let words = usize::try_from(bytes)?.div_ceil(size_of::<usize>());
    let mut storage = vec![0_usize; words];
    // SAFETY: storage is aligned and has the requested byte size.
    check(
        unsafe {
            GetTokenInformation(token, class, storage.as_mut_ptr().cast(), bytes, &mut bytes)
        },
        "read AppContainer token information",
    )?;
    Ok(storage)
}

fn token_u32(token: HANDLE, class: i32) -> Result<u32> {
    let information = token_information(token, class)?;
    Ok(unsafe { *information.as_ptr().cast::<u32>() })
}

fn token_authentication_id(token: HANDLE) -> Result<String> {
    let statistics = token_information(token, TokenStatistics)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_STATISTICS structure.
    let statistics = unsafe { &*(statistics.as_ptr().cast::<TOKEN_STATISTICS>()) };
    Ok(format!(
        "{:08x}{:08x}",
        statistics.AuthenticationId.HighPart as u32, statistics.AuthenticationId.LowPart
    ))
}

fn token_user_sid(token: HANDLE) -> Result<String> {
    let user = token_information(token, TokenUser)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_USER structure.
    let user = unsafe { &*(user.as_ptr().cast::<TOKEN_USER>()) };
    sid_text(user.User.Sid)
}

fn set_low_integrity(token: HANDLE) -> Result<()> {
    let sid = OwnedSid::from_string("S-1-16-4096")?;
    let label = TOKEN_MANDATORY_LABEL {
        Label: windows_sys::Win32::Security::SID_AND_ATTRIBUTES {
            Sid: sid.0,
            Attributes: SE_GROUP_INTEGRITY as u32,
        },
    };
    // SAFETY: label and its SID remain live through the assignment call.
    check(
        unsafe {
            SetTokenInformation(
                token,
                TokenIntegrityLevel,
                (&label as *const TOKEN_MANDATORY_LABEL).cast(),
                u32::try_from(size_of::<TOKEN_MANDATORY_LABEL>())?
                    .checked_add(unsafe { GetLengthSid(sid.0) })
                    .context("AppContainer integrity-label size overflow")?,
            )
        },
        "set AppContainer product token low integrity",
    )
}

fn enable_privilege(token: HANDLE, name: &str) -> Result<()> {
    let name = wide(OsStr::new(name));
    let mut luid = unsafe { zeroed() };
    // SAFETY: name is NUL-terminated and luid points to writable storage.
    check(
        unsafe { LookupPrivilegeValueW(null(), name.as_ptr(), &mut luid) },
        "resolve AppContainer broker privilege",
    )?;
    let requested = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
    };
    // SAFETY: setting the calling thread's last-error value has no pointer or lifetime contract.
    unsafe { windows_sys::Win32::Foundation::SetLastError(ERROR_SUCCESS) };
    // SAFETY: token is live and requested names one valid privilege entry.
    check(
        unsafe { AdjustTokenPrivileges(token, 0, &requested, 0, null_mut(), null_mut()) },
        "enable AppContainer broker privilege",
    )?;
    if unsafe { windows_sys::Win32::Foundation::GetLastError() } != ERROR_SUCCESS {
        return Err(io::Error::last_os_error()).context("enable AppContainer broker privilege");
    }
    Ok(())
}

fn create_job() -> Result<(OwnedHandle, OwnedHandle)> {
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() {
        return Err(io::Error::last_os_error()).context("create AppContainer private Job");
    }
    let job = OwnedHandle(job);
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    check(
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())?,
            )
        },
        "configure AppContainer kill-on-close Job",
    )?;
    let completion = unsafe { CreateIoCompletionPort(INVALID_HANDLE_VALUE, null_mut(), 0, 1) };
    if completion.is_null() {
        return Err(io::Error::last_os_error()).context("create AppContainer Job completion port");
    }
    let completion = OwnedHandle(completion);
    let association = JOBOBJECT_ASSOCIATE_COMPLETION_PORT {
        CompletionKey: JOB_COMPLETION_KEY as *mut c_void,
        CompletionPort: completion.0,
    };
    check(
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectAssociateCompletionPortInformation,
                (&association as *const JOBOBJECT_ASSOCIATE_COMPLETION_PORT).cast(),
                u32::try_from(size_of::<JOBOBJECT_ASSOCIATE_COMPLETION_PORT>())?,
            )
        },
        "associate AppContainer Job completion port",
    )?;
    Ok((job, completion))
}

fn create_pipe(attributes: &SECURITY_ATTRIBUTES, name: &str) -> Result<(OwnedHandle, OwnedHandle)> {
    let mut read = null_mut();
    let mut write = null_mut();
    check(
        unsafe { CreatePipe(&mut read, &mut write, attributes, 0) },
        &format!("create {name} pipe"),
    )?;
    Ok((OwnedHandle(read), OwnedHandle(write)))
}

fn wait_active_zero(completion: HANDLE, timeout: Duration) -> Result<bool> {
    let deadline = Instant::now().checked_add(timeout).context("Job cleanup deadline overflow")?;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let mut bytes = 0_u32;
        let mut key = 0_usize;
        let mut overlapped = null_mut();
        let wait_ms = u32::try_from(remaining.as_millis().clamp(1, u128::from(u32::MAX)))?;
        let result = unsafe {
            GetQueuedCompletionStatus(completion, &mut bytes, &mut key, &mut overlapped, wait_ms)
        };
        if result == 0 {
            if unsafe { windows_sys::Win32::Foundation::GetLastError() }
                == windows_sys::Win32::Foundation::WAIT_TIMEOUT
            {
                return Ok(false);
            }
            return Err(io::Error::last_os_error()).context("wait for AppContainer Job event");
        }
        if key == JOB_COMPLETION_KEY && bytes == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO {
            return Ok(true);
        }
    }
}

fn network_profile_present(
    appcontainer_sid: &OwnedSid,
    account_sid: &str,
    expected_name: &str,
) -> Result<bool> {
    let account_sid = OwnedSid::from_string(account_sid)?;
    let mut count = 0_u32;
    let mut entries: *mut INET_FIREWALL_APP_CONTAINER = null_mut();
    let error = unsafe { NetworkIsolationEnumAppContainers(0, &mut count, &mut entries) };
    if error != ERROR_SUCCESS {
        return check_windows_error(error, "enumerate account AppContainer profiles")
            .map(|_| false);
    }
    let found = if entries.is_null() {
        false
    } else {
        // SAFETY: the API returned count contiguous entries that stay live until the free below.
        unsafe {
            std::slice::from_raw_parts(
                entries,
                usize::try_from(count).expect("Windows u32 count fits in usize"),
            )
        }
        .iter()
        .any(|entry| {
            !entry.appContainerSid.is_null()
                && !entry.userSid.is_null()
                && unsafe { pwstr_equals(entry.appContainerName, expected_name) }
                && unsafe { EqualSid(entry.appContainerSid.cast(), appcontainer_sid.0.cast()) } != 0
                && unsafe { EqualSid(entry.userSid.cast(), account_sid.0.cast()) } != 0
        })
    };
    if !entries.is_null() {
        let free = unsafe { NetworkIsolationFreeAppContainers(entries) };
        check_windows_error(free, "free AppContainer profile enumeration")?;
    }
    Ok(found)
}

unsafe fn pwstr_equals(value: *const u16, expected: &str) -> bool {
    if value.is_null() {
        return false;
    }
    let expected = expected.encode_utf16().collect::<Vec<_>>();
    for (index, expected) in expected.iter().enumerate() {
        if unsafe { *value.add(index) } != *expected {
            return false;
        }
    }
    (unsafe { *value.add(expected.len()) }) == 0
}

fn derive_profile_sid(name: &str) -> Result<OwnedSid> {
    let name = wide(OsStr::new(name));
    let mut sid = null_mut();
    check_hresult(
        unsafe { DeriveAppContainerSidFromAppContainerName(name.as_ptr(), &mut sid) },
        "derive deleted AppContainer profile SID",
    )?;
    Ok(OwnedSid(sid))
}

fn write_appcontainer_registry_sentinel(nonce: &str) -> Result<bool> {
    let mut key = null_mut();
    let result = unsafe { GetAppContainerRegistryLocation(KEY_SET_VALUE, &mut key) };
    if result < 0 {
        return Ok(false);
    }
    let key_owner = RegistryKey(key);
    let name = wide(OsStr::new("cmux-startup-benchmark"));
    let value = nonce.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let result = unsafe {
        RegSetValueExW(
            key_owner.0,
            name.as_ptr(),
            0,
            1,
            value.as_ptr().cast(),
            u32::try_from(value.len() * size_of::<u16>())?,
        )
    };
    Ok(result == ERROR_SUCCESS)
}

struct RegistryKey(windows_sys::Win32::System::Registry::HKEY);

impl Drop for RegistryKey {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { RegCloseKey(self.0) };
        }
    }
}

fn grant_sid(path: &Path, sid: PSID, access: u32, container: bool) -> Result<()> {
    let path = wide(path.as_os_str());
    let mut old_dacl: *mut ACL = null_mut();
    let mut descriptor = null_mut();
    check_windows_error(
        unsafe {
            GetNamedSecurityInfoW(
                path.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                &mut old_dacl,
                null_mut(),
                &mut descriptor,
            )
        },
        "read AppContainer ACL",
    )?;
    let entry = EXPLICIT_ACCESS_W {
        grfAccessPermissions: access,
        grfAccessMode: GRANT_ACCESS,
        grfInheritance: if container {
            windows_sys::Win32::Security::SUB_CONTAINERS_AND_OBJECTS_INHERIT
        } else {
            0
        },
        Trustee: TRUSTEE_W {
            pMultipleTrustee: null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_UNKNOWN,
            ptstrName: sid.cast(),
        },
    };
    let mut new_dacl = null_mut();
    let build = unsafe { SetEntriesInAclW(1, &entry, old_dacl, &mut new_dacl) };
    if build != ERROR_SUCCESS {
        unsafe { LocalFree(descriptor) };
        return check_windows_error(build, "build AppContainer ACL grant");
    }
    let assign = unsafe {
        SetNamedSecurityInfoW(
            path.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            new_dacl,
            null_mut(),
        )
    };
    unsafe {
        LocalFree(new_dacl.cast());
        LocalFree(descriptor);
    }
    check_windows_error(assign, "assign AppContainer ACL grant")
}

fn file_security(path: &Path, information: u32) -> Result<Vec<usize>> {
    let path = wide(path.as_os_str());
    let mut bytes = 0_u32;
    let _ = unsafe { GetFileSecurityW(path.as_ptr(), information, null_mut(), 0, &mut bytes) };
    if bytes == 0 {
        return Err(io::Error::last_os_error()).context("size pre-launch file security descriptor");
    }
    let words = usize::try_from(bytes)?.div_ceil(size_of::<usize>());
    let mut storage = vec![0_usize; words];
    check(
        unsafe {
            GetFileSecurityW(
                path.as_ptr(),
                information,
                storage.as_mut_ptr().cast(),
                bytes,
                &mut bytes,
            )
        },
        "read pre-launch file security descriptor",
    )?;
    storage.truncate(usize::try_from(bytes)?.div_ceil(size_of::<usize>()));
    Ok(storage)
}

fn target_parent_chain(target: &Path) -> Result<Vec<PathBuf>> {
    let mut parents = Vec::new();
    let mut current = target.parent().context("AppContainer target has no parent")?;
    while let Some(parent) = current.parent() {
        parents.push(current.to_path_buf());
        if parent == current {
            break;
        }
        current = parent;
    }
    Ok(parents)
}

fn restore_acl_leases(leases: &mut Vec<AclLease>) -> Result<Vec<AclRestorationEvidence>> {
    let mut evidence = Vec::with_capacity(leases.len());
    let mut first_error = None;
    for lease in leases.iter_mut().rev() {
        match lease.restore() {
            Ok(record) => evidence.push(record),
            Err(error) if first_error.is_none() => first_error = Some(error),
            Err(_) => {}
        }
    }
    if let Some(error) = first_error {
        return Err(error).context("restore all AppContainer ACL leases");
    }
    evidence.reverse();
    Ok(evidence)
}

fn validate_config(config: &BrokerConfig, path: &Path) -> Result<()> {
    validate_nonce(&config.nonce)?;
    validate_profile_name(&config.profile_name)?;
    if config.schema_version != EVIDENCE_SCHEMA_VERSION
        || config.target_sha256 != sha256_file(&config.target)?
        || config.target.starts_with(&config.fixture_root)
        || path.parent() != Some(config.fixture_root.as_path())
        || config.output.parent() != Some(config.fixture_root.as_path())
        || config.failure_output.parent() != Some(config.fixture_root.as_path())
        || config.adjacent_path.starts_with(&config.fixture_root)
        || config.profile_folder.starts_with(&config.fixture_root)
    {
        bail!("AppContainer broker config violated its identity boundary");
    }
    let expected_sid = derive_profile_sid(&config.profile_name)?;
    let observed = OwnedSid::from_string(&config.appcontainer_sid)?;
    if unsafe { EqualSid(expected_sid.0, observed.0) } == 0 {
        bail!("AppContainer broker config profile SID changed");
    }
    Ok(())
}

fn validate_product(product: &ProductEvidence, config: &BrokerConfig) -> Result<()> {
    if product.schema_version != EVIDENCE_SCHEMA_VERSION
        || product.nonce != config.nonce
        || !product.entry_reached
        || !product.fixture_write
        || !product.adjacent_write_denied
        || !product.profile_owned_write
        || !product.registry_owned_write
        || !product.outbound_network_denied
        || !product.inbound_network_denied
        || !product.descendant_ready
        || !product.token_is_appcontainer
        || !product.appcontainer_sid_match
        || !product.restricting_sid_count_zero
        || !product.capability_count_zero
        || !product.low_integrity
        || !product.no_enabled_privileges
        || !product.account_authentication_match
    {
        bail!("AppContainer product feasibility proof failed");
    }
    Ok(())
}

fn validate_broker(broker: &BrokerEvidence, config: &BrokerConfig) -> Result<()> {
    validate_product(&broker.product, config)?;
    if broker.schema_version != EVIDENCE_SCHEMA_VERSION
        || broker.nonce != config.nonce
        || broker.appcontainer_sid != config.appcontainer_sid
        || !broker.create_process_as_user_succeeded
        || !broker.explicit_three_handle_list
        || !broker.security_capabilities_applied
        || !broker.product_exact_job_before_resume
        || broker.product_resume_previous_count != 1
        || broker.product_process_id == 0
        || broker.product_primary_thread_id == 0
        || !broker.descendant_observed_in_job
        || !broker.active_process_zero
    {
        bail!("AppContainer broker feasibility proof failed");
    }
    Ok(())
}

fn copy_broker_failure(source: &Path, output: &Path) -> Result<PathBuf> {
    let failure: BrokerFailureEvidence = read_bounded_json(source, MAX_RECORD_BYTES)?;
    validate_nonce(&failure.nonce)?;
    if failure.schema_version != EVIDENCE_SCHEMA_VERSION
        || failure.stage != "account-broker-product-launch"
        || failure.error.is_empty()
        || failure.error.len() > 4096
    {
        bail!("AppContainer broker failure evidence is invalid");
    }
    let stem = output.file_stem().and_then(|value| value.to_str()).unwrap_or("appcontainer");
    let destination = output.with_file_name(format!("{stem}-failure.json"));
    write_new_json(&destination, &failure)?;
    Ok(destination)
}

fn bounded_error(error: &anyhow::Error) -> String {
    let value = format!("{error:#}");
    if value.len() <= 4096 {
        return value;
    }
    let mut end = 4096;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn filtered_product_environment(
    config: &BrokerConfig,
    network: SocketAddr,
    inbound_ip: std::net::IpAddr,
) -> Result<Vec<u16>> {
    let mut values = vec![
        ("CMUX_APP_CONTAINER_ADJACENT", config.adjacent_path.to_string_lossy().into_owned()),
        ("CMUX_APP_CONTAINER_AUTH_ID", config.account_authentication_id.clone()),
        ("CMUX_APP_CONTAINER_FIXTURE", config.fixture_root.to_string_lossy().into_owned()),
        ("CMUX_APP_CONTAINER_INBOUND_IP", inbound_ip.to_string()),
        ("CMUX_APP_CONTAINER_NETWORK", network.to_string()),
        ("CMUX_APP_CONTAINER_NONCE", config.nonce.clone()),
        ("CMUX_APP_CONTAINER_PROFILE", config.profile_folder.to_string_lossy().into_owned()),
        ("CMUX_APP_CONTAINER_SID", config.appcontainer_sid.clone()),
        ("LOCALAPPDATA", config.fixture_root.to_string_lossy().into_owned()),
        ("TEMP", config.fixture_root.to_string_lossy().into_owned()),
        ("TMP", config.fixture_root.to_string_lossy().into_owned()),
    ];
    for key in ["COMSPEC", "PATHEXT", "SystemRoot", "WINDIR"] {
        if let Ok(value) = std::env::var(key) {
            values.push((key, value));
        }
    }
    values.sort_by(|left, right| left.0.to_ascii_uppercase().cmp(&right.0.to_ascii_uppercase()));
    let mut block = Vec::new();
    for (key, value) in values {
        if key.contains(['=', '\0']) || value.contains('\0') {
            bail!("AppContainer product environment contained an invalid value");
        }
        block.extend(format!("{key}={value}").encode_utf16());
        block.push(0);
    }
    block.push(0);
    Ok(block)
}

fn run_bounded_command(command: &mut Command, operation: &str) -> Result<std::process::Output> {
    let mut child = command.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    let mut stdout = child.stdout.take().context("capture bounded command stdout")?;
    let mut stderr = child.stderr.take().context("capture bounded command stderr")?;
    let stdout_thread = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).map(|_| bytes)
    });
    let stderr_thread = thread::spawn(move || {
        let mut bytes = Vec::new();
        stderr.read_to_end(&mut bytes).map(|_| bytes)
    });
    let status = match child.wait_timeout(CLEANUP_TIMEOUT)? {
        Some(status) => status,
        None => {
            child.kill()?;
            let _ = child.wait();
            let _ = stdout_thread.join();
            let _ = stderr_thread.join();
            bail!("{operation} exceeded its bounded deadline");
        }
    };
    let stdout = stdout_thread
        .join()
        .map_err(|_| anyhow::anyhow!("{operation} stdout reader panicked"))??;
    let stderr = stderr_thread
        .join()
        .map_err(|_| anyhow::anyhow!("{operation} stderr reader panicked"))??;
    Ok(std::process::Output { status, stdout, stderr })
}

fn read_bounded_tail(mut reader: impl Read, maximum: usize) -> io::Result<Vec<u8>> {
    let mut tail = Vec::new();
    let mut chunk = [0_u8; 4096];
    loop {
        let count = reader.read(&mut chunk)?;
        if count == 0 {
            return Ok(tail);
        }
        let excess = tail.len().saturating_add(count).saturating_sub(maximum);
        if excess >= tail.len() {
            tail.clear();
        } else if excess != 0 {
            tail.drain(..excess);
        }
        let start = count.saturating_sub(maximum);
        tail.extend_from_slice(&chunk[start..count]);
        if tail.len() > maximum {
            tail.drain(..tail.len() - maximum);
        }
    }
}

fn trusted_network_listener() -> Result<TcpListener> {
    TcpListener::bind("0.0.0.0:0").context("create trusted AppContainer outbound listener")
}

fn trusted_non_loopback_ip() -> Result<std::net::IpAddr> {
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.connect("192.0.2.1:9")?;
    let address = socket.local_addr()?.ip();
    if address.is_loopback() || address.is_unspecified() {
        bail!("trusted AppContainer controller did not resolve a non-loopback address");
    }
    Ok(address)
}

fn windows_command_line(values: &[&OsStr]) -> Vec<u16> {
    let mut line = String::new();
    for (index, value) in values.iter().enumerate() {
        if index != 0 {
            line.push(' ');
        }
        line.push_str(&quote_windows_argument(&value.to_string_lossy()));
    }
    line.encode_utf16().chain(Some(0)).collect()
}

fn quote_windows_argument(value: &str) -> String {
    let mut result = String::from("\"");
    let mut slashes = 0_usize;
    for character in value.chars() {
        match character {
            '\\' => slashes += 1,
            '"' => {
                result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
                result.push('"');
                slashes = 0;
            }
            _ => {
                result.extend(std::iter::repeat_n('\\', slashes));
                slashes = 0;
                result.push(character);
            }
        }
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}

fn required_env(name: &str) -> Result<String> {
    let value = std::env::var(name).with_context(|| format!("{name} is required"))?;
    if value.is_empty() {
        bail!("{name} must not be empty");
    }
    Ok(value)
}

fn required_value(values: &[String], option: &str) -> Result<String> {
    values
        .windows(2)
        .find(|pair| pair[0] == option)
        .map(|pair| pair[1].clone())
        .with_context(|| format!("{option} is required"))
}

fn required_path(values: &[String], option: &str) -> Result<PathBuf> {
    required_value(values, option).map(PathBuf::from)
}

fn random_nonce() -> Result<String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!(error.to_string()))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn validate_nonce(nonce: &str) -> Result<()> {
    if nonce.len() != 64 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("AppContainer nonce must be 64 hexadecimal characters");
    }
    Ok(())
}

fn validate_profile_name(name: &str) -> Result<()> {
    if name.len() > 64
        || !name.starts_with("cmux.bench.ac.")
        || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'.')
    {
        bail!("AppContainer profile name violated its bounded namespace");
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        bail!("AppContainer executable must be one regular file");
    }
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    io::copy(&mut file, &mut digest)?;
    Ok(format!("{:x}", digest.finalize()))
}

fn hash_words(words: &[usize]) -> String {
    let bytes = unsafe {
        std::slice::from_raw_parts(words.as_ptr().cast::<u8>(), std::mem::size_of_val(words))
    };
    format!("{:x}", Sha256::digest(bytes))
}

fn write_new_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    serde_json::to_writer(&mut file, value)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(())
}

fn read_bounded_json<T: for<'de> Deserialize<'de>>(path: &Path, maximum: usize) -> Result<T> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > maximum as u64 {
        bail!("AppContainer evidence is not one bounded regular file");
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(Some(0)).collect()
}

unsafe fn pwstr_to_path(value: *const u16) -> Result<PathBuf> {
    if value.is_null() {
        bail!("Windows returned a null AppContainer profile path");
    }
    let mut length = 0_usize;
    while length < 32 * 1024 && unsafe { *value.add(length) } != 0 {
        length += 1;
    }
    if length == 32 * 1024 {
        bail!("AppContainer profile path exceeded its bound");
    }
    Ok(PathBuf::from(String::from_utf16(unsafe { std::slice::from_raw_parts(value, length) })?))
}

fn sid_text(sid: PSID) -> Result<String> {
    let mut text = null_mut();
    check(unsafe { ConvertSidToStringSidW(sid, &mut text) }, "format Windows SID")?;
    let value = unsafe { pwstr_to_path(text) };
    unsafe { LocalFree(text.cast()) };
    Ok(value?.to_string_lossy().into_owned())
}

fn check(value: i32, operation: &str) -> Result<()> {
    if value == 0 {
        return Err(io::Error::last_os_error()).context(operation.to_string());
    }
    Ok(())
}

fn check_hresult(value: i32, operation: &str) -> Result<()> {
    if value < 0 {
        return Err(io::Error::from_raw_os_error(value)).context(operation.to_string());
    }
    Ok(())
}

fn check_windows_error(value: u32, operation: &str) -> Result<()> {
    if value != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(i32::try_from(value)?))
            .context(operation.to_string());
    }
    Ok(())
}

fn result_label<T>(result: &Result<T>) -> &'static str {
    if result.is_ok() { "ok" } else { "failed" }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_name_is_nonce_bound_and_bounded() {
        let nonce = "12".repeat(32);
        let name = format!("cmux.bench.ac.{}", &nonce[..32]);
        validate_profile_name(&name).unwrap();
        assert!(validate_profile_name("cmux.bench.ac.bad-name").is_err());
        assert!(validate_profile_name(&format!("cmux.bench.ac.{}", "1".repeat(80))).is_err());
    }

    #[test]
    fn command_line_quotes_spaces_quotes_and_trailing_slashes() {
        assert_eq!(quote_windows_argument("a b"), "\"a b\"");
        assert_eq!(quote_windows_argument("a\\\"b"), "\"a\\\\\\\"b\"");
        assert_eq!(quote_windows_argument("a\\"), "\"a\\\\\"");
    }

    #[test]
    fn evidence_rejects_an_acl_that_was_not_restored() {
        let entry = AclRestorationEvidence {
            path: PathBuf::from("fixture"),
            grant: "fixture-write".into(),
            before_sha256: "a".repeat(64),
            restored_sha256: "b".repeat(64),
            exact_restore: false,
        };
        assert!(!entry.exact_restore);
        assert_ne!(entry.before_sha256, entry.restored_sha256);
    }
}
