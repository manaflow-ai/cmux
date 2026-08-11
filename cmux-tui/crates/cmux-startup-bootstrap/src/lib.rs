use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

pub const BOOTSTRAP_SCHEMA_VERSION: u32 = 1;
pub const MAX_BOOTSTRAP_MESSAGE_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapProductLaunch {
    pub timing: PathBuf,
    pub fixture_root: PathBuf,
    pub target: PathBuf,
    pub target_sha256: String,
    pub product_args: Vec<String>,
    pub trusted_path_probe: PathBuf,
    pub expected_bootstrap_sha256: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapConfig {
    pub schema_version: u32,
    pub nonce: String,
    pub launch: BootstrapProductLaunch,
    pub control_read: usize,
    pub control_write: usize,
    pub standard_handles: [usize; 3],
    pub query_job: Option<usize>,
}

impl BootstrapConfig {
    pub fn validate_identity(&self, config_path: &Path) -> Result<()> {
        if self.schema_version != BOOTSTRAP_SCHEMA_VERSION {
            bail!("Windows bootstrap config schema changed");
        }
        validate_hex(&self.nonce, 64, "bootstrap nonce")?;
        validate_hex(&self.launch.target_sha256, 64, "bootstrap target SHA-256")?;
        validate_hex(&self.launch.expected_bootstrap_sha256, 64, "bootstrap executable SHA-256")?;
        let expected_name = format!("bootstrap-{}.json", &self.nonce[..16]);
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
        if self.control_read == 0
            || self.control_write == 0
            || self.standard_handles.contains(&0)
            || self.query_job.is_none_or(|handle| handle == 0)
        {
            bail!("Windows bootstrap config omitted a required transferred handle");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BootstrapChildStage {
    ConfigConsumed,
    LaunchValidated,
    StandardHandlesValidated,
    TimingConsumed,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum BootstrapCommand {
    Arm { nonce: String },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
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
        error: String,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapLaunchEvidence {
    pub schema_version: u32,
    pub bootstrap_sha256: String,
    pub config_nonce: String,
    pub config_consumed: bool,
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
            || !self.exact_job_proof
            || !self.trusted_path_write_denied
        {
            bail!("Windows bootstrap evidence identity or containment proof failed");
        }
        validate_hex(&self.config_nonce, 64, "bootstrap evidence nonce")?;
        validate_hex(&self.bootstrap_sha256, 64, "bootstrap evidence executable SHA-256")
    }
}

fn validate_hex(value: &str, length: usize, name: &str) -> Result<()> {
    if value.len() != length || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{name} must be {length} hexadecimal characters");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> BootstrapConfig {
        let nonce = "ab".repeat(32);
        BootstrapConfig {
            schema_version: BOOTSTRAP_SCHEMA_VERSION,
            nonce: nonce.clone(),
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
            query_job: Some(16),
        }
    }

    #[test]
    fn strict_schema_round_trip_preserves_nonce_identity() {
        let config = config();
        let bytes = serde_json::to_vec(&config).unwrap();
        let decoded: BootstrapConfig = serde_json::from_slice(&bytes).unwrap();
        decoded.validate_identity(Path::new("/fixture/bootstrap-abababababababab.json")).unwrap();
    }

    #[test]
    fn schema_rejects_unknown_fields_and_wrong_nonce_path() {
        let mut value = serde_json::to_value(config()).unwrap();
        value.as_object_mut().unwrap().insert("extra".into(), true.into());
        assert!(serde_json::from_value::<BootstrapConfig>(value).is_err());
        assert!(config().validate_identity(Path::new("/fixture/bootstrap-wrong.json")).is_err());
    }

    #[test]
    fn evidence_requires_the_exact_bootstrap_and_nonce() {
        let evidence = BootstrapLaunchEvidence {
            schema_version: BOOTSTRAP_SCHEMA_VERSION,
            bootstrap_sha256: "ef".repeat(32),
            config_nonce: "ab".repeat(32),
            config_consumed: true,
            ready_elapsed_ms: 17,
            exact_job_proof: true,
            trusted_path_write_denied: true,
        };
        evidence.validate(&"ab".repeat(32), &"ef".repeat(32)).unwrap();
        assert!(evidence.validate(&"cd".repeat(32), &"ef".repeat(32)).is_err());
    }
}
