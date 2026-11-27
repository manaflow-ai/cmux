//! Which proxy a connection goes through, and the tunnel through it.
//!
//! The system's proxy settings decide, per destination, as URLSession does:
//! on iOS and macOS CFNetwork's (a manual HTTP, HTTPS or SOCKS proxy, a PAC
//! file or script, WPAD, an MDM payload: [`super::apple`]), elsewhere the
//! `https_proxy`, `http_proxy`, `all_proxy` and `no_proxy` environment
//! variables. The answer is a list of hops to try in order (a PAC file's
//! `PROXY a:8080; PROXY b:8080; DIRECT`). An HTTP proxy carries the
//! connection with `CONNECT host:port` (RFC 9110 §9.3.6), a SOCKS proxy
//! with SOCKS5 (RFC 1928), each with the system's user name and password when
//! it has them (HTTP Basic, SOCKS5 RFC 1929).
//!
//! A proxy that asks for NTLM or Kerberos (Negotiate) sign-in fails with
//! [`EgressError::ProxyAuthUnsupported`], which says so: the link has no
//! NTLM or Kerberos client (PROTOCOL.md "Corporate networks" has why).

use std::collections::HashMap;
use std::fmt;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::EgressError;

/// The proxy settings a connection follows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum ProxyConfig {
    /// The system's (module docs). `CMUX_MOBILE_DEV_PROXY=URL` in the
    /// environment replaces them (the simulator rig and tests).
    #[default]
    System,
    /// No proxy.
    Direct,
    /// These hops, for every destination (tests).
    Fixed(Vec<Hop>),
}

/// One way out to a destination.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Hop {
    Direct,
    /// An HTTP proxy, tunneled with `CONNECT`.
    Http(ProxyServer),
    /// A SOCKS5 proxy.
    Socks5(ProxyServer),
}

impl fmt::Display for Hop {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Direct => f.write_str("direct"),
            Self::Http(server) => write!(f, "HTTP proxy {server}"),
            Self::Socks5(server) => write!(f, "SOCKS proxy {server}"),
        }
    }
}

/// A proxy's address and the credentials the system has for it.
#[derive(Clone, PartialEq, Eq)]
pub struct ProxyServer {
    pub host: String,
    pub port: u16,
    pub credentials: Option<Credentials>,
}

impl ProxyServer {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self { host: host.into(), port, credentials: None }
    }

    #[must_use]
    pub fn with_credentials(mut self, username: &str, password: &str) -> Self {
        self.credentials =
            Some(Credentials { username: username.to_owned(), password: password.to_owned() });
        self
    }

    /// `http://[user:password@]host:port`, percent-encoded (an HTTP client's
    /// proxy URL).
    pub fn http_url(&self) -> String {
        let auth = self
            .credentials
            .as_ref()
            .map(|c| format!("{}:{}@", percent_encode(&c.username), percent_encode(&c.password)))
            .unwrap_or_default();
        format!("http://{auth}{}", authority(&self.host, self.port))
    }
}

impl fmt::Display for ProxyServer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&authority(&self.host, self.port))
    }
}

/// Never prints the password.
impl fmt::Debug for ProxyServer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProxyServer")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("credentials", &self.credentials.as_ref().map(|c| c.username.as_str()))
            .finish()
    }
}

/// A user name and password the system holds for a proxy.
#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    pub username: String,
    pub password: String,
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials").field("username", &self.username).finish_non_exhaustive()
    }
}

/// `host:port`, with brackets around an IPv6 host.
pub(crate) fn authority(host: &str, port: u16) -> String {
    if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") }
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while let Some(&byte) = bytes.get(at) {
        if byte == b'%'
            && let Some(byte) =
                text.get(at + 1..at + 3).and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            at += 3;
            continue;
        }
        out.push(byte);
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A proxy URL (`http://user:pass@host:8080`, `socks5://host:1080`, or a
/// bare `host:port`, which is HTTP). `None` for what the link cannot use
/// (an `https://` proxy, which wants TLS to the proxy itself).
pub fn parse_proxy_url(text: &str) -> Option<Hop> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let with_scheme = if text.contains("://") { text.to_owned() } else { format!("http://{text}") };
    let url = url::Url::parse(&with_scheme).ok()?;
    let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']').to_owned();
    if host.is_empty() {
        return None;
    }
    // An explicit port, even the scheme's own (`url` hides `:80` on http);
    // none is curl's default proxy port.
    let port = url
        .port()
        .or_else(|| has_port(&with_scheme).then(|| url.port_or_known_default()).flatten());
    let port = port.unwrap_or(1080);
    let mut server = ProxyServer::new(host, port);
    if !url.username().is_empty() {
        server = server.with_credentials(
            &percent_decode(url.username()),
            &percent_decode(url.password().unwrap_or("")),
        );
    }
    match url.scheme() {
        "http" => Some(Hop::Http(server)),
        "socks5" | "socks5h" | "socks" => Some(Hop::Socks5(server)),
        _ => None,
    }
}

/// Whether a URL's authority names a port (`host:80`, `[::1]:80`).
fn has_port(url: &str) -> bool {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host_port)| host_port);
    host_port.rsplit_once(':').is_some_and(|(host, port)| {
        !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) && !host.ends_with(':')
    }) && !host_port.ends_with(']')
}

/// Whether `host` is never proxied, whatever the system settings say: this
/// machine (`localhost`, a loopback address), a link-local address, or a
/// tailnet address (Tailscale's `100.64.0.0/10` and `fd7a:115c:a1e0::/48`,
/// which the WireGuard or tailnet interface carries, never a proxy).
pub fn never_proxied(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") || host.to_ascii_lowercase().ends_with(".localhost") {
        return true;
    }
    let Ok(ip) = host.trim_start_matches('[').trim_end_matches(']').parse::<IpAddr>() else {
        return false;
    };
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_link_local()
                || in_network(ip, IpAddr::V4([100, 64, 0, 0].into()), 10)
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.to_ipv4_mapped().is_some_and(|v4| never_proxied(&v4.to_string()))
                || (v6.segments()[0] & 0xffc0) == 0xfe80
                || in_network(ip, IpAddr::V6([0xfd7a, 0x115c, 0xa1e0, 0, 0, 0, 0, 0].into()), 48)
        }
    }
}

/// Whether a `no_proxy` list (`*`, `example.com`, `.example.com`,
/// `10.0.0.0/8`, `::1`) names `host`.
pub fn no_proxy_matches(list: &str, host: &str) -> bool {
    let host = host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
    let ip = host.parse::<IpAddr>().ok();
    list.split([',', ' ']).map(str::trim).filter(|entry| !entry.is_empty()).any(|entry| {
        let entry = entry.to_ascii_lowercase();
        if entry == "*" {
            return true;
        }
        if let Some((net, bits)) = entry.split_once('/')
            && let (Ok(net), Ok(bits), Some(ip)) = (net.parse::<IpAddr>(), bits.parse::<u32>(), ip)
        {
            return in_network(ip, net, bits);
        }
        let entry = entry.trim_start_matches("*.").trim_start_matches('.');
        host == entry || host.ends_with(&format!(".{entry}"))
    })
}

fn in_network(ip: IpAddr, net: IpAddr, bits: u32) -> bool {
    match (ip, net) {
        (IpAddr::V4(ip), IpAddr::V4(net)) if bits <= 32 => {
            let mask = if bits == 0 { 0 } else { u32::MAX << (32 - bits) };
            u32::from(ip) & mask == u32::from(net) & mask
        }
        (IpAddr::V6(ip), IpAddr::V6(net)) if bits <= 128 => {
            let mask = if bits == 0 { 0 } else { u128::MAX << (128 - bits) };
            u128::from(ip) & mask == u128::from(net) & mask
        }
        _ => false,
    }
}

/// The environment's proxy for a connection to `host` (`secure`: TLS, as
/// an `https` URL would be): `no_proxy`, then `https_proxy` or `http_proxy`,
/// then `all_proxy`, lowercase before uppercase (curl's order).
pub fn env_hops(host: &str, secure: bool, var: impl Fn(&str) -> Option<String>) -> Vec<Hop> {
    let pick = |names: &[&str]| {
        names.iter().find_map(|name| var(name).filter(|value| !value.trim().is_empty()))
    };
    if pick(&["no_proxy", "NO_PROXY"]).is_some_and(|list| no_proxy_matches(&list, host)) {
        return vec![Hop::Direct];
    }
    let scheme = if secure { ["https_proxy", "HTTPS_PROXY"] } else { ["http_proxy", "HTTP_PROXY"] };
    match pick(&scheme)
        .or_else(|| pick(&["all_proxy", "ALL_PROXY"]))
        .and_then(|url| parse_proxy_url(&url))
    {
        Some(hop) => vec![hop],
        None => vec![Hop::Direct],
    }
}

/// One entry of the system's proxy list for a URL (CFNetwork's
/// `CFNetworkCopyProxiesForURL`), before PAC is run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SystemEntry {
    Direct,
    Http(ProxyServer),
    Socks(ProxyServer),
    /// Run this PAC file (a URL; WPAD's `http://wpad/wpad.dat` too).
    PacUrl(String),
    /// Run this PAC script.
    PacScript(String),
    /// A kind the link cannot use (an FTP proxy, a new kind).
    Other(String),
}

/// The hops of the system's list, a PAC entry replaced by what `run_pac`
/// answers for it (its own PAC entries dropped: PAC does not nest). An entry
/// the link cannot use is skipped; nothing usable is direct.
pub fn hops_from_entries(
    entries: Vec<SystemEntry>,
    mut run_pac: impl FnMut(&SystemEntry) -> Option<Vec<SystemEntry>>,
) -> Vec<Hop> {
    let mut hops = Vec::new();
    let push = |hops: &mut Vec<Hop>, hop: Hop| {
        if !hops.contains(&hop) {
            hops.push(hop);
        }
    };
    for entry in entries {
        match entry {
            SystemEntry::Direct => push(&mut hops, Hop::Direct),
            SystemEntry::Http(server) => push(&mut hops, Hop::Http(server)),
            SystemEntry::Socks(server) => push(&mut hops, Hop::Socks5(server)),
            SystemEntry::PacUrl(_) | SystemEntry::PacScript(_) => match run_pac(&entry) {
                Some(answer) => {
                    for inner in answer {
                        match inner {
                            SystemEntry::Direct => push(&mut hops, Hop::Direct),
                            SystemEntry::Http(server) => push(&mut hops, Hop::Http(server)),
                            SystemEntry::Socks(server) => push(&mut hops, Hop::Socks5(server)),
                            other => tracing::debug!(?other, "a PAC answer the link cannot use"),
                        }
                    }
                }
                // A PAC file that cannot be fetched or run: CFNetwork and
                // browsers go direct.
                None => push(&mut hops, Hop::Direct),
            },
            SystemEntry::Other(kind) => {
                tracing::debug!(%kind, "a system proxy kind the link cannot use");
            }
        }
    }
    if hops.is_empty() {
        hops.push(Hop::Direct);
    }
    hops
}

/// How long the system's answer for a destination is kept: a PAC file is
/// fetched and run once per destination in this time, not per connection.
const CACHE_FOR: Duration = Duration::from_secs(30);
/// Bound on asking the system (PAC fetch and run included): past it, direct.
const SYSTEM_WAIT: Duration = Duration::from_secs(5);

/// A destination: host, port and whether TLS runs on it.
type CacheKey = (String, u16, bool);
/// Each destination's hops and when the system gave them.
type Cache = Mutex<HashMap<CacheKey, (Instant, Vec<Hop>)>>;

fn cache() -> &'static Cache {
    static CACHE: std::sync::OnceLock<Cache> = std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Forget every destination's answer: the network changed, and its proxy
/// settings (a PAC URL from DHCP, a VPN's proxy) may have too.
pub fn forget() {
    cache().lock().unwrap_or_else(std::sync::PoisonError::into_inner).clear();
}

fn cached(key: &CacheKey) -> Option<Vec<Hop>> {
    let cache = cache().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    cache.get(key).filter(|(at, _)| at.elapsed() < CACHE_FOR).map(|(_, hops)| hops.clone())
}

fn remember(key: CacheKey, hops: &[Hop]) {
    let mut cache = cache().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    cache.retain(|_, (at, _)| at.elapsed() < CACHE_FOR);
    cache.insert(key, (Instant::now(), hops.to_vec()));
}

/// The cached answer for `host:port` (`secure`: TLS), if one is still fresh:
/// what a caller that must not wait checks before it races the lookup.
pub fn cached_hops(host: &str, port: u16, secure: bool) -> Option<Vec<Hop>> {
    cached(&(host.to_ascii_lowercase(), port, secure))
}

/// The environment's override of the system settings (`CMUX_MOBILE_DEV_PROXY`).
fn dev_override() -> Option<Vec<Hop>> {
    let text = std::env::var("CMUX_MOBILE_DEV_PROXY").ok()?;
    match text.trim() {
        "" => None,
        "direct" | "DIRECT" => Some(vec![Hop::Direct]),
        text => parse_proxy_url(text).map(|hop| vec![hop]),
    }
}

/// The system's hops to `host:port`, asking the OS (blocking: a PAC file may
/// be fetched and run).
fn system_hops_blocking(host: &str, port: u16, secure: bool) -> Vec<Hop> {
    if never_proxied(host) {
        return vec![Hop::Direct];
    }
    if let Some(hops) = dev_override() {
        return hops;
    }
    #[cfg(target_vendor = "apple")]
    {
        let scheme = if secure { "https" } else { "http" };
        super::apple::hops_for_url(&format!("{scheme}://{}/", authority(host, port)))
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = port;
        env_hops(host, secure, |name| std::env::var(name).ok())
    }
}

/// The hops to try, in order, for a connection to `host:port` (`secure`:
/// TLS). The system's answer is cached for [`CACHE_FOR`].
pub async fn hops(host: &str, port: u16, secure: bool, config: &ProxyConfig) -> Vec<Hop> {
    match config {
        ProxyConfig::Direct => vec![Hop::Direct],
        ProxyConfig::Fixed(hops) if hops.is_empty() => vec![Hop::Direct],
        ProxyConfig::Fixed(hops) => hops.clone(),
        ProxyConfig::System => {
            let key = (host.to_ascii_lowercase(), port, secure);
            if let Some(hops) = cached(&key) {
                return hops;
            }
            let owned = host.to_owned();
            let asked =
                tokio::task::spawn_blocking(move || system_hops_blocking(&owned, port, secure));
            let hops = match tokio::time::timeout(SYSTEM_WAIT, asked).await {
                Ok(Ok(hops)) => hops,
                Ok(Err(error)) => {
                    tracing::warn!(%error, "the system proxy lookup failed; connecting directly");
                    vec![Hop::Direct]
                }
                Err(_) => {
                    tracing::warn!(
                        host,
                        "the system proxy lookup took too long; connecting directly"
                    );
                    vec![Hop::Direct]
                }
            };
            remember(key, &hops);
            hops
        }
    }
}

/// [`hops`] without waiting: the cached answer, else the system's asked now
/// on this thread (an HTTP client's proxy callback, which cannot await).
/// [`warm`] first keeps PAC off the caller's thread.
pub fn hops_now(host: &str, port: u16, secure: bool, config: &ProxyConfig) -> Vec<Hop> {
    match config {
        ProxyConfig::System => {
            let key = (host.to_ascii_lowercase(), port, secure);
            if let Some(hops) = cached(&key) {
                return hops;
            }
            let hops = system_hops_blocking(host, port, secure);
            remember(key, &hops);
            hops
        }
        ProxyConfig::Fixed(hops) if !hops.is_empty() => hops.clone(),
        ProxyConfig::Fixed(_) | ProxyConfig::Direct => vec![Hop::Direct],
    }
}

/// The proxy an HTTP client with one proxy and no SOCKS (reqwest's
/// `Proxy::custom`) sends a request for `url` through: the first HTTP proxy the
/// system names for it, unless the settings go direct before it; `None` is
/// direct. It reads the cached answer, else asks on this thread ([`hops_now`]):
/// [`warm`] the origin first.
pub fn http_proxy_url(url: &url::Url) -> Option<String> {
    let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']');
    let secure = matches!(url.scheme(), "https" | "wss");
    let port = url.port_or_known_default()?;
    for hop in hops_now(host, port, secure, &ProxyConfig::System) {
        match hop {
            Hop::Direct => return None,
            Hop::Http(server) => return Some(server.http_url()),
            Hop::Socks5(_) => {}
        }
    }
    None
}

/// Ask the system for `url`'s proxy now, off this thread, so a later
/// [`hops_now`] finds it cached.
pub async fn warm(url: &str) {
    let Ok(url) = url::Url::parse(url) else { return };
    let Some(host) = url.host_str() else { return };
    let secure = matches!(url.scheme(), "https" | "wss");
    let port = url.port_or_known_default().unwrap_or(if secure { 443 } else { 80 });
    let _ = hops(
        host.trim_start_matches('[').trim_end_matches(']'),
        port,
        secure,
        &ProxyConfig::System,
    )
    .await;
}

/// Bound on reading a proxy's answer head.
const MAX_HEAD: usize = 16 * 1024;

/// The proxy's answer to `CONNECT`, up to the blank line, read byte by byte
/// so not one byte of the tunnel is taken.
async fn read_head(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut head = Vec::with_capacity(256);
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).await? == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "the proxy closed the connection before it answered",
            ));
        }
        head.push(byte[0]);
        if head.len() > MAX_HEAD {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "the proxy's answer is too long",
            ));
        }
    }
    Ok(String::from_utf8_lossy(&head).into_owned())
}

/// The authentication schemes of a 407's `Proxy-Authenticate` headers
/// (`Basic`, `NTLM`, `Negotiate`, `Digest`).
pub fn auth_schemes(head: &str) -> Vec<String> {
    let mut schemes = Vec::new();
    for line in head.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else { continue };
        if !name.trim().eq_ignore_ascii_case("proxy-authenticate") {
            continue;
        }
        // Several challenges may share a header, comma separated; a scheme is
        // a challenge's first token (parameters follow it with `=`).
        for part in value.split(',') {
            let token = part.split_whitespace().next().unwrap_or("");
            if !token.is_empty()
                && !token.contains('=')
                && !schemes.iter().any(|s: &String| s.eq_ignore_ascii_case(token))
            {
                schemes.push(token.to_owned());
            }
        }
    }
    schemes
}

/// Whether `host` can stand in a `CONNECT` line as it is: no space, control
/// character (a CR or LF would end the line and smuggle a header), `@`, `/`
/// or other character a host name or bracketed IP literal never has.
pub fn is_plain_host(host: &str) -> bool {
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    !bare.is_empty()
        && bare.len() <= 253
        && bare
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b':' | b'%'))
}

/// Tunnel `stream` (connected to `proxy`) to `host:port` with `CONNECT`,
/// sending Basic credentials when the system has them.
pub(crate) async fn http_connect(
    mut stream: TcpStream,
    proxy: &ProxyServer,
    host: &str,
    port: u16,
) -> Result<TcpStream, EgressError> {
    // A name with a space or a line break would end the request line or
    // smuggle headers into the proxy's request.
    if host.is_empty() || host.bytes().any(|b| b.is_ascii_whitespace() || b.is_ascii_control()) {
        return Err(EgressError::Io(format!("not a host name to tunnel to: {host:?}")));
    }
    let target = authority(host, port);
    if !is_plain_host(host) {
        return Err(EgressError::Io(format!(
            "HTTP proxy {proxy}: the destination {target:?} is not a plain host name or address"
        )));
    }
    let mut request = format!(
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nUser-Agent: cmux-mobile-link\r\nProxy-Connection: Keep-Alive\r\n"
    );
    if let Some(credentials) = &proxy.credentials {
        let token = base64::engine::general_purpose::STANDARD
            .encode(format!("{}:{}", credentials.username, credentials.password));
        request.push_str(&format!("Proxy-Authorization: Basic {token}\r\n"));
    }
    request.push_str("\r\n");
    let io = |error: std::io::Error| EgressError::Io(format!("HTTP proxy {proxy}: {error}"));
    stream.write_all(request.as_bytes()).await.map_err(io)?;
    let head = read_head(&mut stream).await.map_err(io)?;
    let status_line = head.lines().next().unwrap_or("").trim().to_owned();
    let code = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .unwrap_or(0);
    match code {
        200..=299 => Ok(stream),
        407 => {
            let schemes = auth_schemes(&head);
            let basic = schemes.iter().any(|scheme| scheme.eq_ignore_ascii_case("basic"));
            Err(match (&proxy.credentials, basic) {
                (Some(credentials), true) if credentials.password.is_empty() => {
                    EgressError::ProxyAuthNoPassword {
                        proxy: proxy.to_string(),
                        username: credentials.username.clone(),
                    }
                }
                (Some(_), true) => EgressError::ProxyAuthRefused { proxy: proxy.to_string() },
                (None, true) => EgressError::ProxyAuthMissing { proxy: proxy.to_string() },
                _ => EgressError::ProxyAuthUnsupported {
                    proxy: proxy.to_string(),
                    target,
                    schemes: if schemes.is_empty() {
                        "an unnamed".to_owned()
                    } else {
                        schemes.join(" or ")
                    },
                },
            })
        }
        _ => {
            Err(EgressError::ProxyRefused { proxy: proxy.to_string(), target, status: status_line })
        }
    }
}

/// Tunnel `stream` (connected to `proxy`) to `host:port` with SOCKS5,
/// sending the host name (the proxy resolves it) and, when the system has
/// them, the user name and password (RFC 1929).
pub(crate) async fn socks5_connect(
    mut stream: TcpStream,
    proxy: &ProxyServer,
    host: &str,
    port: u16,
) -> Result<TcpStream, EgressError> {
    let target = authority(host, port);
    let io = |error: std::io::Error| EgressError::Io(format!("SOCKS proxy {proxy}: {error}"));
    let refused = |status: String| EgressError::ProxyRefused {
        proxy: proxy.to_string(),
        target: target.clone(),
        status,
    };
    let methods: &[u8] = if proxy.credentials.is_some() { &[0x00, 0x02] } else { &[0x00] };
    let mut hello = vec![0x05, methods.len() as u8];
    hello.extend_from_slice(methods);
    stream.write_all(&hello).await.map_err(io)?;
    let mut choice = [0u8; 2];
    stream.read_exact(&mut choice).await.map_err(io)?;
    match (choice, &proxy.credentials) {
        ([0x05, 0x00], _) => {}
        ([0x05, 0x02], Some(credentials)) => {
            let (user, pass) = (credentials.username.as_bytes(), credentials.password.as_bytes());
            if user.len() > 255 || pass.len() > 255 {
                return Err(refused("credentials too long for SOCKS5".into()));
            }
            let mut auth = vec![0x01, user.len() as u8];
            auth.extend_from_slice(user);
            auth.push(pass.len() as u8);
            auth.extend_from_slice(pass);
            stream.write_all(&auth).await.map_err(io)?;
            let mut answer = [0u8; 2];
            stream.read_exact(&mut answer).await.map_err(io)?;
            if answer[1] != 0x00 {
                return Err(EgressError::ProxyAuthRefused { proxy: proxy.to_string() });
            }
        }
        ([0x05, 0xFF], None) => {
            return Err(EgressError::ProxyAuthMissing { proxy: proxy.to_string() });
        }
        ([0x05, method], _) => {
            return Err(EgressError::ProxyAuthUnsupported {
                proxy: proxy.to_string(),
                target: target.clone(),
                schemes: format!("SOCKS method {method:#04x}"),
            });
        }
        _ => return Err(refused("not a SOCKS5 proxy".into())),
    }
    let host_bytes = host.trim_start_matches('[').trim_end_matches(']');
    let mut request = vec![0x05, 0x01, 0x00];
    match host_bytes.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(0x01);
            request.extend_from_slice(&ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(0x04);
            request.extend_from_slice(&ip.octets());
        }
        Err(_) if host_bytes.len() <= 255 => {
            request.push(0x03);
            request.push(host_bytes.len() as u8);
            request.extend_from_slice(host_bytes.as_bytes());
        }
        Err(_) => return Err(refused("host name too long for SOCKS5".into())),
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await.map_err(io)?;
    let mut reply = [0u8; 4];
    stream.read_exact(&mut reply).await.map_err(io)?;
    if reply[1] != 0x00 {
        return Err(refused(format!("SOCKS5 reply {}", reply[1])));
    }
    // The bound address that follows: IPv4, a name, or IPv6, then the port.
    let rest = match reply[3] {
        0x01 => 4 + 2,
        0x04 => 16 + 2,
        0x03 => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await.map_err(io)?;
            usize::from(len[0]) + 2
        }
        _ => return Err(refused("SOCKS5 reply with an unknown address type".into())),
    };
    let mut skip = vec![0u8; rest];
    stream.read_exact(&mut skip).await.map_err(io)?;
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn http(host: &str, port: u16) -> Hop {
        Hop::Http(ProxyServer::new(host, port))
    }

    /// A destination name with a line break or a space never reaches the
    /// proxy: it would end the CONNECT line and smuggle headers in.
    #[tokio::test]
    async fn a_connect_target_that_would_inject_headers_is_refused() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = ProxyServer::new("127.0.0.1", address.port());
        for host in ["evil\r\nX-Injected: 1", "a b", "", "tab\there"] {
            let stream = TcpStream::connect(address).await.unwrap();
            let error = http_connect(stream, &server, host, 443).await.expect_err(host);
            assert!(
                matches!(error, EgressError::Io(ref message) if message.contains("not a host name")),
                "{error}"
            );
        }
    }

    #[test]
    fn proxy_urls_parse_with_credentials_and_defaults() {
        assert_eq!(parse_proxy_url("proxy.corp:8080"), Some(http("proxy.corp", 8080)));
        assert_eq!(
            parse_proxy_url("http://ann%40corp:p%3Ass@proxy.corp:3128"),
            Some(Hop::Http(
                ProxyServer::new("proxy.corp", 3128).with_credentials("ann@corp", "p:ss")
            ))
        );
        assert_eq!(
            parse_proxy_url("socks5h://10.0.0.1"),
            Some(Hop::Socks5(ProxyServer::new("10.0.0.1", 1080)))
        );
        assert_eq!(parse_proxy_url("http://[2001:db8::1]:8080"), Some(http("2001:db8::1", 8080)));
        // The scheme's own port, written out, is kept; none is 1080.
        assert_eq!(parse_proxy_url("http://proxy.corp:80"), Some(http("proxy.corp", 80)));
        assert_eq!(parse_proxy_url("http://proxy.corp"), Some(http("proxy.corp", 1080)));
        assert_eq!(parse_proxy_url("http://[::1]"), Some(http("::1", 1080)));
        // TLS to the proxy itself is not something the link speaks.
        assert_eq!(parse_proxy_url("https://proxy.corp:443"), None);
        assert_eq!(parse_proxy_url(""), None);
        // The URL form keeps the credentials, encoded.
        let server = ProxyServer::new("p", 1).with_credentials("a b", "c@d");
        assert_eq!(server.http_url(), "http://a%20b:c%40d@p:1");
        // Debug never shows the password.
        assert!(!format!("{server:?}").contains("c@d"));
    }

    #[test]
    fn no_proxy_lists_match_names_suffixes_and_networks() {
        let list = "localhost, .corp.example, intranet, 10.0.0.0/8, ::1";
        assert!(no_proxy_matches(list, "wiki.corp.example"));
        assert!(no_proxy_matches(list, "corp.example"));
        assert!(no_proxy_matches(list, "INTRANET"));
        assert!(no_proxy_matches(list, "10.20.30.40"));
        assert!(no_proxy_matches(list, "[::1]"));
        assert!(!no_proxy_matches(list, "turn.cloudflare.com"));
        assert!(!no_proxy_matches(list, "11.0.0.1"));
        assert!(!no_proxy_matches(list, "notcorp.example"));
        assert!(no_proxy_matches("*", "anything"));
    }

    #[test]
    fn the_environment_picks_by_scheme_then_all_proxy() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).to_owned())
            }
        };
        let vars = env(&[("https_proxy", "http://secure:8443"), ("http_proxy", "plain:8080")]);
        assert_eq!(env_hops("turn.cloudflare.com", true, vars), vec![http("secure", 8443)]);
        assert_eq!(env_hops("turn.cloudflare.com", false, vars), vec![http("plain", 8080)]);
        let vars = env(&[("ALL_PROXY", "socks5://s:1080"), ("NO_PROXY", ".internal")]);
        assert_eq!(env_hops("a.internal", true, vars), vec![Hop::Direct]);
        assert_eq!(
            env_hops("x.example", true, vars),
            vec![Hop::Socks5(ProxyServer::new("s", 1080))]
        );
        assert_eq!(env_hops("x.example", true, env(&[])), vec![Hop::Direct]);
    }

    /// A PAC entry is replaced by its answer, in order; an unusable kind is
    /// skipped; a PAC file that cannot run is direct; repeats collapse.
    #[test]
    fn system_entries_become_hops_with_pac_run_in_place() {
        let pac = SystemEntry::PacUrl("http://wpad/wpad.dat".into());
        let entries = vec![
            SystemEntry::Other("FTP".into()),
            pac.clone(),
            SystemEntry::Http(ProxyServer::new("b", 8080)),
            SystemEntry::Direct,
        ];
        let hops = hops_from_entries(entries, |entry| {
            assert_eq!(entry, &pac);
            Some(vec![
                SystemEntry::Http(ProxyServer::new("a", 3128)),
                SystemEntry::PacUrl("nested".into()),
                SystemEntry::Http(ProxyServer::new("b", 8080)),
            ])
        });
        assert_eq!(hops, vec![http("a", 3128), http("b", 8080), Hop::Direct]);
        assert_eq!(
            hops_from_entries(vec![SystemEntry::PacScript("bad".into())], |_| None),
            vec![Hop::Direct]
        );
        assert_eq!(hops_from_entries(Vec::new(), |_| None), vec![Hop::Direct]);
    }

    #[test]
    fn loopback_link_local_and_tailnet_hosts_are_never_proxied() {
        for host in [
            "localhost",
            "a.localhost",
            "127.0.0.1",
            "[::1]",
            "::1",
            "169.254.1.2",
            "fe80::1",
            "100.64.0.1",
            "100.127.255.254",
            "fd7a:115c:a1e0::10",
            "[fd7a:115c:a1e0:ab12::1]",
            "::ffff:127.0.0.1",
        ] {
            assert!(never_proxied(host), "{host}");
        }
        for host in
            ["cmux.dev", "100.128.0.1", "10.0.0.1", "8.8.8.8", "2001:db8::1", "fd7a:115d::1"]
        {
            assert!(!never_proxied(host), "{host}");
        }
    }

    #[test]
    fn a_connect_target_is_a_plain_host() {
        for host in [
            "cmux.dev",
            "relay.cmux.dev",
            "10.0.0.1",
            "[2001:db8::1]",
            "2001:db8::1",
            "fe80::1%en0",
        ] {
            assert!(is_plain_host(host), "{host}");
        }
        for host in ["", "a b", "evil\r\nX-Injected: 1", "a\nb", "user@host", "host/path", "[]"] {
            assert!(!is_plain_host(host), "{host:?}");
        }
    }

    #[test]
    fn forget_clears_cached_answers() {
        remember(("forget.example".into(), 443, true), &[http("p", 1)]);
        assert_eq!(cached_hops("FORGET.example", 443, true), Some(vec![http("p", 1)]));
        forget();
        assert_eq!(cached_hops("forget.example", 443, true), None);
    }

    #[test]
    fn a_407_names_its_schemes() {
        let head = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nproxy-authenticate: NTLM\r\nProxy-Authenticate: Basic realm=\"corp\", Digest realm=\"corp\", nonce=\"x\"\r\n\r\n";
        assert_eq!(auth_schemes(head), vec!["Negotiate", "NTLM", "Basic", "Digest"]);
    }
}
