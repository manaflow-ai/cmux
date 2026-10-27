//! Read-only binding of a local sidecar to its supervisor-owned mux socket.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::net::UnixStream;

use super::{AdminError, AdminRequest, call_admin_over_stream, verify_unix_peer_owner};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MuxBinding {
    pub mux_socket: PathBuf,
    pub link_socket: PathBuf,
}

impl MuxBinding {
    pub fn new(mux_socket: &Path, link_socket: &Path) -> std::io::Result<Self> {
        Ok(Self {
            mux_socket: cmux_blocking::fs::canonicalize(mux_socket)
                .or_else(|_| std::path::absolute(mux_socket))?,
            link_socket: std::path::absolute(link_socket)?,
        })
    }

    /// Whether both sockets resolve to the same files as `other`'s.
    fn same_destination(&self, other: &Self) -> std::io::Result<bool> {
        use cmux_blocking::fs::canonicalize;
        Ok(canonicalize(&self.mux_socket)? == canonicalize(&other.mux_socket)?
            && canonicalize(&self.link_socket)? == canonicalize(&other.link_socket)?)
    }
}

/// Verify the live configuration through the same process as the already-open
/// link. The caller keeps that link for its relay; it must not reconnect by path
/// after this check. Older sidecars without this read are refused only when the
/// caller explicitly selected a mux destination.
pub async fn verify_mux_binding(
    link: &UnixStream,
    admin_path: &Path,
    expected_link: &Path,
    expected_mux: &Path,
) -> Result<(), AdminError> {
    verify_unix_peer_owner(link)?;
    // This probe belongs inside the caller's binding deadline too: a stale
    // pathname or a full accept queue must not hang explicit attachment.
    let owner = UnixStream::connect(expected_mux).await?;
    verify_unix_peer_owner(&owner)?;
    let admin = UnixStream::connect(admin_path).await?;
    verify_unix_peer_owner(&admin)?;
    let peer_pid = link.peer_cred()?.pid();
    if peer_pid.is_none() || peer_pid != admin.peer_cred()?.pid() {
        return Err(AdminError::Protocol("mux binding responder is not the link process".into()));
    }
    let response = call_admin_over_stream(admin, &AdminRequest::MuxBinding).await?;
    if !response.ok {
        return Err(AdminError::Protocol("running sidecar cannot prove its mux binding".into()));
    }
    let binding: MuxBinding =
        serde_json::from_value(response.result.ok_or_else(|| {
            AdminError::Protocol("running sidecar omitted its mux binding".into())
        })?)?;
    let expected = MuxBinding {
        mux_socket: expected_mux.to_path_buf(),
        link_socket: expected_link.to_path_buf(),
    };
    let same = cmux_blocking::spawn_blocking(move || binding.same_destination(&expected))
        .await
        .map_err(std::io::Error::other)??;
    if !same {
        return Err(AdminError::Protocol(
            "running sidecar serves a different mux destination".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
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
            let auth = AuthDatabase::load_or_create(directory.path().join("auth"), "binding", true)
                .unwrap();
            let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
            let admin = directory.path().join("admin.sock");
            let server = if bound {
                serve_admin_with_mux_binding(
                    daemon,
                    &admin,
                    vec![],
                    None,
                    None,
                    Some(binding.clone()),
                )
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
            verify_mux_binding(&stream, &fixture.admin, &other_path, &fixture.binding.mux_socket)
                .await;
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
        let replacement =
            std::os::unix::net::UnixListener::bind(&fixture.binding.link_socket).unwrap();
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
            verify_mux_binding(&stream, &fixture.admin, &child_path, &fixture.binding.mux_socket)
                .await;
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
}
