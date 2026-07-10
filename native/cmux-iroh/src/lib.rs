//! Blocking C FFI over iroh for cmux mobile terminal transport.
//!
//! Swift owns endpoint secret-key custody. Callers may generate a 32-byte iroh
//! secret key through this library, store it in Keychain, and pass the same key
//! back to `cmux_iroh_endpoint_bind` on subsequent binds.

use std::{
    ffi::{CStr, CString, c_char},
    net::SocketAddr,
    os::raw::c_int,
    ptr,
    str::FromStr,
    sync::OnceLock,
    time::Duration,
};

use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr,
    endpoint::{
        ConnectError, ConnectWithOptsError, ConnectingError, Connection, ConnectionError,
        ReadError, RecvStream, SendStream, WriteError, presets,
    },
};
use tokio::{runtime::Runtime, sync::Mutex};

const ALPN: &[u8] = b"dev.cmux.mobile.terminal/0";
const SECRET_KEY_LEN: usize = 32;

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ErrorKind {
    None = 0,
    InvalidArgument = 1,
    TimedOut = 2,
    ConnectionRefused = 3,
    HostUnreachable = 4,
    PermissionDenied = 5,
    DnsFailed = 6,
    SecureChannelFailed = 7,
    EndpointClosed = 8,
    NotConnected = 9,
    Io = 10,
    Internal = 11,
}

#[repr(C)]
pub struct CmuxIrohError {
    kind: u32,
    message: *mut c_char,
    message_cap: usize,
}

pub struct CmuxIrohEndpoint {
    endpoint: Endpoint,
}

pub struct CmuxIrohConnection {
    connection: Connection,
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime should build")
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_secret_key_generate(
    out_secret_key: *mut u8,
    out_secret_key_len: usize,
    error: *mut CmuxIrohError,
) -> c_int {
    clear_error(error);
    if out_secret_key.is_null() || out_secret_key_len != SECRET_KEY_LEN {
        set_error(
            error,
            ErrorKind::InvalidArgument,
            "secret key output buffer must be exactly 32 bytes",
        );
        return -1;
    }

    let key = SecretKey::generate().to_bytes();
    unsafe {
        ptr::copy_nonoverlapping(key.as_ptr(), out_secret_key, SECRET_KEY_LEN);
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_bind(
    secret_key: *const u8,
    secret_key_len: usize,
    enable_relay: bool,
    accept_connections: bool,
    error: *mut CmuxIrohError,
) -> *mut CmuxIrohEndpoint {
    clear_error(error);
    let Some(secret_key) = read_secret_key(secret_key, secret_key_len, error) else {
        return ptr::null_mut();
    };

    let result = runtime().block_on(async move {
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            // Force the stable public n0 relay map when relays are enabled.
            .relay_mode(if enable_relay {
                RelayMode::Default
            } else {
                RelayMode::Disabled
            });
        if accept_connections {
            builder = builder.alpns(vec![ALPN.to_vec()]);
        }
        builder.bind().await
    });

    match result {
        Ok(endpoint) => Box::into_raw(Box::new(CmuxIrohEndpoint { endpoint })),
        Err(error_value) => {
            set_error(
                error,
                classify_message(&format!("{error_value:#}")),
                format!("bind failed: {error_value:#}"),
            );
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_id(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        return ptr::null_mut();
    };
    string_to_c(endpoint.endpoint.id().to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_route_json(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        return ptr::null_mut();
    };
    let addr = endpoint.endpoint.addr();
    let direct_addrs = addr
        .ip_addrs()
        .map(|addr| addr.to_string())
        .collect::<Vec<_>>();
    let relay_url = addr.relay_urls().next().map(|url| url.to_string());
    let route = serde_json::json!({
        "id": "iroh",
        "kind": "iroh",
        "endpoint": {
            "type": "peer",
            "id": endpoint.endpoint.id().to_string(),
            "direct_addrs": direct_addrs,
            "relay_url": relay_url,
        },
        "priority": 5,
    });
    string_to_c(route.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_online(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    error: *mut CmuxIrohError,
) -> c_int {
    clear_error(error);
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(error, ErrorKind::InvalidArgument, "null endpoint");
        return -1;
    };

    let online = runtime().block_on(async {
        tokio::time::timeout(
            Duration::from_millis(timeout_ms.max(1)),
            endpoint.endpoint.online(),
        )
        .await
    });
    match online {
        Ok(()) => 0,
        Err(_) => {
            set_error(
                error,
                ErrorKind::TimedOut,
                "timed out waiting for relay connection",
            );
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_accept(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    error: *mut CmuxIrohError,
) -> *mut CmuxIrohConnection {
    clear_error(error);
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(error, ErrorKind::InvalidArgument, "null endpoint");
        return ptr::null_mut();
    };

    let result = runtime().block_on(async {
        tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), async {
            let incoming = endpoint.endpoint.accept().await.ok_or_else(|| {
                FfiFailure::new(ErrorKind::EndpointClosed, "endpoint closed".to_string())
            })?;
            let connection = incoming.await.map_err(|error_value| {
                FfiFailure::new(
                    classify_message(&format!("{error_value:#}")),
                    format!("incoming connection failed: {error_value:#}"),
                )
            })?;
            let (send, recv) = connection.accept_bi().await.map_err(|error_value| {
                FfiFailure::new(
                    classify_message(&format!("{error_value:#}")),
                    format!("accept_bi failed: {error_value:#}"),
                )
            })?;
            Ok::<_, FfiFailure>((connection, send, recv))
        })
        .await
        .map_err(|_| FfiFailure::new(ErrorKind::TimedOut, "accept timed out".to_string()))?
    });
    finish_connection(result, error)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_connect(
    endpoint: *mut CmuxIrohEndpoint,
    endpoint_id: *const c_char,
    relay_url: *const c_char,
    direct_addrs: *const *const c_char,
    direct_addr_count: usize,
    timeout_ms: u64,
    error: *mut CmuxIrohError,
) -> *mut CmuxIrohConnection {
    clear_error(error);
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(error, ErrorKind::InvalidArgument, "null endpoint");
        return ptr::null_mut();
    };
    let Some(id_str) = optional_c_to_str(endpoint_id) else {
        set_error(
            error,
            ErrorKind::InvalidArgument,
            "null or invalid endpoint id",
        );
        return ptr::null_mut();
    };
    let id = match EndpointId::from_str(id_str) {
        Ok(id) => id,
        Err(error_value) => {
            set_error(
                error,
                ErrorKind::InvalidArgument,
                format!("invalid endpoint id: {error_value:#}"),
            );
            return ptr::null_mut();
        }
    };

    let Some(addrs) = parse_transport_addrs(relay_url, direct_addrs, direct_addr_count, error)
    else {
        return ptr::null_mut();
    };
    let addr = if addrs.is_empty() {
        EndpointAddr::from(id)
    } else {
        EndpointAddr::from_parts(id, addrs)
    };

    let result = runtime().block_on(async {
        tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), async {
            let connection = endpoint
                .endpoint
                .connect(addr, ALPN)
                .await
                .map_err(connect_error_to_failure)?;
            let (send, recv) = connection.open_bi().await.map_err(|error_value| {
                FfiFailure::new(
                    classify_message(&format!("{error_value:#}")),
                    format!("open_bi failed: {error_value:#}"),
                )
            })?;
            Ok::<_, FfiFailure>((connection, send, recv))
        })
        .await
        .map_err(|_| FfiFailure::new(ErrorKind::TimedOut, "connect timed out".to_string()))?
    });
    finish_connection(result, error)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_recv(
    connection: *mut CmuxIrohConnection,
    buf: *mut u8,
    cap: usize,
    error: *mut CmuxIrohError,
) -> isize {
    clear_error(error);
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        set_error(error, ErrorKind::InvalidArgument, "null connection");
        return -1;
    };
    if buf.is_null() || cap == 0 {
        set_error(
            error,
            ErrorKind::InvalidArgument,
            "null or empty receive buffer",
        );
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts_mut(buf, cap) };
    let result = runtime().block_on(async {
        let mut recv = connection.recv.lock().await;
        recv.read(slice).await
    });
    match result {
        Ok(Some(read)) => read as isize,
        Ok(None) => 0,
        Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(close)))
            if u64::from(close.error_code) == 0 =>
        {
            0
        }
        Err(error_value) => {
            let kind = read_error_kind(&error_value);
            set_error(error, kind, format!("recv failed: {error_value:#}"));
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_send(
    connection: *mut CmuxIrohConnection,
    bytes: *const u8,
    len: usize,
    error: *mut CmuxIrohError,
) -> c_int {
    clear_error(error);
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        set_error(error, ErrorKind::InvalidArgument, "null connection");
        return -1;
    };
    if len == 0 {
        return 0;
    }
    if bytes.is_null() {
        set_error(error, ErrorKind::InvalidArgument, "null send buffer");
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    let result = runtime().block_on(async {
        let mut send = connection.send.lock().await;
        send.write_all(slice).await
    });
    match result {
        Ok(()) => 0,
        Err(error_value) => {
            let kind = write_error_kind(&error_value);
            set_error(error, kind, format!("send failed: {error_value:#}"));
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_close(connection: *mut CmuxIrohConnection) {
    if connection.is_null() {
        return;
    }
    let connection = unsafe { Box::from_raw(connection) };
    runtime().block_on(async {
        let mut send = connection.send.lock().await;
        if send.finish().is_ok() {
            let _ = tokio::time::timeout(Duration::from_secs(5), send.stopped()).await;
        }
        drop(send);
        connection.connection.close(0u32.into(), b"close");
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_close(endpoint: *mut CmuxIrohEndpoint) {
    if endpoint.is_null() {
        return;
    }
    let endpoint = unsafe { Box::from_raw(endpoint) };
    runtime().block_on(async {
        endpoint.endpoint.close().await;
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_string_free(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    drop(unsafe { CString::from_raw(string) });
}

#[derive(Debug)]
struct FfiFailure {
    kind: ErrorKind,
    message: String,
}

impl FfiFailure {
    fn new(kind: ErrorKind, message: String) -> Self {
        Self { kind, message }
    }
}

fn read_secret_key(
    secret_key: *const u8,
    secret_key_len: usize,
    error: *mut CmuxIrohError,
) -> Option<SecretKey> {
    if secret_key.is_null() || secret_key_len != SECRET_KEY_LEN {
        set_error(
            error,
            ErrorKind::InvalidArgument,
            "secret key input must be exactly 32 bytes",
        );
        return None;
    }

    let mut bytes = [0u8; SECRET_KEY_LEN];
    unsafe {
        bytes.copy_from_slice(std::slice::from_raw_parts(secret_key, SECRET_KEY_LEN));
    }
    Some(SecretKey::from_bytes(&bytes))
}

fn parse_transport_addrs(
    relay_url: *const c_char,
    direct_addrs: *const *const c_char,
    direct_addr_count: usize,
    error: *mut CmuxIrohError,
) -> Option<Vec<TransportAddr>> {
    if direct_addrs.is_null() && direct_addr_count > 0 {
        set_error(
            error,
            ErrorKind::InvalidArgument,
            "direct address array is null with non-zero count",
        );
        return None;
    }

    let mut addrs = Vec::new();
    if !direct_addrs.is_null() {
        for index in 0..direct_addr_count {
            let raw = unsafe { *direct_addrs.add(index) };
            let Some(addr_str) = optional_c_to_str(raw) else {
                set_error(
                    error,
                    ErrorKind::InvalidArgument,
                    format!("direct address {index} is null or invalid UTF-8"),
                );
                return None;
            };
            match SocketAddr::from_str(addr_str) {
                Ok(addr) => addrs.push(TransportAddr::Ip(addr)),
                Err(error_value) => {
                    set_error(
                        error,
                        ErrorKind::InvalidArgument,
                        format!("invalid direct addr {addr_str}: {error_value:#}"),
                    );
                    return None;
                }
            }
        }
    }

    if let Some(relay_str) = optional_c_to_str(relay_url) {
        if !relay_str.is_empty() {
            match RelayUrl::from_str(relay_str) {
                Ok(url) => addrs.push(TransportAddr::Relay(url)),
                Err(error_value) => {
                    set_error(
                        error,
                        ErrorKind::InvalidArgument,
                        format!("invalid relay url: {error_value:#}"),
                    );
                    return None;
                }
            }
        }
    }

    Some(addrs)
}

fn finish_connection(
    result: Result<(Connection, SendStream, RecvStream), FfiFailure>,
    error: *mut CmuxIrohError,
) -> *mut CmuxIrohConnection {
    match result {
        Ok((connection, send, recv)) => Box::into_raw(Box::new(CmuxIrohConnection {
            connection,
            send: Mutex::new(send),
            recv: Mutex::new(recv),
        })),
        Err(failure) => {
            set_error(error, failure.kind, failure.message);
            ptr::null_mut()
        }
    }
}

fn connect_error_to_failure(error: ConnectError) -> FfiFailure {
    let kind = connect_error_kind(&error);
    FfiFailure::new(kind, format!("connect failed: {error:#}"))
}

fn connect_error_kind(error: &ConnectError) -> ErrorKind {
    match error {
        ConnectError::Connect { source, .. } => connect_with_opts_error_kind(source),
        ConnectError::Connecting { source, .. } => connecting_error_kind(source),
        ConnectError::Connection { source, .. } => connection_error_kind(source),
        _ => classify_message(&format!("{error:#}")),
    }
}

fn connect_with_opts_error_kind(error: &ConnectWithOptsError) -> ErrorKind {
    match error {
        ConnectWithOptsError::SelfConnect { .. } => ErrorKind::InvalidArgument,
        ConnectWithOptsError::NoAddress { .. } => ErrorKind::HostUnreachable,
        ConnectWithOptsError::Noq { source, .. } => classify_message(&format!("{source:#}")),
        ConnectWithOptsError::InternalConsistencyError { .. } => ErrorKind::Internal,
        ConnectWithOptsError::LocallyRejected { .. } => ErrorKind::PermissionDenied,
        ConnectWithOptsError::EndpointClosed { .. } => ErrorKind::EndpointClosed,
        _ => classify_message(&format!("{error:#}")),
    }
}

fn connecting_error_kind(error: &ConnectingError) -> ErrorKind {
    match error {
        ConnectingError::ConnectionError { source, .. } => connection_error_kind(source),
        ConnectingError::HandshakeFailure { .. } => ErrorKind::SecureChannelFailed,
        ConnectingError::InternalConsistencyError { .. } => ErrorKind::Internal,
        ConnectingError::LocallyRejected { .. } => ErrorKind::PermissionDenied,
        _ => classify_message(&format!("{error:#}")),
    }
}

fn read_error_kind(error: &ReadError) -> ErrorKind {
    match error {
        ReadError::Reset(_) | ReadError::ZeroRttRejected => ErrorKind::ConnectionRefused,
        ReadError::ConnectionLost(source) => connection_error_kind(source),
        ReadError::ClosedStream => ErrorKind::NotConnected,
    }
}

fn write_error_kind(error: &WriteError) -> ErrorKind {
    match error {
        WriteError::Stopped(_) | WriteError::ZeroRttRejected => ErrorKind::ConnectionRefused,
        WriteError::ConnectionLost(source) => connection_error_kind(source),
        WriteError::ClosedStream => ErrorKind::NotConnected,
    }
}

fn connection_error_kind(error: &ConnectionError) -> ErrorKind {
    match error {
        ConnectionError::VersionMismatch => ErrorKind::SecureChannelFailed,
        ConnectionError::TransportError(_) => classify_message(&format!("{error:#}")),
        ConnectionError::ConnectionClosed(_) | ConnectionError::ApplicationClosed(_) => {
            ErrorKind::NotConnected
        }
        ConnectionError::Reset => ErrorKind::ConnectionRefused,
        ConnectionError::TimedOut => ErrorKind::TimedOut,
        ConnectionError::LocallyClosed => ErrorKind::NotConnected,
        ConnectionError::CidsExhausted => ErrorKind::Internal,
    }
}

fn classify_message(message: &str) -> ErrorKind {
    let lower = message.to_ascii_lowercase();
    if lower.contains("timed out") || lower.contains("timeout") {
        ErrorKind::TimedOut
    } else if lower.contains("connection refused") || lower.contains("refused") {
        ErrorKind::ConnectionRefused
    } else if lower.contains("host unreachable")
        || lower.contains("network unreachable")
        || lower.contains("no route")
    {
        ErrorKind::HostUnreachable
    } else if lower.contains("permission denied") || lower.contains("operation not permitted") {
        ErrorKind::PermissionDenied
    } else if lower.contains("dns") || lower.contains("lookup") || lower.contains("resolve") {
        ErrorKind::DnsFailed
    } else if lower.contains("handshake")
        || lower.contains("certificate")
        || lower.contains("authentication")
        || lower.contains("tls")
    {
        ErrorKind::SecureChannelFailed
    } else if lower.contains("closed") {
        ErrorKind::NotConnected
    } else {
        ErrorKind::Io
    }
}

fn clear_error(error: *mut CmuxIrohError) {
    if error.is_null() {
        return;
    }
    unsafe {
        (*error).kind = ErrorKind::None as u32;
        write_error_message((*error).message, (*error).message_cap, "");
    }
}

fn set_error(error: *mut CmuxIrohError, kind: ErrorKind, message: impl AsRef<str>) {
    if error.is_null() {
        return;
    }
    unsafe {
        (*error).kind = kind as u32;
        write_error_message((*error).message, (*error).message_cap, message.as_ref());
    }
}

unsafe fn write_error_message(message: *mut c_char, message_cap: usize, value: &str) {
    if message.is_null() || message_cap == 0 {
        return;
    }
    let bytes = value.as_bytes();
    let len = bytes.len().min(message_cap - 1);
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), message.cast::<u8>(), len);
        *message.add(len) = 0;
    }
}

fn string_to_c(string: String) -> *mut c_char {
    match CString::new(string) {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn optional_c_to_str<'a>(raw: *const c_char) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn c_api_bind_connect_echo_with_caller_owned_keys() {
        let mut server_key = [0u8; SECRET_KEY_LEN];
        let mut client_key = [0u8; SECRET_KEY_LEN];
        let mut error_message = [0i8; 512];
        let mut error = CmuxIrohError {
            kind: 0,
            message: error_message.as_mut_ptr(),
            message_cap: error_message.len(),
        };

        assert_eq!(
            cmux_iroh_secret_key_generate(server_key.as_mut_ptr(), server_key.len(), &mut error,),
            0,
            "{}",
            ffi_error_message(&error)
        );
        assert_eq!(
            cmux_iroh_secret_key_generate(client_key.as_mut_ptr(), client_key.len(), &mut error,),
            0,
            "{}",
            ffi_error_message(&error)
        );

        let server = cmux_iroh_endpoint_bind(
            server_key.as_ptr(),
            server_key.len(),
            false,
            true,
            &mut error,
        );
        assert!(!server.is_null(), "{}", ffi_error_message(&error));
        let client = cmux_iroh_endpoint_bind(
            client_key.as_ptr(),
            client_key.len(),
            false,
            false,
            &mut error,
        );
        assert!(!client.is_null(), "{}", ffi_error_message(&error));

        let route_raw = cmux_iroh_endpoint_route_json(server);
        assert!(!route_raw.is_null());
        let route_json = unsafe { CStr::from_ptr(route_raw) }
            .to_str()
            .unwrap()
            .to_string();
        cmux_iroh_string_free(route_raw);

        let route: serde_json::Value = serde_json::from_str(&route_json).unwrap();
        let endpoint = route.get("endpoint").unwrap();
        let endpoint_id = endpoint.get("id").unwrap().as_str().unwrap().to_string();
        let direct_addrs = endpoint
            .get("direct_addrs")
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|value| value.as_str().map(ToOwned::to_owned))
            .collect::<Vec<_>>();
        assert!(
            !direct_addrs.is_empty(),
            "route should include direct addrs: {route_json}"
        );

        let server_addr = server as usize;
        let accept_thread = thread::spawn(move || {
            let server = server_addr as *mut CmuxIrohEndpoint;
            let mut error_message = [0i8; 512];
            let mut error = CmuxIrohError {
                kind: 0,
                message: error_message.as_mut_ptr(),
                message_cap: error_message.len(),
            };
            let connection = cmux_iroh_endpoint_accept(server, 10_000, &mut error);
            assert!(!connection.is_null(), "{}", ffi_error_message(&error));
            connection as usize
        });

        let endpoint_id = CString::new(endpoint_id).unwrap();
        let c_addrs = direct_addrs
            .iter()
            .map(|addr| CString::new(addr.as_str()).unwrap())
            .collect::<Vec<_>>();
        let addr_ptrs = c_addrs.iter().map(|addr| addr.as_ptr()).collect::<Vec<_>>();

        let client_conn = cmux_iroh_endpoint_connect(
            client,
            endpoint_id.as_ptr(),
            ptr::null(),
            addr_ptrs.as_ptr(),
            addr_ptrs.len(),
            10_000,
            &mut error,
        );
        assert!(!client_conn.is_null(), "{}", ffi_error_message(&error));

        let ping = b"ping";
        assert_eq!(
            cmux_iroh_connection_send(client_conn, ping.as_ptr(), ping.len(), &mut error),
            0,
            "{}",
            ffi_error_message(&error)
        );
        let server_conn = accept_thread.join().unwrap() as *mut CmuxIrohConnection;
        let mut recv_buf = [0u8; 16];
        let read = cmux_iroh_connection_recv(
            server_conn,
            recv_buf.as_mut_ptr(),
            recv_buf.len(),
            &mut error,
        );
        assert_eq!(read, ping.len() as isize, "{}", ffi_error_message(&error));
        assert_eq!(&recv_buf[..read as usize], ping);

        let pong = b"pong";
        assert_eq!(
            cmux_iroh_connection_send(server_conn, pong.as_ptr(), pong.len(), &mut error),
            0,
            "{}",
            ffi_error_message(&error)
        );
        let read = cmux_iroh_connection_recv(
            client_conn,
            recv_buf.as_mut_ptr(),
            recv_buf.len(),
            &mut error,
        );
        assert_eq!(read, pong.len() as isize, "{}", ffi_error_message(&error));
        assert_eq!(&recv_buf[..read as usize], pong);

        cmux_iroh_connection_close(client_conn);
        cmux_iroh_connection_close(server_conn);
        cmux_iroh_endpoint_close(client);
        cmux_iroh_endpoint_close(server);
    }

    fn ffi_error_message(error: &CmuxIrohError) -> String {
        let message = if error.message.is_null() {
            ""
        } else {
            unsafe { CStr::from_ptr(error.message) }
                .to_str()
                .unwrap_or("")
        };
        format!("kind={} message={message}", error.kind)
    }
}
