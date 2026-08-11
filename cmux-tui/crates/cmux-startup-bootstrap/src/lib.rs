use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub const BOOTSTRAP_SCHEMA_VERSION: u32 = 5;
pub const MAX_BOOTSTRAP_CONFIG_BYTES: usize = 64 * 1024;
pub const MAX_BOOTSTRAP_RECORD_BYTES: usize = 4 * 1024;
pub const CONFIG_MAGIC: [u8; 8] = *b"CMUXB001";
pub const ARM_MAGIC: [u8; 8] = *b"CMUXA001";
pub const EVENT_MAGIC: [u8; 8] = *b"CMUXE001";
pub const NATIVE_ENTRY_CHECKPOINT_MAGIC: [u8; 8] = *b"CMUXN001";

const CONFIG_HEADER_BYTES: usize = 104;
const RECORD_HEADER_BYTES: usize = 56;
const CONFIG_FIELD_COUNT: u32 = 10;
const REQUIRED_HANDLE_COUNT: usize = 6;
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
const READY_PRIVATE_WINDOW_STATION: u32 = 1 << 15;
const READY_PRIVATE_DESKTOP: u32 = 1 << 16;
const READY_WINDOW_STATION_DACL: u32 = 1 << 17;
const READY_DESKTOP_DACL: u32 = 1 << 18;
const READY_WINDOW_STATION_LOW_INTEGRITY: u32 = 1 << 19;
const READY_DESKTOP_LOW_INTEGRITY: u32 = 1 << 20;
const READY_RESTRICTED_DESKTOP_ACCESS: u32 = 1 << 21;
const READY_RESTRICTED_LOGON_SID_MATCH: u32 = 1 << 22;
const READY_WINDOW_STATION_LOGON_SID_DACL: u32 = 1 << 23;
const READY_DESKTOP_LOGON_SID_DACL: u32 = 1 << 24;
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
    | READY_PRIVATE_WINDOW_STATION
    | READY_PRIVATE_DESKTOP
    | READY_WINDOW_STATION_DACL
    | READY_DESKTOP_DACL
    | READY_WINDOW_STATION_LOW_INTEGRITY
    | READY_DESKTOP_LOW_INTEGRITY
    | READY_RESTRICTED_DESKTOP_ACCESS
    | READY_RESTRICTED_LOGON_SID_MATCH
    | READY_WINDOW_STATION_LOGON_SID_DACL
    | READY_DESKTOP_LOGON_SID_DACL;
const EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED: u32 = 1 << 0;
const EXIT_PRODUCT_AUTHENTICATION_MATCH: u32 = 1 << 1;
const EXIT_PRODUCT_LOW_INTEGRITY: u32 = 1 << 2;
const EXIT_PRODUCT_WRITE_RESTRICTED: u32 = 1 << 3;
const EXIT_PRODUCT_NO_ENABLED_PRIVILEGES: u32 = 1 << 4;
const EXIT_PRODUCT_RESTRICTING_SID_MATCH: u32 = 1 << 5;
const EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH: u32 = 1 << 6;
const EXIT_PRODUCT_PRIVATE_DESKTOP: u32 = 1 << 7;
const EXIT_PRODUCT_CREATE_NO_WINDOW: u32 = 1 << 8;
const EXIT_PRODUCT_LOGON_SID_MATCH: u32 = 1 << 9;
const EXIT_ALL_FLAGS: u32 = EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED
    | EXIT_PRODUCT_AUTHENTICATION_MATCH
    | EXIT_PRODUCT_LOW_INTEGRITY
    | EXIT_PRODUCT_WRITE_RESTRICTED
    | EXIT_PRODUCT_NO_ENABLED_PRIVILEGES
    | EXIT_PRODUCT_RESTRICTING_SID_MATCH
    | EXIT_PRODUCT_SYSTEM_RESTRICTING_SID_MATCH
    | EXIT_PRODUCT_PRIVATE_DESKTOP
    | EXIT_PRODUCT_CREATE_NO_WINDOW
    | EXIT_PRODUCT_LOGON_SID_MATCH;
const MAX_RESTRICTING_SID_BYTES: usize = 184;
pub const WINDOWS_WRITE_RESTRICTED_CODE_SID: &str = "S-1-5-33";

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
    pub private_window_station: String,
    pub private_desktop: String,
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
        let (expected_station, expected_desktop) = windows_private_desktop_identity(&self.nonce)?;
        if self.launch.private_window_station != expected_station
            || format!("{}\\{}", self.launch.private_window_station, self.launch.private_desktop)
                != expected_desktop
        {
            bail!("Windows bootstrap private desktop identity changed");
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
        if [
            self.control_read,
            self.control_write,
            self.standard_handles[0],
            self.standard_handles[1],
            self.standard_handles[2],
            self.query_job,
        ]
        .contains(&0)
        {
            bail!("Windows bootstrap config omitted a required transferred handle");
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
    RestrictedDesktopAccessReady = 8,
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
            8 => Ok(Self::RestrictedDesktopAccessReady),
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
        private_window_station: bool,
        private_desktop: bool,
        window_station_dacl: bool,
        desktop_dacl: bool,
        window_station_low_integrity: bool,
        desktop_low_integrity: bool,
        restricted_desktop_access: bool,
        restricted_logon_sid_match: bool,
        window_station_logon_sid_dacl: bool,
        desktop_logon_sid_dacl: bool,
        broker_authentication_id: AuthenticationId,
        restricted_authentication_id: AuthenticationId,
        restricting_sid: String,
        logon_sid: String,
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
        product_private_desktop: bool,
        product_create_no_window: bool,
        product_logon_sid_match: bool,
        product_authentication_id: AuthenticationId,
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
        product_private_desktop: bool,
        product_create_no_window: bool,
        product_logon_sid_match: bool,
        product_authentication_id: AuthenticationId,
        resume_previous_count: u32,
    },
    Error {
        nonce: String,
        windows_error: u32,
        stage: u32,
    },
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
    pub bootstrap_sha256: String,
    pub config_nonce: String,
    pub config_consumed: bool,
    pub resume_previous_count: u32,
    pub ready_elapsed_ms: u64,
    pub exact_job_proof: bool,
    pub trusted_path_write_denied: bool,
    pub bootstrap_write_denied: bool,
    pub account_sid: String,
    pub restricting_sid: String,
    pub system_restricting_sid: String,
    pub logon_sid: String,
    pub private_window_station: String,
    pub private_desktop: String,
    pub private_desktop_ready_before_resume: bool,
    pub bootstrap_create_no_window: bool,
    pub broker_authentication_id: String,
    pub restricted_authentication_id: String,
    pub product_authentication_id: String,
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
    pub window_station_dacl_proven: bool,
    pub desktop_dacl_proven: bool,
    pub window_station_logon_sid_dacl_proven: bool,
    pub desktop_logon_sid_dacl_proven: bool,
    pub window_station_low_integrity: bool,
    pub desktop_low_integrity: bool,
    pub restricted_desktop_access_proven: bool,
    pub product_write_restricted: bool,
    pub product_restricting_sid_match: bool,
    pub product_system_restricting_sid_match: bool,
    pub product_logon_sid_match: bool,
    pub product_low_integrity: bool,
    pub product_no_enabled_privileges: bool,
    pub product_exact_job: bool,
    pub product_private_desktop: bool,
    pub product_create_no_window: bool,
    pub product_resume_previous_count: u32,
}

impl BootstrapLaunchEvidence {
    pub fn validate(&self, expected_nonce: &str, expected_bootstrap_sha256: &str) -> Result<()> {
        let (expected_station, expected_desktop) =
            windows_private_desktop_identity(expected_nonce)?;
        if self.schema_version != BOOTSTRAP_SCHEMA_VERSION
            || self.config_nonce != expected_nonce
            || self.bootstrap_sha256 != expected_bootstrap_sha256
            || !self.config_consumed
            || self.resume_previous_count != 1
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
            || self.private_window_station != expected_station
            || self.private_desktop != expected_desktop
            || !self.private_desktop_ready_before_resume
            || !self.bootstrap_create_no_window
            || !self.window_station_dacl_proven
            || !self.desktop_dacl_proven
            || !self.window_station_logon_sid_dacl_proven
            || !self.desktop_logon_sid_dacl_proven
            || !self.window_station_low_integrity
            || !self.desktop_low_integrity
            || !self.restricted_desktop_access_proven
            || !self.product_write_restricted
            || !self.product_restricting_sid_match
            || !self.product_system_restricting_sid_match
            || !self.product_logon_sid_match
            || !self.product_low_integrity
            || !self.product_no_enabled_privileges
            || !self.product_exact_job
            || !self.product_private_desktop
            || !self.product_create_no_window
            || self.product_resume_previous_count != 1
        {
            bail!("Windows bootstrap evidence identity or containment proof failed");
        }
        validate_hex(&self.config_nonce, 64, "bootstrap evidence nonce")?;
        validate_hex(&self.bootstrap_sha256, 64, "bootstrap evidence executable SHA-256")?;
        validate_hex(&self.broker_authentication_id, 16, "broker authentication ID")?;
        validate_hex(&self.restricted_authentication_id, 16, "restricted authentication ID")?;
        validate_hex(&self.product_authentication_id, 16, "product authentication ID")?;
        validate_restricting_sid(&self.account_sid)?;
        validate_restricting_sid(&self.restricting_sid)?;
        validate_logon_sid(&self.logon_sid)
    }
}

pub fn windows_private_desktop_identity(nonce: &str) -> Result<(String, String)> {
    validate_hex(nonce, 64, "private desktop nonce")?;
    let station = format!("cmux-ws-{}", &nonce[..32]);
    let desktop = format!("{station}\\cmux-desk-{}", &nonce[32..]);
    Ok((station, desktop))
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
    let (expected_station, expected_desktop) = windows_private_desktop_identity(&config.nonce)?;
    if config.launch.private_window_station != expected_station
        || format!("{}\\{}", config.launch.private_window_station, config.launch.private_desktop)
            != expected_desktop
    {
        bail!("Windows bootstrap private desktop identity changed");
    }
    let handles = [
        config.control_read,
        config.control_write,
        config.standard_handles[0],
        config.standard_handles[1],
        config.standard_handles[2],
        config.query_job,
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
    push_path(&mut bytes, &config.launch.timing)?;
    push_path(&mut bytes, &config.launch.fixture_root)?;
    push_path(&mut bytes, &config.launch.target)?;
    push_bytes(&mut bytes, config.launch.target_sha256.as_bytes())?;
    push_path(&mut bytes, &config.launch.trusted_path_probe)?;
    push_bytes(&mut bytes, config.launch.expected_bootstrap_sha256.as_bytes())?;
    push_bytes(&mut bytes, config.launch.restricting_sid.as_bytes())?;
    push_bytes(&mut bytes, config.launch.logon_sid.as_bytes())?;
    push_utf16(&mut bytes, &config.launch.private_window_station)?;
    push_utf16(&mut bytes, &config.launch.private_desktop)?;
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
    let private_window_station = take_utf16_string(bytes, &mut cursor)?;
    let private_desktop = take_utf16_string(bytes, &mut cursor)?;
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
            private_window_station,
            private_desktop,
        },
        control_read: handles[0],
        control_write: handles[1],
        standard_handles: [handles[2], handles[3], handles[4]],
        query_job: handles[5],
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
        1 if bytes.len() == 60 && flags == 0 => Ok(BootstrapMessage::Stage {
            nonce,
            stage: BootstrapChildStage::from_u32(read_u32(bytes, 56)?)?,
        }),
        2 if bytes.len() >= 112 && flags & !READY_ALL_FLAGS == 0 => {
            let sid_length = usize::try_from(read_u32(bytes, 104)?)?;
            let logon_sid_length = usize::try_from(read_u32(bytes, 108)?)?;
            if sid_length == 0
                || sid_length > MAX_RESTRICTING_SID_BYTES
                || logon_sid_length == 0
                || logon_sid_length > MAX_RESTRICTING_SID_BYTES
                || bytes.len() != 112 + sid_length + logon_sid_length
            {
                bail!("Windows bootstrap READY SID length was invalid");
            }
            let restricting_end = 112 + sid_length;
            let restricting_sid = std::str::from_utf8(&bytes[112..restricting_end])?.to_owned();
            let logon_sid = std::str::from_utf8(&bytes[restricting_end..])?.to_owned();
            validate_restricting_sid(&restricting_sid)?;
            validate_logon_sid(&logon_sid)?;
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
                private_window_station: flags & READY_PRIVATE_WINDOW_STATION != 0,
                private_desktop: flags & READY_PRIVATE_DESKTOP != 0,
                window_station_dacl: flags & READY_WINDOW_STATION_DACL != 0,
                desktop_dacl: flags & READY_DESKTOP_DACL != 0,
                window_station_low_integrity: flags & READY_WINDOW_STATION_LOW_INTEGRITY != 0,
                desktop_low_integrity: flags & READY_DESKTOP_LOW_INTEGRITY != 0,
                restricted_desktop_access: flags & READY_RESTRICTED_DESKTOP_ACCESS != 0,
                restricted_logon_sid_match: flags & READY_RESTRICTED_LOGON_SID_MATCH != 0,
                window_station_logon_sid_dacl: flags & READY_WINDOW_STATION_LOGON_SID_DACL != 0,
                desktop_logon_sid_dacl: flags & READY_DESKTOP_LOGON_SID_DACL != 0,
                broker_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 88)?,
                    high_part: read_u32(bytes, 92)? as i32,
                },
                restricted_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 96)?,
                    high_part: read_u32(bytes, 100)? as i32,
                },
                restricting_sid,
                logon_sid,
            })
        }
        3 if bytes.len() == 72 && flags & !EXIT_ALL_FLAGS == 0 => {
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
                product_private_desktop: flags & EXIT_PRODUCT_PRIVATE_DESKTOP != 0,
                product_create_no_window: flags & EXIT_PRODUCT_CREATE_NO_WINDOW != 0,
                product_logon_sid_match: flags & EXIT_PRODUCT_LOGON_SID_MATCH != 0,
                product_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 64)?,
                    high_part: read_u32(bytes, 68)? as i32,
                },
            })
        }
        4 if bytes.len() == 64 && flags == 0 => Ok(BootstrapMessage::Error {
            nonce,
            windows_error: read_u32(bytes, 56)?,
            stage: read_u32(bytes, 60)?,
        }),
        5 if bytes.len() == 72 && flags & !EXIT_ALL_FLAGS == 0 => {
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
                product_private_desktop: flags & EXIT_PRODUCT_PRIVATE_DESKTOP != 0,
                product_create_no_window: flags & EXIT_PRODUCT_CREATE_NO_WINDOW != 0,
                product_logon_sid_match: flags & EXIT_PRODUCT_LOGON_SID_MATCH != 0,
                product_authentication_id: AuthenticationId {
                    low_part: read_u32(bytes, 60)?,
                    high_part: read_u32(bytes, 64)? as i32,
                },
                resume_previous_count: read_u32(bytes, 68)?,
            })
        }
        _ => bail!("Windows bootstrap event type, flags, or length changed"),
    }
}

#[cfg(test)]
fn encode_event(message: &BootstrapMessage) -> Result<Vec<u8>> {
    let (event_type, flags, nonce, payload) = match message {
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
            private_window_station,
            private_desktop,
            window_station_dacl,
            desktop_dacl,
            window_station_low_integrity,
            desktop_low_integrity,
            restricted_desktop_access,
            restricted_logon_sid_match,
            window_station_logon_sid_dacl,
            desktop_logon_sid_dacl,
            broker_authentication_id,
            restricted_authentication_id,
            restricting_sid,
            logon_sid,
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
            flags |= u32::from(*private_window_station) * READY_PRIVATE_WINDOW_STATION;
            flags |= u32::from(*private_desktop) * READY_PRIVATE_DESKTOP;
            flags |= u32::from(*window_station_dacl) * READY_WINDOW_STATION_DACL;
            flags |= u32::from(*desktop_dacl) * READY_DESKTOP_DACL;
            flags |= u32::from(*window_station_low_integrity) * READY_WINDOW_STATION_LOW_INTEGRITY;
            flags |= u32::from(*desktop_low_integrity) * READY_DESKTOP_LOW_INTEGRITY;
            flags |= u32::from(*restricted_desktop_access) * READY_RESTRICTED_DESKTOP_ACCESS;
            flags |= u32::from(*restricted_logon_sid_match) * READY_RESTRICTED_LOGON_SID_MATCH;
            flags |=
                u32::from(*window_station_logon_sid_dacl) * READY_WINDOW_STATION_LOGON_SID_DACL;
            flags |= u32::from(*desktop_logon_sid_dacl) * READY_DESKTOP_LOGON_SID_DACL;
            validate_restricting_sid(restricting_sid)?;
            validate_logon_sid(logon_sid)?;
            let mut payload = decode_hex_32(bootstrap_sha256, "bootstrap SHA-256")?.to_vec();
            payload.extend_from_slice(&broker_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(broker_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&restricted_authentication_id.low_part.to_le_bytes());
            payload
                .extend_from_slice(&(restricted_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&u32::try_from(restricting_sid.len())?.to_le_bytes());
            payload.extend_from_slice(&u32::try_from(logon_sid.len())?.to_le_bytes());
            payload.extend_from_slice(restricting_sid.as_bytes());
            payload.extend_from_slice(logon_sid.as_bytes());
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
            product_private_desktop,
            product_create_no_window,
            product_logon_sid_match,
            product_authentication_id,
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
            flags |= u32::from(*product_private_desktop) * EXIT_PRODUCT_PRIVATE_DESKTOP;
            flags |= u32::from(*product_create_no_window) * EXIT_PRODUCT_CREATE_NO_WINDOW;
            flags |= u32::from(*product_logon_sid_match) * EXIT_PRODUCT_LOGON_SID_MATCH;
            let mut payload = code.to_le_bytes().to_vec();
            payload.extend_from_slice(&u32::from(*private_job_descendant_contained).to_le_bytes());
            payload.extend_from_slice(&product_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(product_authentication_id.high_part as u32).to_le_bytes());
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
            product_private_desktop,
            product_create_no_window,
            product_logon_sid_match,
            product_authentication_id,
            resume_previous_count,
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
            flags |= u32::from(*product_private_desktop) * EXIT_PRODUCT_PRIVATE_DESKTOP;
            flags |= u32::from(*product_create_no_window) * EXIT_PRODUCT_CREATE_NO_WINDOW;
            flags |= u32::from(*product_logon_sid_match) * EXIT_PRODUCT_LOGON_SID_MATCH;
            let mut payload = u32::from(*private_job_descendant_contained).to_le_bytes().to_vec();
            payload.extend_from_slice(&product_authentication_id.low_part.to_le_bytes());
            payload.extend_from_slice(&(product_authentication_id.high_part as u32).to_le_bytes());
            payload.extend_from_slice(&resume_previous_count.to_le_bytes());
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
                private_window_station: "cmux-ws-abababababababababababababababab".into(),
                private_desktop: "cmux-desk-abababababababababababababababab".into(),
            },
            control_read: 11,
            control_write: 12,
            standard_handles: [13, 14, 15],
            query_job: 16,
        }
    }

    #[test]
    fn bounded_binary_config_round_trip_preserves_schema_and_nonce() {
        let config = config();
        let bytes = encode_config(&config).unwrap();
        let decoded = decode_config(&bytes).unwrap();
        assert_eq!(decoded, config);
        decoded.validate_identity(Path::new("/fixture/bootstrap-abababababababab.bin")).unwrap();
    }

    #[test]
    fn binary_config_rejects_schema_nonce_and_record_bounds() {
        let mut bytes = encode_config(&config()).unwrap();
        bytes[8..12].copy_from_slice(&(BOOTSTRAP_SCHEMA_VERSION + 1).to_le_bytes());
        assert!(decode_config(&bytes).is_err());
        assert!(config().validate_identity(Path::new("/fixture/bootstrap-wrong.bin")).is_err());
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
        let mut interactive_desktop = config();
        interactive_desktop.launch.private_window_station = "WinSta0".into();
        interactive_desktop.launch.private_desktop = "Default".into();
        assert!(encode_config(&interactive_desktop).is_err());
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
    }

    #[test]
    fn private_desktop_identity_is_nonce_bound_and_noninteractive() {
        let nonce = format!("{}{}", "12".repeat(16), "34".repeat(16));
        let (station, desktop) = windows_private_desktop_identity(&nonce).unwrap();
        assert_eq!(station, format!("cmux-ws-{}", "12".repeat(16)));
        assert_eq!(desktop, format!("cmux-ws-{}\\cmux-desk-{}", "12".repeat(16), "34".repeat(16)));
        assert!(!station.eq_ignore_ascii_case("WinSta0"));
        assert!(windows_private_desktop_identity("bad").is_err());
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
            private_window_station: true,
            private_desktop: true,
            window_station_dacl: true,
            desktop_dacl: true,
            window_station_low_integrity: true,
            desktop_low_integrity: true,
            restricted_desktop_access: true,
            restricted_logon_sid_match: true,
            window_station_logon_sid_dacl: true,
            desktop_logon_sid_dacl: true,
            broker_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            restricted_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            restricting_sid: "S-1-5-21-1-2-3-4".into(),
            logon_sid: "S-1-5-5-123-456".into(),
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
            product_private_desktop: true,
            product_create_no_window: true,
            product_logon_sid_match: true,
            product_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
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
            product_private_desktop: true,
            product_create_no_window: true,
            product_logon_sid_match: true,
            product_authentication_id: AuthenticationId { low_part: 7, high_part: 9 },
            resume_previous_count: 1,
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
            bootstrap_sha256: "ef".repeat(32),
            config_nonce: "ab".repeat(32),
            config_consumed: true,
            resume_previous_count: 1,
            ready_elapsed_ms: 30_000,
            exact_job_proof: true,
            trusted_path_write_denied: true,
            bootstrap_write_denied: true,
            account_sid: "S-1-5-21-1-2-3-1001".into(),
            restricting_sid: "S-1-5-21-1-2-3-4".into(),
            system_restricting_sid: WINDOWS_WRITE_RESTRICTED_CODE_SID.into(),
            logon_sid: "S-1-5-5-123-456".into(),
            private_window_station: "cmux-ws-abababababababababababababababab".into(),
            private_desktop:
                "cmux-ws-abababababababababababababababab\\cmux-desk-abababababababababababababababab"
                    .into(),
            private_desktop_ready_before_resume: true,
            bootstrap_create_no_window: true,
            broker_authentication_id: "0000000900000007".into(),
            restricted_authentication_id: "0000000900000007".into(),
            product_authentication_id: "0000000900000007".into(),
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
            window_station_dacl_proven: true,
            desktop_dacl_proven: true,
            window_station_logon_sid_dacl_proven: true,
            desktop_logon_sid_dacl_proven: true,
            window_station_low_integrity: true,
            desktop_low_integrity: true,
            restricted_desktop_access_proven: true,
            product_write_restricted: true,
            product_restricting_sid_match: true,
            product_system_restricting_sid_match: true,
            product_logon_sid_match: true,
            product_low_integrity: true,
            product_no_enabled_privileges: true,
            product_exact_job: true,
            product_private_desktop: true,
            product_create_no_window: true,
            product_resume_previous_count: 1,
        };
        evidence.validate(&"ab".repeat(32), &"ef".repeat(32)).unwrap();
        let mut wrong_resume = evidence.clone();
        wrong_resume.resume_previous_count = 2;
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
        wrong_desktop.private_desktop = "WinSta0\\Default".into();
        assert!(wrong_desktop.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut desktop_proven_too_late = evidence.clone();
        desktop_proven_too_late.private_desktop_ready_before_resume = false;
        assert!(desktop_proven_too_late.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
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
