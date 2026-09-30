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
