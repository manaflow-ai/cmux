use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub const BOOTSTRAP_SCHEMA_VERSION: u32 = 1;
pub const MAX_BOOTSTRAP_CONFIG_BYTES: usize = 64 * 1024;
pub const MAX_BOOTSTRAP_RECORD_BYTES: usize = 4 * 1024;
pub const CONFIG_MAGIC: [u8; 8] = *b"CMUXB001";
pub const ARM_MAGIC: [u8; 8] = *b"CMUXA001";
pub const EVENT_MAGIC: [u8; 8] = *b"CMUXE001";

const CONFIG_HEADER_BYTES: usize = 104;
const RECORD_HEADER_BYTES: usize = 56;
const CONFIG_FIELD_COUNT: u32 = 6;
const REQUIRED_HANDLE_COUNT: usize = 6;
const MAX_PRODUCT_ARGUMENTS: usize = 1024;
const READY_CONFIG_CONSUMED: u32 = 1 << 0;
const READY_HANDLES_VALID: u32 = 1 << 1;
const READY_HANDLES_INHERITABLE: u32 = 1 << 2;
const READY_PRIVATE_JOB_MEMBER: u32 = 1 << 3;
const READY_TRUSTED_PATH_DENIED: u32 = 1 << 4;
const READY_ALL_FLAGS: u32 = READY_CONFIG_CONSUMED
    | READY_HANDLES_VALID
    | READY_HANDLES_INHERITABLE
    | READY_PRIVATE_JOB_MEMBER
    | READY_TRUSTED_PATH_DENIED;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapProductLaunch {
    pub timing: PathBuf,
    pub fixture_root: PathBuf,
    pub target: PathBuf,
    pub target_sha256: String,
    pub product_args: Vec<String>,
    pub trusted_path_probe: PathBuf,
    pub expected_bootstrap_sha256: String,
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
}

impl BootstrapChildStage {
    fn from_u32(value: u32) -> Result<Self> {
        match value {
            1 => Ok(Self::ConfigConsumed),
            2 => Ok(Self::LaunchValidated),
            3 => Ok(Self::StandardHandlesValidated),
            4 => Ok(Self::TimingConsumed),
            _ => bail!("Windows bootstrap event contained an unknown stage"),
        }
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
    },
    Exit {
        nonce: String,
        code: u32,
        private_job_descendant_contained: bool,
    },
    Error {
        nonce: String,
        windows_error: u32,
        stage: u32,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
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
}

impl BootstrapLaunchEvidence {
    pub fn validate(&self, expected_nonce: &str, expected_bootstrap_sha256: &str) -> Result<()> {
        if self.schema_version != BOOTSTRAP_SCHEMA_VERSION
            || self.config_nonce != expected_nonce
            || self.bootstrap_sha256 != expected_bootstrap_sha256
            || !self.config_consumed
            || self.resume_previous_count != 1
            || self.ready_elapsed_ms > 30_000
            || !self.exact_job_proof
            || !self.trusted_path_write_denied
        {
            bail!("Windows bootstrap evidence identity or containment proof failed");
        }
        validate_hex(&self.config_nonce, 64, "bootstrap evidence nonce")?;
        validate_hex(&self.bootstrap_sha256, 64, "bootstrap evidence executable SHA-256")
    }
}

pub fn encode_config(config: &BootstrapConfig) -> Result<Vec<u8>> {
    if config.schema_version != BOOTSTRAP_SCHEMA_VERSION {
        bail!("Windows bootstrap config schema changed");
    }
    let nonce = decode_hex_32(&config.nonce, "bootstrap nonce")?;
    validate_hex(&config.launch.target_sha256, 64, "bootstrap target SHA-256")?;
    validate_hex(&config.launch.expected_bootstrap_sha256, 64, "bootstrap executable SHA-256")?;
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
        2 if bytes.len() == 88 && flags & !READY_ALL_FLAGS == 0 => Ok(BootstrapMessage::Ready {
            nonce,
            bootstrap_sha256: encode_hex(&bytes[56..88]),
            config_consumed: flags & READY_CONFIG_CONSUMED != 0,
            standard_handles_valid: flags & READY_HANDLES_VALID != 0,
            standard_handles_inheritable: flags & READY_HANDLES_INHERITABLE != 0,
            private_job_member: flags & READY_PRIVATE_JOB_MEMBER != 0,
            trusted_path_write_denied: flags & READY_TRUSTED_PATH_DENIED != 0,
        }),
        3 if bytes.len() == 64 && flags == 0 => {
            let contained = read_u32(bytes, 60)?;
            if contained > 1 {
                bail!("Windows bootstrap exit containment flag was invalid");
            }
            Ok(BootstrapMessage::Exit {
                nonce,
                code: read_u32(bytes, 56)?,
                private_job_descendant_contained: contained == 1,
            })
        }
        4 if bytes.len() == 64 && flags == 0 => Ok(BootstrapMessage::Error {
            nonce,
            windows_error: read_u32(bytes, 56)?,
            stage: read_u32(bytes, 60)?,
        }),
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
        } => {
            let mut flags = 0;
            flags |= u32::from(*config_consumed) * READY_CONFIG_CONSUMED;
            flags |= u32::from(*standard_handles_valid) * READY_HANDLES_VALID;
            flags |= u32::from(*standard_handles_inheritable) * READY_HANDLES_INHERITABLE;
            flags |= u32::from(*private_job_member) * READY_PRIVATE_JOB_MEMBER;
            flags |= u32::from(*trusted_path_write_denied) * READY_TRUSTED_PATH_DENIED;
            (2, flags, nonce, decode_hex_32(bootstrap_sha256, "bootstrap SHA-256")?.to_vec())
        }
        BootstrapMessage::Exit { nonce, code, private_job_descendant_contained } => {
            let mut payload = code.to_le_bytes().to_vec();
            payload.extend_from_slice(&u32::from(*private_job_descendant_contained).to_le_bytes());
            (3, 0, nonce, payload)
        }
        BootstrapMessage::Error { nonce, windows_error, stage } => {
            let mut payload = windows_error.to_le_bytes().to_vec();
            payload.extend_from_slice(&stage.to_le_bytes());
            (4, 0, nonce, payload)
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

    fn config() -> BootstrapConfig {
        BootstrapConfig {
            schema_version: BOOTSTRAP_SCHEMA_VERSION,
            nonce: "ab".repeat(32),
            launch: BootstrapProductLaunch {
                timing: PathBuf::from("/fixture/timing.page"),
                fixture_root: PathBuf::from("/fixture"),
                target: PathBuf::from("/trusted/cmux-tui.exe"),
                target_sha256: "cd".repeat(32),
                product_args: vec!["--version".into()],
                trusted_path_probe: PathBuf::from("/trusted/probe"),
                expected_bootstrap_sha256: "ef".repeat(32),
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
        bytes[8..12].copy_from_slice(&2_u32.to_le_bytes());
        assert!(decode_config(&bytes).is_err());
        assert!(config().validate_identity(Path::new("/fixture/bootstrap-wrong.bin")).is_err());
        let mut oversized = config();
        oversized.launch.product_args = vec!["x".repeat(MAX_BOOTSTRAP_CONFIG_BYTES)];
        assert!(encode_config(&oversized).is_err());
        let mut too_many = encode_config(&config()).unwrap();
        too_many[20..24]
            .copy_from_slice(&u32::try_from(MAX_PRODUCT_ARGUMENTS + 1).unwrap().to_le_bytes());
        assert!(decode_config(&too_many).is_err());
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
    fn event_decoder_preserves_type_flags_nonce_and_clean_eof() {
        let message = BootstrapMessage::Ready {
            nonce: "34".repeat(32),
            bootstrap_sha256: "56".repeat(32),
            config_consumed: true,
            standard_handles_valid: true,
            standard_handles_inheritable: true,
            private_job_member: true,
            trusted_path_write_denied: true,
        };
        let bytes = encode_event(&message).unwrap();
        assert_eq!(decode_event(&bytes).unwrap(), message);
        assert_eq!(read_event(&mut Cursor::new(bytes)).unwrap(), Some(message));
        assert_eq!(read_event(&mut Cursor::new(Vec::<u8>::new())).unwrap(), None);
    }

    #[test]
    fn event_decoder_rejects_wrong_schema_nonce_length_and_truncation() {
        let message =
            BootstrapMessage::Error { nonce: "78".repeat(32), windows_error: 5, stage: 7 };
        let mut schema = encode_event(&message).unwrap();
        schema[8..12].copy_from_slice(&2_u32.to_le_bytes());
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
        };
        evidence.validate(&"ab".repeat(32), &"ef".repeat(32)).unwrap();
        let mut wrong_resume = evidence.clone();
        wrong_resume.resume_previous_count = 2;
        assert!(wrong_resume.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
        let mut late = evidence;
        late.ready_elapsed_ms = 30_001;
        assert!(late.validate(&"ab".repeat(32), &"ef".repeat(32)).is_err());
    }
}
