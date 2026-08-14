use std::env;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

#[cfg(unix)]
use super::lifecycle::longest_control_socket_path;
use super::{Scenario, TargetKind};

const REQUIRED_WARMUPS: usize = 10;
const REQUIRED_SAMPLES: usize = 50;

#[derive(Debug)]
pub struct Args {
    pub trusted_sha: String,
    pub trusted_source: PathBuf,
    pub supervisor_binary: PathBuf,
    pub supervisor_binary_sha256: String,
    pub windows_bootstrap_binary: PathBuf,
    pub windows_bootstrap_sha256: String,
    pub sandbox_backend: String,
    pub sandbox_preflight: PathBuf,
    pub sandbox_preflight_sha256: String,
    pub baseline_binary: PathBuf,
    pub candidate_binary: PathBuf,
    pub baseline_source: PathBuf,
    pub candidate_source: PathBuf,
    pub baseline_sha: String,
    pub candidate_sha: String,
    pub baseline_binary_sha256: String,
    pub candidate_binary_sha256: String,
    pub warmups: usize,
    pub samples: usize,
    pub suite_deadline_seconds: usize,
    pub output_dir: PathBuf,
    pub fixture_parent: PathBuf,
    pub platform_label: String,
    pub profile_only: Option<Scenario>,
    pub profile_target: Option<TargetKind>,
    pub baseline_launcher: Vec<String>,
    pub candidate_launcher: Vec<String>,
}

impl Args {
    pub fn parse() -> Result<Self> {
        let mut parser = Parser::new(env::args().skip(1));
        let mut args = Self {
            trusted_sha: String::new(),
            trusted_source: PathBuf::new(),
            supervisor_binary: PathBuf::new(),
            supervisor_binary_sha256: String::new(),
            windows_bootstrap_binary: PathBuf::new(),
            windows_bootstrap_sha256: String::new(),
            sandbox_backend: String::new(),
            sandbox_preflight: PathBuf::new(),
            sandbox_preflight_sha256: String::new(),
            baseline_binary: PathBuf::new(),
            candidate_binary: PathBuf::new(),
            baseline_source: PathBuf::new(),
            candidate_source: PathBuf::new(),
            baseline_sha: String::new(),
            candidate_sha: String::new(),
            baseline_binary_sha256: String::new(),
            candidate_binary_sha256: String::new(),
            warmups: REQUIRED_WARMUPS,
            samples: REQUIRED_SAMPLES,
            suite_deadline_seconds: 3_600,
            output_dir: PathBuf::new(),
            fixture_parent: PathBuf::new(),
            platform_label: String::new(),
            profile_only: None,
            profile_target: None,
            baseline_launcher: Vec::new(),
            candidate_launcher: Vec::new(),
        };

        while let Some((key, inline)) = parser.next_key()? {
            match key.as_str() {
                "--trusted-sha" => args.trusted_sha = parser.value(&key, inline)?,
                "--trusted-source" => args.trusted_source = parser.path(&key, inline)?,
                "--supervisor-binary" => args.supervisor_binary = parser.path(&key, inline)?,
                "--supervisor-binary-sha256" => {
                    args.supervisor_binary_sha256 = parser.value(&key, inline)?;
                }
                "--windows-bootstrap-binary" => {
                    args.windows_bootstrap_binary = parser.path(&key, inline)?;
                }
                "--windows-bootstrap-sha256" => {
                    args.windows_bootstrap_sha256 = parser.value(&key, inline)?;
                }
                "--sandbox-backend" => args.sandbox_backend = parser.value(&key, inline)?,
                "--sandbox-preflight" => args.sandbox_preflight = parser.path(&key, inline)?,
                "--sandbox-preflight-sha256" => {
                    args.sandbox_preflight_sha256 = parser.value(&key, inline)?;
                }
                "--baseline-binary" => args.baseline_binary = parser.path(&key, inline)?,
                "--candidate-binary" => args.candidate_binary = parser.path(&key, inline)?,
                "--baseline-source" => args.baseline_source = parser.path(&key, inline)?,
                "--candidate-source" => args.candidate_source = parser.path(&key, inline)?,
                "--baseline-sha" => args.baseline_sha = parser.value(&key, inline)?,
                "--candidate-sha" => args.candidate_sha = parser.value(&key, inline)?,
                "--baseline-binary-sha256" => {
                    args.baseline_binary_sha256 = parser.value(&key, inline)?;
                }
                "--candidate-binary-sha256" => {
                    args.candidate_binary_sha256 = parser.value(&key, inline)?;
                }
                "--warmups" => args.warmups = parser.number(&key, inline)?,
                "--samples" => args.samples = parser.number(&key, inline)?,
                "--suite-deadline-seconds" => {
                    args.suite_deadline_seconds = parser.number(&key, inline)?;
                }
                "--output-dir" => args.output_dir = parser.path(&key, inline)?,
                "--fixture-parent" => args.fixture_parent = parser.path(&key, inline)?,
                "--platform-label" => args.platform_label = parser.value(&key, inline)?,
                "--profile-only" => args.profile_only = Some(parser.value(&key, inline)?.parse()?),
                "--profile-target" => {
                    args.profile_target = Some(parser.value(&key, inline)?.parse()?);
                }
                "--baseline-launcher-arg" => {
                    args.baseline_launcher.push(parser.value(&key, inline)?);
                }
                "--candidate-launcher-arg" => {
                    args.candidate_launcher.push(parser.value(&key, inline)?);
                }
                _ => bail!("unknown argument {key}"),
            }
        }
        args.validate()?;
        Ok(args)
    }

    fn validate(&mut self) -> Result<()> {
        self.trusted_source = canonical_directory(&self.trusted_source, "--trusted-source")?;
        self.supervisor_binary = canonical_file(&self.supervisor_binary, "--supervisor-binary")?;
        self.sandbox_preflight = canonical_file(&self.sandbox_preflight, "--sandbox-preflight")?;
        self.baseline_binary = canonical_file(&self.baseline_binary, "--baseline-binary")?;
        self.candidate_binary = canonical_file(&self.candidate_binary, "--candidate-binary")?;
        self.baseline_source = canonical_directory(&self.baseline_source, "--baseline-source")?;
        self.candidate_source = canonical_directory(&self.candidate_source, "--candidate-source")?;
        if self.baseline_binary == self.candidate_binary {
            bail!("baseline and candidate binaries must differ");
        }
        if self.baseline_source == self.candidate_source {
            bail!("baseline and candidate source directories must differ");
        }
        validate_sha(&self.trusted_sha, "--trusted-sha")?;
        validate_sha(&self.baseline_sha, "--baseline-sha")?;
        validate_sha(&self.candidate_sha, "--candidate-sha")?;
        if self.trusted_sha != self.baseline_sha {
            bail!("trusted and baseline SHAs must match");
        }
        validate_sha256(&self.supervisor_binary_sha256, "--supervisor-binary-sha256")?;
        #[cfg(windows)]
        {
            self.windows_bootstrap_binary =
                canonical_file(&self.windows_bootstrap_binary, "--windows-bootstrap-binary")?;
            validate_sha256(&self.windows_bootstrap_sha256, "--windows-bootstrap-sha256")?;
        }
        #[cfg(not(windows))]
        if !self.windows_bootstrap_binary.as_os_str().is_empty()
            || !self.windows_bootstrap_sha256.is_empty()
        {
            bail!("Windows bootstrap options are invalid on this platform");
        }
        validate_sha256(&self.sandbox_preflight_sha256, "--sandbox-preflight-sha256")?;
        if self.sandbox_backend != expected_sandbox_backend() {
            bail!("--sandbox-backend must be {} on this platform", expected_sandbox_backend());
        }
        validate_sha256(&self.baseline_binary_sha256, "--baseline-binary-sha256")?;
        validate_sha256(&self.candidate_binary_sha256, "--candidate-binary-sha256")?;
        if self.baseline_sha == self.candidate_sha {
            bail!("baseline and candidate SHAs must differ");
        }
        if self.output_dir.as_os_str().is_empty() {
            bail!("--output-dir is required");
        }
        if self.suite_deadline_seconds == 0 {
            bail!("--suite-deadline-seconds must be positive");
        }
        self.fixture_parent = canonical_directory(&self.fixture_parent, "--fixture-parent")?;
        validate_fixture_socket_path_budget(&self.fixture_parent)?;
        if self.platform_label.trim().is_empty() {
            bail!("--platform-label is required");
        }
        validate_comparison_counts(self.warmups, self.samples)?;
        match (self.profile_only, self.profile_target) {
            (Some(_), None) => bail!("--profile-target is required with --profile-only"),
            (None, Some(_)) => bail!("--profile-only is required with --profile-target"),
            (None, None) => {
                if !self.baseline_launcher.is_empty() || !self.candidate_launcher.is_empty() {
                    bail!("launcher arguments require --profile-only");
                }
            }
            (Some(_), Some(_)) => {}
        }
        Ok(())
    }
}

fn expected_sandbox_backend() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "linux-bwrap"
    }
    #[cfg(target_os = "macos")]
    {
        "macos-seatbelt"
    }
    #[cfg(windows)]
    {
        "windows-restricted-token-job"
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        "unsupported"
    }
}

fn validate_comparison_counts(warmups: usize, samples: usize) -> Result<()> {
    if warmups != REQUIRED_WARMUPS {
        bail!("startup evidence requires exactly {REQUIRED_WARMUPS} warmup pairs");
    }
    if samples != REQUIRED_SAMPLES {
        bail!("startup evidence requires exactly {REQUIRED_SAMPLES} measured pairs");
    }
    Ok(())
}

fn validate_sha(value: &str, option: &str) -> Result<()> {
    if value.len() != 40
        || !value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("{option} must be a lowercase 40-character hexadecimal SHA");
    }
    Ok(())
}

fn validate_sha256(value: &str, option: &str) -> Result<()> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{option} must be a 64-character hexadecimal SHA-256");
    }
    Ok(())
}

fn canonical_file(path: &Path, option: &str) -> Result<PathBuf> {
    if path.as_os_str().is_empty() {
        bail!("{option} is required");
    }
    let path = path.canonicalize().with_context(|| format!("resolve {option}"))?;
    if !path.is_file() {
        bail!("{option} is not a file: {}", path.display());
    }
    Ok(path)
}

fn canonical_directory(path: &Path, option: &str) -> Result<PathBuf> {
    if path.as_os_str().is_empty() {
        bail!("{option} is required");
    }
    let path = path.canonicalize().with_context(|| format!("resolve {option}"))?;
    if !path.is_dir() {
        bail!("{option} is not a directory: {}", path.display());
    }
    Ok(path)
}

#[cfg(unix)]
fn validate_fixture_socket_path_budget(parent: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;

    const MAX_SOCKET_PATH_BYTES: usize = 103;
    let socket_path_bytes = longest_control_socket_path(parent).as_os_str().as_bytes().len();
    if socket_path_bytes > MAX_SOCKET_PATH_BYTES {
        bail!(
            "--fixture-parent would require {socket_path_bytes} bytes for the longest control socket path, maximum is {MAX_SOCKET_PATH_BYTES}"
        );
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_fixture_socket_path_budget(_parent: &Path) -> Result<()> {
    Ok(())
}

struct Parser {
    values: std::vec::IntoIter<String>,
}

impl Parser {
    fn new(values: impl Iterator<Item = String>) -> Self {
        Self { values: values.collect::<Vec<_>>().into_iter() }
    }

    fn next_key(&mut self) -> Result<Option<(String, Option<String>)>> {
        let Some(argument) = self.values.next() else {
            return Ok(None);
        };
        if !argument.starts_with("--") {
            bail!("expected an option, got {argument}");
        }
        Ok(Some(match argument.split_once('=') {
            Some((key, value)) => (key.to_string(), Some(value.to_string())),
            None => (argument, None),
        }))
    }

    fn value(&mut self, key: &str, inline: Option<String>) -> Result<String> {
        inline
            .or_else(|| self.values.next())
            .filter(|value| !value.is_empty())
            .with_context(|| format!("{key} requires a value"))
    }

    fn path(&mut self, key: &str, inline: Option<String>) -> Result<PathBuf> {
        self.value(key, inline).map(PathBuf::from)
    }

    fn number(&mut self, key: &str, inline: Option<String>) -> Result<usize> {
        self.value(key, inline)?
            .parse()
            .with_context(|| format!("{key} requires a positive integer"))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn comparison_counts_are_fixed_for_comparable_evidence() {
        assert!(validate_comparison_counts(10, 50).is_ok());
        assert!(validate_comparison_counts(9, 50).is_err());
        assert!(validate_comparison_counts(11, 50).is_err());
        assert!(validate_comparison_counts(10, 49).is_err());
        assert!(validate_comparison_counts(10, 51).is_err());
        assert!(validate_comparison_counts(100, 500).is_err());
        assert!(validate_comparison_counts(10, usize::MAX).is_err());
    }

    #[test]
    fn source_identity_requires_full_lowercase_sha() {
        assert!(validate_sha(&"a".repeat(40), "--sha").is_ok());
        assert!(validate_sha(&"a".repeat(39), "--sha").is_err());
        assert!(validate_sha(&"a".repeat(41), "--sha").is_err());
        assert!(validate_sha(&"A".repeat(40), "--sha").is_err());
        assert!(validate_sha(&"g".repeat(40), "--sha").is_err());
    }

    #[test]
    fn trusted_infrastructure_must_equal_baseline_product_identity() -> Result<()> {
        #[cfg(unix)]
        let root = tempfile::Builder::new().prefix("cbt").tempdir_in("/tmp")?;
        #[cfg(not(unix))]
        let root = tempfile::Builder::new().prefix("cbt").tempdir()?;
        let root = root.path();
        let trusted_source = root.join("trusted-source");
        let baseline_source = root.join("baseline-source");
        let candidate_source = root.join("candidate-source");
        let fixture_parent = root.join("fixtures");
        for directory in [
            &trusted_source,
            &baseline_source,
            &candidate_source,
            &fixture_parent,
        ] {
            fs::create_dir(directory)?;
        }
        let supervisor_binary = root.join("supervisor");
        let sandbox_preflight = root.join("preflight.json");
        let baseline_binary = root.join("baseline");
        let candidate_binary = root.join("candidate");
        let windows_bootstrap_binary = root.join("bootstrap.exe");
        for file in [
            &supervisor_binary,
            &sandbox_preflight,
            &baseline_binary,
            &candidate_binary,
            &windows_bootstrap_binary,
        ] {
            fs::write(file, b"test")?;
        }

        let mut args = Args {
            trusted_sha: "a".repeat(40),
            trusted_source,
            supervisor_binary,
            supervisor_binary_sha256: "a".repeat(64),
            windows_bootstrap_binary: if cfg!(windows) {
                windows_bootstrap_binary
            } else {
                PathBuf::new()
            },
            windows_bootstrap_sha256: if cfg!(windows) {
                "a".repeat(64)
            } else {
                String::new()
            },
            sandbox_backend: expected_sandbox_backend().to_string(),
            sandbox_preflight,
            sandbox_preflight_sha256: "a".repeat(64),
            baseline_binary,
            candidate_binary,
            baseline_source,
            candidate_source,
            baseline_sha: "a".repeat(40),
            candidate_sha: "b".repeat(40),
            baseline_binary_sha256: "a".repeat(64),
            candidate_binary_sha256: "b".repeat(64),
            warmups: 10,
            samples: 50,
            suite_deadline_seconds: 3_600,
            output_dir: root.join("output"),
            fixture_parent,
            platform_label: "test".to_string(),
            profile_only: None,
            profile_target: None,
            baseline_launcher: Vec::new(),
            candidate_launcher: Vec::new(),
        };
        args.trusted_sha = "c".repeat(40);

        let error = args.validate().expect_err("trusted and baseline SHAs must match");
        assert!(error.to_string().contains("trusted and baseline SHAs must match"));
        Ok(())
    }

    #[test]
    fn binary_attestation_hash_requires_exact_sha256_shape() {
        assert!(validate_sha256(&"a".repeat(64), "--hash").is_ok());
        assert!(validate_sha256(&"a".repeat(63), "--hash").is_err());
        assert!(validate_sha256(&"g".repeat(64), "--hash").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn fixture_parent_reserves_the_full_unix_socket_path_budget() {
        assert!(validate_fixture_socket_path_budget(Path::new("/tmp/cbf")).is_ok());
        let hosted_parent = Path::new("/private/tmp/cbf-85575338-1");
        let longest = longest_control_socket_path(hosted_parent);
        assert_eq!(longest.file_name().and_then(|name| name.to_str()), Some("mux.sock"));
        assert!(validate_fixture_socket_path_budget(hosted_parent).is_ok());
        assert!(
            validate_fixture_socket_path_budget(Path::new(&format!("/tmp/{}", "x".repeat(80))))
                .is_err()
        );
    }
}
