use std::ffi::OsString;
use std::io::{self, BufReader, Read, Write};
use std::net::Shutdown;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::server::PROTOCOL_VERSION;
use serde_json::Value;

const LOCAL_PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const STREAM_IO_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) trait ConnectionControl: Send + Sync {
    fn close(&self);
}

pub(super) struct DuplexConnection {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub control: Arc<dyn ConnectionControl>,
}

pub(super) trait CloudConnector: Send + Sync {
    fn connect(&self) -> io::Result<DuplexConnection>;
}

pub(super) trait LocalSessionConnector: Send + Sync {
    fn verify_protocol(&self) -> anyhow::Result<()>;
    fn open(&self) -> io::Result<DuplexConnection>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SshOptions {
    pub host: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<PathBuf>,
}

pub(super) struct SshCloudConnector {
    options: SshOptions,
}

impl SshCloudConnector {
    pub(super) fn new(options: SshOptions) -> anyhow::Result<Self> {
        validate_ssh_component("host", &options.host)?;
        if let Some(user) = &options.user {
            validate_ssh_component("user", user)?;
        }
        if options.port == Some(0) {
            anyhow::bail!("machine-agent SSH port cannot be zero");
        }
        Ok(Self { options })
    }

    fn command_args(&self) -> Vec<OsString> {
        let mut args = vec![
            OsString::from("-T"),
            OsString::from("-o"),
            OsString::from("BatchMode=yes"),
            OsString::from("-o"),
            OsString::from("RequestTTY=no"),
            OsString::from("-o"),
            OsString::from("RemoteCommand=none"),
            OsString::from("-o"),
            OsString::from("ClearAllForwardings=yes"),
            OsString::from("-o"),
            OsString::from("ForwardAgent=no"),
            OsString::from("-o"),
            OsString::from("ServerAliveInterval=15"),
            OsString::from("-o"),
            OsString::from("ServerAliveCountMax=3"),
        ];
        if let Some(port) = self.options.port {
            args.push(OsString::from("-p"));
            args.push(OsString::from(port.to_string()));
        }
        if let Some(identity) = &self.options.identity_file {
            args.push(OsString::from("-i"));
            args.push(identity.as_os_str().to_owned());
            args.push(OsString::from("-o"));
            args.push(OsString::from("IdentitiesOnly=yes"));
        }
        let destination = self.options.user.as_ref().map_or_else(
            || self.options.host.clone(),
            |user| format!("{user}@{}", self.options.host),
        );
        args.push(OsString::from(destination));
        // This is the complete and immutable server exec contract. User input
        // never contributes a remote command token.
        args.extend(["cmux", "machine", "register"].map(OsString::from));
        args
    }
}

impl CloudConnector for SshCloudConnector {
    fn connect(&self) -> io::Result<DuplexConnection> {
        let mut child = Command::new("ssh")
            .args(self.command_args())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let writer =
            child.stdin.take().ok_or_else(|| io::Error::other("OpenSSH did not expose stdin"))?;
        let reader =
            child.stdout.take().ok_or_else(|| io::Error::other("OpenSSH did not expose stdout"))?;
        let control: Arc<dyn ConnectionControl> =
            Arc::new(ChildConnectionControl { child: Mutex::new(Some(child)) });
        Ok(DuplexConnection { reader: Box::new(reader), writer: Box::new(writer), control })
    }
}

fn validate_ssh_component(label: &str, value: &str) -> anyhow::Result<()> {
    if value.is_empty()
        || value.starts_with('-')
        || value.chars().any(|character| character.is_control() || character.is_whitespace())
    {
        anyhow::bail!("invalid machine-agent SSH {label}");
    }
    Ok(())
}

struct ChildConnectionControl {
    child: Mutex<Option<Child>>,
}

impl ConnectionControl for ChildConnectionControl {
    fn close(&self) {
        let Ok(mut child) = self.child.lock() else { return };
        if let Some(mut child) = child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for ChildConnectionControl {
    fn drop(&mut self) {
        self.close();
    }
}

pub(super) struct SocketSessionConnector {
    socket: PathBuf,
}

impl SocketSessionConnector {
    pub(super) fn new(socket: PathBuf) -> Self {
        Self { socket }
    }
}

impl LocalSessionConnector for SocketSessionConnector {
    fn verify_protocol(&self) -> anyhow::Result<()> {
        let mut stream = transport::connect(&self.socket).map_err(|error| {
            anyhow::anyhow!(
                "cannot connect machine agent to cmux session socket {}: {error}",
                self.socket.display()
            )
        })?;
        stream.set_read_timeout(Some(LOCAL_PROBE_TIMEOUT))?;
        stream.set_write_timeout(Some(LOCAL_PROBE_TIMEOUT))?;
        stream.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n")?;
        stream.flush()?;
        let mut reader = BufReader::new(stream);
        let response = read_bounded_json_line(&mut reader, 64 * 1024)?;
        let value: Value = serde_json::from_slice(&response)?;
        if value.get("ok").and_then(Value::as_bool) != Some(true) {
            anyhow::bail!("selected cmux session rejected the protocol probe");
        }
        let protocol = value
            .pointer("/data/protocol")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow::anyhow!("selected cmux session omitted its protocol version"))?;
        if protocol != u64::from(PROTOCOL_VERSION) {
            anyhow::bail!(
                "selected cmux session speaks protocol {protocol}, expected {PROTOCOL_VERSION}"
            );
        }
        Ok(())
    }

    fn open(&self) -> io::Result<DuplexConnection> {
        let writer = transport::connect(&self.socket)?;
        writer.set_write_timeout(Some(STREAM_IO_TIMEOUT))?;
        let reader = writer.try_clone_box()?;
        reader.set_read_timeout(None)?;
        let control_stream = writer.try_clone_box()?;
        let control: Arc<dyn ConnectionControl> =
            Arc::new(StreamConnectionControl { stream: Mutex::new(Some(control_stream)) });
        Ok(DuplexConnection { reader: Box::new(reader), writer: Box::new(writer), control })
    }
}

struct StreamConnectionControl {
    stream: Mutex<Option<Box<dyn transport::Stream>>>,
}

impl ConnectionControl for StreamConnectionControl {
    fn close(&self) {
        let Ok(mut stream) = self.stream.lock() else { return };
        if let Some(stream) = stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }
}

impl Drop for StreamConnectionControl {
    fn drop(&mut self) {
        self.close();
    }
}

fn read_bounded_json_line<R: io::BufRead>(reader: &mut R, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "cmux session disconnected"));
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if bytes.len().saturating_add(newline) > limit {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "cmux response is too large",
                ));
            }
            bytes.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            return Ok(bytes);
        }
        if bytes.len().saturating_add(available.len()) > limit {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "cmux response is too large"));
        }
        let consumed = available.len();
        bytes.extend_from_slice(available);
        reader.consume(consumed);
    }
}

#[cfg(test)]
pub(super) fn duplex_from_unix_stream(
    stream: std::os::unix::net::UnixStream,
) -> io::Result<DuplexConnection> {
    let reader = stream.try_clone()?;
    let control_stream = stream.try_clone()?;
    let control: Arc<dyn ConnectionControl> =
        Arc::new(TestStreamControl { stream: Mutex::new(Some(control_stream)) });
    Ok(DuplexConnection { reader: Box::new(reader), writer: Box::new(stream), control })
}

#[cfg(test)]
struct TestStreamControl {
    stream: Mutex<Option<std::os::unix::net::UnixStream>>,
}

#[cfg(test)]
impl ConnectionControl for TestStreamControl {
    fn close(&self) {
        let Ok(mut stream) = self.stream.lock() else { return };
        if let Some(stream) = stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::path::Path;
    use std::thread;

    use super::*;

    #[test]
    fn ssh_exec_command_is_exact_and_user_input_only_selects_destination() {
        let connector = SshCloudConnector::new(SshOptions {
            host: "cmux.cloud".into(),
            user: Some("lawrence".into()),
            port: Some(2222),
            identity_file: Some(Path::new("/keys/cmux").into()),
        })
        .unwrap();
        let args = connector.command_args();
        assert_eq!(
            &args[args.len() - 3..],
            [OsStr::new("cmux"), OsStr::new("machine"), OsStr::new("register")]
        );
        assert!(args.contains(&OsString::from("lawrence@cmux.cloud")));
        assert!(args.contains(&OsString::from("IdentitiesOnly=yes")));
        assert!(args.contains(&OsString::from("BatchMode=yes")));
        assert!(args.contains(&OsString::from("RemoteCommand=none")));
        assert!(args.contains(&OsString::from("ClearAllForwardings=yes")));
        assert!(args.contains(&OsString::from("ForwardAgent=no")));
        assert!(!args.iter().any(|argument| argument.to_string_lossy().contains("sh -c")));
        assert!(
            SshCloudConnector::new(SshOptions {
                host: "-oProxyCommand=bad".into(),
                user: None,
                port: None,
                identity_file: None,
            })
            .is_err()
        );
    }

    #[test]
    fn local_connector_accepts_only_the_current_cmux_protocol() {
        fn verify(version: u32) -> anyhow::Result<()> {
            let path = std::env::temp_dir()
                .join(format!("cmux-machine-agent-probe-{}-{version}.sock", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let listener = UnixListener::bind(&path).unwrap();
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = String::new();
                BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
                assert_eq!(request, "{\"id\":1,\"cmd\":\"identify\"}\n");
                writeln!(stream, "{{\"id\":1,\"ok\":true,\"data\":{{\"protocol\":{version}}}}}")
                    .unwrap();
            });
            let result = SocketSessionConnector::new(path.clone()).verify_protocol();
            server.join().unwrap();
            std::fs::remove_file(path).unwrap();
            result
        }

        verify(PROTOCOL_VERSION).unwrap();
        assert!(verify(PROTOCOL_VERSION - 1).is_err());
    }
}
