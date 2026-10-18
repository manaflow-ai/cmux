//! The shipped link uses the same install and WireGuard identity that was paired.
#![cfg(unix)]

use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::Mutex;

use cmux_server::pairing::{self, Transport};
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited, jwk_thumbprint};
use serde_json::{Value, json};

const INSTALL: &str = "inst_00000000000000000001";
const NOW: u64 = 1_790_978_474_000;

#[derive(Default)]
struct Api(Mutex<Option<String>>);

impl Transport for Api {
    fn health(&self, _: &str) -> cmux_server::Result<Value> {
        Ok(json!({"environment":"staging"}))
    }

    fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
        *self.0.lock().unwrap() = Some(body["wg_public_key"].as_str().unwrap().into());
        Ok(json!({
            "code":"7KQ4M2XD", "expires_at":NOW+600_000,
            "thumbprint":jwk_thumbprint(&body["public_jwk"]).unwrap(),
            "collect_secret":"AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }))
    }

    fn wait(&self, _: &str, _: &Begun) -> cmux_server::Result<Waited> {
        Ok(Waited::Paired(Paired {
            host: "host_00000000000000000001".into(),
            team: "team_00000000000000000001".into(),
            user: "user_00000000000000000001".into(),
            install: INSTALL.into(),
        }))
    }
}

fn enrolled(home: &Path) -> (std::path::PathBuf, String) {
    let identity = home.join("pairing/identity.json");
    let api = Api::default();
    pairing::enroll(
        &identity,
        "https://api.example.test",
        json!({"name":"Test server","platform":"linux","os_version":"test","arch":"aarch64","cmux_version":"1.0.0"}),
        None,
        &api,
        NOW,
        |_| Ok(()),
    )
    .unwrap();
    let public = api.0.lock().unwrap().clone().unwrap();
    (identity, public)
}

fn command(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg0("cmux")
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("CMUX_TUI_STATE_DIR", home.join("daemon"))
        .stdin(Stdio::null())
        .current_dir(home)
        .output()
        .unwrap()
}

#[test]
fn paired_server_link_init_uses_the_enrolled_install_and_wireguard_key_without_copying_it() {
    let home = tempfile::tempdir().unwrap();
    let (identity, public) = enrolled(home.path());
    let before = std::fs::read(&identity).unwrap();
    let link = home.path().join("server-link");
    for _ in 0..2 {
        let out = command(
            home.path(),
            &[
                "link",
                "init",
                "--state-dir",
                link.to_str().unwrap(),
                "--server-identity",
                identity.to_str().unwrap(),
                "--port",
                "0",
            ],
        );
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let shown: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(shown["install"], INSTALL);
        assert_eq!(shown["public_key"], public);
        assert!(std::fs::read(&identity).unwrap() == before, "enrollment record changed");
        assert!(!link.join("private.key").exists(), "the enrollment key was copied");
    }
}

#[test]
fn paired_server_link_invalid_enrollment_does_not_create_link_state() {
    let home = tempfile::tempdir().unwrap();
    let link = home.path().join("server-link");
    let identity = home.path().join("missing-identity.json");
    let out = command(
        home.path(),
        &[
            "link",
            "init",
            "--state-dir",
            link.to_str().unwrap(),
            "--server-identity",
            identity.to_str().unwrap(),
        ],
    );
    assert!(!out.status.success());
    assert!(!link.exists());
    assert!(!identity.exists());
}

#[test]
fn paired_server_link_enrollment_cannot_replace_an_existing_local_link_identity() {
    let home = tempfile::tempdir().unwrap();
    let (identity, _) = enrolled(home.path());
    let link = home.path().join("existing-link");
    let init = command(
        home.path(),
        &[
            "link",
            "init",
            "--state-dir",
            link.to_str().unwrap(),
            "--install",
            "inst_other",
            "--port",
            "0",
        ],
    );
    assert!(init.status.success(), "{}", String::from_utf8_lossy(&init.stderr));
    let key = std::fs::read(link.join("private.key")).unwrap();
    let config = std::fs::read(link.join("config.json")).unwrap();
    let out = command(
        home.path(),
        &[
            "link",
            "init",
            "--state-dir",
            link.to_str().unwrap(),
            "--server-identity",
            identity.to_str().unwrap(),
        ],
    );
    assert!(!out.status.success());
    assert!(std::fs::read(link.join("private.key")).unwrap() == key, "existing key changed");
    assert!(std::fs::read(link.join("config.json")).unwrap() == config, "existing config changed");
}
