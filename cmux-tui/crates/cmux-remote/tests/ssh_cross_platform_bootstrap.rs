#![cfg(unix)]

use cmux_remote::ssh_bootstrap::{
    BUILD_IDENTITY, BootstrapOutcome, DISTRIBUTION_VERSION, SshBootstrapConfig, SshBootstrapper,
};
use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;

struct Fixture {
    _directory: tempfile::TempDir,
    config: SshBootstrapConfig,
    installed: std::path::PathBuf,
    staged: std::path::PathBuf,
}

impl Fixture {
    fn new(corrupt: bool) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("cmux-tui");
        fs::write(&source, b"local executable must not be uploaded").unwrap();
        let artifacts = directory.path().join("cmux-tui-ssh");
        fs::create_dir(&artifacts).unwrap();
        let (os, uname_os, target) = if std::env::consts::OS == "macos" {
            ("linux", "Linux", "cmux-tui-aarch64-unknown-linux-musl")
        } else {
            ("macos", "Darwin", "cmux-tui-aarch64-apple-darwin")
        };
        let payload = b"verified remote platform executable";
        let digest = format!("{:x}", Sha256::digest(payload));
        fs::write(artifacts.join(target), if corrupt { b"tampered".as_slice() } else { payload })
            .unwrap();
        fs::write(
            artifacts.join("manifest.json"),
            serde_json::to_vec(&serde_json::json!({
                "commit": BUILD_IDENTITY,
                "binaries": {target: digest},
            }))
            .unwrap(),
        )
        .unwrap();
        let installed = directory.path().join("installed");
        let staged = directory.path().join("staged");
        let probe = serde_json::json!({
            "app": "cmux-tui", "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION, "build_identity": BUILD_IDENTITY,
            "remote_protocol": REMOTE_PROTOCOL_VERSION, "os": os, "arch": "aarch64",
        });
        let script = directory.path().join("ssh");
        fs::write(
            &script,
            format!(
                r#"#!/bin/sh
case "$*" in
  *"uname -s -m"*) printf '%s\n' '{uname_os} aarch64' ;;
  *"mkdir -p "*|*"mkdir -m 700 "*) exit 0 ;;
  *".cmux-upload-"*" remote-probe --json"*) [ -f '{staged}' ] || exit 127; printf '%s' '{probe}' ;;
  *"remote-probe --json"*) [ -f '{installed}' ] || exit 127; printf '%s' '{probe}' ;;
  *"exec 3> "*".cmux-upload-"*) cat >'{staged}' ;;
  *"mv -f "*".cmux-upload-"*) mv '{staged}' '{installed}' ;;
  *"rm -f "*".cmux-upload-"*) rm -f '{staged}' ;;
  *"rmdir "*) exit 0 ;;
  *) exit 2 ;;
esac
"#,
                staged = staged.display(),
                installed = installed.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(source);
        Self { _directory: directory, config, installed, staged }
    }
}

#[tokio::test]
async fn ssh_cross_platform_bootstrap_uploads_verified_companion_artifact() {
    let fixture = Fixture::new(false);
    assert_eq!(
        SshBootstrapper::new(fixture.config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&fixture.installed).unwrap(), b"verified remote platform executable");
}

#[tokio::test]
async fn ssh_cross_platform_bootstrap_rejects_tampering_before_remote_upload() {
    let fixture = Fixture::new(true);
    let error = SshBootstrapper::new(fixture.config).unwrap().ensure_installed().await.unwrap_err();
    assert!(error.to_string().contains("checksum"), "{error}");
    assert!(!fixture.staged.exists());
    assert!(!fixture.installed.exists());
}

/// The app bundles only the checksum of each Linux build, not the executable.
/// The first host of a platform downloads the published build once into the
/// local cache, checks it against the pin and uploads it; later hosts reuse the
/// cached copy, and a host that already runs the matching build downloads and
/// uploads nothing.
struct OnDemandFixture {
    directory: tempfile::TempDir,
    payload: &'static [u8],
    digest: String,
    target: &'static str,
    uname_os: &'static str,
    os: &'static str,
}

impl OnDemandFixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let (os, uname_os, target) = if std::env::consts::OS == "macos" {
            ("linux", "Linux", "cmux-tui-aarch64-unknown-linux-musl")
        } else {
            ("macos", "Darwin", "cmux-tui-aarch64-apple-darwin")
        };
        let payload: &'static [u8] = b"published remote platform executable";
        let digest = format!("{:x}", Sha256::digest(payload));
        let artifacts = directory.path().join("app/cmux-tui-ssh");
        fs::create_dir_all(&artifacts).unwrap();
        fs::write(directory.path().join("app/cmux-tui"), b"local executable must not be uploaded")
            .unwrap();
        fs::write(
            artifacts.join("manifest.json"),
            serde_json::to_vec(&serde_json::json!({
                "commit": BUILD_IDENTITY,
                "binaries": {target: digest},
            }))
            .unwrap(),
        )
        .unwrap();
        Self { directory, payload, digest, target, uname_os, os }
    }

    fn published(&self) -> std::path::PathBuf {
        self.directory.path().join("published").join(BUILD_IDENTITY).join(self.target)
    }

    fn publish(&self, bytes: &[u8]) {
        fs::create_dir_all(self.published().parent().unwrap()).unwrap();
        fs::write(self.published(), bytes).unwrap();
    }

    fn cache(&self) -> std::path::PathBuf {
        self.directory.path().join("cache")
    }

    /// A fake SSH host named `host`, with its own install and staging paths.
    fn host(&self, host: &str) -> (SshBootstrapConfig, std::path::PathBuf, std::path::PathBuf) {
        let root = self.directory.path().join(host);
        fs::create_dir_all(&root).unwrap();
        let installed = root.join("installed");
        let staged = root.join("staged");
        let probe = serde_json::json!({
            "app": "cmux-tui", "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION, "build_identity": BUILD_IDENTITY,
            "remote_protocol": REMOTE_PROTOCOL_VERSION, "os": self.os, "arch": "aarch64",
        });
        // An install from an older cmux release reports another build.
        let older = serde_json::json!({
            "app": "cmux-tui", "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION, "build_identity": "older-cmux-release",
            "remote_protocol": REMOTE_PROTOCOL_VERSION, "os": self.os, "arch": "aarch64",
        });
        let script = root.join("ssh");
        fs::write(
            &script,
            format!(
                r#"#!/bin/sh
case "$*" in
  *"uname -s -m"*) printf '%s\n' '{uname_os} aarch64' ;;
  *"mkdir -p "*|*"mkdir -m 700 "*) exit 0 ;;
  *".cmux-upload-"*" remote-probe --json"*) [ -f '{staged}' ] || exit 127; printf '%s' '{probe}' ;;
  *"remote-probe --json"*) [ -f '{installed}' ] || exit 127
    if [ "$(cat '{installed}')" = older ]; then printf '%s' '{older}'; else printf '%s' '{probe}'; fi ;;
  *"exec 3> "*".cmux-upload-"*) cat >'{staged}' ;;
  *"mv -f "*".cmux-upload-"*) mv '{staged}' '{installed}' ;;
  *"rm -f "*".cmux-upload-"*) rm -f '{staged}' ;;
  *"rmdir "*) exit 0 ;;
  *) exit 2 ;;
esac
"#,
                uname_os = self.uname_os,
                staged = staged.display(),
                installed = installed.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = SshBootstrapConfig::defaults(host);
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(self.directory.path().join("app/cmux-tui"));
        config.payload_base_url =
            format!("file://{}", self.directory.path().join("published").display());
        config.payload_cache = Some(self.cache());
        (config, installed, staged)
    }

    fn cached_files(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(self.cache()) else { return Vec::new() };
        let mut names: Vec<String> = entries
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

#[tokio::test]
async fn ssh_on_demand_payload_downloads_once_and_every_host_reuses_the_cache() {
    let fixture = OnDemandFixture::new();
    fixture.publish(fixture.payload);

    let (first, first_installed, _) = fixture.host("first");
    assert_eq!(
        SshBootstrapper::new(first).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&first_installed).unwrap(), fixture.payload);
    assert_eq!(fixture.cached_files(), vec![format!("{}-{}", fixture.digest, fixture.target)]);

    // The published copy is gone: a second host can only be served from cache.
    fs::remove_file(fixture.published()).unwrap();
    let (second, second_installed, _) = fixture.host("second");
    assert_eq!(
        SshBootstrapper::new(second).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&second_installed).unwrap(), fixture.payload);
}

#[tokio::test]
async fn ssh_on_demand_payload_reuses_a_matching_remote_install_without_downloading() {
    let fixture = OnDemandFixture::new();
    let (config, installed, _) = fixture.host("current");
    fs::write(&installed, b"already installed matching build").unwrap();
    // Nothing is published and nothing is cached, so any download would fail.
    assert_eq!(
        SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::AlreadyInstalled
    );
    assert_eq!(fs::read(&installed).unwrap(), b"already installed matching build");
    assert!(fixture.cached_files().is_empty());
}

#[tokio::test]
async fn ssh_on_demand_payload_replaces_an_older_remote_install() {
    let fixture = OnDemandFixture::new();
    fixture.publish(fixture.payload);
    let (config, installed, _) = fixture.host("older");
    fs::write(&installed, b"older").unwrap();
    assert_eq!(
        SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&installed).unwrap(), fixture.payload);
}

/// A connection attempt that ends mid-download (its process exits) leaves the
/// partial file; the next attempt resumes it instead of starting over.
#[tokio::test]
async fn ssh_on_demand_payload_resumes_a_partial_download() {
    let fixture = OnDemandFixture::new();
    fixture.publish(fixture.payload);
    fs::create_dir_all(fixture.cache()).unwrap();
    let partial = fixture.cache().join(format!("{}-{}.partial", fixture.digest, fixture.target));
    fs::write(&partial, &fixture.payload[..10]).unwrap();
    let (config, installed, _) = fixture.host("resume");
    assert_eq!(
        SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&installed).unwrap(), fixture.payload);
    assert_eq!(fixture.cached_files(), vec![format!("{}-{}", fixture.digest, fixture.target)]);
}

/// A partial file that already holds the whole build is finished without any
/// network access.
#[tokio::test]
async fn ssh_on_demand_payload_finishes_a_complete_partial_without_downloading() {
    let fixture = OnDemandFixture::new();
    fs::create_dir_all(fixture.cache()).unwrap();
    let partial = fixture.cache().join(format!("{}-{}.partial", fixture.digest, fixture.target));
    fs::write(&partial, fixture.payload).unwrap();
    let (config, installed, _) = fixture.host("complete");
    assert_eq!(
        SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&installed).unwrap(), fixture.payload);
}

/// Cached builds of other versions are pruned once they are a month old.
#[tokio::test]
async fn ssh_on_demand_payload_prunes_month_old_builds_of_other_versions() {
    let fixture = OnDemandFixture::new();
    fixture.publish(fixture.payload);
    fs::create_dir_all(fixture.cache()).unwrap();
    let old = fixture.cache().join(format!("{}-{}", "0".repeat(64), fixture.target));
    let recent = fixture.cache().join(format!("{}-{}", "1".repeat(64), fixture.target));
    fs::write(&old, b"old build").unwrap();
    fs::write(&recent, b"recent build").unwrap();
    let month_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(31 * 86_400);
    fs::File::options().write(true).open(&old).unwrap().set_modified(month_ago).unwrap();
    let (config, _, _) = fixture.host("prune");
    SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap();
    assert!(!old.exists());
    assert!(recent.exists());
}

#[tokio::test]
async fn ssh_on_demand_payload_rejects_a_tampered_download_before_upload() {
    let fixture = OnDemandFixture::new();
    fixture.publish(b"tampered");
    let (config, installed, staged) = fixture.host("target");
    let error = SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap_err();
    assert!(error.to_string().contains("checksum"), "{error}");
    assert!(!staged.exists());
    assert!(!installed.exists());
    assert!(fixture.cached_files().is_empty(), "{:?}", fixture.cached_files());
}

/// A published build installs from npm. Whatever npm serves must match the
/// SHA-256 that the local npm package pinned for the remote platform before
/// the binary runs or moves into place.
struct NpmFixture {
    _directory: tempfile::TempDir,
    config: SshBootstrapConfig,
    installed: std::path::PathBuf,
    staged: std::path::PathBuf,
}

impl NpmFixture {
    fn new(served: &[u8]) -> Self {
        let directory = tempfile::tempdir().unwrap();
        // Same layout as an installed npm platform package:
        // bin/cmux-tui next to bin/cmux-tui-ssh/manifest.json.
        let package_bin = directory.path().join("bin");
        let pins = package_bin.join("cmux-tui-ssh");
        fs::create_dir_all(&pins).unwrap();
        let source = package_bin.join("cmux-tui");
        fs::write(&source, b"local npm platform executable").unwrap();
        let pinned = b"published linux executable";
        fs::write(
            pins.join("manifest.json"),
            serde_json::to_vec(&serde_json::json!({
                "commit": BUILD_IDENTITY,
                "binaries": {
                    "cmux-tui-aarch64-unknown-linux-musl": format!("{:x}", Sha256::digest(pinned)),
                },
            }))
            .unwrap(),
        )
        .unwrap();
        let served_file = directory.path().join("served");
        fs::write(&served_file, served).unwrap();
        let installed = directory.path().join("installed");
        let staged = directory.path().join("staged");
        let probe = serde_json::json!({
            "app": "cmux-tui", "version": "9.9.9", "distribution_version": "9.9.9",
            "npm_bootstrap_version": "9.9.9", "build_identity": "npm-build",
            "remote_protocol": REMOTE_PROTOCOL_VERSION, "os": "linux", "arch": "aarch64",
        });
        let script = directory.path().join("ssh");
        fs::write(
            &script,
            format!(
                r#"#!/bin/sh
digest() {{ set -- $(sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"); printf 'cmux-sha256 %s\n' "$1"; }}
case "$*" in
  *"uname -s -m"*) printf '%s\n' 'Linux aarch64' ;;
  *"mkdir -p "*|*"mkdir -m 700 "*) exit 0 ;;
  *".cmux-upload-"*"npm pack "*"cmux-tui-linux-arm64@9.9.9"*) cp '{served}' '{staged}'; digest '{staged}' ;;
  *"npx --yes"*) cp '{served}' '{installed}' ;;
  *".cmux-upload-"*" remote-probe --json"*) [ -f '{staged}' ] || exit 127; printf '%s' '{probe}' ;;
  *"remote-probe --json"*) [ -f '{installed}' ] || exit 127; printf '%s' '{probe}' ;;
  *"mv -f "*".cmux-upload-"*) mv '{staged}' '{installed}' ;;
  *"rm -f "*".cmux-upload-"*) rm -f '{staged}' ;;
  *"rmdir "*) exit 0 ;;
  *) exit 2 ;;
esac
"#,
                served = served_file.display(),
                staged = staged.display(),
                installed = installed.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_version = "9.9.9".into();
        config.package_installable = true;
        config.local_binary = Some(source);
        Self { _directory: directory, config, installed, staged }
    }
}

#[tokio::test]
async fn ssh_npm_bootstrap_refuses_a_package_that_differs_from_the_pinned_digest() {
    let fixture = NpmFixture::new(b"attacker-published executable");
    let result = SshBootstrapper::new(fixture.config).unwrap().ensure_installed().await;
    assert!(
        matches!(&result, Err(error) if error.to_string().contains("checksum")),
        "an npm package that differs from the pinned SHA-256 was trusted: {result:?}"
    );
    assert!(!fixture.installed.exists(), "the unverified npm binary was left installed");
    assert!(!fixture.staged.exists(), "the unverified npm binary was left staged");
}

#[tokio::test]
async fn ssh_npm_bootstrap_installs_a_package_that_matches_the_pinned_digest() {
    let fixture = NpmFixture::new(b"published linux executable");
    assert_eq!(
        SshBootstrapper::new(fixture.config).unwrap().ensure_installed().await.unwrap(),
        BootstrapOutcome::Installed
    );
    assert_eq!(fs::read(&fixture.installed).unwrap(), b"published linux executable");
    assert!(!fixture.staged.exists());
}

/// A remote whose login shell is fish or tcsh. OpenSSH joins the remote
/// argv with spaces and hands the string to the login shell, which parses
/// only plain words the way `sh` does. Anything else (`$?`, `{ ...; }`,
/// `[ ... ]`, `( ... )`, redirections) must arrive as one
/// `sh -c '<script>'` command. This stand-in rejects every other command
/// string, then really runs the command, so staging, the npm download, the
/// digest check, the upload and the promotion all happen on disk.
struct NonPosixLoginShellFixture {
    _directory: tempfile::TempDir,
    config: SshBootstrapConfig,
    rejected: std::path::PathBuf,
}

/// What `npm` prints when a newer npm is published.
const NPM_NOTICE: &str = "echo 'npm notice New major version of npm available! 10.9.2 -> 11.6.1'";

/// The npm platform package and pinned-manifest target for the platform the
/// stand-in remote reports. That is what `uname` prints, which can differ
/// from the test binary's own target (for example under Rosetta).
fn host_release_target() -> Option<(&'static str, &'static str)> {
    let uname = std::process::Command::new("uname").args(["-s", "-m"]).output().ok()?;
    let uname = String::from_utf8_lossy(&uname.stdout).to_string();
    let mut fields = uname.split_whitespace();
    match (fields.next()?, fields.next()?) {
        ("Linux", "aarch64" | "arm64") => {
            Some(("cmux-tui-linux-arm64", "aarch64-unknown-linux-musl"))
        }
        ("Linux", "x86_64" | "amd64") => Some(("cmux-tui-linux-x64", "x86_64-unknown-linux-musl")),
        ("Darwin", "aarch64" | "arm64") => Some(("cmux-tui-darwin-arm64", "aarch64-apple-darwin")),
        ("Darwin", "x86_64") => Some(("cmux-tui-darwin-x64", "x86_64-apple-darwin")),
        _ => None,
    }
}

impl NonPosixLoginShellFixture {
    fn new(npm: bool) -> Option<Self> {
        Self::with_notice(npm, false)
    }

    /// With `notice`, npm and the remote shell both print a notice on
    /// stdout while the package is fetched, as npm's update notifier or a
    /// login-shell message can.
    fn with_notice(npm: bool, notice: bool) -> Option<Self> {
        let (npm_package, target) = host_release_target()?;
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let probe = serde_json::json!({
            "app": "cmux-tui", "version": "9.9.9", "distribution_version": "9.9.9",
            "npm_bootstrap_version": "9.9.9", "build_identity": BUILD_IDENTITY,
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": std::env::consts::OS, "arch": std::env::consts::ARCH,
        });
        // The published binary answers the probe, so promotion is real.
        let binary = format!("#!/bin/sh\nprintf '%s' '{probe}'\n");

        let package_bin = root.join("bin");
        fs::create_dir_all(&package_bin).unwrap();
        let source = package_bin.join("cmux-tui");
        fs::write(&source, &binary).unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        // npm builds pin only the digest; the native app also ships the
        // payload, which the upload path sends over SSH.
        let pins = package_bin.join("cmux-tui-ssh");
        fs::create_dir(&pins).unwrap();
        if !npm {
            fs::write(pins.join(format!("cmux-tui-{target}")), &binary).unwrap();
        }
        fs::write(
            pins.join("manifest.json"),
            serde_json::to_vec(&serde_json::json!({
                "commit": BUILD_IDENTITY,
                "binaries": {
                    format!("cmux-tui-{target}"): format!("{:x}", Sha256::digest(&binary)),
                },
            }))
            .unwrap(),
        )
        .unwrap();

        // `npm pack` stand-in: writes the published tarball and runs nothing.
        let registry = root.join("registry");
        fs::create_dir_all(registry.join("package/bin")).unwrap();
        fs::write(registry.join("package/bin/cmux-tui"), &binary).unwrap();
        let fake_bin = root.join("fake-bin");
        fs::create_dir(&fake_bin).unwrap();
        fs::write(
            fake_bin.join("npm"),
            format!(
                r#"#!/bin/sh
[ "$1 $2 $3 $4" = 'pack --ignore-scripts --silent {npm_package}@9.9.9' ] || exit 9
{notice}
tar -czf '{npm_package}-9.9.9.tgz' -C '{registry}' package
"#,
                registry = registry.display(),
                notice = if notice { NPM_NOTICE } else { "" },
            ),
        )
        .unwrap();
        fs::set_permissions(fake_bin.join("npm"), fs::Permissions::from_mode(0o755)).unwrap();

        let rejected = root.join("rejected");
        let script = root.join("ssh");
        fs::write(
            &script,
            format!(
                r#"#!/bin/sh
while [ "$#" -gt 0 ]; do
  argument=$1; shift
  if [ "$argument" = "--" ]; then shift; break; fi
done
command_line="$*"
PATH='{fake_bin}':$PATH; export PATH
case "$command_line" in
  *"npm pack "*) {notice} ;;
esac
case "$command_line" in
  *[!A-Za-z0-9_./~:@+\ -]*) ;;
  *) exec sh -c "$command_line" ;;
esac
case "$command_line" in
  "sh -c '"*"'")
    eval "set -- $command_line"
    if [ "$#" -eq 3 ] && [ "$1" = sh ] && [ "$2" = -c ]; then exec sh -c "$3"; fi ;;
esac
printf '%s\n' "$command_line" >>'{rejected}'
echo 'fish: Unsupported use of $? or {{' >&2
exit 127
"#,
                fake_bin = fake_bin.display(),
                rejected = rejected.display(),
                notice = if notice { NPM_NOTICE } else { ":" },
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.remote_binary = root.join("home/.local/bin/cmux-tui").to_string_lossy().into_owned();
        config.package_version = "9.9.9".into();
        config.package_installable = npm;
        config.local_binary = Some(source);
        Some(Self { _directory: directory, config, rejected })
    }

    async fn install(self) {
        let installed = std::path::PathBuf::from(&self.config.remote_binary);
        let result = SshBootstrapper::new(self.config).unwrap().ensure_installed().await;
        let rejected = fs::read_to_string(&self.rejected).unwrap_or_default();
        assert!(
            rejected.is_empty(),
            "a non-POSIX login shell had to parse POSIX syntax:\n{rejected}"
        );
        assert_eq!(result.unwrap(), BootstrapOutcome::Installed);
        let leftovers = fs::read_dir(installed.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(leftovers, ["cmux-tui"], "staging was left behind");
    }
}

#[tokio::test]
async fn ssh_npm_bootstrap_works_when_the_remote_login_shell_is_not_posix() {
    if let Some(fixture) = NonPosixLoginShellFixture::new(true) {
        fixture.install().await;
    }
}

/// A notice on stdout ahead of the digest is not a tampered package.
#[tokio::test]
async fn ssh_npm_bootstrap_ignores_a_notice_printed_before_the_digest() {
    if let Some(fixture) = NonPosixLoginShellFixture::with_notice(true, true) {
        fixture.install().await;
    }
}

#[tokio::test]
async fn ssh_upload_bootstrap_works_when_the_remote_login_shell_is_not_posix() {
    if let Some(fixture) = NonPosixLoginShellFixture::new(false) {
        fixture.install().await;
    }
}
