//! A local `sftp-server` over stdio, for tests of the SFTP client, the
//! file operations and copy jobs without ssh.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::{Child, Command};

use crate::sftp::SftpClient;

const SERVER_PATHS: &[&str] = &[
    "/usr/lib/openssh/sftp-server",
    "/usr/libexec/openssh/sftp-server",
    "/usr/libexec/sftp-server",
    "/usr/lib/ssh/sftp-server",
];

/// The system's `sftp-server`, or `None` (the test then says so and
/// returns).
pub fn sftp_server() -> Option<PathBuf> {
    let found = SERVER_PATHS.iter().map(PathBuf::from).find(|path| path.is_file());
    if found.is_none() {
        eprintln!("SKIP: no sftp-server binary on this machine");
    }
    found
}

/// A running server whose login directory is `home`.
pub struct LocalServer {
    pub client: SftpClient,
    _child: Child,
}

impl LocalServer {
    pub async fn start(server: &Path, home: &Path) -> Self {
        let mut child = Command::new(server)
            .current_dir(home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .expect("sftp-server starts");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let client = SftpClient::connect(stdout, stdin).await.expect("SFTP handshake");
        Self { client, _child: child }
    }
}
