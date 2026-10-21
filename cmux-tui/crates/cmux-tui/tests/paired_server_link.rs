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

struct Api {
    public: Mutex<Option<String>>,
    paired: bool,
}

impl Default for Api {
    fn default() -> Self {
        Self { public: Mutex::new(None), paired: true }
    }
}

impl Transport for Api {
    fn health(&self, _: &str) -> cmux_server::Result<Value> {
        Ok(json!({"environment":"staging"}))
    }

    fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
        *self.public.lock().unwrap() = Some(body["wg_public_key"].as_str().unwrap().into());
        Ok(json!({
            "code":"7KQ4M2XD", "expires_at":NOW+600_000,
            "thumbprint":jwk_thumbprint(&body["public_jwk"]).unwrap(),
            "collect_secret":"AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }))
    }

    fn wait(&self, _: &str, _: &Begun) -> cmux_server::Result<Waited> {
        if !self.paired {
            return Err(cmux_server::Error::unreachable("fixture.pending"));
        }
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
    let public = api.public.lock().unwrap().clone().unwrap();
    (identity, public)
}

fn command(home: &Path, args: &[&str]) -> Output {
    command_locale(home, args, "en_US.UTF-8")
}

fn command_locale(home: &Path, args: &[&str], locale: &str) -> Output {
    cli(home, args, locale).output().unwrap()
}

fn cli(home: &Path, args: &[&str], locale: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .arg0("cmux")
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("LANG", locale)
        .env("CMUX_TUI_STATE_DIR", home.join("daemon"))
        .stdin(Stdio::null())
        .current_dir(home);
    command
}

#[test]
fn paired_server_link_help_explains_the_existing_identity_in_all_supported_languages() {
    let home = tempfile::tempdir().unwrap();
    for (locale, words) in [
        ("en_US.UTF-8", "existing identity"),
        ("de_DE.UTF-8", "Vorhandene Identität"),
        ("fr_FR.UTF-8", "identité existante"),
        ("es_ES.UTF-8", "identidad existente"),
        ("ar_SA.UTF-8", "الهوية الحالية"),
        ("ko_KR.UTF-8", "기존 ID"),
        ("ja_JP.UTF-8", "既存の ID"),
        ("zh_Hans.UTF-8", "现有身份"),
        ("zh_Hant.UTF-8", "現有身分"),
    ] {
        let out = command_locale(home.path(), &["link", "--help"], locale);
        assert!(out.status.success());
        let help = String::from_utf8(out.stdout).unwrap();
        assert!(help.contains("--server-identity FILE"), "{locale}: {help}");
        assert!(help.contains(words), "{locale}: {help}");
    }
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

#[test]
fn paired_server_link_an_explicit_other_install_is_refused_before_creating_state() {
    let home = tempfile::tempdir().unwrap();
    let (identity, _) = enrolled(home.path());
    let link = home.path().join("other-link");
    let out = command(
        home.path(),
        &[
            "link",
            "init",
            "--state-dir",
            link.to_str().unwrap(),
            "--install",
            "inst_other",
            "--server-identity",
            identity.to_str().unwrap(),
        ],
    );
    assert!(!out.status.success());
    assert!(!link.exists());
}

#[test]
fn paired_server_link_pending_or_symlinked_enrollment_cannot_initialize_a_link() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("pending/identity.json");
    let pending = Api { paired: false, ..Api::default() };
    assert!(pairing::enroll(
        &path, "https://api.example.test",
        json!({"name":"Test server","platform":"linux","os_version":"test","arch":"aarch64","cmux_version":"1.0.0"}),
        None, &pending, NOW, |_| Ok(()),
    ).is_err());
    let before = std::fs::read(&path).unwrap();
    let (identity, _) = enrolled(home.path());
    let symlink = identity.with_file_name("linked.json");
    std::os::unix::fs::symlink(&identity, &symlink).unwrap();
    for source in [&path, &symlink] {
        let link = home.path().join("refused-link");
        let out = command(
            home.path(),
            &[
                "link",
                "init",
                "--state-dir",
                link.to_str().unwrap(),
                "--server-identity",
                source.to_str().unwrap(),
            ],
        );
        assert!(!out.status.success());
        assert!(!link.exists());
    }
    assert!(std::fs::read(&path).unwrap() == before, "pending enrollment changed");
}

/// Only this test's registered links are stopped, including when an assertion fails.
struct Links {
    home: tempfile::TempDir,
    states: Vec<std::path::PathBuf>,
}

impl Links {
    fn new() -> Self {
        Self { home: cmux_unix_socket::short_test_dir("pairedlink"), states: Vec::new() }
    }

    fn state(&mut self, name: &str) -> std::path::PathBuf {
        let path = self.home.path().join(name).join("link");
        self.states.push(path.clone());
        path
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = command(self.home.path(), args);
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Links {
    fn drop(&mut self) {
        if std::thread::panicking() {
            for log in std::iter::once(self.home.path().join("daemon.log"))
                .chain(self.states.iter().map(|state| state.join("link.log")))
            {
                if let Ok(text) = std::fs::read_to_string(log) {
                    eprintln!("owned process log:\n{text}");
                }
            }
        }
        for state in &self.states {
            if state.exists() {
                let _ = command(
                    self.home.path(),
                    &["link", "stop", "--state-dir", state.to_str().unwrap()],
                );
            }
        }
    }
}

fn initialize_server(links: &Links, state: &Path, identity: &Path) -> Value {
    links.json(&[
        "link",
        "init",
        "--state-dir",
        state.to_str().unwrap(),
        "--server-identity",
        identity.to_str().unwrap(),
        "--port",
        "0",
    ])
}

fn add_peer(links: &Links, state: &Path, install: &str, public: &str, udp: &str) {
    let address: std::net::SocketAddr = udp.parse().unwrap();
    let endpoint = format!("[::1]:{}", address.port());
    let result = links.json(&[
        "link",
        "peer",
        "add",
        "--state-dir",
        state.to_str().unwrap(),
        "--install",
        install,
        "--user",
        "user_00000000000000000001",
        "--team",
        "team_00000000000000000001",
        "--public-key",
        public,
        "--endpoint",
        &endpoint,
    ]);
    assert_eq!(result["reloaded"], true, "peer update did not reach the live mesh");
}

async fn within<T>(stage: &str, future: impl Future<Output = T>) -> T {
    tokio::time::timeout(std::time::Duration::from_secs(10), future)
        .await
        .unwrap_or_else(|_| panic!("owned loopback deadline: {stage}"))
}

/// The real daemon is signed as the same code as each link. Readiness uses its
/// inherited one-shot descriptor rather than polling or weakening caller checks.
struct Daemon(std::process::Child);

impl Daemon {
    async fn start(home: &Path, socket: &Path) -> Self {
        use std::io::Read as _;
        use std::os::fd::AsRawFd;

        let (mut read, write) = std::io::pipe().unwrap();
        let fd = write.as_raw_fd();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--link-entry", "--socket"])
            .arg(socket)
            .arg("--state")
            .arg(home.join("daemon.json"))
            .arg("--owner-ready-fd")
            .arg(fd.to_string())
            .env_clear()
            .env("HOME", home)
            .env("TMPDIR", home)
            .env("CMUX_TUI_CONFIG", home.join("config.json"))
            .env("CMUX_TUI_STATE_DIR", home.join("daemon"))
            .current_dir(home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(home.join("daemon.log")).unwrap());
        // SAFETY: fcntl is async-signal-safe; only this owned descriptor has
        // close-on-exec cleared in the child, which claims and closes it.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let daemon = Self(command.spawn().unwrap());
        drop(write);
        let ready = within(
            "daemon readiness",
            tokio::task::spawn_blocking(move || {
                let mut byte = [0];
                read.read_exact(&mut byte).map(|()| byte[0])
            }),
        )
        .await
        .unwrap()
        .unwrap_or_else(|error| {
            panic!(
                "daemon readiness: {error}: {}",
                std::fs::read_to_string(home.join("daemon.log")).unwrap_or_default()
            )
        });
        assert_eq!(ready, b'1');
        daemon
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn paired_server_link_unchecked_peer_dial_exits_with_stdin_still_open() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let mut links = Links::new();
    let (identity, public) = enrolled(links.home.path());
    let server = links.state("server");
    let client = links.state("client");
    initialize_server(&links, &server, &identity);
    let client_init = links.json(&[
        "link",
        "init",
        "--state-dir",
        client.to_str().unwrap(),
        "--install",
        "inst_client",
        "--port",
        "0",
    ]);

    let session = links.home.path().join("s.sock");
    let _daemon = Daemon::start(links.home.path(), &session).await;
    let server_live = links.json(&[
        "link",
        "ensure",
        "--state-dir",
        server.to_str().unwrap(),
        "--session-socket",
        session.to_str().unwrap(),
    ]);
    let client_live = links.json(&["link", "ensure", "--state-dir", client.to_str().unwrap()]);
    add_peer(
        &links,
        &server,
        "inst_client",
        client_init["public_key"].as_str().unwrap(),
        client_live["udp"].as_str().unwrap(),
    );
    add_peer(&links, &client, INSTALL, &public, server_live["udp"].as_str().unwrap());

    let mut command = cli(
        links.home.path(),
        &["link", "dial", "--host", INSTALL, "--socket", client_live["socket"].as_str().unwrap()],
        "en_US.UTF-8",
    );
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut caller = tokio::process::Command::from(command).kill_on_drop(true).spawn().unwrap();
    let mut input = caller.stdin.take().unwrap();
    let mut output = BufReader::new(caller.stdout.take().unwrap());
    let mut status = BufReader::new(caller.stderr.take().unwrap());
    let mut line = String::new();
    within("dial handshake", status.read_line(&mut line)).await.unwrap();
    let dial: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(dial["ok"], true, "{dial}");
    // This peer has no fresh control-plane check. The daemon must close before
    // dispatching any command, and the CLI must exit even with stdin held open.
    let marker = links.home.path().join("remote-command-ran");
    let request = json!({"id":1,"cmd":"run","argv":["/usr/bin/touch",marker.to_str().unwrap()],"new_workspace":true});
    input.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    line.clear();
    assert_eq!(within("unchecked peer EOF", output.read_line(&mut line)).await.unwrap(), 0);
    assert!(!marker.exists());
    assert!(within("refused dial exit", caller.wait()).await.unwrap().success());
    drop(input);
    let status = links.json(&["link", "status", "--state-dir", server.to_str().unwrap()]);
    assert_eq!(status["public_key"], public);
    assert_eq!(status["identity_source"], "server_pairing");
    assert!(!server.join("private.key").exists());
}

#[test]
fn paired_server_link_changed_enrollment_cannot_silently_reuse_or_stop_a_running_mesh() {
    let mut links = Links::new();
    let (identity, public) = enrolled(links.home.path());
    let state = links.state("server");
    initialize_server(&links, &state, &identity);
    let live = links.json(&["link", "ensure", "--state-dir", state.to_str().unwrap()]);
    let other = cmux_unix_socket::short_test_dir("otherpair");
    let (replacement, other_public) = enrolled(other.path());
    assert_ne!(public, other_public);
    std::fs::write(&identity, std::fs::read(replacement).unwrap()).unwrap();
    let out =
        command(links.home.path(), &["link", "ensure", "--state-dir", state.to_str().unwrap()]);
    assert!(!out.status.success());
    let status = links.json(&["link", "status", "--state-dir", state.to_str().unwrap()]);
    assert_eq!(status["pid"], live["pid"]);
    assert_eq!(status["public_key"], public);
}
