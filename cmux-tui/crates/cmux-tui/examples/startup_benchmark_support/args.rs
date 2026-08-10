use std::env;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use super::{Scenario, TargetKind};

#[derive(Debug)]
pub struct Args {
    pub baseline_binary: PathBuf,
    pub candidate_binary: PathBuf,
    pub baseline_source: PathBuf,
    pub candidate_source: PathBuf,
    pub baseline_sha: String,
    pub candidate_sha: String,
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
            baseline_binary: PathBuf::new(),
            candidate_binary: PathBuf::new(),
            baseline_source: PathBuf::new(),
            candidate_source: PathBuf::new(),
            baseline_sha: String::new(),
            candidate_sha: String::new(),
            warmups: 10,
            samples: 50,
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
                "--baseline-binary" => args.baseline_binary = parser.path(&key, inline)?,
                "--candidate-binary" => args.candidate_binary = parser.path(&key, inline)?,
                "--baseline-source" => args.baseline_source = parser.path(&key, inline)?,
                "--candidate-source" => args.candidate_source = parser.path(&key, inline)?,
                "--baseline-sha" => args.baseline_sha = parser.value(&key, inline)?,
                "--candidate-sha" => args.candidate_sha = parser.value(&key, inline)?,
                "--warmups" => args.warmups = parser.number(&key, inline)?,
                "--samples" => args.samples = parser.number(&key, inline)?,
                "--suite-deadline-seconds" => {
                    args.suite_deadline_seconds = parser.number(&key, inline)?
                }
                "--output-dir" => args.output_dir = parser.path(&key, inline)?,
                "--fixture-parent" => args.fixture_parent = parser.path(&key, inline)?,
                "--platform-label" => args.platform_label = parser.value(&key, inline)?,
                "--profile-only" => args.profile_only = Some(parser.value(&key, inline)?.parse()?),
                "--profile-target" => {
                    args.profile_target = Some(parser.value(&key, inline)?.parse()?)
                }
                "--baseline-launcher-arg" => {
                    args.baseline_launcher.push(parser.value(&key, inline)?)
                }
                "--candidate-launcher-arg" => {
                    args.candidate_launcher.push(parser.value(&key, inline)?)
                }
                _ => bail!("unknown argument {key}"),
            }
        }
        args.validate()?;
        Ok(args)
    }

    fn validate(&mut self) -> Result<()> {
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
        validate_sha(&self.baseline_sha, "--baseline-sha")?;
        validate_sha(&self.candidate_sha, "--candidate-sha")?;
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
        if self.platform_label.trim().is_empty() {
            bail!("--platform-label is required");
        }
        match (self.profile_only, self.profile_target) {
            (Some(_), None) => bail!("--profile-target is required with --profile-only"),
            (None, Some(_)) => bail!("--profile-only is required with --profile-target"),
            (None, None) => {
                if self.warmups < 10 {
                    bail!("full comparison requires at least 10 warmups");
                }
                if self.samples < 50 {
                    bail!("full comparison requires at least 50 paired samples");
                }
                if !self.baseline_launcher.is_empty() || !self.candidate_launcher.is_empty() {
                    bail!("launcher arguments require --profile-only");
                }
            }
            (Some(_), Some(_)) => {}
        }
        Ok(())
    }
}

fn validate_sha(value: &str, option: &str) -> Result<()> {
    if value.len() != 40 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("{option} must be a 40-character hexadecimal SHA");
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
