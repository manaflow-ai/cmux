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
use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_ACCESS_DENIED, ERROR_SUCCESS,
    GENERIC_WRITE, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, LocalFree,
    SetHandleInformation, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::NetworkManagement::WindowsFirewall::{
    INET_FIREWALL_APP_CONTAINER, NetworkIsolationEnumAppContainers,
    NetworkIsolationFreeAppContainers,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    ConvertStringSidToSidW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::Isolation::{
    CreateAppContainerProfile, DeleteAppContainerProfile,
    DeriveAppContainerSidFromAppContainerName, GetAppContainerFolderPath,
    GetAppContainerRegistryLocation,
};
use windows_sys::Win32::Security::{
    AdjustTokenPrivileges, DACL_SECURITY_INFORMATION, EqualSid, GetFileSecurityW,
    GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, ImpersonateLoggedOnUser,
    LABEL_SECURITY_INFORMATION, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT,
    LUID_AND_ATTRIBUTES, LogonUserW, LookupPrivilegeValueW, PSID, RevertToSelf,
    SE_PRIVILEGE_ENABLED, SECURITY_ATTRIBUTES, SECURITY_CAPABILITIES, TOKEN_ADJUST_PRIVILEGES,
    TOKEN_APPCONTAINER_INFORMATION, TOKEN_GROUPS, TOKEN_MANDATORY_LABEL, TOKEN_PRIVILEGES,
    TOKEN_QUERY, TOKEN_STATISTICS, TOKEN_USER, TokenAppContainerSid, TokenCapabilities,
    TokenIntegrityLevel, TokenIsAppContainer, TokenPrivileges, TokenStatistics, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    CREATE_NEW, CreateDirectoryW, CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_TYPE_UNKNOWN,
    GetFileType,
};
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
    JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO, SECURITY_MANDATORY_LOW_RID,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
    CreateProcessWithTokenW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT,
    GetCurrentProcess, GetExitCodeProcess, GetProcessId, GetThreadId,
    InitializeProcThreadAttributeList, OpenProcessToken, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
    PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, PROCESS_INFORMATION, ResumeThread,
    STARTF_USESTDHANDLES, STARTUPINFOEXW, STARTUPINFOW, UpdateProcThreadAttribute,
    WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::{LoadUserProfileW, PROFILEINFOW, UnloadUserProfile};

const EVIDENCE_SCHEMA_VERSION: u32 = 4;
const MAX_RECORD_BYTES: usize = 64 * 1024;
const BROKER_TIMEOUT: Duration = Duration::from_secs(50);
const PRODUCT_TIMEOUT: Duration = Duration::from_secs(30);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(10);
const JOB_COMPLETION_KEY: usize = 0x434d_5558;
const APP_CONTAINER_UNAVAILABLE_SCHEMA_VERSION: u32 = 1;
const APP_CONTAINER_UNAVAILABLE_STATUS: &str = "unavailable";
const APP_CONTAINER_UNAVAILABLE_STAGE: &str = "staging-readability";
const APP_CONTAINER_ACCOUNT_PROBE_IMPERSONATED: &str = "impersonated-account";
const APP_CONTAINER_ACCOUNT_PROBE_PROCESS: &str = "account-process";
const APP_CONTAINER_UNAVAILABLE_REASON: &str = "dedicated Windows account could not read the nonce-bound staged target before the restricted-token broker started";

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerConfig {
    schema_version: u32,
    nonce: String,
    target: PathBuf,
    target_sha256: String,
    staging_root: PathBuf,
    fixture_root: PathBuf,
    adjacent_path: PathBuf,
    profile_folder: PathBuf,
    profile_name: String,
    appcontainer_sid: String,
    account_authentication_id: String,
}

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerFailureEvidence {
    schema_version: u32,
    nonce: String,
    stage: BrokerFailureStage,
    error: String,
    account_sid: Option<String>,
    account_authentication_id: Option<String>,
    target: Option<PathBuf>,
    target_sha256: Option<String>,
    restricted_token_run_started: Option<bool>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
enum BrokerFailureStage {
    ConfigReceive,
    StagingReadability,
    ConfigValidate,
    ProductLaunch,
    SuccessEvidenceEncode,
    SuccessEvidenceWrite,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
enum BrokerWireRecord {
    Success { schema_version: u32, nonce: String, evidence: Box<BrokerEvidence> },
    Failure {
        schema_version: u32,
        nonce: String,
        stage: BrokerFailureStage,
        error: String,
        account_sid: Option<String>,
        account_authentication_id: Option<String>,
        target: Option<PathBuf>,
        target_sha256: Option<String>,
        restricted_token_run_started: Option<bool>,
    },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProductEvidence {
    schema_version: u32,
    nonce: String,
    entry_reached: bool,
    fixture_write: bool,
    staging_write_denied: bool,
    staged_probe_write_denied: bool,
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
    traverse_privilege_only: bool,
    account_authentication_match: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PreLaunchTokenEvidence {
    non_appcontainer: bool,
    restricting_sid_count_zero: bool,
    enabled_privilege_count: u32,
    se_change_notify_enabled: bool,
    traverse_privilege_only: bool,
    account_authentication_match: bool,
}

impl PreLaunchTokenEvidence {
    fn validate(&self) -> Result<()> {
        if !self.non_appcontainer
            || !self.restricting_sid_count_zero
            || self.enabled_privilege_count != 1
            || !self.se_change_notify_enabled
            || !self.traverse_privilege_only
            || !self.account_authentication_match
        {
            bail!(
                "pre-launch AppContainer token proof failed: non_appcontainer={}; restricting_sid_count_zero={}; enabled_privilege_count={}; se_change_notify_enabled={}; traverse_privilege_only={}; account_authentication_match={}",
                self.non_appcontainer,
                self.restricting_sid_count_zero,
                self.enabled_privilege_count,
                self.se_change_notify_enabled,
                self.traverse_privilege_only,
                self.account_authentication_match,
            );
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SuspendedProductTokenEvidence {
    token_is_appcontainer: bool,
    appcontainer_sid_match: bool,
    restricting_sid_count_zero: bool,
    capability_count_zero: bool,
    low_integrity: bool,
    enabled_privilege_count: u32,
    se_change_notify_enabled: bool,
    traverse_privilege_only: bool,
    account_authentication_match: bool,
}

impl SuspendedProductTokenEvidence {
    fn from_proof(proof: &TokenProof, expected_authentication_id: &str) -> Self {
        Self {
            token_is_appcontainer: proof.is_appcontainer,
            appcontainer_sid_match: proof.appcontainer_sid_match,
            restricting_sid_count_zero: proof.restricting_sid_count_zero,
            capability_count_zero: proof.capability_count_zero,
            low_integrity: proof.low_integrity,
            enabled_privilege_count: proof.enabled_privilege_count,
            se_change_notify_enabled: proof.se_change_notify_enabled,
            traverse_privilege_only: proof.traverse_privilege_only,
            account_authentication_match: proof.authentication_id == expected_authentication_id,
        }
    }

    fn validate(&self) -> Result<()> {
        if !self.token_is_appcontainer
            || !self.appcontainer_sid_match
            || !self.restricting_sid_count_zero
            || !self.capability_count_zero
            || !self.low_integrity
            || self.enabled_privilege_count != 1
            || !self.se_change_notify_enabled
            || !self.traverse_privilege_only
            || !self.account_authentication_match
        {
            bail!(
                "suspended AppContainer token proof failed: token_is_appcontainer={}; appcontainer_sid_match={}; restricting_sid_count_zero={}; capability_count_zero={}; low_integrity={}; enabled_privilege_count={}; se_change_notify_enabled={}; traverse_privilege_only={}; account_authentication_match={}",
                self.token_is_appcontainer,
                self.appcontainer_sid_match,
                self.restricting_sid_count_zero,
                self.capability_count_zero,
                self.low_integrity,
                self.enabled_privilege_count,
                self.se_change_notify_enabled,
                self.traverse_privilege_only,
                self.account_authentication_match,
            );
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BrokerEvidence {
    schema_version: u32,
    nonce: String,
    appcontainer_sid: String,
    pre_launch_token: PreLaunchTokenEvidence,
    suspended_product_token: SuspendedProductTokenEvidence,
    product: ProductEvidence,
    launch_api: String,
    create_process_w_succeeded: bool,
    broker_staging_write_denied: bool,
    broker_staged_probe_write_denied: bool,
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
    staged_probe_sha256: String,
    staging_creation_acl_applied: bool,
    fixture_creation_acl_applied: bool,
    staging_directory_deleted: bool,
    fixture_directory_deleted: bool,
    preexisting_parent_path: PathBuf,
    preexisting_parent_before_sha256: String,
    preexisting_parent_after_sha256: String,
    preexisting_parent_unchanged: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct AppContainerUnavailableEvidence {
    schema_version: u32,
    status: &'static str,
    backend: &'static str,
    nonce: String,
    stage: &'static str,
    reason: String,
    runner_staged_target_readable: bool,
    runner_staged_target_sha256: String,
    expected_staged_target_sha256: String,
    staging_creation_acl_applied: bool,
    fixture_creation_acl_applied: bool,
    staged_target_regular_file: bool,
    account_probe_impersonated: bool,
    account_probe_kind: &'static str,
    account_sid: String,
    account_authentication_id: String,
    account_process_target: PathBuf,
    account_process_target_sha256: String,
    account_process_probe_started: bool,
    account_staged_target_readable: bool,
    account_staged_target_error_code: u32,
    restricted_token_run_started: bool,
    profile_deleted: bool,
    account_profile_unloaded: bool,
    adjacent_sentinel_deleted: bool,
    staging_directory_deleted: bool,
    fixture_directory_deleted: bool,
    preexisting_parent_before_sha256: String,
    preexisting_parent_after_sha256: String,
    preexisting_parent_unchanged: bool,
}

impl AppContainerUnavailableEvidence {
    fn validate(&self) -> Result<()> {
        if self.schema_version != APP_CONTAINER_UNAVAILABLE_SCHEMA_VERSION
            || self.status != APP_CONTAINER_UNAVAILABLE_STATUS
            || self.backend != "windows-appcontainer-feasibility"
            || self.stage != APP_CONTAINER_UNAVAILABLE_STAGE
            || self.nonce.len() != 64
            || !self.nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
            || !self.reason.starts_with(APP_CONTAINER_UNAVAILABLE_REASON)
            || self.reason.len() > 4096
            || !self.runner_staged_target_readable
            || self.runner_staged_target_sha256 != self.expected_staged_target_sha256
            || !self.staging_creation_acl_applied
            || !self.fixture_creation_acl_applied
            || !self.staged_target_regular_file
            || !self.account_probe_impersonated
            || (self.account_probe_kind != APP_CONTAINER_ACCOUNT_PROBE_IMPERSONATED
                && self.account_probe_kind != APP_CONTAINER_ACCOUNT_PROBE_PROCESS)
            || !self.account_sid.starts_with("S-")
            || self.account_sid.len() > 256
            || self.account_authentication_id.len() != 16
            || !self.account_authentication_id.bytes().all(|byte| byte.is_ascii_hexdigit())
            || (self.account_probe_kind == APP_CONTAINER_ACCOUNT_PROBE_PROCESS
                && (self.account_process_target.as_os_str().is_empty()
                    || self.account_process_target_sha256 != self.runner_staged_target_sha256
                    || !self.account_process_probe_started))
            || self.account_staged_target_readable
            || self.account_staged_target_error_code != ERROR_ACCESS_DENIED
            || self.restricted_token_run_started
            || !self.profile_deleted
            || !self.account_profile_unloaded
            || !self.adjacent_sentinel_deleted
            || !self.staging_directory_deleted
            || !self.fixture_directory_deleted
            || !self.preexisting_parent_unchanged
            || self.preexisting_parent_before_sha256 != self.preexisting_parent_after_sha256
        {
            bail!("Windows AppContainer unavailable evidence is incomplete");
        }
        if self.account_probe_kind == APP_CONTAINER_ACCOUNT_PROBE_PROCESS {
            let expected_stage = format!("appcontainer-stage-{}", &self.nonce[..16]);
            let target_name = self.account_process_target.file_name().and_then(|name| name.to_str());
            let stage_name = self
                .account_process_target
                .parent()
                .and_then(Path::file_name)
                .and_then(|name| name.to_str());
            if target_name != Some("startup-benchmark-appcontainer-probe.exe")
                || stage_name != Some(expected_stage.as_str())
            {
                bail!("Windows AppContainer account-process target identity is invalid");
            }
        }
        validate_sha256(&self.runner_staged_target_sha256, "runner staged target")?;
        validate_sha256(&self.expected_staged_target_sha256, "expected staged target")?;
        validate_sha256(
            &self.preexisting_parent_before_sha256,
            "pre-existing parent before descriptor",
        )?;
        validate_sha256(
            &self.preexisting_parent_after_sha256,
            "pre-existing parent after descriptor",
        )?;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StagedTargetReadability {
    Ready,
    Unavailable,
    Invalid,
}

fn classify_staged_target_readability(
    runner_staged_target_readable: bool,
    runner_hash_matches: bool,
    staging_acl_attested: bool,
    fixture_acl_attested: bool,
    staged_target_regular_file: bool,
    account_probe_impersonated: bool,
    account_staged_target_readable: bool,
    account_hash_matches: bool,
    account_error_code: Option<i32>,
) -> StagedTargetReadability {
    if !runner_staged_target_readable
        || !runner_hash_matches
        || !staging_acl_attested
        || !fixture_acl_attested
        || !staged_target_regular_file
        || !account_probe_impersonated
    {
        return StagedTargetReadability::Invalid;
    }
    if account_staged_target_readable {
        return if account_hash_matches {
            StagedTargetReadability::Ready
        } else {
            StagedTargetReadability::Invalid
        };
    }
    if account_error_code == Some(ERROR_ACCESS_DENIED as i32) {
        StagedTargetReadability::Unavailable
    } else {
        StagedTargetReadability::Invalid
    }
}

fn raw_os_error(error: &anyhow::Error) -> Option<i32> {
    error
        .chain()
        .find_map(|cause| cause.downcast_ref::<io::Error>().and_then(io::Error::raw_os_error))
}

fn is_staging_readability_unavailable(
    failure: &BrokerFailureEvidence,
    config: &BrokerConfig,
    expected_nonce: &str,
    expected_account_sid: &str,
    expected_account_authentication_id: &str,
) -> bool {
    if failure.schema_version != EVIDENCE_SCHEMA_VERSION
        || failure.nonce != expected_nonce
        || failure.stage != BrokerFailureStage::StagingReadability
    {
        return false;
    }
    if failure.account_sid.as_deref() != Some(expected_account_sid)
        || failure.account_authentication_id.as_deref() != Some(expected_account_authentication_id)
        || failure.target.as_ref() != Some(&config.target)
        || failure.target_sha256.as_deref() != Some(config.target_sha256.as_str())
        || failure.restricted_token_run_started != Some(false)
    {
        return false;
    }
    let target = config.target.display();
    failure.error
        == format!(
            "validate staged AppContainer target hash: {target}: read file metadata for {target}: Access is denied. (os error 5)"
        )
}

impl FeasibilityEvidence {
    fn validate(&self) -> Result<()> {
        let product = &self.broker.product;
        if self.schema_version != EVIDENCE_SCHEMA_VERSION
            || self.backend != "windows-appcontainer-feasibility"
            || self.nonce != self.broker.nonce
            || self.appcontainer_sid != self.broker.appcontainer_sid
            || !self.broker.pre_launch_token.non_appcontainer
            || !self.broker.pre_launch_token.restricting_sid_count_zero
            || self.broker.pre_launch_token.enabled_privilege_count != 1
            || !self.broker.pre_launch_token.se_change_notify_enabled
            || !self.broker.pre_launch_token.traverse_privilege_only
            || !self.broker.pre_launch_token.account_authentication_match
            || !self.broker.suspended_product_token.token_is_appcontainer
            || !self.broker.suspended_product_token.appcontainer_sid_match
            || !self.broker.suspended_product_token.restricting_sid_count_zero
            || !self.broker.suspended_product_token.capability_count_zero
            || !self.broker.suspended_product_token.low_integrity
            || self.broker.suspended_product_token.enabled_privilege_count != 1
            || !self.broker.suspended_product_token.se_change_notify_enabled
            || !self.broker.suspended_product_token.traverse_privilege_only
            || !self.broker.suspended_product_token.account_authentication_match
            || !self.profile_user_sid_matches_account
            || !self.no_capabilities
            || product.schema_version != EVIDENCE_SCHEMA_VERSION
            || product.nonce != self.nonce
            || !product.entry_reached
            || !product.fixture_write
            || !product.staging_write_denied
            || !product.staged_probe_write_denied
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
            || !product.traverse_privilege_only
            || !product.account_authentication_match
            || self.broker.launch_api != "CreateProcessW+SECURITY_CAPABILITIES"
            || !self.broker.create_process_w_succeeded
            || !self.broker.broker_staging_write_denied
            || !self.broker.broker_staged_probe_write_denied
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
            || !self.staging_creation_acl_applied
            || !self.fixture_creation_acl_applied
            || !self.staging_directory_deleted
            || !self.fixture_directory_deleted
            || !self.preexisting_parent_unchanged
            || self.preexisting_parent_before_sha256 != self.preexisting_parent_after_sha256
        {
            bail!("Windows AppContainer feasibility evidence is incomplete");
        }
        validate_sha256(&self.staged_probe_sha256, "staged AppContainer probe")?;
        validate_sha256(
            &self.preexisting_parent_before_sha256,
            "pre-existing parent before descriptor",
        )?;
        validate_sha256(
            &self.preexisting_parent_after_sha256,
            "pre-existing parent after descriptor",
        )?;
        Ok(())
    }
}

pub(super) fn run_controller(values: &[String]) -> Result<()> {
    let fixture_parent = required_path(values, "--fixture-parent")?.canonicalize()?;
    let output = required_path(values, "--output")?;
    if !fixture_parent.is_dir() || output.exists() {
        bail!("AppContainer feasibility paths are not in their initial state");
    }
    let parent_security_information = DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION;
    let parent_security_before = file_security(&fixture_parent, parent_security_information)?;
    let preexisting_parent_before_sha256 = hash_words(&parent_security_before);

    let nonce = random_nonce()?;
    let profile_name = format!("cmux.bench.ac.{}", &nonce[..32]);
    let staging_path = fixture_parent.join(format!("appcontainer-stage-{}", &nonce[..16]));
    let fixture_path = fixture_parent.join(format!("appcontainer-fixture-{}", &nonce[..16]));
    let adjacent = fixture_parent.join(format!("appcontainer-adjacent-{}", &nonce[..16]));
    if staging_path.exists() || fixture_path.exists() || adjacent.exists() {
        bail!("nonce-owned AppContainer paths already existed");
    }

    let current = std::env::current_exe()?.canonicalize()?;
    let target_sha256 = sha256_file(&current)?;
    let user =
        std::env::var("CMUX_BENCH_WINDOWS_USER").context("CMUX_BENCH_WINDOWS_USER is required")?;
    let password = std::env::var("CMUX_BENCH_WINDOWS_PASSWORD")
        .context("CMUX_BENCH_WINDOWS_PASSWORD is required")?;
    let mut account = AccountProfile::logon(&user, &password)?;
    let account_sid = token_user_sid(account.token())?;
    let account_authentication_id = token_authentication_id(account.token())?;
    let runner_sid = current_process_user_sid()?;

    let account_token = account.token();
    let mut profile =
        account.impersonate(|_| AppContainerProfile::create(&profile_name, account_token))?;
    let appcontainer_sid = profile.sid_text.clone();
    let profile_user_sid_matches_account = account
        .impersonate(|_| network_profile_present(&profile.sid, &account_sid, &profile_name))?;
    if !profile_user_sid_matches_account {
        bail!("AppContainer profile did not enumerate for the benchmark account SID");
    }

    let mut staging = OwnedNonceDirectory::create(
        &staging_path,
        &runner_sid,
        &account_sid,
        &appcontainer_sid,
        NonceObjectAccess::ReadExecute,
    )?;
    let mut fixture = OwnedNonceDirectory::create(
        &fixture_path,
        &runner_sid,
        &account_sid,
        &appcontainer_sid,
        NonceObjectAccess::Full,
    )?;
    let staged_target = staging.path().join("startup-benchmark-appcontainer-probe.exe");
    copy_new_regular_file(&current, &staged_target, &runner_sid, &account_sid, &appcontainer_sid)
        .context("stage exact AppContainer probe executable")?;
    let staged_probe_sha256 = sha256_file(&staged_target)?;
    if staged_probe_sha256 != target_sha256 {
        bail!("staged AppContainer probe hash changed");
    }
    fs::write(&adjacent, b"protected").context("create AppContainer adjacent sentinel")?;
    let staging_creation_acl_applied =
        !file_security(staging.path(), DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION)?
            .is_empty();
    let fixture_creation_acl_applied =
        !file_security(fixture.path(), DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION)?
            .is_empty();
    let staged_target_regular_file = {
        let metadata = fs::symlink_metadata(&staged_target)?;
        metadata.file_type().is_file() && !metadata.file_type().is_symlink()
    };
    let mut account_probe_impersonated = false;
    let account_readability = account.impersonate(|_| {
        account_probe_impersonated = true;
        sha256_file(&staged_target)
    });
    let (account_staged_target_readable, account_hash_matches, account_error_code) =
        match &account_readability {
            Ok(observed_hash) => (true, observed_hash == &staged_probe_sha256, None),
            Err(error) => (false, false, raw_os_error(error)),
        };
    let staging_readability = classify_staged_target_readability(
        true,
        staged_probe_sha256 == target_sha256,
        staging_creation_acl_applied,
        fixture_creation_acl_applied,
        staged_target_regular_file,
        account_probe_impersonated,
        account_staged_target_readable,
        account_hash_matches,
        account_error_code,
    );
    if staging_readability == StagedTargetReadability::Unavailable {
        let account_error = account_readability
            .as_ref()
            .err()
            .expect("unavailable staging readability has an account error");
        let evidence = cleanup_unavailable_appcontainer(
            &mut account,
            &mut profile,
            &adjacent,
            &mut staging,
            &mut fixture,
            &fixture_parent,
            parent_security_information,
            &parent_security_before,
            nonce,
            staged_probe_sha256.clone(),
            target_sha256,
            staging_creation_acl_applied,
            fixture_creation_acl_applied,
            staged_target_regular_file,
            account_probe_impersonated,
            APP_CONTAINER_ACCOUNT_PROBE_IMPERSONATED,
            account_sid.clone(),
            account_authentication_id.clone(),
            PathBuf::new(),
            String::new(),
            false,
            u32::try_from(account_error_code.expect("access-denied error code is present"))?,
            account_error,
        )?;
        write_new_json(&output, &evidence)?;
        return Err(super::WindowsClaimUnavailable.into());
    }
    if staging_readability != StagedTargetReadability::Ready {
        let error = account_readability
            .err()
            .map(|error| format!("{error:#}"))
            .unwrap_or_else(|| "account staged-target hash did not match".into());
        bail!("AppContainer staged-target readability proof failed: {error}");
    }
    let config = BrokerConfig {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: nonce.clone(),
        target: staged_target.clone(),
        target_sha256: staged_probe_sha256.clone(),
        staging_root: staging.path().to_path_buf(),
        fixture_root: fixture.path().to_path_buf(),
        adjacent_path: adjacent.clone(),
        profile_folder: profile.folder.clone(),
        profile_name: profile_name.clone(),
        appcontainer_sid: appcontainer_sid.clone(),
        account_authentication_id: account_authentication_id.clone(),
    };
    let broker_run = run_account_broker(account.token(), &staged_target, &config, &nonce);
    let (broker_result, wire_failure, broker_stdout, broker_stderr) = match broker_run {
        Ok(BrokerRunOutput { outcome, stdout, stderr }) => {
            let wire = parse_broker_wire_stdout(&stdout, &nonce);
            let (result, failure) = match (outcome, wire) {
                (Ok(()), Ok(BrokerWireRecord::Success { evidence, .. })) => (Ok(*evidence), None),
                (
                    Err(error),
                    Ok(BrokerWireRecord::Failure {
                        schema_version,
                        nonce,
                        stage,
                        error: wire_error,
                        account_sid,
                        account_authentication_id,
                        target,
                        target_sha256,
                        restricted_token_run_started,
                    }),
                ) => (
                    Err(error),
                    Some(BrokerFailureEvidence {
                        schema_version,
                        nonce,
                        stage,
                        error: wire_error,
                        account_sid,
                        account_authentication_id,
                        target,
                        target_sha256,
                        restricted_token_run_started,
                    }),
                ),
                (Ok(()), Ok(BrokerWireRecord::Failure { .. })) => (
                    Err(anyhow::anyhow!("successful AppContainer broker emitted a failure record")),
                    None,
                ),
                (Err(error), Ok(BrokerWireRecord::Success { .. })) => (
                    Err(error.context("failed AppContainer broker emitted a success record")),
                    None,
                ),
                (_, Err(error)) => (Err(error), None),
            };
            (result, failure, stdout, stderr)
        }
        Err(error) => (Err(error), None, Vec::new(), Vec::new()),
    };
    let broker = match broker_result {
        Ok(broker) => broker,
        Err(error) => {
            if let Some(failure) = wire_failure.as_ref()
                && is_staging_readability_unavailable(
                    failure,
                    &config,
                    &nonce,
                    &account_sid,
                    &account_authentication_id,
                )
            {
                persist_broker_failure(failure, &output, &nonce)?;
                let account_error = anyhow::anyhow!(failure.error.clone());
                let evidence = cleanup_unavailable_appcontainer(
                    &mut account,
                    &mut profile,
                    &adjacent,
                    &mut staging,
                    &mut fixture,
                    &fixture_parent,
                    parent_security_information,
                    &parent_security_before,
                    nonce,
                    staged_probe_sha256.clone(),
                    target_sha256,
                    staging_creation_acl_applied,
                    fixture_creation_acl_applied,
                    staged_target_regular_file,
                    account_probe_impersonated,
                    APP_CONTAINER_ACCOUNT_PROBE_PROCESS,
                    account_sid.clone(),
                    account_authentication_id.clone(),
                    config.target.clone(),
                    config.target_sha256.clone(),
                    true,
                    ERROR_ACCESS_DENIED,
                    &account_error,
                )?;
                write_new_json(&output, &evidence)?;
                return Err(super::WindowsClaimUnavailable.into());
            }
            let copied_failure = wire_failure
                .as_ref()
                .context("AppContainer broker produced no valid failure wire record")
                .and_then(|failure| persist_broker_failure(failure, &output, &nonce));
            let profile_cleanup = account.impersonate(|_| profile.delete());
            let _ = fs::remove_file(&adjacent);
            let parent_unchanged = parent_security_unchanged(
                &fixture_parent,
                parent_security_information,
                &parent_security_before,
            );
            return Err(error.context(format!(
                "AppContainer broker failed; broker stderr: {}; broker stdout: {}; diagnostic: {}; profile cleanup: {}; pre-existing parent unchanged: {}; nonce directories retained because Job zero was not accepted",
                String::from_utf8_lossy(&broker_stderr),
                String::from_utf8_lossy(&broker_stdout),
                result_label(&copied_failure),
                result_label(&profile_cleanup),
                result_label(&parent_unchanged),
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

    fs::remove_file(&adjacent).context("remove AppContainer adjacent sentinel")?;
    if fs::read(&adjacent).is_ok() {
        bail!("AppContainer adjacent sentinel remained after cleanup");
    }
    fixture.remove()?;
    staging.remove()?;
    let fixture_directory_deleted = !fixture_path.exists();
    let staging_directory_deleted = !staging_path.exists();
    let parent_security_after = file_security(&fixture_parent, parent_security_information)?;
    let preexisting_parent_after_sha256 = hash_words(&parent_security_after);
    let preexisting_parent_unchanged = parent_security_before == parent_security_after;
    if !preexisting_parent_unchanged {
        bail!("AppContainer feasibility changed the pre-existing fixture-parent descriptor");
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
        staged_probe_sha256,
        staging_creation_acl_applied: true,
        fixture_creation_acl_applied: true,
        staging_directory_deleted,
        fixture_directory_deleted,
        preexisting_parent_path: fixture_parent,
        preexisting_parent_before_sha256,
        preexisting_parent_after_sha256,
        preexisting_parent_unchanged,
    };
    evidence.validate()?;
    write_new_json(&output, &evidence)?;
    Ok(())
}
pub(super) fn run_broker(values: &[String]) -> Result<()> {
    let expected_nonce = required_value(values, "--nonce")?;
    validate_nonce(&expected_nonce)?;
    let received = read_bounded_all(io::stdin().lock(), MAX_RECORD_BYTES)
        .map_err(anyhow::Error::from)
        .and_then(|bytes| decode_canonical_json_line::<BrokerConfig>(&bytes));
    let config = match received {
        Ok(config) => config,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::ConfigReceive,
                error,
            ));
        }
    };
    // Validate the nonce-bound path and read it from this exact account process before preparing
    // or launching any restricted-token AppContainer process. A raw access denial here means the
    // runner cannot exercise the capability and is a typed unavailable result, not a claim.
    if let Err(error) = validate_config_identity(&config, &expected_nonce) {
        return Err(record_broker_failure(
            &expected_nonce,
            BrokerFailureStage::ConfigValidate,
            error,
        ));
    }
    let process_token = match prepare_broker_process_token() {
        Ok(process_token) => process_token,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::ConfigValidate,
                error.context("prepare account broker token after staging readability"),
            ));
        }
    };
    let process_account_sid = match token_user_sid(process_token.0) {
        Ok(sid) => sid,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::ConfigValidate,
                error.context("read account broker user SID before staging readability"),
            ));
        }
    };
    let process_account_authentication_id = match token_authentication_id(process_token.0) {
        Ok(authentication_id) => authentication_id,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::ConfigValidate,
                error.context("read account broker authentication ID before staging readability"),
            ));
        }
    };
    if let Err(error) = validate_staged_target(&config) {
        return Err(record_staging_readability_failure(
            &expected_nonce,
            error,
            process_account_sid,
            process_account_authentication_id,
            config.target.clone(),
            config.target_sha256.clone(),
        ));
    }
    let evidence = match launch_appcontainer_product(&config, process_token.0) {
        Ok(evidence) => evidence,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::ProductLaunch,
                error,
            ));
        }
    };
    let record = BrokerWireRecord::Success {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: expected_nonce.clone(),
        evidence: Box::new(evidence),
    };
    let encoded = match encode_canonical_json_line(&record) {
        Ok(encoded) => encoded,
        Err(error) => {
            return Err(record_broker_failure(
                &expected_nonce,
                BrokerFailureStage::SuccessEvidenceEncode,
                error,
            ));
        }
    };
    if let Err(error) = write_broker_stdout(&encoded) {
        return Err(record_broker_failure(
            &expected_nonce,
            BrokerFailureStage::SuccessEvidenceWrite,
            error,
        ));
    }
    Ok(())
}

pub(super) fn run_probe(values: &[String]) -> Result<()> {
    if !values.is_empty() {
        bail!("AppContainer probe takes its identity from its filtered environment");
    }
    let nonce = required_env("CMUX_APP_CONTAINER_NONCE")?;
    let fixture_root = PathBuf::from(required_env("CMUX_APP_CONTAINER_FIXTURE")?);
    let staging_root = PathBuf::from(required_env("CMUX_APP_CONTAINER_STAGING")?);
    let staged_probe = PathBuf::from(required_env("CMUX_APP_CONTAINER_TARGET")?);
    let adjacent = PathBuf::from(required_env("CMUX_APP_CONTAINER_ADJACENT")?);
    let profile_folder = PathBuf::from(required_env("CMUX_APP_CONTAINER_PROFILE")?);
    let appcontainer_sid = required_env("CMUX_APP_CONTAINER_SID")?;
    let account_authentication_id = required_env("CMUX_APP_CONTAINER_AUTH_ID")?;
    let outbound_address = required_env("CMUX_APP_CONTAINER_NETWORK")?.parse::<SocketAddr>()?;
    let inbound_ip = required_env("CMUX_APP_CONTAINER_INBOUND_IP")?;

    let fixture_write =
        fs::write(fixture_root.join(format!("inside-{}.txt", &nonce[..16])), nonce.as_bytes())
            .is_ok();
    let staging_write_denied =
        fs::write(staging_root.join(format!("denied-{}.txt", &nonce[..16])), nonce.as_bytes())
            .is_err();
    let staged_probe_write_denied = OpenOptions::new().write(true).open(&staged_probe).is_err();
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
    let proof = current_token_proof(&appcontainer_sid)?;

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
        staging_write_denied,
        staged_probe_write_denied,
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
        traverse_privilege_only: proof.traverse_privilege_only,
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

struct BrokerRunOutput {
    outcome: Result<()>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
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

enum NonceObjectAccess {
    ReadExecute,
    Full,
}

struct OwnedSecurityDescriptor(windows_sys::Win32::Security::PSECURITY_DESCRIPTOR);

impl OwnedSecurityDescriptor {
    fn validate_nonce_sids(
        runner_sid: &str,
        account_sid: &str,
        appcontainer_sid: &str,
    ) -> Result<()> {
        for (name, sid) in
            [("runner", runner_sid), ("account", account_sid), ("AppContainer", appcontainer_sid)]
        {
            OwnedSid::from_string(sid)
                .with_context(|| format!("validate {name} SID for nonce-owned object"))?;
        }
        Ok(())
    }

    fn for_nonce_directory(
        runner_sid: &str,
        account_sid: &str,
        appcontainer_sid: &str,
        access: NonceObjectAccess,
    ) -> Result<Self> {
        Self::validate_nonce_sids(runner_sid, account_sid, appcontainer_sid)?;
        let access = match access {
            NonceObjectAccess::ReadExecute => "GRGX",
            NonceObjectAccess::Full => "GA",
        };
        let sddl = format!(
            "D:P(A;OICI;GA;;;SY)(A;OICI;GA;;;BA)(A;OICI;GA;;;{runner_sid})(A;OICI;{access};;;{account_sid})(A;OICI;{access};;;{appcontainer_sid})S:(ML;OICI;NW;;;LW)"
        );
        Self::from_sddl(&sddl)
    }

    fn for_nonce_read_execute_file(
        runner_sid: &str,
        account_sid: &str,
        appcontainer_sid: &str,
    ) -> Result<Self> {
        Self::validate_nonce_sids(runner_sid, account_sid, appcontainer_sid)?;
        // A leaf file has direct, file-specific ACEs. It has no inheritance flags because it
        // cannot own child objects. FR+FX supplies read attributes, data, execute, and synchronize.
        let sddl = format!(
            "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;{runner_sid})(A;;FRFX;;;{account_sid})(A;;FRFX;;;{appcontainer_sid})S:(ML;;NW;;;LW)"
        );
        Self::from_sddl(&sddl)
    }

    fn from_sddl(sddl: &str) -> Result<Self> {
        let sddl = wide(OsStr::new(sddl));
        let mut descriptor = null_mut();
        // SAFETY: sddl is NUL-terminated and descriptor points to writable storage.
        check(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            },
            "build nonce-owned AppContainer object security descriptor",
        )?;
        Ok(Self(descriptor))
    }
}

impl Drop for OwnedSecurityDescriptor {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the conversion API allocated this descriptor with LocalAlloc.
            unsafe { LocalFree(self.0) };
        }
    }
}

struct OwnedNonceDirectory {
    path: PathBuf,
    removed: bool,
}

// This owner has no Drop deletion. Explicit remove is allowed only after accepted Job-zero proof;
// a failed run retains its bounded RUNNER_TEMP directory for evidence and outer-runner cleanup.

impl OwnedNonceDirectory {
    fn create(
        path: &Path,
        runner_sid: &str,
        account_sid: &str,
        appcontainer_sid: &str,
        access: NonceObjectAccess,
    ) -> Result<Self> {
        if path.exists() {
            bail!("nonce-owned AppContainer directory already existed: {}", path.display());
        }
        let descriptor = OwnedSecurityDescriptor::for_nonce_directory(
            runner_sid,
            account_sid,
            appcontainer_sid,
            access,
        )?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>())?,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: 0,
        };
        let path_wide = wide(path.as_os_str());
        // SAFETY: path is NUL-terminated. The descriptor and attributes remain live for the call.
        check(
            unsafe { CreateDirectoryW(path_wide.as_ptr(), &attributes) },
            "create nonce-owned AppContainer directory",
        )
        .with_context(|| format!("path={}", path.display()))?;
        Ok(Self { path: path.to_path_buf(), removed: false })
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn remove(&mut self) -> Result<()> {
        if self.removed {
            bail!("nonce-owned AppContainer directory was removed twice: {}", self.path.display());
        }
        fs::remove_dir_all(&self.path).with_context(|| {
            format!("remove nonce-owned AppContainer directory {}", self.path.display())
        })?;
        if self.path.exists() {
            bail!(
                "nonce-owned AppContainer directory remained after deletion: {}",
                self.path.display()
            );
        }
        self.removed = true;
        Ok(())
    }
}

fn cleanup_unavailable_appcontainer(
    account: &mut AccountProfile,
    profile: &mut AppContainerProfile,
    adjacent: &Path,
    staging: &mut OwnedNonceDirectory,
    fixture: &mut OwnedNonceDirectory,
    fixture_parent: &Path,
    parent_security_information: u32,
    parent_security_before: &[usize],
    nonce: String,
    runner_staged_target_sha256: String,
    expected_staged_target_sha256: String,
    staging_creation_acl_applied: bool,
    fixture_creation_acl_applied: bool,
    staged_target_regular_file: bool,
    account_probe_impersonated: bool,
    account_probe_kind: &'static str,
    account_sid: String,
    account_authentication_id: String,
    account_process_target: PathBuf,
    account_process_target_sha256: String,
    account_process_probe_started: bool,
    account_staged_target_error_code: u32,
    _account_staged_target_error: &anyhow::Error,
) -> Result<AppContainerUnavailableEvidence> {
    account.impersonate(|_| profile.delete())?;
    let profile_deleted = profile.deleted;
    if !profile_deleted || profile.folder.exists() {
        bail!("AppContainer unavailable cleanup did not delete the profile");
    }

    fs::remove_file(adjacent).context("remove AppContainer unavailable adjacent sentinel")?;
    let adjacent_sentinel_deleted = !adjacent.exists();
    fixture.remove()?;
    staging.remove()?;
    let fixture_directory_deleted = !fixture.path.exists();
    let staging_directory_deleted = !staging.path.exists();

    account.unload()?;
    let account_profile_unloaded = account.profile.is_null();
    if !account_profile_unloaded {
        bail!("AppContainer unavailable cleanup did not unload the account profile");
    }

    let parent_security_after = file_security(fixture_parent, parent_security_information)?;
    let preexisting_parent_unchanged = parent_security_before == parent_security_after;
    if !preexisting_parent_unchanged {
        bail!("AppContainer unavailable cleanup changed the pre-existing parent descriptor");
    }

    let evidence = AppContainerUnavailableEvidence {
        schema_version: APP_CONTAINER_UNAVAILABLE_SCHEMA_VERSION,
        status: APP_CONTAINER_UNAVAILABLE_STATUS,
        backend: "windows-appcontainer-feasibility",
        nonce,
        stage: APP_CONTAINER_UNAVAILABLE_STAGE,
        reason: APP_CONTAINER_UNAVAILABLE_REASON.into(),
        runner_staged_target_readable: true,
        runner_staged_target_sha256,
        expected_staged_target_sha256,
        staging_creation_acl_applied,
        fixture_creation_acl_applied,
        staged_target_regular_file,
        account_probe_impersonated,
        account_probe_kind,
        account_sid,
        account_authentication_id,
        account_process_target,
        account_process_target_sha256,
        account_process_probe_started,
        account_staged_target_readable: false,
        account_staged_target_error_code,
        restricted_token_run_started: false,
        profile_deleted,
        account_profile_unloaded,
        adjacent_sentinel_deleted,
        staging_directory_deleted,
        fixture_directory_deleted,
        preexisting_parent_before_sha256: hash_words(parent_security_before),
        preexisting_parent_after_sha256: hash_words(&parent_security_after),
        preexisting_parent_unchanged,
    };
    evidence.validate()?;
    Ok(evidence)
}

fn run_account_broker(
    token: HANDLE,
    executable: &Path,
    config: &BrokerConfig,
    nonce: &str,
) -> Result<BrokerRunOutput> {
    let broker_wait_ms = u32::try_from(BROKER_TIMEOUT.as_millis())?;
    let config_line = encode_canonical_json_line(config)?;
    let inheritable = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>())?,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let (input_read, input_write) = create_pipe(&inheritable, "AppContainer broker stdin")?;
    let (output_read, output_write) = create_pipe(&inheritable, "AppContainer broker stdout")?;
    let (error_read, error_write) = create_pipe(&inheritable, "AppContainer broker stderr")?;
    for handle in [input_write.0, output_read.0, error_read.0] {
        // SAFETY: these controller ends are live and must not be copied into the broker.
        check(
            unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) },
            "make AppContainer broker controller pipe end non-inheritable",
        )?;
    }
    let mut environment = null_mut();
    // SAFETY: environment points to writable storage and token is a live account token.
    check(
        unsafe { CreateEnvironmentBlock(&mut environment, token, 0) },
        "create trusted AppContainer broker environment",
    )?;
    let command_line = windows_command_line(&[
        executable.as_os_str(),
        OsStr::new("--appcontainer-broker"),
        OsStr::new("--nonce"),
        OsStr::new(nonce),
    ]);
    let application = wide(executable.as_os_str());
    let current_dir = wide(config.staging_root.as_os_str());
    let mut command_line = command_line;
    let mut startup =
        STARTUPINFOW { cb: u32::try_from(size_of::<STARTUPINFOW>())?, ..STARTUPINFOW::default() };
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = input_read.0;
    startup.hStdOutput = output_write.0;
    startup.hStdError = error_write.0;
    let mut process = PROCESS_INFORMATION::default();
    // SAFETY: all pointers and dedicated standard handles remain live for the call. The account
    // environment comes from UserEnv and does not contain runner CMUX_BENCH secrets.
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
    drop(input_read);
    drop(output_write);
    drop(error_write);
    let output_thread = thread::spawn(move || {
        // SAFETY: output_read exclusively owns this pipe handle after the move.
        let file = unsafe { File::from_raw_handle(output_read.0 as RawHandle) };
        std::mem::forget(output_read);
        read_bounded_all(file, MAX_RECORD_BYTES)
    });
    let error_thread = thread::spawn(move || {
        // SAFETY: error_read exclusively owns this pipe handle after the move.
        let file = unsafe { File::from_raw_handle(error_read.0 as RawHandle) };
        std::mem::forget(error_read);
        read_bounded_tail(file, 16 * 1024)
    });
    // SAFETY: input_write exclusively owns this pipe handle after the conversion.
    let mut input = unsafe { File::from_raw_handle(input_write.0 as RawHandle) };
    std::mem::forget(input_write);
    let config_write = input.write_all(&config_line).and_then(|_| input.flush());
    drop(input);
    let environment_cleanup = check(destroyed, "destroy trusted AppContainer broker environment");
    // SAFETY: process_handle is live for this bounded wait.
    let wait = unsafe { WaitForSingleObject(owner.process.0, broker_wait_ms) };
    let outcome = if let Err(error) = config_write {
        Err(error).context("write AppContainer broker config pipe")
    } else if let Err(error) = environment_cleanup {
        Err(error)
    } else if wait == WAIT_OBJECT_0 {
        let mut code = 0_u32;
        // SAFETY: process_handle is live and code points to writable storage.
        match check(
            unsafe { GetExitCodeProcess(owner.process.0, &mut code) },
            "read trusted AppContainer broker exit code",
        ) {
            Ok(()) if code == 0 => Ok(()),
            Ok(()) => Err(anyhow::anyhow!("trusted AppContainer broker exited with code {code}")),
            Err(error) => Err(error),
        }
    } else if wait == WAIT_TIMEOUT {
        Err(anyhow::anyhow!("trusted AppContainer broker exceeded its bounded deadline"))
    } else {
        Err(io::Error::last_os_error()).context("wait for trusted AppContainer broker")
    };
    if wait != WAIT_OBJECT_0 {
        // SAFETY: the process is live. This bounded cleanup owns EOF for both reader threads.
        let terminated = check(
            unsafe {
                windows_sys::Win32::System::Threading::TerminateProcess(owner.process.0, 125)
            },
            "terminate failed AppContainer broker",
        );
        let reaped = if terminated.is_ok() {
            let waited = unsafe { WaitForSingleObject(owner.process.0, 10_000) };
            if waited == WAIT_OBJECT_0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error()).context("reap failed AppContainer broker")
            }
        } else {
            Err(anyhow::anyhow!("broker termination did not run"))
        };
        if terminated.is_err() || reaped.is_err() {
            let primary = match outcome {
                Err(error) => error,
                Ok(()) => anyhow::anyhow!("broker wait failed without a primary error"),
            };
            return Err(primary.context(format!(
                "broker cleanup failed: terminate={}; reap={}",
                result_label(&terminated),
                result_label(&reaped),
            )));
        }
    }
    owner.terminate_on_drop = false;
    drop(owner);
    let stdout = output_thread
        .join()
        .map_err(|_| anyhow::anyhow!("AppContainer broker stdout reader panicked"));
    let stderr = error_thread
        .join()
        .map_err(|_| anyhow::anyhow!("AppContainer broker stderr reader panicked"));
    let stdout = stdout??;
    let stderr = stderr??;
    Ok(BrokerRunOutput { outcome, stdout, stderr })
}

fn prepare_broker_process_token() -> Result<OwnedHandle> {
    let mut process_token = null_mut();
    // SAFETY: process token storage is writable. This is the trusted account-owned broker token.
    check(
        unsafe {
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                &mut process_token,
            )
        },
        "open account broker primary token",
    )?;
    let process_token = OwnedHandle(process_token);
    disable_all_privileges(process_token.0)?;
    enable_privilege(process_token.0, "SeChangeNotifyPrivilege")?;
    Ok(process_token)
}

fn launch_appcontainer_product(
    config: &BrokerConfig,
    process_token: HANDLE,
) -> Result<BrokerEvidence> {
    let appcontainer_sid = OwnedSid::from_string(&config.appcontainer_sid)?;
    let pre_launch_token =
        pre_launch_token_evidence(process_token, &config.account_authentication_id)?;
    pre_launch_token.validate()?;
    let broker_staging_write_denied = fs::write(
        config.staging_root.join(format!("broker-denied-{}.txt", &config.nonce[..16])),
        config.nonce.as_bytes(),
    )
    .is_err();
    let broker_staged_probe_write_denied =
        OpenOptions::new().write(true).open(&config.target).is_err();
    if !broker_staging_write_denied || !broker_staged_probe_write_denied {
        bail!("trusted account broker had write access to AppContainer staging");
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
    // SAFETY: strings, environment, startup attributes, and handle list are live. The trusted
    // account broker is the source process. SECURITY_CAPABILITIES creates the AppContainer output
    // token, and only the exact three standard handles are inheritable.
    let created = unsafe {
        CreateProcessW(
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
    check(created, "CreateProcessW suspended AppContainer feasibility product")?;
    let mut product_owner = ProductProcessOwner {
        process: OwnedHandle(process.hProcess),
        thread: OwnedHandle(process.hThread),
        terminate_on_drop: true,
    };
    drop(input_read);
    drop(output_write);
    drop(error_write);

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
    let post_launch =
        (|| -> Result<(ProductEvidence, bool, SuspendedProductTokenEvidence, u32, u32, u32)> {
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
            let after =
                token_proof_from_process(product_owner.process.0, &config.appcontainer_sid)?;
            let suspended_product_token = SuspendedProductTokenEvidence::from_proof(
                &after,
                &config.account_authentication_id,
            );
            suspended_product_token.validate()?;
            // SAFETY: thread_handle is the suspended primary thread.
            let resume_previous_count = unsafe { ResumeThread(product_owner.thread.0) };
            if resume_previous_count != 1 {
                bail!("AppContainer product resume count was {resume_previous_count}, expected 1");
            }
            let product_process_id = unsafe { GetProcessId(product_owner.process.0) };
            let product_primary_thread_id = unsafe { GetThreadId(product_owner.thread.0) };

            let record = receiver
                .recv_timeout(PRODUCT_TIMEOUT)
                .context("AppContainer product evidence deadline expired")??;
            let mut product: ProductEvidence =
                serde_json::from_slice(record.strip_suffix(b"\n").unwrap_or(&record))?;
            product.inbound_network_denied = match product.inbound_bound_address {
                None => true,
                Some(address) => {
                    TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_err()
                }
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
            Ok((
                product,
                accounting.ActiveProcesses >= 2,
                suspended_product_token,
                resume_previous_count,
                product_process_id,
                product_primary_thread_id,
            ))
        })();
    // SAFETY: job is live. Termination is the sole release for the deliberately blocked probes.
    let terminate =
        check(unsafe { TerminateJobObject(job.0, 125) }, "terminate AppContainer feasibility Job");
    let active_process_zero = if terminate.is_ok() {
        wait_active_zero(job.0, completion.0, CLEANUP_TIMEOUT)
    } else {
        Ok(false)
    };
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
    let (
        product,
        descendant_observed_in_job,
        suspended_product_token,
        resume_previous_count,
        product_process_id,
        product_primary_thread_id,
    ) = post_launch.map_err(|error| {
        error.context(format!("AppContainer product stderr: {}", String::from_utf8_lossy(&stderr)))
    })?;
    if !descendant_observed_in_job || !active_process_zero {
        bail!("AppContainer Job did not prove descendant containment and empty cleanup");
    }

    Ok(BrokerEvidence {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: config.nonce.clone(),
        appcontainer_sid: config.appcontainer_sid.clone(),
        pre_launch_token,
        suspended_product_token,
        product,
        launch_api: "CreateProcessW+SECURITY_CAPABILITIES".into(),
        create_process_w_succeeded: true,
        broker_staging_write_denied,
        broker_staged_probe_write_denied,
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
    enabled_privilege_count: u32,
    se_change_notify_enabled: bool,
    traverse_privilege_only: bool,
    authentication_id: String,
}

fn pre_launch_token_evidence(
    token: HANDLE,
    expected_authentication_id: &str,
) -> Result<PreLaunchTokenEvidence> {
    let authentication_id = token_authentication_id(token)?;
    let privileges = enabled_privilege_proof(token)?;
    Ok(PreLaunchTokenEvidence {
        non_appcontainer: token_u32(token, TokenIsAppContainer)? == 0,
        restricting_sid_count_zero: token_restricting_sid_count_zero(token)?,
        enabled_privilege_count: privileges.enabled_count,
        se_change_notify_enabled: privileges.se_change_notify_enabled,
        traverse_privilege_only: privileges.traverse_privilege_only,
        account_authentication_match: authentication_id == expected_authentication_id,
    })
}

fn current_token_proof(expected_sid: &str) -> Result<TokenProof> {
    let mut token = null_mut();
    // SAFETY: token points to writable handle storage.
    check(
        unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
        "open AppContainer product token",
    )?;
    let token = OwnedHandle(token);
    let proof = token_proof(token.0, expected_sid)?;
    Ok(proof)
}

fn token_proof_from_process(process: HANDLE, expected_sid: &str) -> Result<TokenProof> {
    let mut token = null_mut();
    // SAFETY: process is live and token points to writable storage.
    check(
        unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) },
        "open suspended AppContainer product token",
    )?;
    let token = OwnedHandle(token);
    token_proof(token.0, expected_sid)
}

fn token_proof(token: HANDLE, expected_sid: &str) -> Result<TokenProof> {
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
    let authentication_id = token_authentication_id(token)?;
    let privileges = enabled_privilege_proof(token)?;
    Ok(TokenProof {
        is_appcontainer,
        appcontainer_sid_match,
        restricting_sid_count_zero: token_restricting_sid_count_zero(token)?,
        capability_count_zero: capabilities.GroupCount == 0,
        low_integrity: token_is_low_integrity(token)?,
        enabled_privilege_count: privileges.enabled_count,
        se_change_notify_enabled: privileges.se_change_notify_enabled,
        traverse_privilege_only: privileges.traverse_privilege_only,
        authentication_id,
    })
}

fn token_restricting_sid_count_zero(token: HANDLE) -> Result<bool> {
    let restricting_sids =
        token_information(token, windows_sys::Win32::Security::TokenRestrictedSids)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_GROUPS header.
    let restricting_sids = unsafe { &*(restricting_sids.as_ptr().cast::<TOKEN_GROUPS>()) };
    Ok(restricting_sids.GroupCount == 0)
}

fn token_is_low_integrity(token: HANDLE) -> Result<bool> {
    let integrity = token_information(token, TokenIntegrityLevel)?;
    // SAFETY: GetTokenInformation filled this aligned mandatory-label structure.
    let integrity = unsafe { &*(integrity.as_ptr().cast::<TOKEN_MANDATORY_LABEL>()) };
    let count = unsafe { GetSidSubAuthorityCount(integrity.Label.Sid) };
    if count.is_null() || unsafe { *count } == 0 {
        return Ok(false);
    }
    let rid = unsafe { GetSidSubAuthority(integrity.Label.Sid, u32::from(unsafe { *count }) - 1) };
    Ok(!rid.is_null() && unsafe { *rid } == SECURITY_MANDATORY_LOW_RID as u32)
}

struct EnabledPrivilegeProof {
    enabled_count: u32,
    se_change_notify_enabled: bool,
    traverse_privilege_only: bool,
}

fn enabled_privilege_proof(token: HANDLE) -> Result<EnabledPrivilegeProof> {
    let privileges = token_information(token, TokenPrivileges)?;
    // SAFETY: GetTokenInformation filled this aligned TOKEN_PRIVILEGES header and array.
    let privileges = unsafe { &*(privileges.as_ptr().cast::<TOKEN_PRIVILEGES>()) };
    let first = privileges.Privileges.as_ptr();
    let change_notify = privilege_luid("SeChangeNotifyPrivilege")?;
    let mut enabled_count = 0_u32;
    let mut se_change_notify_enabled = false;
    for index in 0..privileges.PrivilegeCount {
        let privilege = unsafe { &*first.add(index as usize) };
        if privilege.Attributes & SE_PRIVILEGE_ENABLED == 0 {
            continue;
        }
        enabled_count += 1;
        if privilege.Luid.LowPart == change_notify.LowPart
            && privilege.Luid.HighPart == change_notify.HighPart
        {
            se_change_notify_enabled = true;
        }
    }
    Ok(EnabledPrivilegeProof {
        enabled_count,
        se_change_notify_enabled,
        traverse_privilege_only: enabled_count == 1 && se_change_notify_enabled,
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

fn current_process_user_sid() -> Result<String> {
    let mut token = null_mut();
    // SAFETY: token points to writable handle storage.
    check(
        unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
        "open trusted controller token for staging ownership",
    )?;
    let token = OwnedHandle(token);
    token_user_sid(token.0)
}

fn disable_all_privileges(token: HANDLE) -> Result<()> {
    // SAFETY: setting the calling thread's last-error value has no pointer or lifetime contract.
    unsafe { windows_sys::Win32::Foundation::SetLastError(ERROR_SUCCESS) };
    // SAFETY: token is live. When DisableAllPrivileges is true, Windows ignores NewState.
    check(
        unsafe { AdjustTokenPrivileges(token, 1, null(), 0, null_mut(), null_mut()) },
        "disable every AppContainer broker-token privilege",
    )?;
    // SAFETY: this reads the calling thread's last-error value after AdjustTokenPrivileges.
    let windows_error = unsafe { windows_sys::Win32::Foundation::GetLastError() };
    if windows_error != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(i32::try_from(windows_error)?))
            .context("disable every AppContainer broker-token privilege");
    }
    Ok(())
}

fn enable_privilege(token: HANDLE, name: &str) -> Result<()> {
    let luid = privilege_luid(name)?;
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

fn privilege_luid(name: &str) -> Result<windows_sys::Win32::Foundation::LUID> {
    let name = wide(OsStr::new(name));
    let mut luid = unsafe { zeroed() };
    // SAFETY: name is NUL-terminated and luid points to writable storage.
    check(
        unsafe { LookupPrivilegeValueW(null(), name.as_ptr(), &mut luid) },
        "resolve AppContainer broker privilege",
    )?;
    Ok(luid)
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

fn wait_active_zero(job: HANDLE, completion: HANDLE, timeout: Duration) -> Result<bool> {
    if job_active_processes(job)? == 0 {
        return Ok(true);
    }
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
                return Ok(job_active_processes(job)? == 0);
            }
            return Err(io::Error::last_os_error()).context("wait for AppContainer Job event");
        }
        if key == JOB_COMPLETION_KEY && bytes == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO {
            return Ok(true);
        }
    }
}

fn job_active_processes(job: HANDLE) -> Result<u32> {
    let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
    // SAFETY: accounting matches the requested Job information class.
    check(
        unsafe {
            QueryInformationJobObject(
                job,
                JobObjectBasicAccountingInformation,
                (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                u32::try_from(size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>())?,
                null_mut(),
            )
        },
        "query AppContainer Job active-process count",
    )?;
    Ok(accounting.ActiveProcesses)
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

fn parent_security_unchanged(path: &Path, information: u32, before: &[usize]) -> Result<()> {
    let after = file_security(path, information)?;
    if before != after {
        bail!("AppContainer feasibility changed the pre-existing parent security descriptor");
    }
    Ok(())
}
fn validate_config_identity(config: &BrokerConfig, expected_nonce: &str) -> Result<()> {
    validate_nonce(&config.nonce)?;
    validate_profile_name(&config.profile_name)?;
    if config.schema_version != EVIDENCE_SCHEMA_VERSION || config.nonce != expected_nonce {
        bail!("AppContainer broker config violated its identity boundary");
    }
    if config.target.parent() != Some(config.staging_root.as_path())
        || config.staging_root == config.fixture_root
        || config.staging_root.parent() != config.fixture_root.parent()
        || config.adjacent_path.starts_with(&config.fixture_root)
        || config.profile_folder.starts_with(&config.fixture_root)
    {
        bail!("AppContainer broker config violated its identity boundary");
    }
    let expected_sid = derive_profile_sid(&config.profile_name)
        .context("derive expected AppContainer profile SID")?;
    let observed = OwnedSid::from_string(&config.appcontainer_sid)
        .context("parse AppContainer profile SID from broker config")?;
    if unsafe { EqualSid(expected_sid.0, observed.0) } == 0 {
        bail!("AppContainer broker config profile SID changed");
    }
    Ok(())
}

fn validate_staged_target(config: &BrokerConfig) -> Result<()> {
    let observed_target_sha256 = sha256_file(&config.target).with_context(|| {
        format!("validate staged AppContainer target hash: {}", config.target.display())
    })?;
    if config.target_sha256 != observed_target_sha256 {
        bail!("AppContainer broker config violated its identity boundary");
    }
    let target = fs::symlink_metadata(&config.target).with_context(|| {
        format!("validate staged AppContainer target metadata: {}", config.target.display())
    })?;
    if !target.file_type().is_file() || target.file_type().is_symlink() {
        bail!("staged AppContainer target was not one regular file");
    }
    Ok(())
}

fn validate_config(config: &BrokerConfig, expected_nonce: &str) -> Result<()> {
    validate_config_identity(config, expected_nonce)?;
    validate_staged_target(config)
}

fn validate_product(product: &ProductEvidence, config: &BrokerConfig) -> Result<()> {
    if product.schema_version != EVIDENCE_SCHEMA_VERSION
        || product.nonce != config.nonce
        || !product.entry_reached
        || !product.fixture_write
        || !product.staging_write_denied
        || !product.staged_probe_write_denied
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
        || !product.traverse_privilege_only
        || !product.account_authentication_match
    {
        bail!("AppContainer product feasibility proof failed");
    }
    Ok(())
}

fn validate_broker(broker: &BrokerEvidence, config: &BrokerConfig) -> Result<()> {
    validate_product(&broker.product, config)?;
    broker.pre_launch_token.validate()?;
    broker.suspended_product_token.validate()?;
    if broker.schema_version != EVIDENCE_SCHEMA_VERSION
        || broker.nonce != config.nonce
        || broker.appcontainer_sid != config.appcontainer_sid
        || broker.launch_api != "CreateProcessW+SECURITY_CAPABILITIES"
        || !broker.create_process_w_succeeded
        || !broker.broker_staging_write_denied
        || !broker.broker_staged_probe_write_denied
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

fn validate_broker_failure(failure: &BrokerFailureEvidence, expected_nonce: &str) -> Result<()> {
    validate_nonce(&failure.nonce)?;
    if failure.schema_version != EVIDENCE_SCHEMA_VERSION
        || failure.nonce != expected_nonce
        || failure.error.is_empty()
        || failure.error.len() > 4096
    {
        bail!("AppContainer broker failure evidence is invalid");
    }
    let has_process_probe_fields = failure.account_sid.is_some()
        || failure.account_authentication_id.is_some()
        || failure.target.is_some()
        || failure.target_sha256.is_some()
        || failure.restricted_token_run_started.is_some();
    if failure.stage == BrokerFailureStage::StagingReadability {
        let (Some(account_sid), Some(account_authentication_id), Some(target), Some(target_sha256), Some(restricted_token_run_started)) = (
            failure.account_sid.as_ref(),
            failure.account_authentication_id.as_ref(),
            failure.target.as_ref(),
            failure.target_sha256.as_ref(),
            failure.restricted_token_run_started,
        ) else {
            bail!("AppContainer staging-readability failure evidence is incomplete");
        };
        if !account_sid.starts_with("S-")
            || account_sid.len() > 256
            || account_authentication_id.len() != 16
            || !account_authentication_id.bytes().all(|byte| byte.is_ascii_hexdigit())
            || target.as_os_str().is_empty()
            || restricted_token_run_started
        {
            bail!("AppContainer staging-readability failure evidence is invalid");
        }
        validate_sha256(target_sha256, "AppContainer staging-readability target")?;
    } else if has_process_probe_fields {
        bail!("AppContainer broker failure evidence has unexpected process probe fields");
    }
    Ok(())
}

fn persist_broker_failure(
    failure: &BrokerFailureEvidence,
    output: &Path,
    expected_nonce: &str,
) -> Result<PathBuf> {
    validate_broker_failure(failure, expected_nonce)?;
    let stem = output.file_stem().and_then(|value| value.to_str()).unwrap_or("appcontainer");
    let destination = output.with_file_name(format!("{stem}-failure.json"));
    write_new_json(&destination, failure)?;
    Ok(destination)
}

fn record_broker_failure(
    nonce: &str,
    stage: BrokerFailureStage,
    error: anyhow::Error,
) -> anyhow::Error {
    let failure = BrokerWireRecord::Failure {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: nonce.to_string(),
        stage,
        error: bounded_error(&error),
        account_sid: None,
        account_authentication_id: None,
        target: None,
        target_sha256: None,
        restricted_token_run_started: None,
    };
    match encode_canonical_json_line(&failure).and_then(|encoded| write_broker_stdout(&encoded)) {
        Ok(()) => error,
        Err(write) => error.context(format!(
            "also failed to write AppContainer broker failure wire record: {write:#}"
        )),
    }
}

fn record_staging_readability_failure(
    nonce: &str,
    error: anyhow::Error,
    account_sid: String,
    account_authentication_id: String,
    target: PathBuf,
    target_sha256: String,
) -> anyhow::Error {
    let failure = BrokerWireRecord::Failure {
        schema_version: EVIDENCE_SCHEMA_VERSION,
        nonce: nonce.to_string(),
        stage: BrokerFailureStage::StagingReadability,
        error: bounded_error(&error),
        account_sid: Some(account_sid),
        account_authentication_id: Some(account_authentication_id),
        target: Some(target),
        target_sha256: Some(target_sha256),
        restricted_token_run_started: Some(false),
    };
    match encode_canonical_json_line(&failure).and_then(|encoded| write_broker_stdout(&encoded)) {
        Ok(()) => error,
        Err(write) => error.context(format!(
            "also failed to write AppContainer staging-readability failure record: {write:#}"
        )),
    }
}

fn encode_canonical_json_line(value: &impl Serialize) -> Result<Vec<u8>> {
    let mut encoded = serde_json::to_vec(value)?;
    if encoded.len() + 1 > MAX_RECORD_BYTES {
        bail!("AppContainer broker JSON line exceeded its bound");
    }
    encoded.push(b'\n');
    Ok(encoded)
}

fn decode_canonical_json_line<T>(encoded: &[u8]) -> Result<T>
where
    T: for<'de> Deserialize<'de> + Serialize,
{
    if encoded.is_empty()
        || encoded.len() > MAX_RECORD_BYTES
        || !encoded.ends_with(b"\n")
        || encoded[..encoded.len() - 1].contains(&b'\n')
        || encoded[..encoded.len() - 1].contains(&b'\r')
    {
        bail!("AppContainer broker transport was not exactly one bounded JSON line");
    }
    let value: T = serde_json::from_slice(&encoded[..encoded.len() - 1])?;
    if encode_canonical_json_line(&value)? != encoded {
        bail!("AppContainer broker JSON line was not canonical");
    }
    Ok(value)
}

fn validate_broker_wire(record: &BrokerWireRecord, expected_nonce: &str) -> Result<()> {
    match record {
        BrokerWireRecord::Success { schema_version, nonce, evidence } => {
            validate_nonce(nonce)?;
            if *schema_version != EVIDENCE_SCHEMA_VERSION
                || nonce != expected_nonce
                || evidence.schema_version != EVIDENCE_SCHEMA_VERSION
                || evidence.nonce != expected_nonce
            {
                bail!("AppContainer broker success wire identity was invalid");
            }
        }
        BrokerWireRecord::Failure {
            schema_version,
            nonce,
            stage,
            error,
            account_sid,
            account_authentication_id,
            target,
            target_sha256,
            restricted_token_run_started,
        } => {
            let failure = BrokerFailureEvidence {
                schema_version: *schema_version,
                nonce: nonce.clone(),
                stage: *stage,
                error: error.clone(),
                account_sid: account_sid.clone(),
                account_authentication_id: account_authentication_id.clone(),
                target: target.clone(),
                target_sha256: target_sha256.clone(),
                restricted_token_run_started: *restricted_token_run_started,
            };
            validate_broker_failure(&failure, expected_nonce)?;
        }
    }
    Ok(())
}

fn parse_broker_wire_stdout(stdout: &[u8], expected_nonce: &str) -> Result<BrokerWireRecord> {
    let record = decode_canonical_json_line(stdout)?;
    validate_broker_wire(&record, expected_nonce)?;
    Ok(record)
}

fn write_broker_stdout(encoded: &[u8]) -> Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    stdout.write_all(encoded)?;
    stdout.flush()?;
    Ok(())
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
        ("CMUX_APP_CONTAINER_STAGING", config.staging_root.to_string_lossy().into_owned()),
        ("CMUX_APP_CONTAINER_TARGET", config.target.to_string_lossy().into_owned()),
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

fn read_bounded_all(mut reader: impl Read, maximum: usize) -> io::Result<Vec<u8>> {
    let mut contents = Vec::new();
    let mut chunk = [0_u8; 4096];
    let mut exceeded = false;
    loop {
        let count = reader.read(&mut chunk)?;
        if count == 0 {
            if exceeded {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "AppContainer broker stdout exceeded its bound",
                ));
            }
            return Ok(contents);
        }
        if contents.len().saturating_add(count) > maximum {
            exceeded = true;
            continue;
        }
        if !exceeded {
            contents.extend_from_slice(&chunk[..count]);
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

fn validate_sha256(value: &str, name: &str) -> Result<()> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{name} SHA-256 is invalid");
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
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("read file metadata for {}", path.display()))?;
    if !metadata.file_type().is_file() {
        bail!("AppContainer executable must be one regular file");
    }
    let mut file =
        File::open(path).with_context(|| format!("open file for hashing: {}", path.display()))?;
    let mut digest = Sha256::new();
    io::copy(&mut file, &mut digest)
        .with_context(|| format!("read file for hashing: {}", path.display()))?;
    Ok(format!("{:x}", digest.finalize()))
}

fn copy_new_regular_file(
    source: &Path,
    destination: &Path,
    runner_sid: &str,
    account_sid: &str,
    appcontainer_sid: &str,
) -> Result<()> {
    let source_metadata = fs::symlink_metadata(source)?;
    if !source_metadata.file_type().is_file() || source_metadata.file_type().is_symlink() {
        bail!("AppContainer staged source was not one regular file");
    }
    let mut source = File::open(source)?;
    let descriptor = OwnedSecurityDescriptor::for_nonce_read_execute_file(
        runner_sid,
        account_sid,
        appcontainer_sid,
    )?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>())?,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    let destination_wide = wide(destination.as_os_str());
    // SAFETY: the path is NUL-terminated. The descriptor and attributes remain live for the
    // atomic create call. The returned handle is owned by destination after the validity check.
    let destination_handle = unsafe {
        CreateFileW(
            destination_wide.as_ptr(),
            GENERIC_WRITE,
            0,
            &attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    };
    if destination_handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error())
            .with_context(|| format!("create secured staged file: {}", destination.display()));
    }
    // SAFETY: CreateFileW returned one valid, uniquely owned handle.
    let mut destination = unsafe { File::from_raw_handle(destination_handle as RawHandle) };
    io::copy(&mut source, &mut destination)?;
    destination.flush()?;
    drop(destination);
    Ok(())
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

fn result_label<T>(result: &Result<T>) -> String {
    match result {
        Ok(_) => "ok".into(),
        Err(error) => format!("failed: {}", bounded_error(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn staging_readability_requires_runner_and_acl_attestation_before_unavailable() {
        assert_eq!(
            classify_staged_target_readability(
                true,
                true,
                true,
                true,
                true,
                true,
                false,
                false,
                Some(ERROR_ACCESS_DENIED as i32),
            ),
            StagedTargetReadability::Unavailable
        );
        for (runner_readable, runner_hash_matches, staging_acl, fixture_acl, regular) in [
            (false, true, true, true, true),
            (true, false, true, true, true),
            (true, true, false, true, true),
            (true, true, true, false, true),
            (true, true, true, true, false),
        ] {
            assert_eq!(
                classify_staged_target_readability(
                    runner_readable,
                    runner_hash_matches,
                    staging_acl,
                    fixture_acl,
                    regular,
                    false,
                    false,
                    false,
                    Some(ERROR_ACCESS_DENIED as i32),
                ),
                StagedTargetReadability::Invalid
            );
        }
    }

    #[test]
    fn staging_readability_rejects_generic_access_denied_and_hash_mismatch() {
        assert_eq!(
            classify_staged_target_readability(
                true, true, true, true, true, true, false, false, None,
            ),
            StagedTargetReadability::Invalid
        );
        assert_eq!(
            classify_staged_target_readability(
                true, true, true, true, true, true, true, false, None,
            ),
            StagedTargetReadability::Invalid
        );
        assert_eq!(
            classify_staged_target_readability(
                true, true, true, true, true, true, true, true, None,
            ),
            StagedTargetReadability::Ready
        );
    }

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
    fn broker_config_transport_is_canonical_bounded_and_nonce_bound() {
        let nonce = "12".repeat(32);
        let config = BrokerConfig {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.clone(),
            target: PathBuf::from("C:/stage/probe.exe"),
            target_sha256: "34".repeat(32),
            staging_root: PathBuf::from("C:/stage"),
            fixture_root: PathBuf::from("C:/fixture"),
            adjacent_path: PathBuf::from("C:/adjacent"),
            profile_folder: PathBuf::from("C:/profile"),
            profile_name: format!("cmux.bench.ac.{}", &nonce[..32]),
            appcontainer_sid: "S-1-15-2-1".into(),
            account_authentication_id: "0000000100000002".into(),
        };
        let encoded = encode_canonical_json_line(&config).unwrap();
        let decoded: BrokerConfig = decode_canonical_json_line(&encoded).unwrap();

        assert_eq!(decoded.nonce, nonce);
        assert_eq!(decoded.target, PathBuf::from("C:/stage/probe.exe"));
        assert!(validate_config(&decoded, &"56".repeat(32)).is_err());
        let mut extra = encoded.clone();
        extra.extend_from_slice(&encoded);
        assert!(decode_canonical_json_line::<BrokerConfig>(&extra).is_err());

        let mut unknown = serde_json::to_value(&config).unwrap();
        unknown["unexpected"] = serde_json::json!(true);
        assert!(
            decode_canonical_json_line::<BrokerConfig>(
                &encode_canonical_json_line(&unknown).unwrap()
            )
            .is_err()
        );
    }

    #[test]
    fn pre_launch_token_failure_names_every_proof_field() {
        let evidence = PreLaunchTokenEvidence {
            non_appcontainer: false,
            restricting_sid_count_zero: false,
            enabled_privilege_count: 2,
            se_change_notify_enabled: false,
            traverse_privilege_only: false,
            account_authentication_match: false,
        };

        let error = format!("{:#}", evidence.validate().unwrap_err());
        for field in [
            "non_appcontainer=false",
            "restricting_sid_count_zero=false",
            "enabled_privilege_count=2",
            "se_change_notify_enabled=false",
            "traverse_privilege_only=false",
            "account_authentication_match=false",
        ] {
            assert!(error.contains(field), "missing field detail: {field}");
        }
    }

    #[test]
    fn pre_launch_token_accepts_only_the_traverse_privilege() {
        let evidence = PreLaunchTokenEvidence {
            non_appcontainer: true,
            restricting_sid_count_zero: true,
            enabled_privilege_count: 1,
            se_change_notify_enabled: true,
            traverse_privilege_only: true,
            account_authentication_match: true,
        };

        evidence.validate().unwrap();
    }

    #[test]
    fn nonce_owned_directory_cleanup_does_not_change_its_parent_descriptor() {
        let parent = tempfile::tempdir().unwrap();
        let information = DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION;
        let before = file_security(parent.path(), information).unwrap();
        let current_sid = current_process_user_sid().unwrap();
        let owned_path = parent.path().join("owned");
        let mut owned = OwnedNonceDirectory::create(
            &owned_path,
            &current_sid,
            &current_sid,
            &current_sid,
            NonceObjectAccess::Full,
        )
        .unwrap();

        fs::write(owned.path().join("probe"), b"owned").unwrap();
        owned.remove().unwrap();

        assert!(!owned_path.exists());
        parent_security_unchanged(parent.path(), information, &before).unwrap();
    }

    fn sample_broker_evidence(nonce: &str) -> BrokerEvidence {
        BrokerEvidence {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.into(),
            appcontainer_sid: "S-1-15-2-1".into(),
            pre_launch_token: PreLaunchTokenEvidence {
                non_appcontainer: true,
                restricting_sid_count_zero: true,
                enabled_privilege_count: 1,
                se_change_notify_enabled: true,
                traverse_privilege_only: true,
                account_authentication_match: true,
            },
            suspended_product_token: SuspendedProductTokenEvidence {
                token_is_appcontainer: true,
                appcontainer_sid_match: true,
                restricting_sid_count_zero: true,
                capability_count_zero: true,
                low_integrity: true,
                enabled_privilege_count: 1,
                se_change_notify_enabled: true,
                traverse_privilege_only: true,
                account_authentication_match: true,
            },
            product: ProductEvidence {
                schema_version: EVIDENCE_SCHEMA_VERSION,
                nonce: nonce.into(),
                entry_reached: true,
                fixture_write: true,
                staging_write_denied: true,
                staged_probe_write_denied: true,
                adjacent_write_denied: true,
                profile_owned_write: true,
                registry_owned_write: true,
                outbound_network_denied: true,
                inbound_network_denied: true,
                inbound_bound_address: None,
                descendant_ready: true,
                token_is_appcontainer: true,
                appcontainer_sid_match: true,
                restricting_sid_count_zero: true,
                capability_count_zero: true,
                low_integrity: true,
                traverse_privilege_only: true,
                account_authentication_match: true,
            },
            launch_api: "CreateProcessW+SECURITY_CAPABILITIES".into(),
            create_process_w_succeeded: true,
            broker_staging_write_denied: true,
            broker_staged_probe_write_denied: true,
            explicit_three_handle_list: true,
            security_capabilities_applied: true,
            product_exact_job_before_resume: true,
            product_resume_previous_count: 1,
            product_process_id: 1,
            product_primary_thread_id: 2,
            descendant_observed_in_job: true,
            active_process_zero: true,
        }
    }

    #[test]
    fn broker_failure_record_uses_schema_four_and_the_fixed_stage_allowlist() {
        for (stage, expected) in [
            (BrokerFailureStage::ConfigReceive, "config-receive"),
            (BrokerFailureStage::StagingReadability, "staging-readability"),
            (BrokerFailureStage::ConfigValidate, "config-validate"),
            (BrokerFailureStage::ProductLaunch, "product-launch"),
            (BrokerFailureStage::SuccessEvidenceEncode, "success-evidence-encode"),
            (BrokerFailureStage::SuccessEvidenceWrite, "success-evidence-write"),
        ] {
            let evidence = BrokerFailureEvidence {
                schema_version: EVIDENCE_SCHEMA_VERSION,
                nonce: "12".repeat(32),
                stage,
                error: "denied".into(),
                account_sid: None,
                account_authentication_id: None,
                target: None,
                target_sha256: None,
                restricted_token_run_started: None,
            };

            let encoded = serde_json::to_value(&evidence).unwrap();
            assert_eq!(encoded["schema_version"], 4);
            assert_eq!(encoded["stage"], expected);
            let decoded: BrokerFailureEvidence = serde_json::from_value(encoded).unwrap();
            assert_eq!(decoded.stage, stage);
        }

        let unknown = serde_json::json!({
            "schema_version": 4,
            "nonce": "12".repeat(32),
            "stage": "unknown",
            "error": "denied",
        });
        assert!(serde_json::from_value::<BrokerFailureEvidence>(unknown).is_err());
    }

    #[test]
    fn staging_readability_failure_requires_exact_account_identity_and_target() {
        let nonce = "12".repeat(32);
        let staging_root = PathBuf::from(
            r"\\?\D:\a\_temp\cbt\appcontainer-stage-1212121212121212",
        );
        let target = staging_root.join("startup-benchmark-appcontainer-probe.exe");
        let config = BrokerConfig {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.clone(),
            target: target.clone(),
            target_sha256: "34".repeat(32),
            staging_root: staging_root.clone(),
            fixture_root: PathBuf::from(
                r"\\?\D:\a\_temp\cbt\appcontainer-fixture-1212121212121212",
            ),
            adjacent_path: PathBuf::from(r"\\?\D:\a\_temp\cbt\appcontainer-adjacent-1212"),
            profile_folder: PathBuf::from(r"\\?\D:\a\profile"),
            profile_name: format!("cmux.bench.ac.{}", &nonce[..32]),
            appcontainer_sid: "S-1-15-2-1".into(),
            account_authentication_id: "0000000100000002".into(),
        };
        let exact_error = format!(
            "validate staged AppContainer target hash: {target}: read file metadata for {target}: Access is denied. (os error 5)"
        );
        let make_failure = |stage, error, account_sid, authentication_id, failure_target, hash, restricted| {
            BrokerFailureEvidence {
                schema_version: EVIDENCE_SCHEMA_VERSION,
                nonce: nonce.clone(),
                stage,
                error: error.into(),
                account_sid: Some(account_sid.into()),
                account_authentication_id: Some(authentication_id.into()),
                target: Some(failure_target),
                target_sha256: Some(hash.into()),
                restricted_token_run_started: Some(restricted),
            }
        };
        let valid = make_failure(
            BrokerFailureStage::StagingReadability,
            exact_error.clone(),
            "S-1-5-21-1",
            "0000000100000002",
            target.clone(),
            "34".repeat(32),
            false,
        );
        assert!(is_staging_readability_unavailable(
            &valid,
            &config,
            &nonce,
            "S-1-5-21-1",
            "0000000100000002",
        ));
        for invalid in [
            make_failure(
                BrokerFailureStage::ConfigValidate,
                exact_error.clone(),
                "S-1-5-21-1",
                "0000000100000002",
                target.clone(),
                "34".repeat(32),
                false,
            ),
            make_failure(
                BrokerFailureStage::StagingReadability,
                exact_error.clone(),
                "S-1-5-21-2",
                "0000000100000002",
                target.clone(),
                "34".repeat(32),
                false,
            ),
            make_failure(
                BrokerFailureStage::StagingReadability,
                exact_error.clone(),
                "S-1-5-21-1",
                "0000000100000003",
                target.clone(),
                "34".repeat(32),
                false,
            ),
            make_failure(
                BrokerFailureStage::StagingReadability,
                exact_error.clone(),
                "S-1-5-21-1",
                "0000000100000002",
                target.with_file_name("other.exe"),
                "34".repeat(32),
                false,
            ),
            make_failure(
                BrokerFailureStage::StagingReadability,
                exact_error.clone(),
                "S-1-5-21-1",
                "0000000100000002",
                target.clone(),
                "35".repeat(32),
                false,
            ),
            make_failure(
                BrokerFailureStage::StagingReadability,
                exact_error,
                "S-1-5-21-1",
                "0000000100000002",
                target,
                "34".repeat(32),
                true,
            ),
        ] {
            assert!(!is_staging_readability_unavailable(
                &invalid,
                &config,
                &nonce,
                "S-1-5-21-1",
                "0000000100000002",
            ));
        }
    }

    #[test]
    fn broker_wire_is_one_canonical_nonce_bound_line() {
        let nonce = "12".repeat(32);
        let failure = BrokerWireRecord::Failure {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.clone(),
            stage: BrokerFailureStage::ConfigValidate,
            error: "denied".into(),
            account_sid: None,
            account_authentication_id: None,
            target: None,
            target_sha256: None,
            restricted_token_run_started: None,
        };
        let encoded = encode_canonical_json_line(&failure).unwrap();

        assert!(matches!(
            parse_broker_wire_stdout(&encoded, &nonce).unwrap(),
            BrokerWireRecord::Failure { stage: BrokerFailureStage::ConfigValidate, .. }
        ));
        let mut extra = encoded.clone();
        extra.extend_from_slice(&encoded);
        assert!(parse_broker_wire_stdout(&extra, &nonce).is_err());
        assert!(parse_broker_wire_stdout(&encoded[..encoded.len() - 1], &nonce).is_err());
        assert!(parse_broker_wire_stdout(&encoded, &"34".repeat(32)).is_err());
        let mut unknown = serde_json::to_value(&failure).unwrap();
        unknown["unexpected"] = serde_json::json!(true);
        assert!(
            parse_broker_wire_stdout(&encode_canonical_json_line(&unknown).unwrap(), &nonce,)
                .is_err()
        );

        let success = BrokerWireRecord::Success {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.clone(),
            evidence: Box::new(sample_broker_evidence(&nonce)),
        };
        let encoded = encode_canonical_json_line(&success).unwrap();
        assert!(matches!(
            parse_broker_wire_stdout(&encoded, &nonce).unwrap(),
            BrokerWireRecord::Success { .. }
        ));
    }

    #[test]
    fn trusted_controller_persists_the_wire_failure_record() {
        let directory = tempfile::tempdir().unwrap();
        let requested_output = directory.path().join("preflight.json");
        let nonce = "12".repeat(32);
        let evidence = BrokerFailureEvidence {
            schema_version: EVIDENCE_SCHEMA_VERSION,
            nonce: nonce.clone(),
            stage: BrokerFailureStage::ConfigValidate,
            error: "denied".into(),
            account_sid: None,
            account_authentication_id: None,
            target: None,
            target_sha256: None,
            restricted_token_run_started: None,
        };
        assert!(persist_broker_failure(&evidence, &requested_output, &"34".repeat(32)).is_err());
        let copied = persist_broker_failure(&evidence, &requested_output, &nonce).unwrap();
        let copied: BrokerFailureEvidence = read_bounded_json(&copied, MAX_RECORD_BYTES).unwrap();
        assert_eq!(copied, evidence);
    }
}
