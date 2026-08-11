use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub const BOOTSTRAP_SCHEMA_VERSION: u32 = 8;
pub const ACCOUNT_LAUNCHER_SCHEMA_VERSION: u32 = 2;
pub const MAX_BOOTSTRAP_CONFIG_BYTES: usize = 64 * 1024;
pub const MAX_BOOTSTRAP_RECORD_BYTES: usize = 4 * 1024;
pub const CONFIG_MAGIC: [u8; 8] = *b"CMUXB001";
pub const ARM_MAGIC: [u8; 8] = *b"CMUXA001";
pub const EVENT_MAGIC: [u8; 8] = *b"CMUXE001";
pub const NATIVE_ENTRY_CHECKPOINT_MAGIC: [u8; 8] = *b"CMUXN001";
pub const ACCOUNT_LAUNCHER_CONFIG_MAGIC: [u8; 8] = *b"CMUXL001";
pub const ACCOUNT_LAUNCHER_ADOPTED_MAGIC: [u8; 8] = *b"CMUXJ001";

const CONFIG_HEADER_BYTES: usize = 120;
const ACCOUNT_LAUNCHER_CONFIG_HEADER_BYTES: usize = 144;
const RECORD_HEADER_BYTES: usize = 56;
const CONFIG_FIELD_COUNT: u32 = 8;
const ACCOUNT_LAUNCHER_CONFIG_FIELD_COUNT: u32 = 7;
const REQUIRED_HANDLE_COUNT: usize = 7;
const ACCOUNT_LAUNCHER_HANDLE_COUNT: usize = 8;
const MAX_PRODUCT_ARGUMENTS: usize = 1024;
const READY_CONFIG_CONSUMED: u32 = 1 << 0;
const READY_HANDLES_VALID: u32 = 1 << 1;
const READY_HANDLES_INHERITABLE: u32 = 1 << 2;
const READY_PRIVATE_JOB_MEMBER: u32 = 1 << 3;
const READY_TRUSTED_PATH_DENIED: u32 = 1 << 4;
const READY_BOOTSTRAP_WRITE_DENIED: u32 = 1 << 5;
const READY_SE_INCREASE_QUOTA_PRESENT: u32 = 1 << 6;
const READY_SE_INCREASE_QUOTA_ENABLED: u32 = 1 << 7;
const READY_RESTRICTED_TOKEN: u32 = 1 << 8;
const READY_RESTRICTED_LOW_INTEGRITY: u32 = 1 << 9;
const READY_RESTRICTED_NO_ENABLED_PRIVILEGES: u32 = 1 << 10;
const READY_RESTRICTED_AUTHENTICATION_MATCH: u32 = 1 << 11;
const READY_RESTRICTING_SID_MATCH: u32 = 1 << 12;
const READY_WRITE_RESTRICTED_CREATED: u32 = 1 << 13;
const READY_SYSTEM_RESTRICTING_SID_MATCH: u32 = 1 << 14;
const READY_OS_ASSIGNED_WINDOW_STATION: u32 = 1 << 15;
const READY_OS_ASSIGNED_DESKTOP: u32 = 1 << 16;
const READY_WINDOW_STATION_NONINTERACTIVE: u32 = 1 << 17;
const READY_DESKTOP_NONINTERACTIVE_DEFAULT: u32 = 1 << 18;
const READY_WINDOW_STATION_LOW_INTEGRITY: u32 = 1 << 19;
const READY_DESKTOP_LOW_INTEGRITY: u32 = 1 << 20;
const READY_RESTRICTED_DESKTOP_ACCESS: u32 = 1 << 21;
const READY_RESTRICTED_LOGON_SID_MATCH: u32 = 1 << 22;
const READY_WINDOW_STATION_LOGON_SID_DACL: u32 = 1 << 23;
const READY_DESKTOP_LOGON_SID_DACL: u32 = 1 << 24;
const READY_TOKEN_SESSION_MATCH: u32 = 1 << 25;
const READY_JOB_UI_RESTRICTIONS_MATCH: u32 = 1 << 26;
const READY_ALL_FLAGS: u32 = READY_CONFIG_CONSUMED
    | READY_HANDLES_VALID
    | READY_HANDLES_INHERITABLE
    | READY_PRIVATE_JOB_MEMBER
    | READY_TRUSTED_PATH_DENIED
    | READY_BOOTSTRAP_WRITE_DENIED
    | READY_SE_INCREASE_QUOTA_PRESENT
    | READY_SE_INCREASE_QUOTA_ENABLED
    | READY_RESTRICTED_TOKEN
    | READY_RESTRICTED_LOW_INTEGRITY
    | READY_RESTRICTED_NO_ENABLED_PRIVILEGES
    | READY_RESTRICTED_AUTHENTICATION_MATCH
    | READY_RESTRICTING_SID_MATCH
    | READY_WRITE_RESTRICTED_CREATED
    | READY_SYSTEM_RESTRICTING_SID_MATCH
    | READY_OS_ASSIGNED_WINDOW_STATION
    | READY_OS_ASSIGNED_DESKTOP
    | READY_WINDOW_STATION_NONINTERACTIVE
    | READY_DESKTOP_NONINTERACTIVE_DEFAULT
    | READY_WINDOW_STATION_LOW_INTEGRITY
    | READY_DESKTOP_LOW_INTEGRITY
    | READY_RESTRICTED_DESKTOP_ACCESS
    | READY_RESTRICTED_LOGON_SID_MATCH
    | READY_WINDOW_STATION_LOGON_SID_DACL
    | READY_DESKTOP_LOGON_SID_DACL
    | READY_TOKEN_SESSION_MATCH
    | READY_JOB_UI_RESTRICTIONS_MATCH;
const EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED: u32 = 1 << 0;
const EXIT_PRODUCT_AUTHENTICATION_MATCH: u32 = 1 << 1;
const EXIT_PRODUCT_LOW_INTEGRITY: u32 = 1 << 2;
const EXIT_PRODUCT_WRITE_RESTRICTED: u32 = 1 << 3;
const EXIT_PRODUCT_NO_ENABLED_PRIVILEGES: u32 = 1 << 4;
const EXIT_PRODUCT_RESTRICTING_SID_MATCH: u32 = 1 << 5;
const EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH: u32 = 1 << 6;
const EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH: u32 = 1 << 7;
const EXIT_PRODUCT_CREATE_NO_WINDOW: u32 = 1 << 8;
const EXIT_PRODUCT_LOGON_SID_MATCH: u32 = 1 << 9;
const EXIT_PRODUCT_SESSION_ID_MATCH: u32 = 1 << 10;
const EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY: u32 = 1 << 11;
const EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY: u32 = 1 << 12;
const EXIT_ALL_FLAGS: u32 = EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED
    | EXIT_PRODUCT_AUTHENTICATION_MATCH
    | EXIT_PRODUCT_LOW_INTEGRITY
    | EXIT_PRODUCT_WRITE_RESTRICTED
    | EXIT_PRODUCT_NO_ENABLED_PRIVILEGES
    | EXIT_PRODUCT_RESTRICTING_SID_MATCH
    | EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH
    | EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH
    | EXIT_PRODUCT_CREATE_NO_WINDOW
    | EXIT_PRODUCT_LOGON_SID_MATCH
    | EXIT_PRODUCT_SESSION_ID_MATCH
    | EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY
    | EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY;
const MAX_RESTRICTING_SID_BYTES: usize = 184;
pub const WINDOWS_WRITE_RESTRICTED_CODE_SID: &str = "S-1-5-33";
pub const WINDOWS_JOB_UI_RESTRICTION_MASK: u32 = 0xff;
pub const WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER: u32 = 0x4c4e_4348;
pub const WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER: u32 = 0x4253_5450;

const LAUNCHER_READY_CONFIG_CONSUMED: u32 = 1 << 0;
const LAUNCHER_READY_SELF_HASH_MATCH: u32 = 1 << 1;
const LAUNCHER_READY_BOOTSTRAP_HASH_MATCH: u32 = 1 << 2;
const LAUNCHER_READY_HANDLES_EXACT: u32 = 1 << 3;
const LAUNCHER_READY_HANDLE_INHERITANCE_EXACT: u32 = 1 << 4;
const LAUNCHER_READY_JOB_MEMBER: u32 = 1 << 5;
const LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH: u32 = 1 << 6;
const LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT: u32 = 1 << 7;
const LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED: u32 = 1 << 8;
const LAUNCHER_READY_SESSION_MATCH: u32 = 1 << 9;
const LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED: u32 = 1 << 10;
const LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER: u32 = 1 << 11;
const LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH: u32 = 1 << 12;
const LAUNCHER_READY_EMPTY_DESKTOP_SELECTION: u32 = 1 << 13;
const LAUNCHER_READY_CREATE_NO_WINDOW: u32 = 1 << 14;
const LAUNCHER_READY_HANDLE_LIST_EXACT: u32 = 1 << 15;
const LAUNCHER_READY_SUPERVISOR_TARGET_EXACT: u32 = 1 << 16;
const LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED: u32 = 1 << 17;
const LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED: u32 = 1 << 0;
const LAUNCHER_READY_ALL_FLAGS: u32 = LAUNCHER_READY_CONFIG_CONSUMED
    | LAUNCHER_READY_SELF_HASH_MATCH
    | LAUNCHER_READY_BOOTSTRAP_HASH_MATCH
    | LAUNCHER_READY_HANDLES_EXACT
    | LAUNCHER_READY_HANDLE_INHERITANCE_EXACT
    | LAUNCHER_READY_JOB_MEMBER
    | LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH
    | LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT
    | LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED
    | LAUNCHER_READY_SESSION_MATCH
    | LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED
    | LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER
    | LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH
    | LAUNCHER_READY_EMPTY_DESKTOP_SELECTION
    | LAUNCHER_READY_CREATE_NO_WINDOW
    | LAUNCHER_READY_HANDLE_LIST_EXACT
    | LAUNCHER_READY_SUPERVISOR_TARGET_EXACT
    | LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapProductLaunch {
    pub timing: PathBuf,
    pub fixture_root: PathBuf,
    pub target: PathBuf,
    pub target_sha256: String,
    pub product_args: Vec<String>,
    pub trusted_path_probe: PathBuf,
    pub expected_bootstrap_sha256: String,
    pub restricting_sid: String,
    pub logon_sid: String,
    pub account_token_session_id: u32,
    pub job_ui_restriction_mask: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapConfig {
    pub schema_version: u32,
    pub nonce: String,
    pub launch: BootstrapProductLaunch,
    pub control_read: usize,
    pub control_write: usize,
    pub standard_handles: [usize; 3],
    pub query_job: usize,
    pub launcher_gate: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountLauncherConfig {
    pub schema_version: u32,
    pub nonce: String,
    pub launcher_stage_marker: u32,
    pub bootstrap_stage_marker: u32,
    pub launcher: PathBuf,
    pub launcher_sha256: String,
    pub bootstrap: PathBuf,
    pub bootstrap_sha256: String,
    pub bootstrap_config: PathBuf,
    pub bootstrap_config_sha256: String,
    pub bootstrap_entry_checkpoint: PathBuf,
    pub account_token_session_id: u32,
    pub job_ui_restriction_mask: u32,
    pub control_read: usize,
    pub control_write: usize,
    pub standard_handles: [usize; 3],
    pub query_job: usize,
    pub launcher_gate: usize,
    pub supervisor_process: usize,
    pub supervisor_process_id: u32,
}

impl AccountLauncherConfig {
    pub fn validate_identity(&self, config_path: &Path) -> Result<()> {
        if self.schema_version != ACCOUNT_LAUNCHER_SCHEMA_VERSION
            || self.launcher_stage_marker != WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER
            || self.bootstrap_stage_marker != WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER
            || self.launcher_stage_marker == self.bootstrap_stage_marker
        {
            bail!("Windows account launcher stage identity changed");
        }
        validate_hex(&self.nonce, 64, "account launcher nonce")?;
        validate_hex(&self.launcher_sha256, 64, "account launcher SHA-256")?;
        validate_hex(&self.bootstrap_sha256, 64, "native bootstrap SHA-256")?;
        validate_hex(&self.bootstrap_config_sha256, 64, "native bootstrap config SHA-256")?;
        if self.launcher == self.bootstrap || self.launcher_sha256 == self.bootstrap_sha256 {
            bail!("Windows account launcher cannot launch itself as the native bootstrap");
        }
        let expected_name = format!("launcher-{}.bin", &self.nonce[..16]);
        if config_path.file_name().and_then(|name| name.to_str()) != Some(&expected_name) {
            bail!("Windows account launcher config path did not match its nonce");
        }
        let fixture_root =
            config_path.parent().context("Windows account launcher config has no parent")?;
        if !self.launcher.is_absolute()
            || !self.bootstrap.is_absolute()
            || self.launcher.starts_with(fixture_root)
            || self.bootstrap.starts_with(fixture_root)
            || self.bootstrap_config.parent() != Some(fixture_root)
            || self.bootstrap_entry_checkpoint.parent() != Some(fixture_root)
        {
            bail!("Windows account launcher paths violated their ownership boundary");
        }
        if self.job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
            bail!("Windows account launcher Job UI restriction mask changed");
        }
        if self.supervisor_process_id == 0 {
            bail!("Windows account launcher supervisor process identity changed");
        }
        let handles = [
            self.control_read,
            self.control_write,
            self.standard_handles[0],
            self.standard_handles[1],
            self.standard_handles[2],
            self.query_job,
            self.launcher_gate,
            self.supervisor_process,
        ];
        if handles.contains(&0) {
            bail!("Windows account launcher omitted a transferred handle");
        }
        for (index, handle) in handles.iter().enumerate() {
            if handles[..index].contains(handle) {
                bail!("Windows account launcher handle values were not exact and distinct");
            }
        }
        Ok(())
    }
}

impl BootstrapConfig {
    pub fn validate_identity(&self, config_path: &Path) -> Result<()> {
        if self.schema_version != BOOTSTRAP_SCHEMA_VERSION {
            bail!("Windows bootstrap config schema changed");
        }
        validate_hex(&self.nonce, 64, "bootstrap nonce")?;
        validate_hex(&self.launch.target_sha256, 64, "bootstrap target SHA-256")?;
        validate_hex(&self.launch.expected_bootstrap_sha256, 64, "bootstrap executable SHA-256")?;
        validate_restricting_sid(&self.launch.restricting_sid)?;
        validate_logon_sid(&self.launch.logon_sid)?;
        if self.launch.job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
            bail!("Windows bootstrap Job UI restriction mask changed");
        }
        let expected_name = format!("bootstrap-{}.bin", &self.nonce[..16]);
        if config_path.file_name().and_then(|name| name.to_str()) != Some(&expected_name) {
            bail!("Windows bootstrap config path did not match its nonce");
        }
        if config_path.parent() != Some(self.launch.fixture_root.as_path())
            || self.launch.timing.parent() != Some(self.launch.fixture_root.as_path())
            || self.launch.target.starts_with(&self.launch.fixture_root)
            || self.launch.trusted_path_probe.starts_with(&self.launch.fixture_root)
            || !self.launch.trusted_path_probe.is_absolute()
            || !self.launch.target.is_absolute()
        {
            bail!("Windows bootstrap config paths violated their ownership boundary");
        }
        let handles = [
            self.control_read,
            self.control_write,
            self.standard_handles[0],
            self.standard_handles[1],
            self.standard_handles[2],
            self.query_job,
            self.launcher_gate,
        ];
        if handles.contains(&0) {
            bail!("Windows bootstrap config omitted a required transferred handle");
        }
        for (index, handle) in handles.iter().enumerate() {
            if handles[..index].contains(handle) {
                bail!("Windows bootstrap handle values were not exact and distinct");
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum BootstrapChildStage {
    ConfigConsumed = 1,
    LaunchValidated = 2,
    StandardHandlesValidated = 3,
    TimingConsumed = 4,
    NativeEntryReached = 5,
    NativeConfigReadStarted = 6,
    RestrictedProductTokenReady = 7,
    OsAssignedDesktopReady = 8,
}

impl BootstrapChildStage {
    fn from_u32(value: u32) -> Result<Self> {
        match value {
            1 => Ok(Self::ConfigConsumed),
            2 => Ok(Self::LaunchValidated),
            3 => Ok(Self::StandardHandlesValidated),
            4 => Ok(Self::TimingConsumed),
            5 => Ok(Self::NativeEntryReached),
            6 => Ok(Self::NativeConfigReadStarted),
            7 => Ok(Self::RestrictedProductTokenReady),
            8 => Ok(Self::OsAssignedDesktopReady),
            _ => bail!("Windows bootstrap event contained an unknown stage"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum NativeEntryCheckpointStage {
    EntryReached = 1,
    ConfigReadStarted = 2,
    ConfigConsumed = 3,
}

pub fn decode_native_entry_checkpoint(
    bytes: &[u8],
    expected_nonce: &str,
) -> Result<NativeEntryCheckpointStage> {
    if bytes.len() != 48 {
        bail!("Windows native entry checkpoint had the wrong length");
    }
    require_magic(bytes, &NATIVE_ENTRY_CHECKPOINT_MAGIC, "native entry checkpoint")?;
    if read_u32(bytes, 8)? != BOOTSTRAP_SCHEMA_VERSION {
        bail!("Windows native entry checkpoint schema changed");
    }
    let expected_nonce = decode_hex_32(expected_nonce, "native entry checkpoint nonce")?;
    if bytes[16..48] != expected_nonce[..] {
        bail!("Windows native entry checkpoint nonce changed");
    }
    match read_u32(bytes, 12)? {
        1 => Ok(NativeEntryCheckpointStage::EntryReached),
        2 => Ok(NativeEntryCheckpointStage::ConfigReadStarted),
        3 => Ok(NativeEntryCheckpointStage::ConfigConsumed),
        _ => bail!("Windows native entry checkpoint stage changed"),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BootstrapMessage {
    AccountLauncherReady {
        nonce: String,
        launcher_sha256: String,
        bootstrap_sha256: String,
        config_consumed: bool,
        self_hash_match: bool,
        bootstrap_hash_match: bool,
        handles_exact: bool,
        handle_inheritance_exact: bool,
        private_job_member: bool,
        job_ui_restrictions_match: bool,
        se_increase_quota_present: bool,
        se_increase_quota_enabled: bool,
        session_match: bool,
        bootstrap_created_suspended: bool,
        bootstrap_private_job_member: bool,
        bootstrap_session_match: bool,
        empty_desktop_selection: bool,
        create_no_window: bool,
        handle_list_exact: bool,
        supervisor_target_exact: bool,
        bootstrap_handles_duplicated: bool,
        account_token_session_id: u32,
        launcher_token_session_id: u32,
        bootstrap_token_session_id: u32,
        job_ui_restriction_mask: u32,
        bootstrap_process_id: u32,
        bootstrap_primary_thread_id: u32,
        supervisor_process_id: u32,
        launcher_process_id: u32,
        bootstrap_process_handle: u64,
        bootstrap_primary_thread_handle: u64,
    },
    AccountLauncherExit {
        nonce: String,
        bootstrap_exit_code: u32,
        bootstrap_resume_previous_count: u32,
        bootstrap_process_id: u32,
    },
    AccountLauncherResumed {
        nonce: String,
        bootstrap_resume_previous_count: u32,
        bootstrap_process_id: u32,
        adoption_acknowledged: bool,
    },
    AccountLauncherError {
        nonce: String,
        windows_error: u32,
        stage: u32,
    },
    Stage {
        nonce: String,
        stage: BootstrapChildStage,
    },
    Ready {
        nonce: String,
        bootstrap_sha256: String,
        config_consumed: bool,
        standard_handles_valid: bool,
        standard_handles_inheritable: bool,
        private_job_member: bool,
        trusted_path_write_denied: bool,
        bootstrap_write_denied: bool,
        se_increase_quota_present: bool,
        se_increase_quota_enabled: bool,
        restricted_token: bool,
        restricted_low_integrity: bool,
        restricted_no_enabled_privileges: bool,
        restricted_authentication_match: bool,
        restricting_sid_match: bool,
        write_restricted_created: bool,
        system_restricting_sid_match: bool,
        os_assigned_window_station: bool,
        os_assigned_desktop: bool,
        window_station_noninteractive: bool,
        desktop_noninteractive_default: bool,
        window_station_low_integrity: bool,
        desktop_low_integrity: bool,
        restricted_desktop_access: bool,
        restricted_logon_sid_match: bool,
        window_station_logon_sid_dacl: bool,
        desktop_logon_sid_dacl: bool,
        token_session_match: bool,
        job_ui_restrictions_match: bool,
        broker_authentication_id: AuthenticationId,
        restricted_authentication_id: AuthenticationId,
        account_token_session_id: u32,
        bootstrap_token_session_id: u32,
        restricted_token_session_id: u32,
        job_ui_restriction_mask: u32,
        restricting_sid: String,
        logon_sid: String,
        observed_window_station: String,
        observed_desktop: String,
    },
    Exit {
        nonce: String,
        code: u32,
        private_job_descendant_contained: bool,
        create_process_as_user_succeeded: bool,
        product_authentication_match: bool,
        product_low_integrity: bool,
        product_write_restricted: bool,
        product_no_enabled_privileges: bool,
        product_restricting_sid_match: bool,
        product_system_restricting_sid_match: bool,
        product_desktop_assignment_match: bool,
        product_create_no_window: bool,
        product_logon_sid_match: bool,
        product_session_id_match: bool,
        product_window_station_low_integrity: bool,
        product_desktop_low_integrity: bool,
        product_authentication_id: AuthenticationId,
        product_token_session_id: u32,
    },
    ProductStarted {
        nonce: String,
        private_job_descendant_contained: bool,
        create_process_as_user_succeeded: bool,
        product_authentication_match: bool,
        product_low_integrity: bool,
        product_write_restricted: bool,
        product_no_enabled_privileges: bool,
        product_restricting_sid_match: bool,
        product_system_restricting_sid_match: bool,
        product_desktop_assignment_match: bool,
        product_create_no_window: bool,
        product_logon_sid_match: bool,
        product_session_id_match: bool,
        product_window_station_low_integrity: bool,
        product_desktop_low_integrity: bool,
        product_authentication_id: AuthenticationId,
        product_token_session_id: u32,
        resume_previous_count: u32,
    },
    Error {
        nonce: String,
        windows_error: u32,
        stage: u32,
    },
}

pub fn validate_account_launcher_ready_message(
    message: &BootstrapMessage,
    expected_nonce: &str,
    expected_launcher_sha256: &str,
    expected_bootstrap_sha256: &str,
    expected_session_id: u32,
    expected_supervisor_process_id: u32,
    expected_launcher_process_id: u32,
) -> Result<()> {
    let BootstrapMessage::AccountLauncherReady {
        nonce,
        launcher_sha256,
        bootstrap_sha256,
        config_consumed,
        self_hash_match,
        bootstrap_hash_match,
        handles_exact,
        handle_inheritance_exact,
        private_job_member,
        job_ui_restrictions_match,
        se_increase_quota_present,
        se_increase_quota_enabled,
        session_match,
        bootstrap_created_suspended,
        bootstrap_private_job_member,
        bootstrap_session_match,
        empty_desktop_selection,
        create_no_window,
        handle_list_exact,
        supervisor_target_exact,
        bootstrap_handles_duplicated,
        account_token_session_id,
        launcher_token_session_id,
        bootstrap_token_session_id,
        job_ui_restriction_mask,
        bootstrap_process_id,
        bootstrap_primary_thread_id,
        supervisor_process_id,
        launcher_process_id,
        bootstrap_process_handle,
        bootstrap_primary_thread_handle,
    } = message
    else {
        bail!("Windows account launcher readiness record had the wrong stage");
    };
    if nonce != expected_nonce
        || launcher_sha256 != expected_launcher_sha256
        || bootstrap_sha256 != expected_bootstrap_sha256
        || !config_consumed
        || !self_hash_match
        || !bootstrap_hash_match
        || !handles_exact
        || !handle_inheritance_exact
        || !private_job_member
        || !job_ui_restrictions_match
        || !se_increase_quota_present
        || !se_increase_quota_enabled
        || !session_match
        || !bootstrap_created_suspended
        || !bootstrap_private_job_member
        || !bootstrap_session_match
        || !empty_desktop_selection
        || !create_no_window
        || !handle_list_exact
        || !supervisor_target_exact
        || !bootstrap_handles_duplicated
        || *account_token_session_id != expected_session_id
        || *launcher_token_session_id != expected_session_id
        || *bootstrap_token_session_id != expected_session_id
        || *job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK
        || *bootstrap_process_id == 0
        || *bootstrap_primary_thread_id == 0
        || *supervisor_process_id != expected_supervisor_process_id
        || *launcher_process_id != expected_launcher_process_id
        || *bootstrap_process_handle == 0
        || *bootstrap_primary_thread_handle == 0
        || bootstrap_process_handle == bootstrap_primary_thread_handle
    {
        bail!("Windows account launcher readiness or adoption proof failed");
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthenticationId {
    pub low_part: u32,
    pub high_part: i32,
}

impl AuthenticationId {
    pub fn evidence_value(self) -> String {
        format!("{:08x}{:08x}", self.high_part as u32, self.low_part)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapLaunchEvidence {
    pub schema_version: u32,
    pub account_launcher_sha256: String,
    pub bootstrap_sha256: String,
    pub config_nonce: String,
    pub config_consumed: bool,
    pub account_launcher_config_consumed: bool,
    pub account_launcher_ready_before_bootstrap: bool,
    pub account_launcher_resume_previous_count: u32,
    pub bootstrap_resume_previous_count: u32,
    pub account_launcher_create_no_window: bool,
    pub account_launcher_private_job_member: bool,
    pub account_launcher_handles_exact: bool,
    pub account_launcher_handle_inheritance_exact: bool,
    pub account_launcher_supervisor_target_exact: bool,
    pub account_launcher_se_increase_quota_present: bool,
    pub account_launcher_se_increase_quota_enabled: bool,
    pub account_launcher_token_session_id: u32,
    pub bootstrap_created_suspended: bool,
    pub bootstrap_created_with_create_process_as_user: bool,
    pub bootstrap_empty_desktop_selection: bool,
    pub bootstrap_explicit_handle_list: bool,
    pub bootstrap_process_id: u32,
    pub bootstrap_primary_thread_id: u32,
    pub bootstrap_remote_handles_adopted: bool,
    pub bootstrap_adoption_acknowledged_before_resume: bool,
    pub bootstrap_handle_types_exact: bool,
    pub bootstrap_image_identity_verified: bool,
    pub bootstrap_exact_job_before_resume: bool,
    pub bootstrap_account_token_identity_verified: bool,
    pub bootstrap_suspended_state_verified: bool,
    pub ready_elapsed_ms: u64,
    pub exact_job_proof: bool,
    pub trusted_path_write_denied: bool,
    pub bootstrap_write_denied: bool,
    pub account_sid: String,
    pub restricting_sid: String,
    pub system_restricting_sid: String,
    pub logon_sid: String,
    pub observed_window_station: String,
    pub observed_desktop: String,
    pub os_assigned_desktop_ready_before_resume: bool,
    pub window_station_noninteractive: bool,
    pub desktop_noninteractive_default: bool,
    pub bootstrap_create_no_window: bool,
    pub broker_authentication_id: String,
    pub restricted_authentication_id: String,
    pub product_authentication_id: String,
    pub account_token_session_id: u32,
    pub bootstrap_token_session_id: u32,
    pub restricted_token_session_id: u32,
    pub product_token_session_id: u32,
    pub token_session_ids_match: bool,
    pub restricted_authentication_matches_broker: bool,
    pub product_authentication_matches_broker: bool,
    pub se_increase_quota_present: bool,
    pub se_increase_quota_enabled: bool,
    pub create_process_as_user_succeeded: bool,
    pub restricted_token_write_restricted: bool,
    pub restricted_token_restricting_sid_match: bool,
    pub restricted_token_system_restricting_sid_match: bool,
    pub restricted_token_logon_sid_match: bool,
    pub restricted_token_low_integrity: bool,
    pub restricted_token_no_enabled_privileges: bool,
    pub window_station_logon_sid_dacl_proven: bool,
    pub desktop_logon_sid_dacl_proven: bool,
    pub window_station_low_integrity: bool,
    pub desktop_low_integrity: bool,
    pub restricted_desktop_access_proven: bool,
    pub job_ui_restriction_mask: u32,
    pub job_ui_restrictions_exact_before_resume: bool,
    pub product_write_restricted: bool,
    pub product_restricting_sid_match: bool,
    pub product_system_restricting_sid_match: bool,
    pub product_logon_sid_match: bool,
    pub product_low_integrity: bool,
    pub product_no_enabled_privileges: bool,
    pub product_exact_job: bool,
    pub product_desktop_assignment_match: bool,
    pub product_window_station_low_integrity: bool,
    pub product_desktop_low_integrity: bool,
    pub product_create_no_window: bool,
    pub product_resume_previous_count: u32,
}

impl BootstrapLaunchEvidence {
    pub fn validate(&self, expected_nonce: &str, expected_bootstrap_sha256: &str) -> Result<()> {
        if self.schema_version != BOOTSTRAP_SCHEMA_VERSION
            || self.config_nonce != expected_nonce
            || self.bootstrap_sha256 != expected_bootstrap_sha256
            || !self.config_consumed
            || !self.account_launcher_config_consumed
            || !self.account_launcher_ready_before_bootstrap
            || self.account_launcher_resume_previous_count != 1
            || self.bootstrap_resume_previous_count != 1
            || !self.account_launcher_create_no_window
            || !self.account_launcher_private_job_member
            || !self.account_launcher_handles_exact
            || !self.account_launcher_handle_inheritance_exact
            || !self.account_launcher_supervisor_target_exact
            || !self.account_launcher_se_increase_quota_present
            || !self.account_launcher_se_increase_quota_enabled
            || self.account_launcher_token_session_id != self.account_token_session_id
            || !self.bootstrap_created_suspended
            || !self.bootstrap_created_with_create_process_as_user
            || !self.bootstrap_empty_desktop_selection
            || !self.bootstrap_explicit_handle_list
            || self.bootstrap_process_id == 0
            || self.bootstrap_primary_thread_id == 0
            || !self.bootstrap_remote_handles_adopted
            || !self.bootstrap_adoption_acknowledged_before_resume
            || !self.bootstrap_handle_types_exact
            || !self.bootstrap_image_identity_verified
            || !self.bootstrap_exact_job_before_resume
            || !self.bootstrap_account_token_identity_verified
            || !self.bootstrap_suspended_state_verified
            || self.ready_elapsed_ms > 30_000
            || !self.exact_job_proof
            || !self.trusted_path_write_denied
            || !self.bootstrap_write_denied
            || self.broker_authentication_id != self.restricted_authentication_id
            || self.broker_authentication_id != self.product_authentication_id
            || !self.restricted_authentication_matches_broker
            || !self.product_authentication_matches_broker
            || !self.se_increase_quota_present
            || !self.se_increase_quota_enabled
            || !self.create_process_as_user_succeeded
            || !self.restricted_token_write_restricted
            || !self.restricted_token_restricting_sid_match
            || !self.restricted_token_system_restricting_sid_match
            || !self.restricted_token_logon_sid_match
            || !self.restricted_token_low_integrity
            || !self.restricted_token_no_enabled_privileges
            || self.system_restricting_sid != WINDOWS_WRITE_RESTRICTED_CODE_SID
            || validate_os_assigned_desktop_identity(
                &self.observed_window_station,
                &self.observed_desktop,
            )
            .is_err()
            || !self.os_assigned_desktop_ready_before_resume
            || !self.window_station_noninteractive
            || !self.desktop_noninteractive_default
            || !self.bootstrap_create_no_window
            || !self.window_station_logon_sid_dacl_proven
            || !self.desktop_logon_sid_dacl_proven
            || !self.window_station_low_integrity
            || !self.desktop_low_integrity
            || !self.restricted_desktop_access_proven
            || self.job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK
            || !self.job_ui_restrictions_exact_before_resume
            || !self.token_session_ids_match
            || self.account_token_session_id != self.bootstrap_token_session_id
            || self.account_token_session_id != self.restricted_token_session_id
            || self.account_token_session_id != self.product_token_session_id
            || !self.product_write_restricted
            || !self.product_restricting_sid_match
            || !self.product_system_restricting_sid_match
            || !self.product_logon_sid_match
            || !self.product_low_integrity
            || !self.product_no_enabled_privileges
            || !self.product_exact_job
            || !self.product_desktop_assignment_match
            || !self.product_window_station_low_integrity
            || !self.product_desktop_low_integrity
            || !self.product_create_no_window
            || self.product_resume_previous_count != 1
        {
            bail!("Windows bootstrap evidence identity or containment proof failed");
        }
        validate_hex(&self.config_nonce, 64, "bootstrap evidence nonce")?;
        validate_hex(
            &self.account_launcher_sha256,
            64,
            "account launcher evidence executable SHA-256",
        )?;
        validate_hex(&self.bootstrap_sha256, 64, "bootstrap evidence executable SHA-256")?;
        validate_hex(&self.broker_authentication_id, 16, "broker authentication ID")?;
        validate_hex(&self.restricted_authentication_id, 16, "restricted authentication ID")?;
        validate_hex(&self.product_authentication_id, 16, "product authentication ID")?;
        validate_restricting_sid(&self.account_sid)?;
        validate_restricting_sid(&self.restricting_sid)?;
        validate_logon_sid(&self.logon_sid)
    }
}

pub fn validate_os_assigned_desktop_identity(station: &str, desktop: &str) -> Result<()> {
    if station.is_empty()
        || station.eq_ignore_ascii_case("WinSta0")
        || station.contains('\\')
        || !desktop.eq_ignore_ascii_case("Default")
    {
        bail!("Windows bootstrap did not use an OS-assigned noninteractive default desktop");
    }
    Ok(())
}

pub fn encode_account_launcher_config(config: &AccountLauncherConfig) -> Result<Vec<u8>> {
    if config.schema_version != ACCOUNT_LAUNCHER_SCHEMA_VERSION {
        bail!("Windows account launcher config schema changed");
    }
    let nonce = decode_hex_32(&config.nonce, "account launcher nonce")?;
    validate_hex(&config.launcher_sha256, 64, "account launcher SHA-256")?;
    validate_hex(&config.bootstrap_sha256, 64, "native bootstrap SHA-256")?;
    validate_hex(&config.bootstrap_config_sha256, 64, "native bootstrap config SHA-256")?;
    if config.launcher_stage_marker != WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER
        || config.bootstrap_stage_marker != WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER
        || config.launcher_stage_marker == config.bootstrap_stage_marker
    {
        bail!("Windows account launcher stage markers changed");
    }
    if config.launcher == config.bootstrap || config.launcher_sha256 == config.bootstrap_sha256 {
        bail!("Windows account launcher cannot launch itself as the native bootstrap");
    }
    if config.job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
        bail!("Windows account launcher Job UI restriction mask changed");
    }
    if config.supervisor_process_id == 0 {
        bail!("Windows account launcher supervisor process identity changed");
    }
    let handles = [
        config.control_read,
        config.control_write,
        config.standard_handles[0],
        config.standard_handles[1],
        config.standard_handles[2],
        config.query_job,
        config.launcher_gate,
        config.supervisor_process,
    ];
    if handles.contains(&0) {
        bail!("Windows account launcher omitted a transferred handle");
    }
    for (index, handle) in handles.iter().enumerate() {
        if handles[..index].contains(handle) {
            bail!("Windows account launcher handle values were not exact and distinct");
        }
    }
    let mut bytes = vec![0; ACCOUNT_LAUNCHER_CONFIG_HEADER_BYTES];
    bytes[..8].copy_from_slice(&ACCOUNT_LAUNCHER_CONFIG_MAGIC);
    put_u32(&mut bytes, 8, ACCOUNT_LAUNCHER_SCHEMA_VERSION)?;
    put_u32(&mut bytes, 16, ACCOUNT_LAUNCHER_CONFIG_FIELD_COUNT)?;
    put_u32(&mut bytes, 20, config.launcher_stage_marker)?;
    put_u32(&mut bytes, 24, config.bootstrap_stage_marker)?;
    bytes[32..64].copy_from_slice(&nonce);
    for (index, handle) in handles.into_iter().enumerate() {
        put_u64(&mut bytes, 64 + index * 8, u64::try_from(handle)?)?;
    }
    put_u32(&mut bytes, 128, config.account_token_session_id)?;
    put_u32(&mut bytes, 132, config.job_ui_restriction_mask)?;
    put_u32(&mut bytes, 136, config.supervisor_process_id)?;
    push_path(&mut bytes, &config.launcher)?;
    push_bytes(&mut bytes, config.launcher_sha256.as_bytes())?;
    push_path(&mut bytes, &config.bootstrap)?;
    push_bytes(&mut bytes, config.bootstrap_sha256.as_bytes())?;
    push_path(&mut bytes, &config.bootstrap_config)?;
    push_bytes(&mut bytes, config.bootstrap_config_sha256.as_bytes())?;
    push_path(&mut bytes, &config.bootstrap_entry_checkpoint)?;
    if bytes.len() > MAX_BOOTSTRAP_CONFIG_BYTES {
        bail!("Windows account launcher config exceeded its bound");
    }
    let total = u32::try_from(bytes.len())?;
    put_u32(&mut bytes, 12, total)?;
    Ok(bytes)
}

pub fn decode_account_launcher_config(bytes: &[u8]) -> Result<AccountLauncherConfig> {
    if bytes.len() < ACCOUNT_LAUNCHER_CONFIG_HEADER_BYTES
        || bytes.len() > MAX_BOOTSTRAP_CONFIG_BYTES
    {
        bail!("Windows account launcher config had an invalid length");
    }
    require_magic(bytes, &ACCOUNT_LAUNCHER_CONFIG_MAGIC, "account launcher config")?;
    if read_u32(bytes, 8)? != ACCOUNT_LAUNCHER_SCHEMA_VERSION
        || usize::try_from(read_u32(bytes, 12)?)? != bytes.len()
        || read_u32(bytes, 16)? != ACCOUNT_LAUNCHER_CONFIG_FIELD_COUNT
        || read_u32(bytes, 28)? != 0
    {
        bail!("Windows account launcher config header changed");
    }
    let launcher_stage_marker = read_u32(bytes, 20)?;
    let bootstrap_stage_marker = read_u32(bytes, 24)?;
    if launcher_stage_marker != WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER
        || bootstrap_stage_marker != WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER
        || launcher_stage_marker == bootstrap_stage_marker
    {
        bail!("Windows account launcher stage markers changed");
    }
    let nonce = encode_hex(&bytes[32..64]);
    let mut handles = [0_usize; ACCOUNT_LAUNCHER_HANDLE_COUNT];
    for (index, handle) in handles.iter_mut().enumerate() {
        *handle = usize::try_from(read_u64(bytes, 64 + index * 8)?)?;
    }
    if handles.contains(&0) {
        bail!("Windows account launcher omitted a transferred handle");
    }
    for (index, handle) in handles.iter().enumerate() {
        if handles[..index].contains(handle) {
            bail!("Windows account launcher handle values were not exact and distinct");
        }
    }
    let account_token_session_id = read_u32(bytes, 128)?;
    let job_ui_restriction_mask = read_u32(bytes, 132)?;
    let supervisor_process_id = read_u32(bytes, 136)?;
    if supervisor_process_id == 0 || read_u32(bytes, 140)? != 0 {
        bail!("Windows account launcher supervisor process identity changed");
    }
    if job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
        bail!("Windows account launcher Job UI restriction mask changed");
    }
    let mut cursor = ACCOUNT_LAUNCHER_CONFIG_HEADER_BYTES;
    let launcher = take_path(bytes, &mut cursor)?;
    let launcher_sha256 = take_ascii(bytes, &mut cursor, 64, "account launcher SHA-256")?;
    let bootstrap = take_path(bytes, &mut cursor)?;
    let bootstrap_sha256 = take_ascii(bytes, &mut cursor, 64, "native bootstrap SHA-256")?;
    let bootstrap_config = take_path(bytes, &mut cursor)?;
    let bootstrap_config_sha256 =
        take_ascii(bytes, &mut cursor, 64, "native bootstrap config SHA-256")?;
    let bootstrap_entry_checkpoint = take_path(bytes, &mut cursor)?;
    if cursor != bytes.len() {
        bail!("Windows account launcher config contained trailing data");
    }
    if launcher == bootstrap || launcher_sha256 == bootstrap_sha256 {
        bail!("Windows account launcher cannot launch itself as the native bootstrap");
    }
    Ok(AccountLauncherConfig {
        schema_version: ACCOUNT_LAUNCHER_SCHEMA_VERSION,
        nonce,
        launcher_stage_marker,
        bootstrap_stage_marker,
        launcher,
        launcher_sha256,
        bootstrap,
        bootstrap_sha256,
        bootstrap_config,
        bootstrap_config_sha256,
        bootstrap_entry_checkpoint,
        account_token_session_id,
        job_ui_restriction_mask,
        control_read: handles[0],
        control_write: handles[1],
        standard_handles: [handles[2], handles[3], handles[4]],
        query_job: handles[5],
        launcher_gate: handles[6],
        supervisor_process: handles[7],
        supervisor_process_id,
    })
}

pub fn encode_config(config: &BootstrapConfig) -> Result<Vec<u8>> {
    if config.schema_version != BOOTSTRAP_SCHEMA_VERSION {
        bail!("Windows bootstrap config schema changed");
    }
    let nonce = decode_hex_32(&config.nonce, "bootstrap nonce")?;
    validate_hex(&config.launch.target_sha256, 64, "bootstrap target SHA-256")?;
    validate_hex(&config.launch.expected_bootstrap_sha256, 64, "bootstrap executable SHA-256")?;
    validate_restricting_sid(&config.launch.restricting_sid)?;
    validate_logon_sid(&config.launch.logon_sid)?;
    if config.launch.job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
        bail!("Windows bootstrap Job UI restriction mask changed");
    }
    let handles = [
        config.control_read,
        config.control_write,
        config.standard_handles[0],
        config.standard_handles[1],
        config.standard_handles[2],
        config.query_job,
        config.launcher_gate,
    ];
    if handles.contains(&0) {
        bail!("Windows bootstrap config omitted a required transferred handle");
    }
    if config.launch.product_args.len() > MAX_PRODUCT_ARGUMENTS {
        bail!("Windows bootstrap config had too many product arguments");
    }
    let mut bytes = vec![0; CONFIG_HEADER_BYTES];
    bytes[..8].copy_from_slice(&CONFIG_MAGIC);
    put_u32(&mut bytes, 8, BOOTSTRAP_SCHEMA_VERSION)?;
    put_u32(&mut bytes, 16, CONFIG_FIELD_COUNT)?;
    put_u32(&mut bytes, 20, u32::try_from(config.launch.product_args.len())?)?;
    bytes[24..56].copy_from_slice(&nonce);
    for (index, handle) in handles.into_iter().enumerate() {
        put_u64(&mut bytes, 56 + index * 8, u64::try_from(handle)?)?;
    }
    put_u32(&mut bytes, 112, config.launch.account_token_session_id)?;
    put_u32(&mut bytes, 116, config.launch.job_ui_restriction_mask)?;
    push_path(&mut bytes, &config.launch.timing)?;
    push_path(&mut bytes, &config.launch.fixture_root)?;
    push_path(&mut bytes, &config.launch.target)?;
    push_bytes(&mut bytes, config.launch.target_sha256.as_bytes())?;
    push_path(&mut bytes, &config.launch.trusted_path_probe)?;
    push_bytes(&mut bytes, config.launch.expected_bootstrap_sha256.as_bytes())?;
    push_bytes(&mut bytes, config.launch.restricting_sid.as_bytes())?;
    push_bytes(&mut bytes, config.launch.logon_sid.as_bytes())?;
    for argument in &config.launch.product_args {
        push_utf16(&mut bytes, argument)?;
    }
    if bytes.len() > MAX_BOOTSTRAP_CONFIG_BYTES {
        bail!("Windows bootstrap config exceeded its bound");
    }
    let total = u32::try_from(bytes.len())?;
    put_u32(&mut bytes, 12, total)?;
    Ok(bytes)
}

pub fn decode_config(bytes: &[u8]) -> Result<BootstrapConfig> {
    if bytes.len() < CONFIG_HEADER_BYTES || bytes.len() > MAX_BOOTSTRAP_CONFIG_BYTES {
        bail!("Windows bootstrap config had an invalid length");
    }
    require_magic(bytes, &CONFIG_MAGIC, "config")?;
    if read_u32(bytes, 8)? != BOOTSTRAP_SCHEMA_VERSION
        || usize::try_from(read_u32(bytes, 12)?)? != bytes.len()
        || read_u32(bytes, 16)? != CONFIG_FIELD_COUNT
    {
        bail!("Windows bootstrap config header changed");
    }
    let arg_count = usize::try_from(read_u32(bytes, 20)?)?;
    if arg_count > MAX_PRODUCT_ARGUMENTS {
        bail!("Windows bootstrap config had too many product arguments");
    }
    let nonce = encode_hex(&bytes[24..56]);
    let mut handles = [0_usize; REQUIRED_HANDLE_COUNT];
    for (index, handle) in handles.iter_mut().enumerate() {
        *handle = usize::try_from(read_u64(bytes, 56 + index * 8)?)?;
    }
    if handles.contains(&0) {
        bail!("Windows bootstrap config omitted a required transferred handle");
    }
    let account_token_session_id = read_u32(bytes, 112)?;
    let job_ui_restriction_mask = read_u32(bytes, 116)?;
    if job_ui_restriction_mask != WINDOWS_JOB_UI_RESTRICTION_MASK {
        bail!("Windows bootstrap Job UI restriction mask changed");
    }
    let mut cursor = CONFIG_HEADER_BYTES;
    let timing = take_path(bytes, &mut cursor)?;
    let fixture_root = take_path(bytes, &mut cursor)?;
    let target = take_path(bytes, &mut cursor)?;
    let target_sha256 = take_ascii(bytes, &mut cursor, 64, "target SHA-256")?;
    let trusted_path_probe = take_path(bytes, &mut cursor)?;
    let expected_bootstrap_sha256 = take_ascii(bytes, &mut cursor, 64, "bootstrap SHA-256")?;
    let restricting_sid =
        take_ascii_variable(bytes, &mut cursor, MAX_RESTRICTING_SID_BYTES, "restricting SID")?;
    validate_restricting_sid(&restricting_sid)?;
    let logon_sid =
        take_ascii_variable(bytes, &mut cursor, MAX_RESTRICTING_SID_BYTES, "logon SID")?;
    validate_logon_sid(&logon_sid)?;
    let mut product_args = Vec::with_capacity(arg_count);
    for _ in 0..arg_count {
        product_args.push(take_utf16_string(bytes, &mut cursor)?);
    }
    if cursor != bytes.len() {
        bail!("Windows bootstrap config contained trailing data");
    }
    Ok(BootstrapConfig {
        schema_version: BOOTSTRAP_SCHEMA_VERSION,
        nonce,
        launch: BootstrapProductLaunch {
            timing,
            fixture_root,
            target,
            target_sha256,
            product_args,
            trusted_path_probe,
            expected_bootstrap_sha256,
            restricting_sid,
            logon_sid,
            account_token_session_id,
            job_ui_restriction_mask,
        },
        control_read: handles[0],
        control_write: handles[1],
        standard_handles: [handles[2], handles[3], handles[4]],
        query_job: handles[5],
        launcher_gate: handles[6],
    })
}

pub fn encode_arm(nonce: &str) -> Result<Vec<u8>> {
    let nonce = decode_hex_32(nonce, "bootstrap ARM nonce")?;
    let mut bytes = vec![0; 48];
    bytes[..8].copy_from_slice(&ARM_MAGIC);
    put_u32(&mut bytes, 8, BOOTSTRAP_SCHEMA_VERSION)?;
    put_u32(&mut bytes, 12, 48)?;
    bytes[16..48].copy_from_slice(&nonce);
    Ok(bytes)
}

pub fn encode_account_launcher_adopted(nonce: &str) -> Result<Vec<u8>> {
    let nonce = decode_hex_32(nonce, "account launcher adoption nonce")?;
    let mut bytes = vec![0; 48];
    bytes[..8].copy_from_slice(&ACCOUNT_LAUNCHER_ADOPTED_MAGIC);
    put_u32(&mut bytes, 8, BOOTSTRAP_SCHEMA_VERSION)?;
    put_u32(&mut bytes, 12, 48)?;
    bytes[16..48].copy_from_slice(&nonce);
    Ok(bytes)
}

pub fn decode_arm(bytes: &[u8]) -> Result<String> {
    if bytes.len() != 48 {
        bail!("Windows bootstrap ARM record had the wrong length");
    }
    require_magic(bytes, &ARM_MAGIC, "ARM")?;
    if read_u32(bytes, 8)? != BOOTSTRAP_SCHEMA_VERSION || read_u32(bytes, 12)? != 48 {
        bail!("Windows bootstrap ARM record header changed");
    }
    Ok(encode_hex(&bytes[16..48]))
}

pub fn read_event(reader: &mut impl Read) -> Result<Option<BootstrapMessage>> {
    let mut header = [0_u8; RECORD_HEADER_BYTES];
    let mut first = [0_u8; 1];
    match reader.read_exact(&mut first) {
        Ok(()) => header[0] = first[0],
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error).context("read Windows bootstrap event prefix"),
    }
    reader.read_exact(&mut header[1..]).context("read Windows bootstrap event header")?;
    require_magic(&header, &EVENT_MAGIC, "event")?;
    if read_u32(&header, 8)? != BOOTSTRAP_SCHEMA_VERSION {
        bail!("Windows bootstrap event schema changed");
    }
    let total = usize::try_from(read_u32(&header, 12)?)?;
    if !(RECORD_HEADER_BYTES..=MAX_BOOTSTRAP_RECORD_BYTES).contains(&total) {
        bail!("Windows bootstrap event exceeded its bound");
    }
    let mut bytes = Vec::with_capacity(total);
    bytes.extend_from_slice(&header);
    bytes.resize(total, 0);
    reader
        .read_exact(&mut bytes[RECORD_HEADER_BYTES..])
        .context("read Windows bootstrap event payload")?;
    decode_event(&bytes).map(Some)
}

pub fn decode_event(bytes: &[u8]) -> Result<BootstrapMessage> {
    if bytes.len() < RECORD_HEADER_BYTES || bytes.len() > MAX_BOOTSTRAP_RECORD_BYTES {
        bail!("Windows bootstrap event had an invalid length");
    }
    require_magic(bytes, &EVENT_MAGIC, "event")?;
    if read_u32(bytes, 8)? != BOOTSTRAP_SCHEMA_VERSION
        || usize::try_from(read_u32(bytes, 12)?)? != bytes.len()
    {
        bail!("Windows bootstrap event header changed");
    }
    let event_type = read_u32(bytes, 16)?;
    let flags = read_u32(bytes, 20)?;
    let nonce = encode_hex(&bytes[24..56]);
    match event_type {
        6 if bytes.len() == 168 && flags & !LAUNCHER_READY_ALL_FLAGS == 0 => {
            Ok(BootstrapMessage::AccountLauncherReady {
                nonce,
                launcher_sha256: encode_hex(&bytes[56..88]),
                bootstrap_sha256: encode_hex(&bytes[88..120]),
                config_consumed: flags & LAUNCHER_READY_CONFIG_CONSUMED != 0,
                self_hash_match: flags & LAUNCHER_READY_SELF_HASH_MATCH != 0,
                bootstrap_hash_match: flags & LAUNCHER_READY_BOOTSTRAP_HASH_MATCH != 0,
                handles_exact: flags & LAUNCHER_READY_HANDLES_EXACT != 0,
                handle_inheritance_exact: flags & LAUNCHER_READY_HANDLE_INHERITANCE_EXACT != 0,
                private_job_member: flags & LAUNCHER_READY_JOB_MEMBER != 0,
                job_ui_restrictions_match: flags & LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH != 0,
                se_increase_quota_present: flags & LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT != 0,
                se_increase_quota_enabled: flags & LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED != 0,
                session_match: flags & LAUNCHER_READY_SESSION_MATCH != 0,
                bootstrap_created_suspended: flags & LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED
                    != 0,
                bootstrap_private_job_member: flags & LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER != 0,
                bootstrap_session_match: flags & LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH != 0,
                empty_desktop_selection: flags & LAUNCHER_READY_EMPTY_DESKTOP_SELECTION != 0,
                create_no_window: flags & LAUNCHER_READY_CREATE_NO_WINDOW != 0,
                handle_list_exact: flags & LAUNCHER_READY_HANDLE_LIST_EXACT != 0,
                supervisor_target_exact: flags & LAUNCHER_READY_SUPERVISOR_TARGET_EXACT != 0,
                bootstrap_handles_duplicated: flags & LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED
                    != 0,
                account_token_session_id: read_u32(bytes, 120)?,
                launcher_token_session_id: read_u32(bytes, 124)?,
                bootstrap_token_session_id: read_u32(bytes, 128)?,
                job_ui_restriction_mask: read_u32(bytes, 132)?,
                bootstrap_process_id: read_u32(bytes, 136)?,
                bootstrap_primary_thread_id: read_u32(bytes, 140)?,
                supervisor_process_id: read_u32(bytes, 144)?,
                launcher_process_id: read_u32(bytes, 148)?,
                bootstrap_process_handle: read_u64(bytes, 152)?,
                bootstrap_primary_thread_handle: read_u64(bytes, 160)?,
            })
        }
        7 if bytes.len() == 68 && flags == 0 => Ok(BootstrapMessage::AccountLauncherExit {
            nonce,
            bootstrap_exit_code: read_u32(bytes, 56)?,
            bootstrap_resume_previous_count: read_u32(bytes, 60)?,
            bootstrap_process_id: read_u32(bytes, 64)?,
        }),
        8 if bytes.len() == 64 && flags == 0 => Ok(BootstrapMessage::AccountLauncherError {
            nonce,
            windows_error: read_u32(bytes, 56)?,
            stage: read_u32(bytes, 60)?,
        }),
        9 if bytes.len() == 64 && flags & !LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED == 0 => {
            Ok(BootstrapMessage::AccountLauncherResumed {
                nonce,
                bootstrap_resume_previous_count: read_u32(bytes, 56)?,
                bootstrap_process_id: read_u32(bytes, 60)?,
                adoption_acknowledged: flags & LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED != 0,
            })
        }
        1 if bytes.len() == 60 && flags == 0 => Ok(BootstrapMessage::Stage {
            nonce,
            stage: BootstrapChildStage::from_u32(read_u32(bytes, 56)?)?,
        }),
        2 if bytes.len() >= 136 && flags & !READY_ALL_FLAGS == 0 => {
            let sid_length = usize::try_from(read_u32(bytes, 120)?)?;
            let logon_sid_length = usize::try_from(read_u32(bytes, 124)?)?;
            let station_length = usize::try_from(read_u32(bytes, 128)?)?;
            let desktop_length = usize::try_from(read_u32(bytes, 132)?)?;
            if sid_length == 0
                || sid_length > MAX_RESTRICTING_SID_BYTES
                || logon_sid_length == 0
                || logon_sid_length > MAX_RESTRICTING_SID_BYTES
                || station_length == 0
                || desktop_length == 0
                || bytes.len()
                    != 136 + sid_length + logon_sid_length + station_length + desktop_length
            {
                bail!("Windows bootstrap READY identity length was invalid");
            }
            let restricting_end = 136 + sid_length;
            let logon_end = restricting_end + logon_sid_length;
            let station_end = logon_end + station_length;
            let restricting_sid = std::str::from_utf8(&bytes[136..restricting_end])?.to_owned();
            let logon_sid = std::str::from_utf8(&bytes[restricting_end..logon_end])?.to_owned();
            let observed_window_station =
                std::str::from_utf8(&bytes[logon_end..station_end])?.to_owned();
            let observed_desktop = std::str::from_utf8(&bytes[station_end..])?.to_owned();
            validate_restricting_sid(&restricting_sid)?;
            validate_logon_sid(&logon_sid)?;
            validate_os_assigned_desktop_identity(&observed_window_station, &observed_desktop)?;
            Ok(BootstrapMessage::Ready {
                nonce,
                bootstrap_sha256: encode_hex(&bytes[56..88]),
                config_consumed: flags & READY_CONFIG_CONSUMED != 0,
                standard_handles_valid: flags & READY_HANDLES_VALID != 0,
                standard_handles_inheritable: flags & READY_HANDLES_INHERITABLE != 0,
                private_job_member: flags & READY_PRIVATE_JOB_MEMBER != 0,
                trusted_path_write_denied: flags & READY_TRUSTED_PATH_DENIED != 0,
                bootstrap_write_denied: flags & READY_BOOTSTRAP_WRITE_DENIED != 0,
                se_increase_quota_present: flags & READY_SE_INCREASE_QUOTA_PRESENT != 0,
                se_increase_quota_enabled: flags & READY_SE_INCREASE_QUOTA_ENABLED != 0,
                restricted_token: flags & READY_RESTRICTED_TOKEN != 0,
                restricted_low_integrity: flags & READY_RESTRICTED_LOW_INTEGRITY != 0,
                restricted_no_enabled_privileges: flags & READY_RESTRICTED_NO_ENABLED_PRIVILEGES
                    != 0,
                restricted_authentication_match: flags & READY_RESTRICTED_AUTHENTICATION_MATCH != 0,
                restricting_sid_match: flags & READY_RESTRICTING_SID_MATCH != 0,
                write_restricted_created: flags & READY_WRITE_RESTRICTED_CREATED != 0,
                system_restricting_sid_match: flags & READY_SYSTEM_RESTRICTING_SID_MATCH != 0,
                os_assigned_window_station: flags & READY_OS_ASSIGNED_WINDOW_STATION != 0,
                os_assigned_desktop: flags & READY_OS_ASSIGNED_DESKTOP != 0,
                window_station_noninteractive: flags & READY_WINDOW_STATION_NONINTERACTIVE != 0,
                desktop_noninteractive_default: flags & READY_DESKTOP_NONINTERACTIVE_DEFAULT != 0,
                window_station_low_integrity: flags & READY_WINDOW_STATION_LOW_INTEGRITY != 0,
                desktop_low_integrity: flags & READY_DESKTOP_LOW_INTEGRITY != 0,
                restricted_desktop_access: flags & READY_RESTRICTED_DESKTOP_ACCESS != 0,
                restricted_logon_sid_match: flags & READY_RESTRICTED_LOGON_SID_MATCH != 0,
                window_station_logon_sid_dacl: flags & READY_WINDOW_STATION_LOGON_SID_DACL != 0,
                desktop_logon_sid_dacl: flags & READY_DESKTOP_LOGON_SID_DACL != 0,
                token_session_match: flags & READY_TOKEN_SESSION_MATCH != 0,
                job_ui_restrictions_match: flags & READY_JOB_UI_RESTRICTIONS_MATCH != 0,
                broker_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 88)?,
                    high_part: read_u32(bytes, 92)? as i32,
                },
                restricted_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 96)?,
                    high_part: read_u32(bytes, 100)? as i32,
                },
                account_token_session_id: read_u32(bytes, 104)?,
                bootstrap_token_session_id: read_u32(bytes, 108)?,
                restricted_token_session_id: read_u32(bytes, 112)?,
                job_ui_restriction_mask: read_u32(bytes, 116)?,
                restricting_sid,
                logon_sid,
                observed_window_station,
                observed_desktop,
            })
        }
        3 if bytes.len() == 76 && flags & !EXIT_ALL_FLAGS == 0 => {
            let contained = read_u32(bytes, 60)?;
            if contained > 1 {
                bail!("Windows bootstrap exit containment flag was invalid");
            }
            Ok(BootstrapMessage::Exit {
                nonce,
                code: read_u32(bytes, 56)?,
                private_job_descendant_contained: contained == 1,
                create_process_as_user_succeeded: flags & EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED
                    != 0,
                product_authentication_match: flags & EXIT_PRODUCT_AUTHENTICATION_MATCH != 0,
                product_low_integrity: flags & EXIT_PRODUCT_LOW_INTEGRITY != 0,
                product_write_restricted: flags & EXIT_PRODUCT_WRITE_RESTRICTED != 0,
                product_no_enabled_privileges: flags & EXIT_PRODUCT_NO_ENABLED_PRIVILEGES != 0,
                product_restricting_sid_match: flags & EXIT_PRODUCT_RESTRICTING_SID_MATCH != 0,
                product_system_restricting_sid_match: flags
                    & EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH
                    != 0,
                product_desktop_assignment_match: flags & EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH
                    != 0,
                product_create_no_window: flags & EXIT_PRODUCT_CREATE_NO_WINDOW != 0,
                product_logon_sid_match: flags & EXIT_PRODUCT_LOGON_SID_MATCH != 0,
                product_session_id_match: flags & EXIT_PRODUCT_SESSION_ID_MATCH != 0,
                product_window_station_low_integrity: flags
                    & EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY
                    != 0,
                product_desktop_low_integrity: flags & EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY != 0,
                product_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 64)?,
                    high_part: read_u32(bytes, 68)? as i32,
                },
                product_token_session_id: read_u32(bytes, 72)?,
            })
        }
        4 if bytes.len() == 64 && flags == 0 => Ok(BootstrapMessage::Error {
            nonce,
            windows_error: read_u32(bytes, 56)?,
            stage: read_u32(bytes, 60)?,
        }),
        5 if bytes.len() == 76 && flags & !EXIT_ALL_FLAGS == 0 => {
            let contained = read_u32(bytes, 56)?;
            if contained > 1 {
                bail!("Windows bootstrap product-started containment flag was invalid");
            }
            Ok(BootstrapMessage::ProductStarted {
                nonce,
                private_job_descendant_contained: contained == 1,
                create_process_as_user_succeeded: flags & EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED
                    != 0,
                product_authentication_match: flags & EXIT_PRODUCT_AUTHENTICATION_MATCH != 0,
                product_low_integrity: flags & EXIT_PRODUCT_LOW_INTEGRITY != 0,
                product_write_restricted: flags & EXIT_PRODUCT_WRITE_RESTRICTED != 0,
                product_no_enabled_privileges: flags & EXIT_PRODUCT_NO_ENABLED_PRIVILEGES != 0,
                product_restricting_sid_match: flags & EXIT_PRODUCT_RESTRICTING_SID_MATCH != 0,
                product_system_restricting_sid_match: flags
                    & EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH
                    != 0,
                product_desktop_assignment_match: flags & EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH
                    != 0,
                product_create_no_window: flags & EXIT_PRODUCT_CREATE_NO_WINDOW != 0,
                product_logon_sid_match: flags & EXIT_PRODUCT_LOGON_SID_MATCH != 0,
                product_session_id_match: flags & EXIT_PRODUCT_SESSION_ID_MATCH != 0,
                product_window_station_low_integrity: flags
                    & EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY
                    != 0,
                product_desktop_low_integrity: flags & EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY != 0,
                product_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 60)?,
                    high_part: read_u32(bytes, 64)? as i32,
                },
                resume_previous_count: read_u32(bytes, 68)?,
                product_token_session_id: read_u32(bytes, 72)?,
            })
        }
        _ => bail!("Windows bootstrap event type, flags, or length changed"),
    }
}

#[cfg(test)]
fn encode_event(message: &BootstrapMessage) -> Result<Vec<u8>> {
    let (event_type, flags, nonce, payload) = match message {
        BootstrapMessage::AccountLauncherReady {
            nonce,
            launcher_sha256,
            bootstrap_sha256,
            config_consumed,
            self_hash_match,
            bootstrap_hash_match,
            handles_exact,
            handle_inheritance_exact,
            private_job_member,
            job_ui_restrictions_match,
            se_increase_quota_present,
            se_increase_quota_enabled,
            session_match,
            bootstrap_created_suspended,
            bootstrap_private_job_member,
            bootstrap_session_match,
            empty_desktop_selection,
            create_no_window,
            handle_list_exact,
            supervisor_target_exact,
            bootstrap_handles_duplicated,
            account_token_session_id,
            launcher_token_session_id,
            bootstrap_token_session_id,
            job_ui_restriction_mask,
            bootstrap_process_id,
            bootstrap_primary_thread_id,
            supervisor_process_id,
            launcher_process_id,
            bootstrap_process_handle,
            bootstrap_primary_thread_handle,
        } => {
            let mut flags = 0;
            flags |= u32::from(*config_consumed) * LAUNCHER_READY_CONFIG_CONSUMED;
            flags |= u32::from(*self_hash_match) * LAUNCHER_READY_SELF_HASH_MATCH;
            flags |= u32::from(*bootstrap_hash_match) * LAUNCHER_READY_BOOTSTRAP_HASH_MATCH;
            flags |= u32::from(*handles_exact) * LAUNCHER_READY_HANDLES_EXACT;
            flags |= u32::from(*handle_inheritance_exact) * LAUNCHER_READY_HANDLE_INHERITANCE_EXACT;
            flags |= u32::from(*private_job_member) * LAUNCHER_READY_JOB_MEMBER;
            flags |=
                u32::from(*job_ui_restrictions_match) * LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH;
            flags |=
                u32::from(*se_increase_quota_present) * LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT;
            flags |=
                u32::from(*se_increase_quota_enabled) * LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED;
            flags |= u32::from(*session_match) * LAUNCHER_READY_SESSION_MATCH;
            flags |= u32::from(*bootstrap_created_suspended)
                * LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED;
            flags |= u32::from(*bootstrap_private_job_member) * LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER;
            flags |= u32::from(*bootstrap_session_match) * LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH;
            flags |= u32::from(*empty_desktop_selection) * LAUNCHER_READY_EMPTY_DESKTOP_SELECTION;
            flags |= u32::from(*create_no_window) * LAUNCHER_READY_CREATE_NO_WINDOW;
            flags |= u32::from(*handle_list_exact) * LAUNCHER_READY_HANDLE_LIST_EXACT;
            flags |= u32::from(*supervisor_target_exact) * LAUNCHER_READY_SUPERVISOR_TARGET_EXACT;
            flags |= u32::from(*bootstrap_handles_duplicated)
                * LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED;
            let mut payload = decode_hex_32(launcher_sha256, "account launcher SHA-256")?.to_vec();
            payload.extend_from_slice(&decode_hex_32(bootstrap_sha256, "bootstrap SHA-256")?);
            payload.extend_from_slice(&account_token_session_id.to_le_bytes());
            payload.extend_from_slice(&launcher_token_session_id.to_le_bytes());
            payload.extend_from_slice(&bootstrap_token_session_id.to_le_bytes());
            payload.extend_from_slice(&job_ui_restriction_mask.to_le_bytes());
            payload.extend_from_slice(&bootstrap_process_id.to_le_bytes());
            payload.extend_from_slice(&bootstrap_primary_thread_id.to_le_bytes());
            payload.extend_from_slice(&supervisor_process_id.to_le_bytes());
            payload.extend_from_slice(&launcher_process_id.to_le_bytes());
            payload.extend_from_slice(&bootstrap_process_handle.to_le_bytes());
            payload.extend_from_slice(&bootstrap_primary_thread_handle.to_le_bytes());
            (6, flags, nonce, payload)
        }
        BootstrapMessage::AccountLauncherExit {
            nonce,
            bootstrap_exit_code,
            bootstrap_resume_previous_count,
            bootstrap_process_id,
        } => {
            let mut payload = bootstrap_exit_code.to_le_bytes().to_vec();
            payload.extend_from_slice(&bootstrap_resume_previous_count.to_le_bytes());
            payload.extend_from_slice(&bootstrap_process_id.to_le_bytes());
            (7, 0, nonce, payload)
        }
        BootstrapMessage::AccountLauncherError { nonce, windows_error, stage } => {
            let mut payload = windows_error.to_le_bytes().to_vec();
            payload.extend_from_slice(&stage.to_le_bytes());
            (8, 0, nonce, payload)
        }
        BootstrapMessage::AccountLauncherResumed {
            nonce,
            bootstrap_resume_previous_count,
            bootstrap_process_id,
            adoption_acknowledged,
        } => {
            let mut payload = bootstrap_resume_previous_count.to_le_bytes().to_vec();
            payload.extend_from_slice(&bootstrap_process_id.to_le_bytes());
            (
                9,
                u32::from(*adoption_acknowledged) * LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED,
                nonce,
                payload,
            )
        }
        BootstrapMessage::Stage { nonce, stage } => {
            (1, 0, nonce, (*stage as u32).to_le_bytes().to_vec())
        }
        BootstrapMessage::Ready {
            nonce,
            bootstrap_sha256,
            config_consumed,
            standard_handles_valid,
            standard_handles_inheritable,
            private_job_member,
            trusted_path_write_denied,
            bootstrap_write_denied,
            se_increase_quota_present,
            se_increase_quota_enabled,
            restricted_token,
            restricted_low_integrity,
            restricted_no_enabled_privileges,
            restricted_authentication_match,
            restricting_sid_match,
            write_restricted_created,
            system_restricting_sid_match,
            os_assigned_window_station,
            os_assigned_desktop,
            window_station_noninteractive,
            desktop_noninteractive_default,
            window_station_low_integrity,
            desktop_low_integrity,
            restricted_desktop_access,
            restricted_logon_sid_match,
            window_station_logon_sid_dacl,
            desktop_logon_sid_dacl,
            token_session_match,
            job_ui_restrictions_match,
            broker_authentication_id,
            restricted_authentication_id,
            account_token_session_id,
            bootstrap_token_session_id,
            restricted_token_session_id,
            job_ui_restriction_mask,
            restricting_sid,
            logon_sid,
            observed_window_station,
            observed_desktop,
        } => {
            let mut flags = 0;
            flags |= u32::from(*config_consumed) * READY_CONFIG_CONSUMED;
            flags |= u32::from(*standard_handles_valid) * READY_HANDLES_VALID;
            flags |= u32::from(*standard_handles_inheritable) * READY_HANDLES_INHERITABLE;
            flags |= u32::from(*private_job_member) * READY_PRIVATE_JOB_MEMBER;
            flags |= u32::from(*trusted_path_write_denied) * READY_TRUSTED_PATH_DENIED;
            flags |= u32::from(*bootstrap_write_denied) * READY_BOOTSTRAP_WRITE_DENIED;
            flags |= u32::from(*se_increase_quota_present) * READY_SE_INCREASE_QUOTA_PRESENT;
            flags |= u32::from(*se_increase_quota_enabled) * READY_SE_INCREASE_QUOTA_ENABLED;
            flags |= u32::from(*restricted_token) * READY_RESTRICTED_TOKEN;
            flags |= u32::from(*restricted_low_integrity) * READY_RESTRICTED_LOW_INTEGRITY;
            flags |= u32::from(*restricted_no_enabled_privileges)
                * READY_RESTRICTED_NO_ENABLED_PRIVILEGES;
            flags |=
                u32::from(*restricted_authentication_match) * READY_RESTRICTED_AUTHENTICATION_MATCH;
            flags |= u32::from(*restricting_sid_match) * READY_RESTRICTING_SID_MATCH;
            flags |= u32::from(*write_restricted_created) * READY_WRITE_RESTRICTED_CREATED;
            flags |= u32::from(*system_restricting_sid_match) * READY_SYSTEM_RESTRICTING_SID_MATCH;
            flags |= u32::from(*os_assigned_window_station) * READY_OS_ASSIGNED_WINDOW_STATION;
            flags |= u32::from(*os_assigned_desktop) * READY_OS_ASSIGNED_DESKTOP;
            flags |=
                u32::from(*window_station_noninteractive) * READY_WINDOW_STATION_NONINTERACTIVE;
            flags |=
                u32::from(*desktop_noninteractive_default) * READY_DESKTOP_NONINTERACTIVE_DEFAULT;
            flags |= u32::from(*window_station_low_integrity) * READY_WINDOW_STATION_LOW_INTEGRITY;
            flags |= u32::from(*desktop_low_integrity) * READY_DESKTOP_LOW_INTEGRITY;
            flags |= u32::from(*restricted_desktop_access) * READY_RESTRICTED_DESKTOP_ACCESS;
            flags |= u32::from(*restricted_logon_sid_match) * READY_RESTRICTED_LOGON_SID_MATCH;
            flags |=
                u32::from(*window_station_logon_sid_dacl) * READY_WINDOW_STATION_LOGON_SID_DACL;
            flags |= u32::from(*desktop_logon_sid_dacl) * READY_DESKTOP_LOGON_SID_DACL;
            flags |= u32::from(*token_session_match) * READY_TOKEN_SESSION_MATCH;
            flags |= u32::from(*job_ui_restrictions_match) * READY_JOB_UI_RESTRICTIONS_MATCH;
            validate_restricting_sid(restricting_sid)?;
            validate_logon_sid(logon_sid)?;
            validate_os_assigned_desktop_identity(observed_window_station, observed_desktop)?;
            let mut payload = decode_hex_32(bootstrap_sha256, "bootstrap SHA-256")?.to_vec();
            payload.extend_from_slice(&broker_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(broker_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&restricted_authentication_id.low_part.to_le_bytes());
            payload
                .extend_from_slice(&(restricted_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&account_token_session_id.to_le_bytes());
            payload.extend_from_slice(&bootstrap_token_session_id.to_le_bytes());
            payload.extend_from_slice(&restricted_token_session_id.to_le_bytes());
            payload.extend_from_slice(&job_ui_restriction_mask.to_le_bytes());
            payload.extend_from_slice(&u32::try_from(restricting_sid.len())?.to_le_bytes());
            payload.extend_from_slice(&u32::try_from(logon_sid.len())?.to_le_bytes());
            payload.extend_from_slice(&u32::try_from(observed_window_station.len())?.to_le_bytes());
            payload.extend_from_slice(&u32::try_from(observed_desktop.len())?.to_le_bytes());
            payload.extend_from_slice(restricting_sid.as_bytes());
            payload.extend_from_slice(logon_sid.as_bytes());
            payload.extend_from_slice(observed_window_station.as_bytes());
            payload.extend_from_slice(observed_desktop.as_bytes());
            (2, flags, nonce, payload)
        }
        BootstrapMessage::Exit {
            nonce,
            code,
            private_job_descendant_contained,
            create_process_as_user_succeeded,
            product_authentication_match,
            product_low_integrity,
            product_write_restricted,
            product_no_enabled_privileges,
            product_restricting_sid_match,
            product_system_restricting_sid_match,
            product_desktop_assignment_match,
            product_create_no_window,
            product_logon_sid_match,
            product_session_id_match,
            product_window_station_low_integrity,
            product_desktop_low_integrity,
            product_authentication_id,
            product_token_session_id,
        } => {
            let mut flags = 0;
            flags |= u32::from(*create_process_as_user_succeeded)
                * EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED;
            flags |= u32::from(*product_authentication_match) * EXIT_PRODUCT_AUTHENTICATION_MATCH;
            flags |= u32::from(*product_low_integrity) * EXIT_PRODUCT_LOW_INTEGRITY;
            flags |= u32::from(*product_write_restricted) * EXIT_PRODUCT_WRITE_RESTRICTED;
            flags |= u32::from(*product_no_enabled_privileges) * EXIT_PRODUCT_NO_ENABLED_PRIVILEGES;
            flags |= u32::from(*product_restricting_sid_match) * EXIT_PRODUCT_RESTRICTING_SID_MATCH;
            flags |= u32::from(*product_system_restricting_sid_match)
                * EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH;
            flags |= u32::from(*product_desktop_assignment_match)
                * EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH;
            flags |= u32::from(*product_create_no_window) * EXIT_PRODUCT_CREATE_NO_WINDOW;
            flags |= u32::from(*product_logon_sid_match) * EXIT_PRODUCT_LOGON_SID_MATCH;
            flags |= u32::from(*product_session_id_match) * EXIT_PRODUCT_SESSION_ID_MATCH;
            flags |= u32::from(*product_window_station_low_integrity)
                * EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY;
            flags |= u32::from(*product_desktop_low_integrity) * EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY;
            let mut payload = code.to_le_bytes().to_vec();
            payload.extend_from_slice(&u32::from(*private_job_descendant_contained).to_le_bytes());
            payload.extend_from_slice(&product_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(product_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&product_token_session_id.to_le_bytes());
            (3, flags, nonce, payload)
        }
        BootstrapMessage::Error { nonce, windows_error, stage } => {
            let mut payload = windows_error.to_le_bytes().to_vec();
            payload.extend_from_slice(&stage.to_le_bytes());
            (4, 0, nonce, payload)
        }
        BootstrapMessage::ProductStarted {
            nonce,
            private_job_descendant_contained,
            create_process_as_user_succeeded,
            product_authentication_match,
            product_low_integrity,
            product_write_restricted,
            product_no_enabled_privileges,
            product_restricting_sid_match,
            product_system_restricting_sid_match,
            product_desktop_assignment_match,
            product_create_no_window,
            product_logon_sid_match,
            product_session_id_match,
            product_window_station_low_integrity,
            product_desktop_low_integrity,
            product_authentication_id,
            resume_previous_count,
            product_token_session_id,
        } => {
            let mut flags = 0;
            flags |= u32::from(*create_process_as_user_succeeded)
                * EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED;
            flags |= u32::from(*product_authentication_match) * EXIT_PRODUCT_AUTHENTICATION_MATCH;
            flags |= u32::from(*product_low_integrity) * EXIT_PRODUCT_LOW_INTEGRITY;
            flags |= u32::from(*product_write_restricted) * EXIT_PRODUCT_WRITE_RESTRICTED;
            flags |= u32::from(*product_no_enabled_privileges) * EXIT_PRODUCT_NO_ENABLED_PRIVILEGES;
            flags |= u32::from(*product_restricting_sid_match) * EXIT_PRODUCT_RESTRICTING_SID_MATCH;
            flags |= u32::from(*product_system_restricting_sid_match)
                * EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH;
            flags |= u32::from(*product_desktop_assignment_match)
                * EXIT_PRODUCT_DESKTOP_ASSIGNMENT_MATCH;
            flags |= u32::from(*product_create_no_window) * EXIT_PRODUCT_CREATE_NO_WINDOW;
            flags |= u32::from(*product_logon_sid_match) * EXIT_PRODUCT_LOGON_SID_MATCH;
            flags |= u32::from(*product_session_id_match) * EXIT_PRODUCT_SESSION_ID_MATCH;
            flags |= u32::from(*product_window_station_low_integrity)
                * EXIT_PRODUCT_WINDOW_STATION_LOW_INTEGRITY;
            flags |= u32::from(*product_desktop_low_integrity) * EXIT_PRODUCT_DESKTOP_LOW_INTEGRITY;
            let mut payload = u32::from(*private_job_descendant_contained).to_le_bytes().to_vec();
            payload.extend_from_slice(&product_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(product_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&resume_previous_count.to_le_bytes());
            payload.extend_from_slice(&product_token_session_id.to_le_bytes());
            (5, flags, nonce, payload)
        }
    };
    let nonce = decode_hex_32(nonce, "bootstrap event nonce")?;
    let total = RECORD_HEADER_BYTES + payload.len();
    let mut bytes = vec![0; RECORD_HEADER_BYTES];
    bytes[..8].copy_from_slice(&EVENT_MAGIC);
    put_u32(&mut bytes, 8, BOOTSTRAP_SCHEMA_VERSION)?;
    put_u32(&mut bytes, 12, u32::try_from(total)?)?;
    put_u32(&mut bytes, 16, event_type)?;
    put_u32(&mut bytes, 20, flags)?;
    bytes[24..56].copy_from_slice(&nonce);
    bytes.extend_from_slice(&payload);
    Ok(bytes)
}

fn push_path(bytes: &mut Vec<u8>, path: &Path) -> Result<()> {
    #[cfg(windows)]
    let value: Vec<u16> = {
        use std::os::windows::ffi::OsStrExt;
        path.as_os_str().encode_wide().collect()
    };
    #[cfg(not(windows))]
    let value: Vec<u16> = path.to_string_lossy().encode_utf16().collect();
    push_u16s(bytes, &value)
}

fn push_utf16(bytes: &mut Vec<u8>, value: &str) -> Result<()> {
    push_u16s(bytes, &value.encode_utf16().collect::<Vec<_>>())
}

fn push_u16s(bytes: &mut Vec<u8>, value: &[u16]) -> Result<()> {
    if value.is_empty() || value.contains(&0) {
        bail!("Windows bootstrap UTF-16 field was empty or contained NUL");
    }
    let length = value.len().checked_mul(2).context("bootstrap field length overflow")?;
    bytes.extend_from_slice(&u32::try_from(length)?.to_le_bytes());
    for unit in value {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    Ok(())
}

fn push_bytes(bytes: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    bytes.extend_from_slice(&u32::try_from(value.len())?.to_le_bytes());
    bytes.extend_from_slice(value);
    Ok(())
}

fn take_field<'a>(bytes: &'a [u8], cursor: &mut usize) -> Result<&'a [u8]> {
    let length = usize::try_from(read_u32(bytes, *cursor)?)?;
    *cursor = cursor.checked_add(4).context("bootstrap field offset overflow")?;
    let end = cursor.checked_add(length).context("bootstrap field length overflow")?;
    let value = bytes.get(*cursor..end).context("bootstrap field was truncated")?;
    *cursor = end;
    Ok(value)
}

fn take_path(bytes: &[u8], cursor: &mut usize) -> Result<PathBuf> {
    let value = take_utf16(bytes, cursor)?;
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt;
        Ok(std::ffi::OsString::from_wide(&value).into())
    }
    #[cfg(not(windows))]
    Ok(String::from_utf16(&value)?.into())
}

fn take_utf16_string(bytes: &[u8], cursor: &mut usize) -> Result<String> {
    Ok(String::from_utf16(&take_utf16(bytes, cursor)?)?)
}

fn take_utf16(bytes: &[u8], cursor: &mut usize) -> Result<Vec<u16>> {
    let field = take_field(bytes, cursor)?;
    if field.len() % 2 != 0 || field.is_empty() {
        bail!("Windows bootstrap UTF-16 field had an invalid length");
    }
    let mut value = Vec::with_capacity(field.len() / 2);
    for chunk in field.chunks_exact(2) {
        value.push(u16::from_le_bytes([chunk[0], chunk[1]]));
    }
    Ok(value)
}

fn take_ascii(bytes: &[u8], cursor: &mut usize, length: usize, name: &str) -> Result<String> {
    let field = take_field(bytes, cursor)?;
    if field.len() != length || !field.iter().all(u8::is_ascii_hexdigit) {
        bail!("Windows bootstrap {name} was invalid");
    }
    Ok(String::from_utf8(field.to_vec())?)
}

fn take_ascii_variable(
    bytes: &[u8],
    cursor: &mut usize,
    max_length: usize,
    name: &str,
) -> Result<String> {
    let field = take_field(bytes, cursor)?;
    if field.is_empty() || field.len() > max_length || !field.is_ascii() || field.contains(&0) {
        bail!("Windows bootstrap {name} was invalid");
    }
    Ok(String::from_utf8(field.to_vec())?)
}

fn require_magic(bytes: &[u8], expected: &[u8; 8], record: &str) -> Result<()> {
    if bytes.get(..8) != Some(expected) {
        bail!("Windows bootstrap {record} magic changed");
    }
    Ok(())
}

fn put_u32(bytes: &mut [u8], offset: usize, value: u32) -> Result<()> {
    bytes
        .get_mut(offset..offset + 4)
        .context("bootstrap u32 offset was invalid")?
        .copy_from_slice(&value.to_le_bytes());
    Ok(())
}

fn put_u64(bytes: &mut [u8], offset: usize, value: u64) -> Result<()> {
    bytes
        .get_mut(offset..offset + 8)
        .context("bootstrap u64 offset was invalid")?
        .copy_from_slice(&value.to_le_bytes());
    Ok(())
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32> {
    let value: [u8; 4] =
        bytes.get(offset..offset + 4).context("bootstrap u32 was truncated")?.try_into()?;
    Ok(u32::from_le_bytes(value))
}

fn read_u64(bytes: &[u8], offset: usize) -> Result<u64> {
    let value: [u8; 8] =
        bytes.get(offset..offset + 8).context("bootstrap u64 was truncated")?.try_into()?;
    Ok(u64::from_le_bytes(value))
}

fn validate_hex(value: &str, length: usize, name: &str) -> Result<()> {
    if value.len() != length || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{name} must be {length} hexadecimal characters");
    }
    Ok(())
}

fn validate_restricting_sid(value: &str) -> Result<()> {
    if !value.starts_with("S-1-")
        || value.len() > MAX_RESTRICTING_SID_BYTES
        || !value.bytes().all(|byte| byte.is_ascii_digit() || byte == b'-' || byte == b'S')
    {
        bail!("restricting SID was invalid");
    }
    Ok(())
}

fn validate_logon_sid(value: &str) -> Result<()> {
    validate_restricting_sid(value)?;
    let (high, low) = value
        .strip_prefix("S-1-5-5-")
        .and_then(|suffix| suffix.split_once('-'))
        .filter(|(_, low)| !low.contains('-'))
        .context("logon SID did not have the S-1-5-5-X-Y form")?;
    if high.is_empty()
        || low.is_empty()
        || !high.bytes().all(|byte| byte.is_ascii_digit())
        || !low.bytes().all(|byte| byte.is_ascii_digit())
    {
        bail!("logon SID did not have the S-1-5-5-X-Y form");
    }
    Ok(())
}

fn decode_hex_32(value: &str, name: &str) -> Result<[u8; 32]> {
    validate_hex(value, 64, name)?;
    let mut decoded = [0_u8; 32];
    for (index, byte) in decoded.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)?;
    }
    Ok(decoded)
}

fn encode_hex(value: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(value.len() * 2);
    for byte in value {
        encoded.push(HEX[usize::from(byte >> 4)] as char);
        encoded.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[cfg(windows)]
    fn test_path(path: &str) -> PathBuf {
        PathBuf::from(format!(r"C:\{path}"))
    }

    #[cfg(not(windows))]
    fn test_path(path: &str) -> PathBuf {
        PathBuf::from(format!("/{path}"))
    }

    fn config() -> BootstrapConfig {
        BootstrapConfig {
            schema_version: BOOTSTRAP_SCHEMA_VERSION,
            nonce: "ab".repeat(32),
            launch: BootstrapProductLaunch {
                timing: test_path("fixture/timing.page"),
                fixture_root: test_path("fixture"),
                target: test_path("trusted/cmux-tui.exe"),
                target_sha256: "cd".repeat(32),
                product_args: vec!["--version".into()],
                trusted_path_probe: test_path("trusted/probe"),
                expected_bootstrap_sha256: "ef".repeat(32),
                restricting_sid: "S-1-5-21-1-2-3-4".into(),
                logon_sid: "S-1-5-5-123-456".into(),
                account_token_session_id: 7,
                job_ui_restriction_mask: WINDOWS_JOB_UI_RESTRICTION_MASK,
            },
            control_read: 11,
            control_write: 12,
            standard_handles: [13, 14, 15],
            query_job: 16,
            launcher_gate: 17,
        }
    }

    fn account_launcher_config() -> AccountLauncherConfig {
        AccountLauncherConfig {
            schema_version: ACCOUNT_LAUNCHER_SCHEMA_VERSION,
            nonce: "ab".repeat(32),
            launcher_stage_marker: WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER,
            bootstrap_stage_marker: WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER,
            launcher: test_path("trusted/cmux-startup-account-launcher.exe"),
            launcher_sha256: "12".repeat(32),
            bootstrap: test_path("trusted/cmux-startup-bootstrap.exe"),
            bootstrap_sha256: "34".repeat(32),
            bootstrap_config: test_path("fixture/bootstrap-abababababababab.bin"),
            bootstrap_config_sha256: "56".repeat(32),
            bootstrap_entry_checkpoint: test_path("fixture/bootstrap-entry-abababababababab.bin"),
            account_token_session_id: 7,
            job_ui_restriction_mask: WINDOWS_JOB_UI_RESTRICTION_MASK,
            control_read: 11,
            control_write: 12,
            standard_handles: [13, 14, 15],
            query_job: 16,
            launcher_gate: 17,
            supervisor_process: 18,
            supervisor_process_id: 19,
        }
    }

    fn account_launcher_ready() -> BootstrapMessage {
        BootstrapMessage::AccountLauncherReady {
            nonce: "ab".repeat(32),
            launcher_sha256: "12".repeat(32),
            bootstrap_sha256: "34".repeat(32),
            config_consumed: true,
            self_hash_match: true,
            bootstrap_hash_match: true,
            handles_exact: true,
            handle_inheritance_exact: true,
            private_job_member: true,
            job_ui_restrictions_match: true,
            se_increase_quota_present: true,
            se_increase_quota_enabled: true,
            session_match: true,
            bootstrap_created_suspended: true,
            bootstrap_private_job_member: true,
            bootstrap_session_match: true,
            empty_desktop_selection: true,
            create_no_window: true,
            handle_list_exact: true,
            supervisor_target_exact: true,
            bootstrap_handles_duplicated: true,
            account_token_session_id: 7,
            launcher_token_session_id: 7,
            bootstrap_token_session_id: 7,
            job_ui_restriction_mask: WINDOWS_JOB_UI_RESTRICTION_MASK,
            bootstrap_process_id: 41,
            bootstrap_primary_thread_id: 42,
            supervisor_process_id: 43,
            launcher_process_id: 44,
            bootstrap_process_handle: 45,
            bootstrap_primary_thread_handle: 46,
        }
    }

    fn validate_test_account_launcher_ready(message: &BootstrapMessage) -> Result<()> {
        validate_account_launcher_ready_message(
            message,
            &"ab".repeat(32),
            &"12".repeat(32),
            &"34".repeat(32),
            7,
            43,
            44,
        )
    }

    #[test]
    fn bounded_binary_config_round_trip_preserves_schema_and_nonce() {
        let config = config();
        let bytes = encode_config(&config).unwrap();
        let decoded = decode_config(&bytes).unwrap();
        assert_eq!(decoded, config);
        decoded.validate_identity(&test_path("fixture/bootstrap-abababababababab.bin")).unwrap();
    }

    #[test]
    fn account_launcher_config_round_trip_preserves_stage_and_handle_identity() {
        let config = account_launcher_config();
        let bytes = encode_account_launcher_config(&config).unwrap();
        let decoded = decode_account_launcher_config(&bytes).unwrap();
        assert_eq!(decoded, config);
        decoded.validate_identity(&test_path("fixture/launcher-abababababababab.bin")).unwrap();
    }

    #[test]
    fn account_launcher_config_rejects_loops_markers_hashes_and_handles() {
        let mut looped = account_launcher_config();
        looped.bootstrap = looped.launcher.clone();
        assert!(encode_account_launcher_config(&looped).is_err());
        let mut wrong_marker = account_launcher_config();
        wrong_marker.bootstrap_stage_marker = wrong_marker.launcher_stage_marker;
        assert!(encode_account_launcher_config(&wrong_marker).is_err());
        let mut wrong_hash = account_launcher_config();
        wrong_hash.bootstrap_sha256 = "not-hex".into();
        assert!(encode_account_launcher_config(&wrong_hash).is_err());
        let mut duplicate_handle = account_launcher_config();
        duplicate_handle.supervisor_process = duplicate_handle.launcher_gate;
        assert!(encode_account_launcher_config(&duplicate_handle).is_err());
        let mut missing_supervisor = account_launcher_config();
        missing_supervisor.supervisor_process_id = 0;
        assert!(
            missing_supervisor
                .validate_identity(&test_path("fixture/launcher-abababababababab.bin"))
                .is_err()
        );
    }

    #[test]
    fn account_launcher_ready_rejects_job_privilege_session_hash_and_handle_mismatch() {
        let ready = account_launcher_ready();
        validate_test_account_launcher_ready(&ready).unwrap();
        assert_eq!(decode_event(&encode_event(&ready).unwrap()).unwrap(), ready);
        let resumed = BootstrapMessage::AccountLauncherResumed {
            nonce: "ab".repeat(32),
            bootstrap_resume_previous_count: 1,
            bootstrap_process_id: 41,
            adoption_acknowledged: true,
        };
        assert_eq!(decode_event(&encode_event(&resumed).unwrap()).unwrap(), resumed);

        let mut outside_job = account_launcher_ready();
        let BootstrapMessage::AccountLauncherReady { private_job_member, .. } = &mut outside_job
        else {
            unreachable!();
        };
        *private_job_member = false;
        assert!(validate_test_account_launcher_ready(&outside_job).is_err());

        let mut privilege_absent = account_launcher_ready();
        let BootstrapMessage::AccountLauncherReady { se_increase_quota_present, .. } =
            &mut privilege_absent
        else {
            unreachable!();
        };
        *se_increase_quota_present = false;
        assert!(validate_test_account_launcher_ready(&privilege_absent).is_err());

        let mut wrong_session = account_launcher_ready();
        let BootstrapMessage::AccountLauncherReady { bootstrap_token_session_id, .. } =
            &mut wrong_session
        else {
            unreachable!();
        };
        *bootstrap_token_session_id += 1;
        assert!(validate_test_account_launcher_ready(&wrong_session).is_err());

        let mut wrong_hash = account_launcher_ready();
        let BootstrapMessage::AccountLauncherReady { bootstrap_sha256, .. } = &mut wrong_hash
        else {
            unreachable!();
        };
        *bootstrap_sha256 = "56".repeat(32);
        assert!(validate_test_account_launcher_ready(&wrong_hash).is_err());

        let mut reused_handle = account_launcher_ready();
        let BootstrapMessage::AccountLauncherReady {
            bootstrap_process_handle,
            bootstrap_primary_thread_handle,
            ..
        } = &mut reused_handle
        else {
            unreachable!();
        };
        *bootstrap_primary_thread_handle = *bootstrap_process_handle;
        assert!(validate_test_account_launcher_ready(&reused_handle).is_err());
    }

    #[test]
    fn binary_config_rejects_schema_nonce_and_record_bounds() {
        let mut bytes = encode_config(&config()).unwrap();
        bytes[8..12].copy_from_slice(&(BOOTSTRAP_SCHEMA_VERSION + 1).to_le_bytes());
        assert!(decode_config(&bytes).is_err());
        assert!(config().validate_identity(&test_path("fixture/bootstrap-wrong.bin")).is_err());
        let mut oversized = config();
        oversized.launch.product_args = vec!["x".repeat(MAX_BOOTSTRAP_CONFIG_BYTES)];
        assert!(encode_config(&oversized).is_err());
        let mut too_many = encode_config(&config()).unwrap();
        too_many[20..24]
            .copy_from_slice(&u32::try_from(MAX_PRODUCT_ARGUMENTS + 1).unwrap().to_le_bytes());
        assert!(decode_config(&too_many).is_err());
        let mut invalid_sid = config();
        invalid_sid.launch.restricting_sid = "not-a-sid".into();
        assert!(encode_config(&invalid_sid).is_err());
        let mut invalid_logon_sid = config();
        invalid_logon_sid.launch.logon_sid = "not-a-sid".into();
        assert!(encode_config(&invalid_logon_sid).is_err());
        let mut wrong_kind_logon_sid = config();
        wrong_kind_logon_sid.launch.logon_sid = "S-1-5-21-1-2-3-1001".into();
        assert!(encode_config(&wrong_kind_logon_sid).is_err());
        let mut wrong_ui_mask = config();
        wrong_ui_mask.launch.job_ui_restriction_mask = 0xfe;
        assert!(encode_config(&wrong_ui_mask).is_err());
    }

    #[test]
    fn arm_record_is_fixed_and_nonce_bound() {
        let nonce = "12".repeat(32);
        let bytes = encode_arm(&nonce).unwrap();
        assert_eq!(bytes.len(), 48);
        assert_eq!(decode_arm(&bytes).unwrap(), nonce);
        let mut changed = bytes;
        changed.push(0);
        assert!(decode_arm(&changed).is_err());
        let adopted = encode_account_launcher_adopted(&nonce).unwrap();
        assert_eq!(adopted.len(), 48);
        assert_eq!(&adopted[..8], &ACCOUNT_LAUNCHER_ADOPTED_MAGIC);
        assert_eq!(&adopted[16..], &bytes[16..]);
    }

    #[test]
    fn os_assigned_desktop_identity_rejects_interactive_or_nondefault_objects() {
        validate_os_assigned_desktop_identity("Service-0x0-123$", "Default").unwrap();
        assert!(validate_os_assigned_desktop_identity("WinSta0", "Default").is_err());
        assert!(validate_os_assigned_desktop_identity("Service-0x0-123$", "Other").is_err());
        assert!(validate_os_assigned_desktop_identity("", "Default").is_err());
    }

    #[test]
    fn event_decoder_preserves_type_flags_nonce_and_clean_eof() {
        let message = BootstrapMessage::Ready {
            nonce: "34".repeat(32),
            bootstrap_sha256: "56".repeat(32),
            config_consumed: true,
            standard_handles_valid: true,
            standard_handles_inheritable: true,
            private_job_member: true,
            trusted_path_write_denied: true,
            bootstrap_write_denied: true,
            se_increase_quota_present: true,
            se_increase_quota_enabled: true,
            restricted_token: true,
            restricted_low_integrity: true,
            restricted_no_enabled_privileges: true,
            restricted_authentication_match: true,
            restricting_sid_match: true,
            write_restricted_created: true,
            system_restricting_sid_match: true,
            os_assigned_window_station: true,
            os_assigned_desktop: true,
            window_station_noninteractive: true,
            desktop_noninteractive_default: true,
            window_station_low_integrity: true,
            desktop_low_integrity: true,
            restricted_desktop_access: true,
            restricted_logon_sid_match: true,
            window_station_logon_sid_dacl: true,
            desktop_logon_sid_dacl: true,
            token_session_match: true,
            job_ui_restrictions_match: true,
            broker_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            restricted_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            account_token_session_id: 4,
            bootstrap_token_session_id: 4,
            restricted_token_session_id: 4,
            job_ui_restriction_mask: WINDOWS_JOB_UI_RESTRICTION_MASK,
            restricting_sid: "S-1-5-21-1-2-3-4".into(),
            logon_sid: "S-1-5-5-123-456".into(),
            observed_window_station: "Service-0x0-123$".into(),
            observed_desktop: "Default".into(),
        };
        let bytes = encode_event(&message).unwrap();
        assert_eq!(decode_event(&bytes).unwrap(), message);
        assert_eq!(read_event(&mut Cursor::new(bytes)).unwrap(), Some(message));
        assert_eq!(read_event(&mut Cursor::new(Vec::<u8>::new())).unwrap(), None);

        let exit = BootstrapMessage::Exit {
            nonce: "78".repeat(32),
            code: 0,
            private_job_descendant_contained: true,
            create_process_as_user_succeeded: true,
            product_authentication_match: true,
            product_low_integrity: true,
            product_write_restricted: true,
            product_no_enabled_privileges: true,
            product_restricting_sid_match: true,
            product_system_restricting_sid_match: true,
            product_desktop_assignment_match: true,
            product_create_no_window: true,
            product_logon_sid_match: true,
            product_session_id_match: true,
            product_window_station_low_integrity: true,
            product_desktop_low_integrity: true,
            product_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            product_token_session_id: 4,
        };
        assert_eq!(decode_event(&encode_event(&exit).unwrap()).unwrap(), exit);

        let product_started = BootstrapMessage::ProductStarted {
            nonce: "9a".repeat(32),
            private_job_descendant_contained: true,
            create_process_as_user_succeeded: true,
            product_authentication_match: true,
            product_low_integrity: true,
            product_write_restricted: true,
            product_no_enabled_privileges: true,
            product_restricting_sid_match: true,
            product_system_restricting_sid_match: true,
            product_desktop_assignment_match: true,
            product_create_no_window: true,
            product_logon_sid_match: true,
            product_session_id_match: true,
            product_window_station_low_integrity: true,
            product_desktop_low_integrity: true,
            product_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            resume_previous_count: 1,
            product_token_session_id: 4,
        };
        assert_eq!(
            decode_event(&encode_event(&product_started).unwrap()).unwrap(),
            product_started
        );
    }

    #[test]
    fn event_decoder_rejects_wrong_schema_nonce_length_and_truncation() {
        let message =
            BootstrapMessage::Error { nonce: "78".repeat(32), windows_error: 5, stage: 7 };
        let mut schema = encode_event(&message).unwrap();
        schema[8..12].copy_from_slice(&(BOOTSTRAP_SCHEMA_VERSION + 1).to_le_bytes());
        assert!(decode_event(&schema).is_err());
        let mut truncated = encode_event(&message).unwrap();
        truncated.pop();
        assert!(decode_event(&truncated).is_err());
        assert!(read_event(&mut Cursor::new(vec![EVENT_MAGIC[0]])).is_err());
        assert!(
            encode_event(&BootstrapMessage::Error {
                nonce: "bad".into(),
                windows_error: 5,
                stage: 7,
            })
            .is_err()
        );
    }

    #[test]
    fn native_entry_checkpoint_is_bounded_schema_and_nonce_bound() {
        let nonce = "9a".repeat(32);
        let mut checkpoint = [0_u8; 48];
        checkpoint[..8].copy_from_slice(&NATIVE_ENTRY_CHECKPOINT_MAGIC);
        checkpoint[8..12].copy_from_slice(&BOOTSTRAP_SCHEMA_VERSION.to_le_bytes());
        checkpoint[12..16]
            .copy_from_slice(&(NativeEntryCheckpointStage::ConfigReadStarted as u32).to_le_bytes());
        checkpoint[16..].copy_from_slice(&decode_hex_32(&nonce, "test nonce").unwrap());
        assert_eq!(
            decode_native_entry_checkpoint(&checkpoint, &nonce).unwrap(),
            NativeEntryCheckpointStage::ConfigReadStarted
        );
        assert!(decode_native_entry_checkpoint(&checkpoint[..47], &nonce).is_err());
        checkpoint[8..12].copy_from_slice(&(BOOTSTRAP_SCHEMA_VERSION + 1).to_le_bytes());
        assert!(decode_native_entry_checkpoint(&checkpoint, &nonce).is_err());
        checkpoint[8..12].copy_from_slice(&BOOTSTRAP_SCHEMA_VERSION.to_le_bytes());
        assert!(decode_native_entry_checkpoint(&checkpoint, &"bc".repeat(32)).is_err());
    }

    #[test]
    fn evidence_requires_exact_bootstrap_nonce_resume_and_loader_budget() {
        let evidence = BootstrapLaunchEvidence {
            schema_version: BOOTSTRAP_SCHEMA_VERSION,
            account_launcher_sha256: "12".repeat(32),
            bootstrap_sha256: "ef".repeat(32),
            config_nonce: "ab".repeat(32),
            config_consumed: true,
            account_launcher_config_consumed: true,
            account_launcher_ready_before_bootstrap: true,
            account_launcher_resume_previous_count: 1,
            bootstrap_resume_previous_count: 1,
            account_launcher_create_no_window: true,
            account_launcher_private_job_member: true,
            account_launcher_handles_exact: true,
            account_launcher_handle_inheritance_exact: true,
            account_launcher_supervisor_target_exact: true,
            account_launcher_se_increase_quota_present: true,
            account_launcher_se_increase_quota_enabled: true,
            account_launcher_token_session_id: 4,
            bootstrap_created_suspended: true,
            bootstrap_created_with_create_process_as_user: true,
            bootstrap_empty_desktop_selection: true,
            bootstrap_explicit_handle_list: true,
            bootstrap_process_id: 41,
            bootstrap_primary_thread_id: 42,
            bootstrap_remote_handles_adopted: true,
            bootstrap_adoption_acknowledged_before_resume: true,
            bootstrap_handle_types_exact: true,
            bootstrap_image_identity_verified: true,
            bootstrap_exact_job_before_resume: true,
            bootstrap_account_token_identity_verified: true,
            bootstrap_suspended_state_verified: true,
            ready_elapsed_ms: 30_000,
            exact_job_proof: true,
            trusted_path_write_denied: true,
            bootstrap_write_denied: true,
            account_sid: "S-1-5-21-1-2-3-1001".into(),
            restricting_sid: "S-1-5-21-1-2-3-4".into(),
            system_restricting_sid: WINDOWS_WRITE_RESTRICTED_CODE_SID.into(),
            logon_sid: "S-1-5-5-123-456".into(),
            observed_window_station: "Service-0x0-123$".into(),
            observed_desktop: "Default".into(),
            os_assigned_desktop_ready_before_resume: true,
            window_station_noninteractive: true,
            desktop_noninteractive_default: true,
            bootstrap_create_no_window: true,
            broker_authentication_id: "0000000900000007".into(),
            restricted_authentication_id: "0000000900000007".into(),
            product_authentication_id: "0000000900000007".into(),
            account_token_session_id: 4,
            bootstrap_token_session_id: 4,
            restricted_token_session_id: 4,
            product_token_session_id: 4,
            token_session_ids_match: true,
            restricted_authentication_matches_broker: true,
            product_authentication_matches_broker: true,
            se_increase_quota_present: true,
            se_increase_quota_enabled: true,
            create_process_as_user_succeeded: true,
            restricted_token_write_restricted: true,
            restricted_token_restricting_sid_match: true,
            restricted_token_system_restricting_sid_match: true,
            restricted_token_logon_sid_match: true,
            restricted_token_low_integrity: true,
            restricted_token_no_enabled_privileges: true,
            window_station_logon_sid_dacl_proven: true,
            desktop_logon_sid_dacl_proven: true,
            window_station_low_integrity: true,
            desktop_low_integrity: true,
            restricted_desktop_access_proven: true,
            job_ui_restriction_mask: WINDOWS_JOB_UI_RESTRICTION_MASK,
            job_ui_restrictions_exact_before_resume: true,
            product_write_restricted: true,
            product_restricting_sid_match: true,
            product_system_restricting_sid_match: true,
            product_logon_sid_match: true,
            product_low_integrity: true,
            product_no_enabled_privileges: true,
            product_exact_job: true,
            product_desktop_assignment_match: true,
            product_window_station_low_integrity: true,
            product_desktop_low_integrity: true,
            product_create_no_window: true,
            product_resume_previous_count: 1,
        };
        evidence.validate(&"ab".repeat(32), &"ef".repeat(32)).unwrap();
        let mut wrong_resume = evidence.clone();
        wrong_resume.bootstrap_resume_previous_count = 2;
        assert!(wrong_resume.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_sid_proof = evidence.clone();
        wrong_sid_proof.product_restricting_sid_match = false;
        assert!(wrong_sid_proof.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_logon_sid_proof = evidence.clone();
        wrong_logon_sid_proof.product_logon_sid_match = false;
        assert!(wrong_logon_sid_proof.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut invalid_logon_sid = evidence.clone();
        invalid_logon_sid.logon_sid = "not-a-sid".into();
        assert!(invalid_logon_sid.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_desktop = evidence.clone();
        wrong_desktop.observed_window_station = "WinSta0".into();
        assert!(wrong_desktop.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut desktop_proven_too_late = evidence.clone();
        desktop_proven_too_late.os_assigned_desktop_ready_before_resume = false;
        assert!(desktop_proven_too_late.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_session = evidence.clone();
        wrong_session.product_token_session_id += 1;
        assert!(wrong_session.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_job_ui_mask = evidence.clone();
        wrong_job_ui_mask.job_ui_restriction_mask = 0xfe;
        assert!(wrong_job_ui_mask.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut missing_logon_dacl = evidence.clone();
        missing_logon_dacl.desktop_logon_sid_dacl_proven = false;
        assert!(missing_logon_dacl.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut missing_low_label = evidence.clone();
        missing_low_label.window_station_low_integrity = false;
        assert!(missing_low_label.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut console_window_allowed = evidence.clone();
        console_window_allowed.bootstrap_create_no_window = false;
        assert!(console_window_allowed.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut wrong_product_resume = evidence.clone();
        wrong_product_resume.product_resume_previous_count = 2;
        assert!(wrong_product_resume.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut late = evidence;
        late.ready_elapsed_ms = 30_001;
        assert!(late.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
    }
}
