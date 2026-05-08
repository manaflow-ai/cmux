use std::env;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use anyhow::{Context, Result, bail};
use cmux_cli_protocol::{RemoteDaemonBootstrapPlanInfo, RemoteDaemonStatusInfo};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::process::Command;
use uuid::Uuid;

const MANIFEST_ENV: &str = "CMUX_REMOTE_DAEMON_MANIFEST_JSON";
const APP_VERSION_ENV: &str = "CMUX_REMOTE_DAEMON_APP_VERSION";
const BUILD_ENV: &str = "CMUX_REMOTE_DAEMON_BUILD";
const COMMIT_ENV: &str = "CMUX_REMOTE_DAEMON_COMMIT";
const ALLOW_LOCAL_BUILD_ENV: &str = "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD";
const EXPLICIT_BINARY_ENV: &str = "CMUX_REMOTE_DAEMON_BINARY";
const SOURCE_ROOT_ENV: &str = "CMUX_REMOTE_DAEMON_SOURCE_ROOT";
const LEGACY_SOURCE_ROOT_ENV: &str = "CMUXTERM_REPO_ROOT";

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonMetadata {
    app_version: String,
    build: Option<String>,
    commit: Option<String>,
    manifest: Option<RemoteDaemonManifest>,
    manifest_error: Option<String>,
    dev_local_build_fallback: bool,
    explicit_binary: Option<PathBuf>,
    source_fingerprint: Option<String>,
}

impl RemoteDaemonMetadata {
    pub(crate) fn from_environment() -> Self {
        let raw_manifest = env::var(MANIFEST_ENV).ok().and_then(non_empty);
        let (manifest, manifest_error) = match raw_manifest.as_deref() {
            Some(raw) => match serde_json::from_str::<RemoteDaemonManifest>(raw) {
                Ok(manifest) => (Some(manifest), None),
                Err(error) => (None, Some(error.to_string())),
            },
            None => (None, None),
        };
        let app_version = env::var(APP_VERSION_ENV)
            .ok()
            .and_then(non_empty)
            .or_else(|| {
                manifest
                    .as_ref()
                    .map(|manifest| manifest.app_version.clone())
            })
            .unwrap_or_else(|| "dev".to_string());

        Self {
            app_version,
            build: env::var(BUILD_ENV).ok().and_then(non_empty),
            commit: env::var(COMMIT_ENV).ok().and_then(non_empty),
            manifest,
            manifest_error,
            dev_local_build_fallback: env::var(ALLOW_LOCAL_BUILD_ENV).ok().as_deref() == Some("1"),
            explicit_binary: env::var(EXPLICIT_BINARY_ENV)
                .ok()
                .and_then(non_empty)
                .map(PathBuf::from),
            source_fingerprint: compute_remote_daemon_source_fingerprint(),
        }
    }

    pub(crate) fn bootstrap_version(&self) -> String {
        if !self.dev_local_build_fallback {
            return self.app_version.clone();
        }
        match self.source_fingerprint.as_deref() {
            Some(fingerprint) if !fingerprint.is_empty() => {
                format!("{}-dev-{fingerprint}", self.app_version)
            }
            _ => self.app_version.clone(),
        }
    }

    pub(crate) fn remote_path(version: &str, go_os: &str, go_arch: &str) -> String {
        format!(".cmux/bin/cmuxd-remote/{version}/{go_os}-{go_arch}/cmuxd-remote")
    }

    pub(crate) fn bootstrap_plan(
        &self,
        requested_go_os: Option<&str>,
        requested_go_arch: Option<&str>,
    ) -> RemoteDaemonBootstrapPlanInfo {
        let target_goos = normalized_go_os(requested_go_os, host_go_os());
        let target_goarch = normalized_go_arch(requested_go_arch, host_go_arch());
        let version = self.bootstrap_version();
        let local_binary_path = self
            .planned_local_binary_path(&target_goos, &target_goarch, &version)
            .display()
            .to_string();
        let remote_path = Self::remote_path(&version, &target_goos, &target_goarch);
        RemoteDaemonBootstrapPlanInfo {
            version,
            target_goos,
            target_goarch,
            local_binary_path,
            remote_path,
        }
    }

    fn planned_local_binary_path(&self, go_os: &str, go_arch: &str, version: &str) -> PathBuf {
        if let Some(binary) = self.explicit_binary.as_ref()
            && self.dev_local_build_fallback
            && is_executable_file(binary)
        {
            return binary.clone();
        }
        if let Some(manifest) = self.manifest.as_ref()
            && manifest.app_version == version
            && manifest.entry(go_os, go_arch).is_some()
        {
            return remote_daemon_cache_path(version, go_os, go_arch);
        }
        versioned_remote_daemon_build_path(version, go_os, go_arch)
    }

    #[allow(dead_code)]
    pub(crate) async fn local_binary_for_platform(
        &self,
        go_os: &str,
        go_arch: &str,
        version: &str,
    ) -> Result<PathBuf> {
        if let Some(binary) = self.explicit_binary.as_ref()
            && self.dev_local_build_fallback
            && is_executable_file(binary)
        {
            return Ok(binary.clone());
        }

        if let Some(manifest) = self.manifest.as_ref()
            && manifest.app_version == version
            && let Some(entry) = manifest.entry(go_os, go_arch)
        {
            return cached_or_downloaded_manifest_binary(
                entry,
                &manifest.app_version,
                &manifest.release_url,
            )
            .await;
        }

        if !self.dev_local_build_fallback {
            bail!(
                "this build does not include a verified cmuxd-remote manifest for {go_os}-{go_arch}. Use a release/nightly build, or set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback."
            );
        }

        build_local_daemon_binary(go_os, go_arch, version).await
    }

    pub(crate) fn status(
        &self,
        requested_go_os: Option<&str>,
        requested_go_arch: Option<&str>,
    ) -> RemoteDaemonStatusInfo {
        let target_goos = normalized_go_os(requested_go_os, host_go_os());
        let target_goarch = normalized_go_arch(requested_go_arch, host_go_arch());
        let entry = self
            .manifest
            .as_ref()
            .and_then(|manifest| manifest.entry(&target_goos, &target_goarch));
        let cache_version = self
            .manifest
            .as_ref()
            .map(|manifest| manifest.app_version.as_str())
            .unwrap_or(self.app_version.as_str());
        let cache_path = remote_daemon_cache_path(cache_version, &target_goos, &target_goarch);
        let cache_exists = cache_path.is_file();
        let cache_sha256 = cache_exists
            .then(|| sha256_hex_for_file(&cache_path))
            .flatten();
        let expected_sha256 = entry.map(|entry| entry.sha256.clone());
        let cache_verified = match (cache_sha256.as_deref(), expected_sha256.as_deref()) {
            (Some(actual), Some(expected)) => actual.eq_ignore_ascii_case(expected),
            _ => false,
        };

        let release_tag = self
            .manifest
            .as_ref()
            .map(|manifest| manifest.release_tag.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let release_url = self
            .manifest
            .as_ref()
            .map(|manifest| manifest.release_url.clone());
        let asset_name = entry
            .map(|entry| entry.asset_name.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let download_url = entry
            .map(|entry| entry.download_url.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let checksums_asset_name = self
            .manifest
            .as_ref()
            .map(|manifest| manifest.checksums_asset_name.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let checksums_url = self
            .manifest
            .as_ref()
            .map(|manifest| manifest.checksums_url.clone())
            .unwrap_or_else(|| "unknown".to_string());
        let signer_workflow = if release_tag == "nightly" {
            "manaflow-ai/cmux/.github/workflows/nightly.yml"
        } else {
            "manaflow-ai/cmux/.github/workflows/release.yml"
        };

        RemoteDaemonStatusInfo {
            app_version: self.app_version.clone(),
            build: self.build.clone(),
            commit: self.commit.clone(),
            manifest_present: self.manifest.is_some(),
            manifest_error: self.manifest_error.clone(),
            release_tag: release_tag.clone(),
            release_url,
            target_goos,
            target_goarch,
            asset_name: asset_name.clone(),
            download_url,
            checksums_asset_name: checksums_asset_name.clone(),
            checksums_url,
            expected_sha256,
            cache_path: cache_path.display().to_string(),
            cache_exists,
            cache_sha256,
            cache_verified,
            dev_local_build_fallback: self.dev_local_build_fallback,
            download_command: format!(
                "gh release download {release_tag} --repo manaflow-ai/cmux --pattern {asset_name}"
            ),
            download_checksums_command: format!(
                "gh release download {release_tag} --repo manaflow-ai/cmux --pattern {checksums_asset_name}"
            ),
            checksum_verify_command: format!(
                "shasum -a 256 -c {checksums_asset_name} --ignore-missing"
            ),
            attestation_verify_command: format!(
                "gh attestation verify ./{asset_name} --repo manaflow-ai/cmux --signer-workflow {signer_workflow}"
            ),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteDaemonManifest {
    #[allow(dead_code)]
    schema_version: u32,
    app_version: String,
    release_tag: String,
    release_url: String,
    checksums_asset_name: String,
    checksums_url: String,
    entries: Vec<RemoteDaemonManifestEntry>,
}

impl RemoteDaemonManifest {
    fn entry(&self, go_os: &str, go_arch: &str) -> Option<&RemoteDaemonManifestEntry> {
        self.entries
            .iter()
            .find(|entry| entry.go_os == go_os && entry.go_arch == go_arch)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteDaemonManifestEntry {
    go_os: String,
    go_arch: String,
    asset_name: String,
    download_url: String,
    sha256: String,
}

async fn cached_or_downloaded_manifest_binary(
    entry: &RemoteDaemonManifestEntry,
    version: &str,
    release_url: &str,
) -> Result<PathBuf> {
    let cache_path = remote_daemon_cache_path(version, &entry.go_os, &entry.go_arch);
    if cache_path.is_file()
        && is_executable_file(&cache_path)
        && let Some(cache_sha) = sha256_hex_for_file(&cache_path)
        && cache_sha.eq_ignore_ascii_case(&entry.sha256)
    {
        return Ok(cache_path);
    }
    if cache_path.exists() {
        fs::remove_file(&cache_path).with_context(|| {
            format!("remove stale remote daemon cache {}", cache_path.display())
        })?;
    }

    download_manifest_binary(entry, version, release_url, &cache_path).await
}

async fn download_manifest_binary(
    entry: &RemoteDaemonManifestEntry,
    version: &str,
    release_url: &str,
    cache_path: &Path,
) -> Result<PathBuf> {
    let parent = cache_path
        .parent()
        .context("remote daemon cache path has no parent")?;
    tokio::fs::create_dir_all(parent)
        .await
        .with_context(|| format!("create remote daemon cache dir {}", parent.display()))?;
    let client = reqwest::Client::new();
    let bytes = client
        .get(&entry.download_url)
        .header("User-Agent", format!("cmux/{version}"))
        .timeout(std::time::Duration::from_secs(60))
        .send()
        .await
        .with_context(|| format!("download {}", entry.asset_name))?
        .error_for_status()
        .with_context(|| format!("download {}", entry.asset_name))?
        .bytes()
        .await
        .with_context(|| format!("read downloaded {}", entry.asset_name))?;
    let downloaded_sha = sha256_hex_for_bytes(&bytes);
    if !downloaded_sha.eq_ignore_ascii_case(&entry.sha256) {
        if !live_manifest_matches_checksum(release_url, version, entry, &downloaded_sha).await {
            bail!("remote daemon checksum mismatch for {}", entry.asset_name);
        }
    }

    let temp_path = parent.join(format!(".cmuxd-remote.tmp-{}", Uuid::new_v4()));
    tokio::fs::write(&temp_path, &bytes)
        .await
        .with_context(|| format!("write {}", temp_path.display()))?;
    fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o755))
        .with_context(|| format!("chmod {}", temp_path.display()))?;
    if cache_path.exists() {
        fs::remove_file(cache_path)
            .with_context(|| format!("remove old {}", cache_path.display()))?;
    }
    tokio::fs::rename(&temp_path, cache_path)
        .await
        .with_context(|| format!("move {} to {}", temp_path.display(), cache_path.display()))?;
    Ok(cache_path.to_path_buf())
}

async fn live_manifest_matches_checksum(
    release_url: &str,
    version: &str,
    entry: &RemoteDaemonManifestEntry,
    downloaded_sha: &str,
) -> bool {
    let manifest_url = format!(
        "{}/cmuxd-remote-manifest.json",
        release_url.trim_end_matches('/')
    );
    let Ok(response) = reqwest::Client::new()
        .get(manifest_url)
        .header("User-Agent", format!("cmux/{version}"))
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
    else {
        return false;
    };
    let Ok(response) = response.error_for_status() else {
        return false;
    };
    let Ok(bytes) = response.bytes().await else {
        return false;
    };
    let Ok(manifest) = serde_json::from_slice::<RemoteDaemonManifest>(&bytes) else {
        return false;
    };
    manifest
        .entry(&entry.go_os, &entry.go_arch)
        .is_some_and(|live_entry| downloaded_sha.eq_ignore_ascii_case(&live_entry.sha256))
}

async fn build_local_daemon_binary(go_os: &str, go_arch: &str, version: &str) -> Result<PathBuf> {
    let repo_root = find_repo_root()
        .context("cannot locate cmux repo root for dev-only cmuxd-remote build fallback")?;
    let daemon_root = repo_root.join("daemon").join("remote");
    let go_mod = daemon_root.join("go.mod");
    if !go_mod.is_file() {
        bail!("missing daemon module at {}", go_mod.display());
    }
    let go_binary =
        which("go").context("go is required for the dev-only cmuxd-remote build fallback")?;
    let output = versioned_remote_daemon_build_path(version, go_os, go_arch);
    let output_parent = output
        .parent()
        .context("remote daemon build output has no parent")?;
    tokio::fs::create_dir_all(output_parent)
        .await
        .with_context(|| format!("create {}", output_parent.display()))?;

    let ldflags = if go_os == "darwin" {
        format!("-s -w -linkmode=external -X main.version={version}")
    } else {
        format!("-s -w -X main.version={version}")
    };
    let command_output = Command::new(go_binary)
        .args([
            "build",
            "-trimpath",
            "-buildvcs=false",
            "-ldflags",
            &ldflags,
            "-o",
        ])
        .arg(&output)
        .arg("./cmd/cmuxd-remote")
        .current_dir(&daemon_root)
        .env("GOOS", go_os)
        .env("GOARCH", go_arch)
        .env("CGO_ENABLED", if go_os == "darwin" { "1" } else { "0" })
        .stdin(Stdio::null())
        .output()
        .await
        .context("run go build for cmuxd-remote")?;
    if !command_output.status.success() {
        let detail = best_error_line(&command_output.stderr, &command_output.stdout)
            .unwrap_or_else(|| format!("go build failed with status {}", command_output.status));
        bail!("failed to build cmuxd-remote: {detail}");
    }
    if !is_executable_file(&output) {
        bail!("cmuxd-remote build output is not executable");
    }
    Ok(output)
}

fn versioned_remote_daemon_build_path(version: &str, go_os: &str, go_arch: &str) -> PathBuf {
    env::temp_dir()
        .join("cmux-remote-daemon-build")
        .join(version)
        .join(format!("{go_os}-{go_arch}"))
        .join("cmuxd-remote")
}

fn non_empty(raw: String) -> Option<String> {
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn normalized_go_os(requested: Option<&str>, fallback: &str) -> String {
    let normalized = requested
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_ascii_lowercase();
    match normalized.as_str() {
        "macos" | "mac" => "darwin".to_string(),
        other => other.to_string(),
    }
}

fn normalized_go_arch(requested: Option<&str>, fallback: &str) -> String {
    let normalized = requested
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_ascii_lowercase();
    match normalized.as_str() {
        "x86_64" => "amd64".to_string(),
        "aarch64" => "arm64".to_string(),
        other => other.to_string(),
    }
}

fn host_go_os() -> &'static str {
    if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    }
}

fn host_go_arch() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "amd64"
    } else {
        "unknown"
    }
}

fn remote_daemon_cache_path(version: &str, go_os: &str, go_arch: &str) -> PathBuf {
    let root = env::var("HOME")
        .ok()
        .and_then(non_empty)
        .map(|home| {
            if cfg!(target_os = "macos") {
                PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("cmux")
                    .join("remote-daemons")
            } else {
                PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("cmux")
                    .join("remote-daemons")
            }
        })
        .unwrap_or_else(|| env::temp_dir().join("cmux-remote-daemons"));
    root.join(version)
        .join(format!("{go_os}-{go_arch}"))
        .join("cmuxd-remote")
}

fn sha256_hex_for_file(path: &Path) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    Some(sha256_hex_for_bytes(&data))
}

fn sha256_hex_for_bytes(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut output, "{byte:02x}");
    }
    output
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
}

fn which(executable: &str) -> Option<PathBuf> {
    executable_search_paths()
        .into_iter()
        .map(|component| component.join(executable))
        .find(|candidate| is_executable_file(candidate))
}

fn executable_search_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    append_path_components(&mut paths, env::var("PATH").ok().as_deref());
    if let Some(home) = env::var("HOME").ok().and_then(non_empty) {
        paths.push(PathBuf::from(&home).join(".local").join("bin"));
        paths.push(PathBuf::from(&home).join("go").join("bin"));
        paths.push(PathBuf::from(home).join("bin"));
    }
    for path in [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        paths.push(PathBuf::from(path));
    }
    dedupe_paths(paths)
}

fn append_path_components(paths: &mut Vec<PathBuf>, raw_path: Option<&str>) {
    let Some(raw_path) = raw_path else {
        return;
    };
    for component in env::split_paths(OsStr::new(raw_path)) {
        paths.push(component);
    }
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = std::collections::HashSet::new();
    let mut deduped = Vec::new();
    for path in paths {
        if seen.insert(path.clone()) {
            deduped.push(path);
        }
    }
    deduped
}

fn compute_remote_daemon_source_fingerprint() -> Option<String> {
    let repo_root = find_repo_root()?;
    let daemon_root = repo_root.join("daemon").join("remote");
    let mut files = Vec::new();
    collect_remote_daemon_source_files(&daemon_root, &daemon_root, &mut files).ok()?;
    if files.is_empty() {
        return None;
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut hasher = Sha256::new();
    for (relative_path, file_path) in files {
        let data = fs::read(file_path).ok()?;
        hasher.update(relative_path.as_bytes());
        hasher.update([0]);
        hasher.update(data);
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let hex = sha256_hex_for_bytes(&digest);
    Some(hex.chars().take(12).collect())
}

fn collect_remote_daemon_source_files(
    root: &Path,
    current: &Path,
    files: &mut Vec<(String, PathBuf)>,
) -> Result<()> {
    for entry in fs::read_dir(current).with_context(|| format!("read {}", current.display()))? {
        let entry = entry.with_context(|| format!("read entry in {}", current.display()))?;
        let path = entry.path();
        let file_name = entry.file_name();
        if file_name.to_string_lossy().starts_with('.') {
            continue;
        }
        let metadata = entry
            .metadata()
            .with_context(|| format!("stat {}", path.display()))?;
        if metadata.is_dir() {
            collect_remote_daemon_source_files(root, &path, files)?;
            continue;
        }
        if !metadata.is_file() || !is_remote_daemon_source_file(&path) {
            continue;
        }
        let relative_path = path
            .strip_prefix(root)
            .ok()
            .and_then(|relative| relative.to_str())
            .map(str::to_string);
        if let Some(relative_path) = relative_path {
            files.push((relative_path, path));
        }
    }
    Ok(())
}

fn is_remote_daemon_source_file(path: &Path) -> bool {
    let file_name = path.file_name().and_then(OsStr::to_str).unwrap_or_default();
    file_name == "go.mod" || file_name == "go.sum" || path.extension() == Some(OsStr::new("go"))
}

fn find_repo_root() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    for key in [SOURCE_ROOT_ENV, LEGACY_SOURCE_ROOT_ENV] {
        if let Some(path) = env::var(key).ok().and_then(non_empty) {
            candidates.push(PathBuf::from(path));
        }
    }
    if let Ok(cwd) = env::current_dir() {
        candidates.push(cwd);
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));
    if let Ok(exe) = env::current_exe()
        && let Some(parent) = exe.parent()
    {
        candidates.push(parent.to_path_buf());
    }

    for candidate in candidates {
        let mut cursor = candidate.as_path();
        for _ in 0..12 {
            if cursor
                .join("daemon")
                .join("remote")
                .join("go.mod")
                .is_file()
            {
                return Some(cursor.to_path_buf());
            }
            let Some(parent) = cursor.parent() else {
                break;
            };
            if parent == cursor {
                break;
            }
            cursor = parent;
        }
    }
    None
}

fn best_error_line(stderr: &[u8], stdout: &[u8]) -> Option<String> {
    meaningful_error_line(stderr).or_else(|| meaningful_error_line(stdout))
}

fn meaningful_error_line(data: &[u8]) -> Option<String> {
    String::from_utf8_lossy(data)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .rev()
        .find(|line| {
            let lower = line.to_ascii_lowercase();
            !lower.contains("warning:") && !lower.contains("debug:")
        })
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_manifest_json() -> String {
        serde_json::json!({
            "schemaVersion": 1,
            "appVersion": "0.99.0",
            "releaseTag": "nightly",
            "releaseURL": "https://github.com/manaflow-ai/cmux/releases/download/nightly",
            "checksumsAssetName": "cmuxd-remote-checksums.txt",
            "checksumsURL": "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmuxd-remote-checksums.txt",
            "entries": [
                {
                    "goOS": "linux",
                    "goArch": "arm64",
                    "assetName": "cmuxd-remote-linux-arm64",
                    "downloadURL": "https://example.test/cmuxd-remote-linux-arm64",
                    "sha256": "abc123"
                }
            ]
        })
        .to_string()
    }

    #[test]
    fn status_uses_manifest_entry_for_requested_platform() {
        let manifest: RemoteDaemonManifest = serde_json::from_str(&sample_manifest_json()).unwrap();
        let metadata = RemoteDaemonMetadata {
            app_version: "0.99.0".to_string(),
            build: Some("42".to_string()),
            commit: Some("abc".to_string()),
            manifest: Some(manifest),
            manifest_error: None,
            dev_local_build_fallback: false,
            explicit_binary: None,
            source_fingerprint: None,
        };

        let status = metadata.status(Some("linux"), Some("aarch64"));

        assert!(status.manifest_present);
        assert_eq!(status.target_goos, "linux");
        assert_eq!(status.target_goarch, "arm64");
        assert_eq!(status.asset_name, "cmuxd-remote-linux-arm64");
        assert_eq!(status.expected_sha256.as_deref(), Some("abc123"));
        assert!(
            status
                .attestation_verify_command
                .contains(".github/workflows/nightly.yml")
        );
    }

    #[test]
    fn status_reports_missing_manifest_without_failing() {
        let metadata = RemoteDaemonMetadata {
            app_version: "dev".to_string(),
            build: None,
            commit: None,
            manifest: None,
            manifest_error: Some("invalid".to_string()),
            dev_local_build_fallback: true,
            explicit_binary: None,
            source_fingerprint: Some("source123456".to_string()),
        };

        let status = metadata.status(Some("darwin"), Some("amd64"));

        assert!(!status.manifest_present);
        assert_eq!(status.release_tag, "unknown");
        assert_eq!(status.asset_name, "unknown");
        assert_eq!(status.manifest_error.as_deref(), Some("invalid"));
        assert!(status.dev_local_build_fallback);
    }
}
