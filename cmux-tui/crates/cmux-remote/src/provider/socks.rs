//! The subset of SOCKS5 (RFC 1928) the WireGuard hub speaks: CONNECT, no
//! authentication, literal IP targets. Shared by the hub (server side) and
//! [`super::SocksDialer`] (client side) so the two cannot drift.

use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(crate) const VERSION: u8 = 0x05;
pub(crate) const METHOD_NO_AUTH: u8 = 0x00;
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

/// Run the client half of a SOCKS5 CONNECT for `target` over `stream`. On
/// success the stream carries the tunneled connection from here on.
pub(crate) async fn client_connect<S>(stream: &mut S, target: SocketAddr) -> Result<(), SocksError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    stream.write_all(&[VERSION, 1, METHOD_NO_AUTH]).await?;
    let mut chosen = [0u8; 2];
    stream.read_exact(&mut chosen).await?;
    if chosen[0] != VERSION {
        return Err(SocksError::Protocol(format!("server version {}", chosen[0])));
    }
    if chosen[1] != METHOD_NO_AUTH {
        return Err(SocksError::Protocol(format!("server selected method 0x{:02x}", chosen[1])));
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

/// Negotiate the method with a client. Returns `true` when no-auth was agreed
/// and the client may send a request; `false` after telling the client no
/// method was acceptable.
pub(crate) async fn server_greet<S>(stream: &mut S) -> Result<bool, SocksError>
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
    if methods.contains(&METHOD_NO_AUTH) {
        stream.write_all(&[VERSION, METHOD_NO_AUTH]).await?;
        Ok(true)
    } else {
        stream.write_all(&[VERSION, METHOD_UNACCEPTABLE]).await?;
        Ok(false)
    }
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
            assert!(server_greet(&mut server).await.unwrap());
            let request = server_read_request(&mut server).await.unwrap();
            assert_eq!(request.command, COMMAND_CONNECT);
            assert_eq!(request.target, Target::Ip(target));
            server_reply(&mut server, REPLY_SUCCEEDED, Some("100.64.0.1:50000".parse().unwrap()))
                .await
                .unwrap();
        };
        let client_side = async { client_connect(&mut client, target).await.unwrap() };
        tokio::join!(server_side, client_side);
    }

    #[tokio::test]
    async fn a_failure_reply_surfaces_its_code() {
        let (mut client, mut server) = tokio::io::duplex(256);
        let server_side = async {
            assert!(server_greet(&mut server).await.unwrap());
            let _ = server_read_request(&mut server).await.unwrap();
            server_reply(&mut server, REPLY_NOT_ALLOWED, None).await.unwrap();
        };
        let client_side = async {
            let error = client_connect(&mut client, "10.0.0.1:80".parse().unwrap()).await.unwrap_err();
            assert!(matches!(error, SocksError::Reply(REPLY_NOT_ALLOWED)), "{error}");
            assert!(error.to_string().contains("0x02"));
        };
        tokio::join!(server_side, client_side);
    }

    #[tokio::test]
    async fn a_client_offering_only_other_methods_is_refused() {
        let (mut client, mut server) = tokio::io::duplex(64);
        let server_side = async { assert!(!server_greet(&mut server).await.unwrap()) };
        let client_side = async {
            client.write_all(&[VERSION, 1, 0x02]).await.unwrap();
            let mut chosen = [0u8; 2];
            client.read_exact(&mut chosen).await.unwrap();
            assert_eq!(chosen, [VERSION, METHOD_UNACCEPTABLE]);
        };
        tokio::join!(server_side, client_side);
    }

    #[tokio::test]
    async fn domain_targets_parse_to_a_domain_request() {
        let (mut client, mut server) = tokio::io::duplex(256);
        let server_side = async {
            assert!(server_greet(&mut server).await.unwrap());
            let request = server_read_request(&mut server).await.unwrap();
            assert_eq!(
                request.target,
                Target::Domain { name: "example.com".into(), port: 443 }
            );
        };
        let client_side = async {
            client.write_all(&[VERSION, 1, METHOD_NO_AUTH]).await.unwrap();
            let mut chosen = [0u8; 2];
            client.read_exact(&mut chosen).await.unwrap();
            let mut request = vec![VERSION, COMMAND_CONNECT, 0, ADDRESS_DOMAIN, 11];
            request.extend_from_slice(b"example.com");
            request.extend_from_slice(&443u16.to_be_bytes());
            client.write_all(&request).await.unwrap();
        };
        tokio::join!(server_side, client_side);
    }
}
