//! The subset of SOCKS5 (RFC 1928) the WireGuard hub speaks: CONNECT, literal
//! IP targets, and either no authentication or, when the hub was started with
//! a client token, RFC 1929 username/password carrying that token. Shared by
//! the hub (server side) and [`super::SocksDialer`] (client side) so the two
//! cannot drift.

use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use subtle::ConstantTimeEq;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use zeroize::Zeroizing;

pub(crate) const VERSION: u8 = 0x05;
pub(crate) const METHOD_NO_AUTH: u8 = 0x00;
pub(crate) const METHOD_USER_PASSWORD: u8 = 0x02;
pub(crate) const METHOD_UNACCEPTABLE: u8 = 0xFF;
pub(crate) const COMMAND_CONNECT: u8 = 0x01;
pub(crate) const ADDRESS_IPV4: u8 = 0x01;
pub(crate) const ADDRESS_DOMAIN: u8 = 0x03;
pub(crate) const ADDRESS_IPV6: u8 = 0x04;

pub(crate) const REPLY_SUCCEEDED: u8 = 0x00;
pub(crate) const REPLY_GENERAL_FAILURE: u8 = 0x01;
pub(crate) const REPLY_NOT_ALLOWED: u8 = 0x02;
pub(crate) const REPLY_NETWORK_UNREACHABLE: u8 = 0x03;
pub(crate) const REPLY_HOST_UNREACHABLE: u8 = 0x04;
pub(crate) const REPLY_CONNECTION_REFUSED: u8 = 0x05;
pub(crate) const REPLY_COMMAND_NOT_SUPPORTED: u8 = 0x07;
pub(crate) const REPLY_ADDRESS_TYPE_NOT_SUPPORTED: u8 = 0x08;

/// Longest domain name a request may carry; RFC 1928 uses one length byte.
const MAX_DOMAIN_BYTES: usize = 255;

/// RFC 1929 subnegotiation version and the username the hub's clients send.
/// The token is the password; the username only satisfies the wire format.
const USER_PASSWORD_VERSION: u8 = 0x01;
const TOKEN_USERNAME: &[u8] = b"cmux";
const AUTH_SUCCEEDED: u8 = 0x00;
const AUTH_FAILED: u8 = 0x01;

pub(crate) fn reply_description(code: u8) -> &'static str {
    match code {
        REPLY_SUCCEEDED => "succeeded",
        REPLY_GENERAL_FAILURE => "general failure",
        REPLY_NOT_ALLOWED => "connection not allowed by ruleset",
        REPLY_NETWORK_UNREACHABLE => "network unreachable",
        REPLY_HOST_UNREACHABLE => "host unreachable",
        REPLY_CONNECTION_REFUSED => "connection refused",
        0x06 => "TTL expired",
        REPLY_COMMAND_NOT_SUPPORTED => "command not supported",
        REPLY_ADDRESS_TYPE_NOT_SUPPORTED => "address type not supported",
        _ => "unassigned reply code",
    }
}

#[derive(Debug)]
pub(crate) enum SocksError {
    Io(io::Error),
    /// The peer spoke something other than the SOCKS5 subset above.
    Protocol(String),
    /// The server answered CONNECT with a non-success reply.
    Reply(u8),
}

impl fmt::Display for SocksError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "socks io: {error}"),
            Self::Protocol(detail) => write!(formatter, "socks protocol: {detail}"),
            Self::Reply(code) => {
                write!(formatter, "socks reply 0x{code:02x} ({})", reply_description(*code))
            }
        }
    }
}

impl std::error::Error for SocksError {}

impl From<io::Error> for SocksError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// What a client asked the hub to connect to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Target {
    Ip(SocketAddr),
    Domain { name: String, port: u16 },
}

/// A parsed CONNECT-style request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Request {
    pub(crate) command: u8,
    pub(crate) target: Target,
}

// ---- client side -----------------------------------------------------------

/// Run the client half of a SOCKS5 CONNECT for `target` over `stream`. With
/// a `token` the client offers only username/password and sends the token as
/// the password; without one it offers only no-auth. On success the stream
/// carries the tunneled connection from here on.
pub(crate) async fn client_connect<S>(
    stream: &mut S,
    target: SocketAddr,
    token: Option<&[u8]>,
) -> Result<(), SocksError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let method = if token.is_some() { METHOD_USER_PASSWORD } else { METHOD_NO_AUTH };
    stream.write_all(&[VERSION, 1, method]).await?;
    let mut chosen = [0u8; 2];
    stream.read_exact(&mut chosen).await?;
    if chosen[0] != VERSION {
        return Err(SocksError::Protocol(format!("server version {}", chosen[0])));
    }
    if chosen[1] != method {
        return Err(SocksError::Protocol(format!("server selected method 0x{:02x}", chosen[1])));
    }
    if let Some(token) = token {
        let length = u8::try_from(token.len())
            .map_err(|_| SocksError::Protocol("client token longer than 255 bytes".into()))?;
        let mut auth = Zeroizing::new(Vec::with_capacity(3 + TOKEN_USERNAME.len() + token.len()));
        auth.push(USER_PASSWORD_VERSION);
        auth.push(TOKEN_USERNAME.len() as u8);
        auth.extend_from_slice(TOKEN_USERNAME);
        auth.push(length);
        auth.extend_from_slice(token);
        stream.write_all(&auth).await?;
        let mut status = [0u8; 2];
        stream.read_exact(&mut status).await?;
        if status != [USER_PASSWORD_VERSION, AUTH_SUCCEEDED] {
            return Err(SocksError::Protocol("hub refused the client token".into()));
        }
    }

    let mut request = vec![VERSION, COMMAND_CONNECT, 0x00];
    push_address(&mut request, target);
    stream.write_all(&request).await?;

    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != VERSION {
        return Err(SocksError::Protocol(format!("reply version {}", head[0])));
    }
    // Drain the bound address so the stream is positioned at the payload.
    let _ = read_address(stream, head[3]).await?;
    if head[1] != REPLY_SUCCEEDED {
        return Err(SocksError::Reply(head[1]));
    }
    Ok(())
}

// ---- server side -----------------------------------------------------------

/// Negotiate the method with a client. Without a `token` the server accepts
/// only no-auth; with one it accepts only username/password whose password
/// equals the token (compared in constant time). Returns `true` when the
/// client may send a request; `false` after refusing it.
pub(crate) async fn server_greet<S>(
    stream: &mut S,
    token: Option<&[u8]>,
) -> Result<bool, SocksError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut head = [0u8; 2];
    stream.read_exact(&mut head).await?;
    if head[0] != VERSION {
        return Err(SocksError::Protocol(format!("client version {}", head[0])));
    }
    let mut methods = vec![0u8; usize::from(head[1])];
    stream.read_exact(&mut methods).await?;
    let method = if token.is_some() { METHOD_USER_PASSWORD } else { METHOD_NO_AUTH };
    if !methods.contains(&method) {
        stream.write_all(&[VERSION, METHOD_UNACCEPTABLE]).await?;
        return Ok(false);
    }
    stream.write_all(&[VERSION, method]).await?;
    let Some(token) = token else { return Ok(true) };

    let mut version = [0u8; 1];
    stream.read_exact(&mut version).await?;
    if version[0] != USER_PASSWORD_VERSION {
        return Err(SocksError::Protocol(format!("auth version {}", version[0])));
    }
    let username_length = usize::from(stream.read_u8().await?);
    let mut username = vec![0u8; username_length];
    stream.read_exact(&mut username).await?;
    let password_length = usize::from(stream.read_u8().await?);
    let mut password = Zeroizing::new(vec![0u8; password_length]);
    stream.read_exact(&mut password).await?;
    let accepted = password.len() == token.len() && bool::from(password.as_slice().ct_eq(token));
    let status = if accepted { AUTH_SUCCEEDED } else { AUTH_FAILED };
    stream.write_all(&[USER_PASSWORD_VERSION, status]).await?;
    Ok(accepted)
}

/// Read one request after a successful greeting.
pub(crate) async fn server_read_request<S>(stream: &mut S) -> Result<Request, SocksError>
where
    S: AsyncRead + Unpin,
{
    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != VERSION {
        return Err(SocksError::Protocol(format!("request version {}", head[0])));
    }
    let target = read_address(stream, head[3]).await?;
    Ok(Request { command: head[1], target })
}

/// Write a reply. `bound` is the server-side address of the tunneled
/// connection on success; failures report an all-zero IPv4 binding.
pub(crate) async fn server_reply<S>(
    stream: &mut S,
    code: u8,
    bound: Option<SocketAddr>,
) -> Result<(), SocksError>
where
    S: AsyncWrite + Unpin,
{
    let mut reply = vec![VERSION, code, 0x00];
    push_address(
        &mut reply,
        bound.unwrap_or_else(|| SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)),
    );
    stream.write_all(&reply).await?;
    Ok(())
}

fn push_address(buffer: &mut Vec<u8>, address: SocketAddr) {
    match address.ip() {
        IpAddr::V4(ip) => {
            buffer.push(ADDRESS_IPV4);
            buffer.extend_from_slice(&ip.octets());
        }
        IpAddr::V6(ip) => {
            buffer.push(ADDRESS_IPV6);
            buffer.extend_from_slice(&ip.octets());
        }
    }
    buffer.extend_from_slice(&address.port().to_be_bytes());
}

async fn read_address<S>(stream: &mut S, address_type: u8) -> Result<Target, SocksError>
where
    S: AsyncRead + Unpin,
{
    match address_type {
        ADDRESS_IPV4 => {
            let mut octets = [0u8; 4];
            stream.read_exact(&mut octets).await?;
            let port = read_port(stream).await?;
            Ok(Target::Ip(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(octets)), port)))
        }
        ADDRESS_IPV6 => {
            let mut octets = [0u8; 16];
            stream.read_exact(&mut octets).await?;
            let port = read_port(stream).await?;
            Ok(Target::Ip(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(octets)), port)))
        }
        ADDRESS_DOMAIN => {
            let length = usize::from(stream.read_u8().await?);
            if length == 0 || length > MAX_DOMAIN_BYTES {
                return Err(SocksError::Protocol(format!("domain length {length}")));
            }
            let mut name = vec![0u8; length];
            stream.read_exact(&mut name).await?;
            let port = read_port(stream).await?;
            Ok(Target::Domain { name: String::from_utf8_lossy(&name).into_owned(), port })
        }
        other => Err(SocksError::Protocol(format!("address type 0x{other:02x}"))),
    }
}

async fn read_port<S>(stream: &mut S) -> Result<u16, SocksError>
where
    S: AsyncRead + Unpin,
{
    let mut port = [0u8; 2];
    stream.read_exact(&mut port).await?;
    Ok(u16::from_be_bytes(port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn client_and_server_halves_agree_on_the_wire() {
        let (mut client, mut server) = tokio::io::duplex(256);
        let target: SocketAddr = "[fd7a::10]:1337".parse().unwrap();
        let server_side = async {
            assert!(server_greet(&mut server, None).await.unwrap());
            let request = server_read_request(&mut server).await.unwrap();
            assert_eq!(request.command, COMMAND_CONNECT);
            assert_eq!(request.target, Target::Ip(target));
            server_reply(&mut server, REPLY_SUCCEEDED, Some("100.64.0.1:50000".parse().unwrap()))
                .await
                .unwrap();
        };
        let client_side = async { client_connect(&mut client, target, None).await.unwrap() };
        tokio::join!(server_side, client_side);
    }

    #[tokio::test]
    async fn a_client_with_the_token_is_admitted() {
        let (mut client, mut server) = tokio::io::duplex(256);
        let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
        let server_side = async {
            assert!(server_greet(&mut server, Some(b"secret-token")).await.unwrap());
            let request = server_read_request(&mut server).await.unwrap();
            assert_eq!(request.target, Target::Ip(target));
            server_reply(&mut server, REPLY_SUCCEEDED, None).await.unwrap();
        };
        let client_side =
            async { client_connect(&mut client, target, Some(b"secret-token")).await.unwrap() };
        tokio::join!(server_side, client_side);
    }

    #[tokio::test]
    async fn a_hub_with_a_token_refuses_wrong_and_missing_tokens() {
        let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
        for offered in [Some(&b"wrong-token!"[..]), Some(&b"short"[..]), None] {
            let (mut client, mut server) = tokio::io::duplex(256);
            let (admitted, connected) = tokio::join!(
                server_greet(&mut server, Some(b"secret-token")),
                client_connect(&mut client, target, offered),
            );
            assert!(!admitted.unwrap(), "{offered:?} must not be admitted");
            assert!(connected.is_err(), "{offered:?} must not connect");
        }
    }

    #[tokio::test]
    async fn a_hub_without_a_token_refuses_username_password() {
        let (mut client, mut server) = tokio::io::duplex(256);
        let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
        let (admitted, connected) = tokio::join!(
            server_greet(&mut server, None),
            client_connect(&mut client, target, Some(b"secret-token")),
        );
        assert!(!admitted.unwrap());
        assert!(connected.is_err());
    }
}
