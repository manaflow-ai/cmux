//! Minimal C FFI over iroh for the cmux mobile transport spike.
//!
//! This is spike code: it proves a Swift process (macOS app or iOS app) can
//! bind an iroh endpoint, dial another endpoint by EndpointId through the
//! default n0 relays, and exchange bytes over one bidirectional QUIC stream.
//! The single bi-stream is deliberate: it is the byte-stream substrate the
//! existing `CmxByteTransport` protocol (length-prefixed JSON frames) rides on.
//!
//! Shape notes for the production version (see plans/feat-ios-iroh/DESIGN.md):
//! - one blocking C call per `CmxByteTransport` operation (connect/recv/send/close),
//!   called from Swift off the main thread; a shared tokio runtime lives in here.
//! - the dialer opens the stream and speaks first, which matches the existing
//!   mobile protocol where the phone sends the first RPC frame (QUIC `accept_bi`
//!   only resolves once the opener has sent bytes).

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
    endpoint::{Connection, ConnectionError, ReadError, RecvStream, SendStream, presets},
};
use tokio::{runtime::Runtime, sync::Mutex};

const ALPN: &[u8] = b"dev.cmux.mobile.terminal/0";

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

/// Writes `message` into the caller-provided error buffer, truncating to fit.
fn set_error(err_buf: *mut c_char, err_cap: usize, message: &str) {
    if err_buf.is_null() || err_cap == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let len = bytes.len().min(err_cap - 1);
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), err_buf.cast::<u8>(), len);
        *err_buf.add(len) = 0;
    }
}

pub struct CmuxIrohEndpoint {
    endpoint: Endpoint,
}

pub struct CmuxIrohConnection {
    connection: Connection,
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
}

/// Binds an iroh endpoint using the default n0 preset (relays + discovery).
///
/// Returns null on failure with the cause in `err_buf`. The spike always
/// generates a fresh secret key; key custody is a production design topic.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_bind(
    enable_relay: bool,
    accept_connections: bool,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohEndpoint {
    let result = runtime().block_on(async move {
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(SecretKey::generate())
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
        Err(error) => {
            set_error(err_buf, err_cap, &format!("bind failed: {error:#}"));
            ptr::null_mut()
        }
    }
}

/// Returns the endpoint's EndpointId (z-base-32) as a heap string.
/// Free with `cmux_iroh_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_id(endpoint: *const CmuxIrohEndpoint) -> *mut c_char {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        return ptr::null_mut();
    };
    string_to_c(endpoint.endpoint.id().to_string())
}

/// Returns a `CmxAttachRoute`-shaped JSON object for this endpoint
/// (id, direct addrs, relay URL). Free with `cmux_iroh_string_free`.
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
    // `CmxAttachTicket.preferredRoute` sorts ascending and lower wins, so iroh
    // must sit below the Mac's primary Tailscale route (priority 10) to be the
    // default; 5 also stays above debugLoopback (0) so DEBUG/simulator runs
    // keep preferring the loopback mock host.
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

/// Waits until the endpoint has a home relay connection (so dial-by-id from
/// elsewhere can reach it). 0 on success, -1 on timeout.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_online(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(err_buf, err_cap, "null endpoint");
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
            set_error(err_buf, err_cap, "timed out waiting for relay connection");
            -1
        }
    }
}

/// Accepts one incoming connection and its first bidirectional stream.
/// Blocks up to `timeout_ms`. Returns null on failure/timeout.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_accept(
    endpoint: *mut CmuxIrohEndpoint,
    timeout_ms: u64,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(err_buf, err_cap, "null endpoint");
        return ptr::null_mut();
    };
    let result = runtime().block_on(async {
        tokio::time::timeout(Duration::from_millis(timeout_ms.max(1)), async {
            let incoming = endpoint
                .endpoint
                .accept()
                .await
                .ok_or_else(|| "endpoint closed".to_string())?;
            let connection = incoming
                .await
                .map_err(|error| format!("incoming connection failed: {error:#}"))?;
            let (send, recv) = connection
                .accept_bi()
                .await
                .map_err(|error| format!("accept_bi failed: {error:#}"))?;
            Ok::<_, String>((connection, send, recv))
        })
        .await
        .map_err(|_| "accept timed out".to_string())?
    });
    finish_connection(result, err_buf, err_cap)
}

/// Dials `endpoint_id` (optionally with relay URL / direct addr hints) and
/// opens one bidirectional stream. With no hints, n0 discovery resolves the id.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_endpoint_connect(
    endpoint: *mut CmuxIrohEndpoint,
    endpoint_id: *const c_char,
    relay_url: *const c_char,
    direct_addrs: *const *const c_char,
    direct_addr_count: usize,
    timeout_ms: u64,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
        set_error(err_buf, err_cap, "null endpoint");
        return ptr::null_mut();
    };
    let Some(id_str) = c_to_str(endpoint_id) else {
        set_error(err_buf, err_cap, "null or invalid endpoint id");
        return ptr::null_mut();
    };
    let id = match EndpointId::from_str(id_str) {
        Ok(id) => id,
        Err(error) => {
            set_error(err_buf, err_cap, &format!("invalid endpoint id: {error:#}"));
            return ptr::null_mut();
        }
    };

    let mut addrs: Vec<TransportAddr> = Vec::new();
    if !direct_addrs.is_null() {
        for index in 0..direct_addr_count {
            let raw = unsafe { *direct_addrs.add(index) };
            let Some(addr_str) = c_to_str(raw) else {
                continue;
            };
            match SocketAddr::from_str(addr_str) {
                Ok(addr) => addrs.push(TransportAddr::Ip(addr)),
                Err(error) => {
                    set_error(
                        err_buf,
                        err_cap,
                        &format!("invalid direct addr {addr_str}: {error:#}"),
                    );
                    return ptr::null_mut();
                }
            }
        }
    }
    if let Some(relay_str) = c_to_str(relay_url) {
        match RelayUrl::from_str(relay_str) {
            Ok(url) => addrs.push(TransportAddr::Relay(url)),
            Err(error) => {
                set_error(err_buf, err_cap, &format!("invalid relay url: {error:#}"));
                return ptr::null_mut();
            }
        }
    }
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
                .map_err(|error| format!("connect failed: {error:#}"))?;
            let (send, recv) = connection
                .open_bi()
                .await
                .map_err(|error| format!("open_bi failed: {error:#}"))?;
            Ok::<_, String>((connection, send, recv))
        })
        .await
        .map_err(|_| "connect timed out".to_string())?
    });
    finish_connection(result, err_buf, err_cap)
}

/// Receives up to `cap` bytes. Returns bytes read (>0), 0 on clean end of
/// stream, or -1 on error.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_recv(
    connection: *mut CmuxIrohConnection,
    buf: *mut u8,
    cap: usize,
    err_buf: *mut c_char,
    err_cap: usize,
) -> isize {
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        set_error(err_buf, err_cap, "null connection");
        return -1;
    };
    if buf.is_null() || cap == 0 {
        set_error(err_buf, err_cap, "null or empty receive buffer");
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
        // A clean peer close (application error code 0) is end-of-stream,
        // not an error: QUIC CONNECTION_CLOSE can race the stream FIN.
        Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(close)))
            if u64::from(close.error_code) == 0 =>
        {
            0
        }
        Err(error) => {
            set_error(err_buf, err_cap, &format!("recv failed: {error:#}"));
            -1
        }
    }
}

/// Sends `len` bytes. Returns 0 on success, -1 on error.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_connection_send(
    connection: *mut CmuxIrohConnection,
    bytes: *const u8,
    len: usize,
    err_buf: *mut c_char,
    err_cap: usize,
) -> c_int {
    let Some(connection) = (unsafe { connection.as_ref() }) else {
        set_error(err_buf, err_cap, "null connection");
        return -1;
    };
    if len == 0 {
        return 0;
    }
    if bytes.is_null() {
        set_error(err_buf, err_cap, "null send buffer");
        return -1;
    }
    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    let result = runtime().block_on(async {
        let mut send = connection.send.lock().await;
        send.write_all(slice).await
    });
    match result {
        Ok(()) => 0,
        Err(error) => {
            set_error(err_buf, err_cap, &format!("send failed: {error:#}"));
            -1
        }
    }
}

/// Closes the connection and frees its handle.
///
/// Graceful close: `finish()` only queues the FIN plus any buffered stream
/// data, while `Connection::close` is immediate and abandons buffered data.
/// Closing right after finishing could therefore drop a final frame that
/// `send()` already reported as accepted. `stopped()` resolves once the peer
/// acknowledges receipt of all finished stream data, so wait for it (bounded,
/// so a vanished peer cannot wedge close) before closing the connection.
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

/// Closes the endpoint and frees its handle.
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

/// Frees a string returned by this library.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_iroh_string_free(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    drop(unsafe { CString::from_raw(string) });
}

fn finish_connection(
    result: Result<(Connection, SendStream, RecvStream), String>,
    err_buf: *mut c_char,
    err_cap: usize,
) -> *mut CmuxIrohConnection {
    match result {
        Ok((connection, send, recv)) => Box::into_raw(Box::new(CmuxIrohConnection {
            connection,
            send: Mutex::new(send),
            recv: Mutex::new(recv),
        })),
        Err(message) => {
            set_error(err_buf, err_cap, &message);
            ptr::null_mut()
        }
    }
}

fn string_to_c(string: String) -> *mut c_char {
    match CString::new(string) {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn c_to_str<'a>(raw: *const c_char) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}
