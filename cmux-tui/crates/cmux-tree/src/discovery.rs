use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::path::Path;
use std::process::Command;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use crate::config::{default_codex_control_socket, expand_user_path};

const SCAN_INTERVAL: Duration = Duration::from_secs(10);
const PROBE_TIMEOUT: Duration = Duration::from_millis(300);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveredTransport {
    WebSocket { port: u16 },
    UnixSocket,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredServer {
    pub url: String,
    pub transport: DiscoveredTransport,
}

impl DiscoveredServer {
    pub fn machine_id(&self) -> String {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for byte in endpoint_key(&self.url).bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("discovered-{hash:016x}")
    }
}

pub struct LocalDiscovery {
    receiver: Option<Receiver<Vec<DiscoveredServer>>>,
    next_scan_at: Instant,
    enabled: bool,
}

impl LocalDiscovery {
    pub fn new(enabled: bool) -> Self {
        Self { receiver: None, next_scan_at: Instant::now(), enabled }
    }

    pub fn request_scan(&mut self) {
        if self.enabled {
            self.next_scan_at = Instant::now();
        }
    }

    pub fn poll(&mut self) -> Option<Vec<DiscoveredServer>> {
        if self.enabled && self.receiver.is_none() && Instant::now() >= self.next_scan_at {
            let (sender, receiver) = mpsc::channel();
            self.next_scan_at = Instant::now() + SCAN_INTERVAL;
            if thread::Builder::new()
                .name("cmux-tree-discovery".into())
                .spawn(move || {
                    let _ = sender.send(discover_local_servers());
                })
                .is_ok()
            {
                self.receiver = Some(receiver);
            }
        }

        let result = match self.receiver.as_ref()?.try_recv() {
            Ok(servers) => Some(servers),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(Vec::new()),
        };
        if result.is_some() {
            self.receiver = None;
            self.next_scan_at = Instant::now() + SCAN_INTERVAL;
        }
        result
    }
}

#[derive(Debug, Clone)]
struct ProcessInfo {
    pid: u32,
    command: String,
}

#[derive(Debug, Clone)]
struct Candidate {
    url: String,
    transport: DiscoveredTransport,
}

fn discover_local_servers() -> Vec<DiscoveredServer> {
    let processes = read_processes();
    let process_by_pid = processes
        .iter()
        .map(|process| (process.pid, process.command.as_str()))
        .collect::<HashMap<_, _>>();
    let mut candidates = Vec::new();

    for process in &processes {
        if !is_codex_app_server(&process.command) {
            continue;
        }
        if let Some(candidate) = candidate_from_listen_argument(&process.command) {
            candidates.push(candidate);
        }
    }

    if let Some(output) = run_lsof_tcp() {
        candidates.extend(candidates_from_lsof(&output, &process_by_pid));
    }

    let mut unique = BTreeMap::new();
    for candidate in candidates {
        let available = match &candidate.transport {
            DiscoveredTransport::WebSocket { .. } => probe_health(&candidate.url),
            DiscoveredTransport::UnixSocket => unix_socket_exists(&candidate.url),
        };
        if !available {
            continue;
        }
        let key = endpoint_key(&candidate.url);
        unique.entry(key).or_insert(candidate);
    }

    unique
        .into_values()
        .map(|candidate| DiscoveredServer { url: candidate.url, transport: candidate.transport })
        .collect()
}

fn read_processes() -> Vec<ProcessInfo> {
    let Ok(output) = Command::new("ps").args(["-axo", "pid=,command="]).output() else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    parse_processes(&String::from_utf8_lossy(&output.stdout))
}

fn parse_processes(output: &str) -> Vec<ProcessInfo> {
    output
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let split_at = line.find(char::is_whitespace)?;
            let pid = line[..split_at].parse().ok()?;
            let command = line[split_at..].trim().to_string();
            (!command.is_empty()).then_some(ProcessInfo { pid, command })
        })
        .collect()
}

fn run_lsof_tcp() -> Option<String> {
    let arguments = ["-nP", "-Fpcn", "-iTCP", "-sTCP:LISTEN"];
    let output = Command::new("/usr/sbin/lsof")
        .args(arguments)
        .output()
        .or_else(|_| Command::new("lsof").args(arguments).output())
        .ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn candidates_from_lsof(output: &str, process_by_pid: &HashMap<u32, &str>) -> Vec<Candidate> {
    let mut current_pid = None;
    let mut candidates = Vec::new();
    for line in output.lines() {
        let Some((field, value)) = line.split_at_checked(1) else { continue };
        match field {
            "p" => current_pid = value.parse().ok(),
            "n" => {
                let Some(command) = current_pid.and_then(|pid| process_by_pid.get(&pid).copied())
                else {
                    continue;
                };
                if !is_codex_app_server(command) || !auth_is_discoverable(command) {
                    continue;
                }
                let Some((url, port)) = websocket_url_from_listener(value) else {
                    continue;
                };
                candidates
                    .push(Candidate { url, transport: DiscoveredTransport::WebSocket { port } });
            }
            _ => {}
        }
    }
    candidates
}

fn is_codex_app_server(command: &str) -> bool {
    let command = command.to_ascii_lowercase();
    command.contains("codex") && command.split_whitespace().any(|part| part == "app-server")
}

fn candidate_from_listen_argument(command: &str) -> Option<Candidate> {
    if !auth_is_discoverable(command) {
        return None;
    }
    let listen = argument_value(command, "--listen")?;
    if let Some(address) = listen.strip_prefix("ws://") {
        let (url, port) = normalize_websocket_listener(address)?;
        return Some(Candidate { url, transport: DiscoveredTransport::WebSocket { port } });
    }
    let path = listen.strip_prefix("unix://")?;
    let path = if path.is_empty() {
        default_codex_control_socket()
    } else {
        expand_user_path(Path::new(path))
    };
    Some(Candidate {
        url: format!("unix://{}", path.display()),
        transport: DiscoveredTransport::UnixSocket,
    })
}

fn auth_is_discoverable(command: &str) -> bool {
    // Never harvest credentials named by another process. Authenticated endpoints stay manual.
    matches!(argument_value(command, "--ws-auth").as_deref(), None | Some("none"))
}

fn argument_value(command: &str, name: &str) -> Option<String> {
    let parts = command.split_whitespace().collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        if *part == name {
            return parts.get(index + 1).map(|value| trim_argument(value));
        }
        if let Some(value) = part.strip_prefix(name).and_then(|value| value.strip_prefix('=')) {
            return Some(trim_argument(value));
        }
    }
    None
}

fn trim_argument(value: &str) -> String {
    value.trim_matches(['\'', '"']).to_string()
}

fn websocket_url_from_listener(listener: &str) -> Option<(String, u16)> {
    normalize_websocket_listener(listener.trim_end_matches(" (LISTEN)"))
}

fn normalize_websocket_listener(listener: &str) -> Option<(String, u16)> {
    let (host, port) = split_host_port(listener)?;
    if port == 0 {
        return None;
    }
    let host = match host {
        "*" | "0.0.0.0" => "127.0.0.1".to_string(),
        "::" => "::1".to_string(),
        value => value.to_string(),
    };
    let formatted_host = if host.contains(':') { format!("[{host}]") } else { host };
    Some((format!("ws://{formatted_host}:{port}"), port))
}

fn split_host_port(value: &str) -> Option<(&str, u16)> {
    if let Some(value) = value.strip_prefix('[') {
        let close = value.find(']')?;
        let host = &value[..close];
        let port = value[close + 1..].strip_prefix(':')?.parse().ok()?;
        return Some((host, port));
    }
    let (host, port) = value.rsplit_once(':')?;
    Some((host, port.parse().ok()?))
}

fn probe_health(url: &str) -> bool {
    let Some((host, port, _)) = parse_websocket_url(url) else { return false };
    let Ok(ip) = host.parse::<IpAddr>() else { return false };
    let mut stream = match TcpStream::connect_timeout(&SocketAddr::new(ip, port), PROBE_TIMEOUT) {
        Ok(stream) => stream,
        Err(_) => return false,
    };
    let _ = stream.set_read_timeout(Some(PROBE_TIMEOUT));
    let _ = stream.set_write_timeout(Some(PROBE_TIMEOUT));
    let host_header =
        if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
    if write!(stream, "GET /healthz HTTP/1.1\r\nHost: {host_header}\r\nConnection: close\r\n\r\n")
        .is_err()
    {
        return false;
    }
    let mut response = [0_u8; 512];
    let Ok(length) = stream.read(&mut response) else { return false };
    let response = String::from_utf8_lossy(&response[..length]);
    response.starts_with("HTTP/1.1 200") || response.starts_with("HTTP/1.0 200")
}

fn unix_socket_exists(url: &str) -> bool {
    let Some(path) = url.strip_prefix("unix://") else { return false };
    let path = expand_user_path(Path::new(path));
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;

        fs::metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

pub fn endpoint_key(url: &str) -> String {
    let url = url.trim();
    if let Some(path) = url.strip_prefix("unix://") {
        let path = if path.is_empty() {
            default_codex_control_socket()
        } else {
            expand_user_path(Path::new(path))
        };
        return format!("unix://{}", path.display());
    }
    let url = url.trim_end_matches('/');
    let Some((host, port, path)) = parse_websocket_url(url) else {
        return url.to_ascii_lowercase();
    };
    let scheme = if url.to_ascii_lowercase().starts_with("wss://") { "wss" } else { "ws" };
    let host = host.to_ascii_lowercase();
    let host = if ["localhost", "127.0.0.1", "::1", "0.0.0.0", "::"].contains(&host.as_str()) {
        "loopback".to_string()
    } else {
        host
    };
    if path.is_empty() {
        format!("{scheme}://{host}:{port}")
    } else {
        format!("{scheme}://{host}:{port}/{path}")
    }
}

fn parse_websocket_url(url: &str) -> Option<(&str, u16, &str)> {
    let value = url.strip_prefix("ws://").or_else(|| url.strip_prefix("wss://"))?;
    let (authority, path) = value.split_once('/').unwrap_or((value, ""));
    let (host, port) = split_host_port(authority)?;
    Some((host, port, path))
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;

    use super::*;

    #[test]
    fn parses_processes_and_codex_listeners() {
        let processes = parse_processes(
            "  10 /opt/codex app-server --listen ws://127.0.0.1:4500\n\
              11 other-server --listen 127.0.0.1:4600\n",
        );
        let process_by_pid =
            processes.iter().map(|process| (process.pid, process.command.as_str())).collect();
        let candidates = candidates_from_lsof(
            "p10\nccodex\nf8\nn127.0.0.1:4500\n\
             p11\ncother\nf9\nn127.0.0.1:4600\n",
            &process_by_pid,
        );

        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].url, "ws://127.0.0.1:4500");
    }

    #[test]
    fn extracts_websocket_and_unix_listeners() {
        let websocket =
            candidate_from_listen_argument("codex app-server --listen ws://0.0.0.0:4500").unwrap();
        assert_eq!(websocket.url, "ws://127.0.0.1:4500");

        let unix =
            candidate_from_listen_argument("codex app-server --listen unix:///tmp/codex.sock")
                .unwrap();
        assert_eq!(unix.url, "unix:///tmp/codex.sock");
        assert_eq!(unix.transport, DiscoveredTransport::UnixSocket);
    }

    #[test]
    fn skips_authenticated_listeners() {
        assert!(
            candidate_from_listen_argument(
                "codex app-server --listen ws://127.0.0.1:4500 \
                 --ws-auth capability-token --ws-token-file ~/.codex/tree.token"
            )
            .is_none()
        );
        assert!(
            candidate_from_listen_argument(
                "codex app-server --listen ws://127.0.0.1:4500 \
                 --ws-auth signed-bearer --ws-jwt-hs256-secret secret"
            )
            .is_none()
        );
    }

    #[test]
    fn endpoint_keys_dedupe_loopback_aliases() {
        assert_eq!(endpoint_key("ws://localhost:4500/"), endpoint_key("ws://127.0.0.1:4500"));
        assert_ne!(endpoint_key("wss://localhost:4500"), endpoint_key("ws://127.0.0.1:4500"));
        assert_eq!(
            endpoint_key("unix://"),
            format!("unix://{}", default_codex_control_socket().display())
        );
    }

    #[test]
    fn health_probe_requires_a_success_response() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 512];
            let length = stream.read(&mut request).unwrap();
            assert!(
                String::from_utf8_lossy(&request[..length]).starts_with("GET /healthz HTTP/1.1")
            );
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").unwrap();
        });

        assert!(probe_health(&format!("ws://{address}")));
        server.join().unwrap();
    }

    #[test]
    fn lsof_wildcards_resolve_to_loopback() {
        assert_eq!(
            websocket_url_from_listener("*:4510"),
            Some(("ws://127.0.0.1:4510".into(), 4510))
        );
        assert_eq!(
            websocket_url_from_listener("[::]:4511"),
            Some(("ws://[::1]:4511".into(), 4511))
        );
    }

    #[test]
    fn machine_ids_are_stable_per_endpoint() {
        let server = DiscoveredServer {
            url: "ws://127.0.0.1:4500".into(),
            transport: DiscoveredTransport::WebSocket { port: 4500 },
        };
        assert_eq!(server.machine_id(), server.machine_id());
        assert!(server.machine_id().starts_with("discovered-"));
    }
}
