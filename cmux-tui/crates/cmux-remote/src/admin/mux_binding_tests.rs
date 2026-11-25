use super::*;
use crate::admin::{AdminServer, call_admin, serve_admin, serve_admin_with_mux_binding};
use crate::daemon::RemoteDaemon;
use crate::identity::AuthDatabase;
use crate::session::SessionLimits;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

struct Fixture {
    _directory: tempfile::TempDir,
    _mux: std::os::unix::net::UnixListener,
    link: UnixListener,
    admin: PathBuf,
    binding: MuxBinding,
    server: AdminServer,
}

impl Fixture {
    async fn start(bound: bool) -> Self {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let mux = directory.path().join("mux.sock");
        let _mux = std::os::unix::net::UnixListener::bind(&mux).unwrap();
        let link_path = directory.path().join("link.sock");
        let link = UnixListener::bind(&link_path).unwrap();
        let binding = MuxBinding::new(&mux, &link_path).unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("auth"), "binding", true).unwrap();
        let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
        let admin = directory.path().join("admin.sock");
        let server = if bound {
            serve_admin_with_mux_binding(daemon, &admin, vec![], None, None, Some(binding.clone()))
                .await
                .unwrap()
        } else {
            serve_admin(daemon, &admin, vec![]).await.unwrap()
        };
        Self { _directory: directory, _mux, link, admin, binding, server }
    }
}

#[tokio::test]
async fn remote_mux_binding_read_preserves_status() {
    let fixture = Fixture::start(true).await;
    let before = call_admin(&fixture.admin, &AdminRequest::Status).await.unwrap().result;
    let stream = UnixStream::connect(&fixture.binding.link_socket).await.unwrap();
    verify_mux_binding(
        &stream,
        &fixture.admin,
        &fixture.binding.link_socket,
        &fixture.binding.mux_socket,
    )
    .await
    .unwrap();
    let after = call_admin(&fixture.admin, &AdminRequest::Status).await.unwrap().result;
    assert_eq!(before, after);
    fixture.server.shutdown().await.unwrap();
}

#[tokio::test]
async fn remote_mux_binding_refuses_an_unbound_admin_server() {
    let fixture = Fixture::start(false).await;
    let stream = UnixStream::connect(&fixture.binding.link_socket).await.unwrap();
    let result = verify_mux_binding(
        &stream,
        &fixture.admin,
        &fixture.binding.link_socket,
        &fixture.binding.mux_socket,
    )
    .await;
    fixture.server.shutdown().await.unwrap();
    assert!(result.is_err());
}

#[tokio::test]
async fn remote_mux_binding_refuses_another_link_in_the_same_process() {
    let fixture = Fixture::start(true).await;
    let other_path = fixture._directory.path().join("other.sock");
    let _other = UnixListener::bind(&other_path).unwrap();
    let stream = UnixStream::connect(&other_path).await.unwrap();
    let result =
        verify_mux_binding(&stream, &fixture.admin, &other_path, &fixture.binding.mux_socket).await;
    fixture.server.shutdown().await.unwrap();
    assert!(result.is_err());
}

#[tokio::test]
async fn remote_mux_binding_keeps_the_verified_descriptor_after_path_replacement() {
    let fixture = Fixture::start(true).await;
    let mut stream = UnixStream::connect(&fixture.binding.link_socket).await.unwrap();
    let (mut accepted, _) = fixture.link.accept().await.unwrap();
    verify_mux_binding(
        &stream,
        &fixture.admin,
        &fixture.binding.link_socket,
        &fixture.binding.mux_socket,
    )
    .await
    .unwrap();
    std::fs::remove_file(&fixture.binding.link_socket).unwrap();
    let replacement = std::os::unix::net::UnixListener::bind(&fixture.binding.link_socket).unwrap();
    replacement.set_nonblocking(true).unwrap();
    stream.write_all(b"original").await.unwrap();
    let mut bytes = [0; 8];
    accepted.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"original");
    assert_eq!(replacement.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    fixture.server.shutdown().await.unwrap();
}

struct OwnedChild(std::process::Child);

impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn remote_mux_binding_refuses_an_admin_from_another_process() {
    use std::io::BufRead;
    let fixture = Fixture::start(true).await;
    let child_path = fixture._directory.path().join("child.sock");
    let mut child = OwnedChild(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "admin::mux_binding::tests::foreign_link_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_FOREIGN_LINK", &child_path)
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut output = std::io::BufReader::new(child.0.stdout.take().unwrap());
    loop {
        let mut line = String::new();
        assert_ne!(output.read_line(&mut line).unwrap(), 0, "child never bound its listener");
        if line.contains("LINK_READY") {
            break;
        }
    }
    let stream = UnixStream::connect(&child_path).await.unwrap();
    let result =
        verify_mux_binding(&stream, &fixture.admin, &child_path, &fixture.binding.mux_socket).await;
    assert!(result.unwrap_err().to_string().contains("not the link process"));
    fixture.server.shutdown().await.unwrap();
}

#[test]
#[ignore = "owned child fixture; invoked by the peer-process test"]
fn foreign_link_fixture() {
    use std::io::{Read, Write};
    let path = std::env::var_os("CMUX_TEST_FOREIGN_LINK").unwrap();
    let listener = std::os::unix::net::UnixListener::bind(path).unwrap();
    println!("LINK_READY");
    std::io::stdout().flush().unwrap();
    let (mut stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    let _ = stream.read(&mut [0]);
}
