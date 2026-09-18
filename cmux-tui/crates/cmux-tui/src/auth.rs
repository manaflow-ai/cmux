//! Account sign-in for the standalone TUI (headless/Linux flows).
//!
//! Mirrors the macOS `HostBrowserSignInFlow` contract end to end:
//! `handler/native-sign-in` (mints the server-side handoff nonce) -> Stack
//! sign-in -> `handler/after-sign-in` (extracts Stack tokens, validates the
//! return-to) -> loopback callback carrying `cmux_auth_state`,
//! `stack_refresh`, and `stack_access`.
//!
//! Tokens persist to the platform state directory with 0600 permissions.
//! This module is dependency-light on purpose: the web handler performs the
//! Stack work, so the TUI only needs a loopback listener and a JSON store.

use std::fs;
use std::io::{Read as _, Write as _};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::Value;

use crate::cli::AuthAction;

const AUTH_WEB_ORIGIN: &str = "https://cmux.com";
const CALLBACK_PATH: &str = "/auth-callback";
const STATE_PARAM: &str = "cmux_auth_state";
const LOGIN_TIMEOUT: Duration = Duration::from_secs(305);

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct StoredTokens {
    refresh_token: String,
    access_token: String,
    stored_at_epoch: u64,
}

fn store_path() -> PathBuf {
    let root = std::env::var("XDG_STATE_HOME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
            PathBuf::from(home).join(".local/state")
        });
    root.join("cmux").join("auth.json")
}

fn load_tokens() -> Option<StoredTokens> {
    let raw = fs::read_to_string(store_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn save_tokens(refresh_token: &str, access_token: &str) -> Result<(), String> {
    let path = store_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("create state dir: {error}"))?;
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
    }
    let stored_at_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    let tokens = StoredTokens {
        refresh_token: refresh_token.to_string(),
        access_token: access_token.to_string(),
        stored_at_epoch,
    };
    let body =
        serde_json::to_string_pretty(&tokens).map_err(|error| format!("encode tokens: {error}"))?;
    fs::write(&path, body).map_err(|error| format!("write tokens: {error}"))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("chmod tokens: {error}"))?;
    Ok(())
}

fn percent_encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        let unreserved = byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~');
        if unreserved {
            encoded.push(*byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn random_state() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("getrandom failure");
    let mut hex = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

/// The exact URL chain the macOS app builds in
/// `AuthEnvironment.signInURL(callbackState:)`.
fn sign_in_url(callback_state: &str, listener_port: u16) -> String {
    let native_callback = format!(
        "http://127.0.0.1:{listener_port}{CALLBACK_PATH}?{STATE_PARAM}={callback_state}"
    );
    let after_sign_in = format!(
        "{AUTH_WEB_ORIGIN}/handler/after-sign-in?native_app_return_to={}",
        percent_encode_component(&native_callback)
    );
    format!(
        "{AUTH_WEB_ORIGIN}/handler/native-sign-in?after_auth_return_to={}",
        percent_encode_component(&after_sign_in)
    )
}

fn try_open_browser(url: &str) -> bool {
    let program: &str = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    Command::new(program).arg(url).spawn().is_ok()
}

fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((name, value)) => (name.to_string(), decode_component(value)),
            None => (decode_component(pair), String::new()),
        })
        .collect()
}

fn decode_component(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' if index + 2 < bytes.len() => {
                let hex = &value[index + 1..index + 3];
                match u8::from_str_radix(hex, 16) {
                    Ok(byte) => {
                        decoded.push(byte);
                        index += 3;
                    }
                    Err(_) => {
                        decoded.push(bytes[index]);
                        index += 1;
                    }
                }
            }
            b'+' => {
                decoded.push(b' ');
                index += 1;
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn read_request(stream: &mut TcpStream) -> Option<String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                buffer.extend_from_slice(&chunk[..read]);
                if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
                if buffer.len() > 64 * 1024 {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let head = String::from_utf8_lossy(&buffer);
    head.lines().next().map(str::to_string)
}

fn respond_success(stream: &mut TcpStream) {
    let body = "<!doctype html><title>cmux</title><p>Signed in. You can close this window.</p>";
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

/// Decode the Stack access JWT payload and return (sub, exp_epoch).
fn decode_access_token(access_token: &str) -> Option<(String, Option<u64>)> {
    let mut parts = access_token.split('.');
    let _header = parts.next()?;
    let payload = parts.next()?;
    let decoded = BASE64URL.decode(payload.trim_end_matches('=').as_bytes()).ok()?;
    let value: Value = serde_json::from_slice(&decoded).ok()?;
    let sub = value.get("sub").and_then(Value::as_str)?.to_string();
    let exp = value.get("exp").and_then(Value::as_u64);
    Some((sub, exp))
}

fn print_status() -> i32 {
    match load_tokens() {
        None => {
            println!("Not signed in.");
            println!("Run: cmux auth login");
            0
        }
        Some(tokens) => {
            println!("Signed in.");
            if let Some((sub, exp)) = decode_access_token(&tokens.access_token) {
                println!("  user_id:  {sub}");
                if let Some(exp) = exp {
                    let now = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|value| value.as_secs())
                        .unwrap_or_default();
                    if exp <= now {
                        println!("  note:     access token expired; refresh lands in a follow-up");
                    }
                }
            }
            0
        }
    }
}

fn run_login() -> i32 {
    if load_tokens().is_some() {
        println!("Already signed in. Use `cmux auth logout` to sign out first.");
        return 0;
    }
    let listener = match TcpListener::bind(("127.0.0.1", 0)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("cmux: bind loopback listener: {error}");
            return 1;
        }
    };
    let port = match listener.local_addr() {
        Ok(address) => address.port(),
        Err(error) => {
            eprintln!("cmux: read listener port: {error}");
            return 1;
        }
    };
    let state = random_state();
    let url = sign_in_url(&state, port);
    println!("Opening sign-in on the cmux web app.");
    println!("Sign-in URL: {url}");
    let opened = try_open_browser(&url);
    if !opened {
        println!("Open this URL to sign in:");
        println!("{url}");
    }
    println!("Waiting for the sign-in callback on 127.0.0.1:{port} (5m timeout)...");
    let deadline = Instant::now() + LOGIN_TIMEOUT;
    listener
        .set_nonblocking(true)
        .expect("listener nonblocking mode");
    while Instant::now() < deadline {
        let (mut stream, _) = match listener.accept() {
            Ok(connection) => connection,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(error) => {
                eprintln!("cmux: accept: {error}");
                return 1;
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(15)))
            .expect("read timeout");
        let request_line = match read_request(&mut stream) {
            Some(line) => line,
            None => continue,
        };
        let target = request_line.split_whitespace().nth(1).unwrap_or("").to_string();
        if !target.starts_with(CALLBACK_PATH) {
            respond_success(&mut stream);
            continue;
        }
        let query = target.split_once('?').map(|(_, value)| value).unwrap_or("");
        let params = parse_query(query);
        let state_ok = params
            .iter()
            .any(|(name, value)| name == STATE_PARAM && *value == state);
        if !state_ok {
            let body = "<!doctype html><title>cmux</title><p>Sign-in state mismatch. Restart `cmux auth login`.</p>";
            let response = format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(response.as_bytes());
            continue;
        }
        let refresh = params
            .iter()
            .find(|(name, _)| name == "stack_refresh")
            .map(|(_, value)| value.clone());
        let access = params
            .iter()
            .find(|(name, _)| name == "stack_access")
            .map(|(_, value)| value.clone());
        // `stack_access` is the Stack cookie payload: ["<refresh>", "<access>"].
        let access_token = access.as_deref().and_then(|value| {
            serde_json::from_str::<Vec<String>>(value)
                .ok()
                .and_then(|parts| parts.get(1).cloned())
        });
        let (refresh_token, access_token) = match (refresh, access_token) {
            (Some(refresh), Some(access)) => (refresh, access),
            _ => {
                let body = "<!doctype html><title>cmux</title><p>Sign-in callback missing tokens.</p>";
                let response = format!(
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
                continue;
            }
        };
        if let Err(error) = save_tokens(&refresh_token, &access_token) {
            eprintln!("cmux: {error}");
            return 1;
        }
        respond_success(&mut stream);
        println!("Signed in.");
        return 0;
    }
    println!("Timed out waiting for sign-in. Run `cmux auth status` once you've finished in the browser.");
    1
}

fn run_logout() -> i32 {
    if load_tokens().is_none() {
        println!("Already signed out.");
        return 0;
    }
    match fs::remove_file(store_path()) {
        Ok(()) => {
            println!("Signed out.");
            0
        }
        Err(error) => {
            eprintln!("cmux: clear tokens: {error}");
            1
        }
    }
}

pub(crate) fn run(action: AuthAction) -> i32 {
    match action {
        AuthAction::Status => print_status(),
        AuthAction::Login => run_login(),
        AuthAction::Logout => run_logout(),
    }
}
