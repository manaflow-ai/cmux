//! End to end against a real OpenSSH server on 127.0.0.1: the link's
//! plain SSH kind, its host key states and a Finder copy over SFTP.
//!
//! The test starts its own unprivileged `sshd` with throwaway keys made by
//! `ssh-keygen` in a temporary directory. Without `/usr/sbin/sshd` (or the
//! client tools) it prints SKIP and returns.

use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_link::conn::{
    ConnKind, ConnOp, ConnRequest, ConnState, ConnStore, CredentialRef, HostKeyState, Origin,
    Principal, Reject, SshTarget, StoreError, Target,
};
use cmux_link::fs::ops::SftpFsOwner;
use cmux_link::fs::{Rights, SftpRoot};
use cmux_link::ids::random_id;
use cmux_link::job::{ConflictPolicy, CopyRequest, Endpoint, JobEventKind, LocalRoot, start_copy};
use cmux_link::ssh::{ConnectError, SshConfigCredentials, SshConnector, SshSettings};
use serde_json::json;

const SSHD: &str = "/usr/sbin/sshd";
const SSH: &str = "/usr/bin/ssh";
const SSH_KEYGEN: &str = "/usr/bin/ssh-keygen";
const SFTP_SERVERS: &[&str] = &["/usr/lib/openssh/sftp-server", "/usr/libexec/sftp-server"];

struct Sshd {
    child: Child,
}

impl Drop for Sshd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn keygen(path: &Path) {
    keygen_typed(path, "ed25519");
}

fn keygen_typed(path: &Path, key_type: &str) {
    let status = Command::new(SSH_KEYGEN)
        .args(["-q", "-t", key_type, "-N", "", "-C", "cmux-link-test", "-f"])
        .arg(path)
        .stdin(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}

fn fingerprint(public_key: &Path) -> String {
    let output = Command::new(SSH_KEYGEN)
        .args(["-E", "sha256", "-l", "-f"])
        .arg(public_key)
        .output()
        .unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    text.split_whitespace().nth(1).unwrap().to_owned()
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn start_sshd(directory: &Path, port: u16, host_key: &Path, sftp_server: &str) -> Sshd {
    let config = directory.join("sshd_config");
    std::fs::write(
        &config,
        format!(
            "Port {port}\nListenAddress 127.0.0.1\nHostKey {}\nAuthorizedKeysFile {}\n\
             PasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\n\
             PidFile {}\nSubsystem sftp {sftp_server}\nLogLevel ERROR\n",
            host_key.display(),
            directory.join("authorized_keys").display(),
            directory.join("sshd.pid").display(),
        ),
    )
    .unwrap();
    let child = Command::new(SSHD)
        .arg("-D")
        .arg("-e")
        .arg("-f")
        .arg(&config)
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "sshd did not start listening");
        std::thread::sleep(Duration::from_millis(50));
    }
    Sshd { child }
}

struct Lab {
    directory: tempfile::TempDir,
    port: u16,
    sftp_server: String,
    connector: SshConnector,
    store: Arc<ConnStore>,
    principal: Principal,
    user_known_hosts: PathBuf,
}

fn lab() -> Option<Lab> {
    let sftp_server = SFTP_SERVERS.iter().find(|path| Path::new(path).is_file());
    if !Path::new(SSHD).is_file() || !Path::new(SSH).is_file() || sftp_server.is_none() {
        assert!(
            std::env::var_os("CMUX_REQUIRE_SSHD").is_none(),
            "CMUX_REQUIRE_SSHD is set but sshd, ssh or sftp-server is missing"
        );
        eprintln!("SKIP: no sshd, ssh or sftp-server on this machine");
        return None;
    }
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path();
    keygen(&path.join("host_a"));
    keygen(&path.join("host_b"));
    keygen(&path.join("client"));
    keygen_typed(&path.join("host_rsa"), "rsa");
    std::fs::copy(path.join("client.pub"), path.join("authorized_keys")).unwrap();
    std::fs::write(path.join("ssh_config"), "").unwrap();
    let user_known_hosts = path.join("user_known_hosts");
    std::fs::write(&user_known_hosts, "").unwrap();
    let store = Arc::new(ConnStore::open(&path.join("link")).unwrap());
    let mut settings = SshSettings::system(path);
    settings.ssh = PathBuf::from(SSH);
    settings.ssh_keygen = PathBuf::from(SSH_KEYGEN);
    settings.user_known_hosts = vec![user_known_hosts.clone()];
    settings.connect_timeout = Duration::from_secs(10);
    settings.extra_args = [
        "-F".to_owned(),
        path.join("ssh_config").display().to_string(),
        "-i".to_owned(),
        path.join("client").display().to_string(),
        "-o".to_owned(),
        "IdentitiesOnly=yes".to_owned(),
        "-o".to_owned(),
        "IdentityAgent=none".to_owned(),
    ]
    .to_vec();
    let connector = SshConnector {
        settings,
        store: Arc::clone(&store),
        credentials: Arc::new(SshConfigCredentials),
        proxy_command: None,
    };
    Some(Lab {
        port: free_port(),
        sftp_server: (*sftp_server.unwrap()).to_owned(),
        connector,
        store,
        principal: Principal { user: "user_test".into(), app: "app_finder".into() },
        user_known_hosts,
        directory,
    })
}

impl Lab {
    fn path(&self) -> &Path {
        self.directory.path()
    }

    fn sshd(&self, host_key: &str) -> Sshd {
        start_sshd(self.path(), self.port, &self.path().join(host_key), &self.sftp_server)
    }

    fn create_conn(&self) -> String {
        self.create_conn_for(&self.principal)
    }

    fn create_conn_for(&self, principal: &Principal) -> String {
        let conn = random_id("conn_");
        let user = std::env::var("USER").unwrap_or_else(|_| whoami());
        self.store
            .apply(&ConnRequest {
                idempotency_key: random_id("idem_"),
                principal: principal.clone(),
                origin: Origin::User,
                op: ConnOp::Create {
                    conn: conn.clone(),
                    kind: ConnKind::Ssh,
                    target: Target::Ssh(SshTarget {
                        destination: format!("{user}@127.0.0.1"),
                        port: Some(self.port),
                    }),
                    credential: Some(CredentialRef::SshConfig),
                },
            })
            .unwrap();
        conn
    }

    fn confirm(&self, conn: &str, fingerprint: &str, origin: Origin) -> Result<(), StoreError> {
        self.store
            .apply(&ConnRequest {
                idempotency_key: random_id("idem_"),
                principal: self.principal.clone(),
                origin,
                op: ConnOp::ConfirmHostKey {
                    conn: conn.to_owned(),
                    fingerprint: fingerprint.to_owned(),
                },
            })
            .map(|_| ())
    }
}

fn whoami() -> String {
    String::from_utf8(Command::new("id").arg("-un").output().unwrap().stdout)
        .unwrap()
        .trim()
        .to_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn finder_copies_on_a_plain_ssh_host_and_a_changed_key_is_a_hard_stop() {
    let Some(lab) = lab() else { return };
    let fingerprint_a = fingerprint(&lab.path().join("host_a.pub"));
    let fingerprint_b = fingerprint(&lab.path().join("host_b.pub"));
    let conn = lab.create_conn();

    // First contact: the key is unknown; nothing is accepted without the user.
    let sshd = lab.sshd("host_a");
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("unknown key refuses");
    match &error {
        ConnectError::HostKeyUnknown { fingerprint, .. } => assert_eq!(fingerprint, &fingerprint_a),
        other => panic!("expected host_key.unknown, got {other}"),
    }
    assert_eq!(error.code(), "host_key.unknown");
    let record = lab.store.get(&lab.principal, &conn).unwrap();
    assert_eq!(record.state, ConnState::Verifying);
    assert_eq!(
        std::fs::read_to_string(&lab.user_known_hosts).unwrap(),
        "",
        "the user's known_hosts is never written"
    );

    // The sheet confirms with a user gesture; the link connects.
    assert!(matches!(
        lab.confirm(&conn, &fingerprint_a, Origin::Mcp),
        Err(StoreError::Rejected(Reject::OriginNotUser))
    ));
    lab.confirm(&conn, &fingerprint_a, Origin::User).unwrap();
    let session =
        lab.connector.open_sftp(&lab.principal, &conn).await.expect("confirmed key connects");
    assert_eq!(lab.store.get(&lab.principal, &conn).unwrap().state, ConnState::Connected);

    // Finder: copy a folder from this machine to the SSH host, then list it.
    let local = tempfile::tempdir().unwrap();
    std::fs::create_dir(local.path().join("photos")).unwrap();
    let payload: Vec<u8> = (0..2_500_000_u32).map(|value| (value % 241) as u8).collect();
    std::fs::write(local.path().join("photos/one.raw"), &payload).unwrap();
    std::fs::write(local.path().join("photos/two.txt"), "two").unwrap();
    let remote_dir = lab.path().join("remote");
    std::fs::create_dir(&remote_dir).unwrap();
    let root =
        SftpRoot::open(session.client.clone(), remote_dir.to_str().unwrap(), Rights::ReadWrite)
            .await
            .unwrap();
    let mut job = start_copy(CopyRequest {
        from: Endpoint::Local(LocalRoot { base: local.path().to_owned(), rights: Rights::Read }),
        paths: vec!["photos".into()],
        to: Endpoint::Sftp(root.clone()),
        destination: String::new(),
        conflict: ConflictPolicy::Ask,
        window_bytes: 1024 * 1024,
    });
    let mut last = None;
    while let Some(event) = job.events.recv().await {
        let terminal = matches!(
            event.kind,
            JobEventKind::Done | JobEventKind::Failed { .. } | JobEventKind::Cancelled
        );
        last = Some(event.kind);
        if terminal {
            break;
        }
    }
    assert_eq!(last, Some(JobEventKind::Done));
    assert_eq!(std::fs::read(remote_dir.join("photos/one.raw")).unwrap(), payload);
    let owner = SftpFsOwner::default();
    let listing = owner
        .call("app_finder/conn", &root, "fs.list", json!({"path": "photos", "limit": 10}))
        .await
        .unwrap();
    let names: Vec<_> = listing["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["one.raw", "two.txt"]);
    session.close().await;
    drop(sshd);

    // The host now presents another key: hard stop, both fingerprints, no prompt.
    let sshd = lab.sshd("host_b");
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("changed key refuses");
    match &error {
        ConnectError::HostKeyChanged { old_fingerprint, new_fingerprint } => {
            assert_eq!(old_fingerprint, &fingerprint_a);
            assert_eq!(new_fingerprint, &fingerprint_b);
        }
        other => panic!("expected host_key.changed, got {other}"),
    }
    assert_eq!(error.code(), "host_key.changed");
    let record = lab.store.get(&lab.principal, &conn).unwrap();
    assert!(matches!(record.host_key, HostKeyState::Changed { .. }));
    // Every later connect is refused before ssh runs, and nothing but a user
    // confirm of the new fingerprint moves it.
    let again = lab.connector.open_sftp(&lab.principal, &conn).await.err().unwrap();
    assert_eq!(again.code(), "host_key.changed");
    assert!(lab.confirm(&conn, &fingerprint_b, Origin::Cli).is_err());
    assert!(lab.confirm(&conn, &fingerprint_a, Origin::User).is_err());
    let known_hosts = std::fs::read_to_string(lab.store.known_hosts_path(&conn)).unwrap();
    assert!(
        !known_hosts.contains(&key_blob(&lab.path().join("host_b.pub"))),
        "the new key is not trusted"
    );
    lab.confirm(&conn, &fingerprint_b, Origin::User).unwrap();
    let session = lab
        .connector
        .open_sftp(&lab.principal, &conn)
        .await
        .expect("the confirmed new key connects");
    session.close().await;
    drop(sshd);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_known_hosts_is_trusted_input_and_a_mismatch_there_is_a_change() {
    let Some(lab) = lab() else { return };
    let lookup = format!("[127.0.0.1]:{}", lab.port);
    let line = format!("{lookup} ssh-ed25519 {}\n", key_blob(&lab.path().join("host_a.pub")));
    std::fs::write(&lab.user_known_hosts, &line).unwrap();

    let sshd = lab.sshd("host_a");
    let conn = lab.create_conn();
    let session = lab
        .connector
        .open_sftp(&lab.principal, &conn)
        .await
        .expect("a key the user already trusts connects");
    let record = lab.store.get(&lab.principal, &conn).unwrap();
    assert!(matches!(record.host_key, HostKeyState::Confirmed { .. }));
    session.close().await;
    drop(sshd);

    let sshd = lab.sshd("host_b");
    let other = lab.create_conn();
    let error = lab.connector.open_sftp(&lab.principal, &other).await.err().unwrap();
    assert_eq!(error.code(), "host_key.changed", "{error}");
    assert_eq!(std::fs::read_to_string(&lab.user_known_hosts).unwrap(), line, "still read-only");
    drop(sshd);
}

fn key_blob(public_key: &Path) -> String {
    std::fs::read_to_string(public_key).unwrap().split_whitespace().nth(1).unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_key_one_app_confirmed_does_not_let_another_app_connect() {
    let Some(lab) = lab() else { return };
    let fingerprint_a = fingerprint(&lab.path().join("host_a.pub"));
    let sshd = lab.sshd("host_a");
    let conn = lab.create_conn();
    let _ = lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("unknown first");
    lab.confirm(&conn, &fingerprint_a, Origin::User).unwrap();
    lab.connector.open_sftp(&lab.principal, &conn).await.expect("app A connects").close().await;

    let other_app = Principal { user: "user_test".into(), app: "app_other".into() };
    let other = lab.create_conn_for(&other_app);
    let error = lab.connector.open_sftp(&other_app, &other).await.err().expect("app B must ask");
    assert_eq!(error.code(), "host_key.unknown", "{error}");
    assert!(
        std::fs::read_to_string(lab.store.known_hosts_path(&other))
            .unwrap()
            .lines()
            .all(|line| line.starts_with('#')),
        "app B's known-hosts file holds no key"
    );
    drop(sshd);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_key_type_downgrade_is_a_hard_stop() {
    let Some(lab) = lab() else { return };
    // The user trusts an ed25519 key; the host now offers only RSA.
    let lookup = format!("[127.0.0.1]:{}", lab.port);
    let line = format!("{lookup} ssh-ed25519 {}\n", key_blob(&lab.path().join("host_a.pub")));
    std::fs::write(&lab.user_known_hosts, &line).unwrap();
    let sshd = lab.sshd("host_rsa");
    let conn = lab.create_conn();
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("downgrade refuses");
    match &error {
        ConnectError::HostKeyChanged { old_fingerprint, new_fingerprint } => {
            assert_eq!(old_fingerprint, &fingerprint(&lab.path().join("host_a.pub")));
            assert_eq!(new_fingerprint, &fingerprint(&lab.path().join("host_rsa.pub")));
        }
        other => panic!("expected host_key.changed, got {other}"),
    }
    drop(sshd);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_revoked_key_is_a_hard_stop_that_no_confirm_lifts() {
    let Some(lab) = lab() else { return };
    let line = format!("@revoked * ssh-ed25519 {}\n", key_blob(&lab.path().join("host_a.pub")));
    std::fs::write(&lab.user_known_hosts, &line).unwrap();
    let sshd = lab.sshd("host_a");
    let conn = lab.create_conn();
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("revoked refuses");
    assert_eq!(error.code(), "host_key.revoked", "{error}");
    let fingerprint_a = fingerprint(&lab.path().join("host_a.pub"));
    assert!(matches!(
        lab.confirm(&conn, &fingerprint_a, Origin::User),
        Err(StoreError::Rejected(Reject::HostKeyRevoked { .. }))
    ));
    let again = lab.connector.open_sftp(&lab.principal, &conn).await.err().unwrap();
    assert_eq!(again.code(), "host_key.revoked");
    drop(sshd);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_host_trusted_only_through_a_ca_that_offers_a_plain_key_is_a_change() {
    let Some(lab) = lab() else { return };
    // The user trusts host certificates signed by a CA for this host; the
    // host offers a plain key instead.
    let lookup = format!("[127.0.0.1]:{}", lab.port);
    let line = format!(
        "@cert-authority {lookup} ssh-ed25519 {}\n",
        key_blob(&lab.path().join("host_b.pub"))
    );
    std::fs::write(&lab.user_known_hosts, &line).unwrap();
    let sshd = lab.sshd("host_a");
    let conn = lab.create_conn();
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("CA-only host refuses");
    assert_eq!(error.code(), "host_key.changed", "{error}");
    drop(sshd);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hostile_server_cannot_hard_stop_its_own_connection_through_stderr() {
    let Some(lab) = lab() else { return };
    let fingerprint_a = fingerprint(&lab.path().join("host_a.pub"));
    let sshd = lab.sshd("host_a");
    let conn = lab.create_conn();
    let _ = lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("unknown first");
    lab.confirm(&conn, &fingerprint_a, Origin::User).unwrap();
    drop(sshd);

    // The subsystem writes OpenSSH-looking verdicts to stderr after auth and exits.
    let hostile = lab.path().join("hostile-sftp");
    std::fs::write(
        &hostile,
        "#!/bin/sh\necho '@ WARNING: REVOKED HOST KEY DETECTED! @' >&2\necho 'Host key verification failed.' >&2\necho 'Permission denied (publickey).' >&2\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&hostile, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .unwrap();
    let sshd =
        start_sshd(lab.path(), lab.port, &lab.path().join("host_a"), hostile.to_str().unwrap());
    let error =
        lab.connector.open_sftp(&lab.principal, &conn).await.err().expect("the subsystem fails");
    assert_eq!(error.code(), "host.unreachable", "{error}");
    let record = lab.store.get(&lab.principal, &conn).unwrap();
    assert!(matches!(record.host_key, HostKeyState::Confirmed { .. }), "{:?}", record.host_key);
    drop(sshd);
}
