//! The RFB handshake: version, security, ClientInit and ServerInit
//! (RFC 6143 7.1 to 7.3).

use std::io::{Read, Write};

use crate::auth::{self, Credentials, ard, des, security, vencrypt};
use crate::error::{Result, VncError};
use crate::pixel::PixelFormat;
use crate::wire::WireReader;

/// The protocol version both sides agreed on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Version {
    V3_3,
    V3_7,
    V3_8,
}

impl Version {
    /// The version to answer a server's 12-byte banner with. Any 3.x at or
    /// above 8 (Apple sends 003.889) is 3.8; 3.7 is 3.7; anything older,
    /// including UltraVNC's 3.4/3.6, is 3.3.
    pub fn negotiate(banner: &[u8; 12]) -> Result<Self> {
        let text = std::str::from_utf8(banner).unwrap_or("");
        let parsed = text
            .strip_prefix("RFB ")
            .and_then(|rest| rest.strip_suffix('\n'))
            .and_then(|rest| rest.split_once('.'))
            .and_then(|(major, minor)| {
                Some((major.parse::<u32>().ok()?, minor.parse::<u32>().ok()?))
            });
        match parsed {
            Some((major, _)) if major > 3 => Ok(Self::V3_8),
            Some((3, minor)) if minor >= 8 => Ok(Self::V3_8),
            Some((3, 7)) => Ok(Self::V3_7),
            Some((3, _)) => Ok(Self::V3_3),
            _ => Err(VncError::protocol(format!(
                "not an RFB server (banner {:?})",
                crate::wire::latin1(banner)
            ))),
        }
    }

    pub fn banner(self) -> &'static [u8; 12] {
        match self {
            Self::V3_3 => b"RFB 003.003\n",
            Self::V3_7 => b"RFB 003.007\n",
            Self::V3_8 => b"RFB 003.008\n",
        }
    }
}

/// What the server said in ServerInit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInit {
    pub version: Version,
    pub security: u8,
    pub width: u16,
    pub height: u16,
    /// The server's native format (this client replaces it with
    /// [`PixelFormat::RGBX`] right after the handshake).
    pub format: PixelFormat,
    pub name: String,
}

/// Runs the handshake. `shared` keeps other viewers connected (the
/// ClientInit shared flag); a cmux pane always shares.
pub fn handshake<R: Read, W: Write>(
    reader: &mut WireReader<R>,
    writer: &mut W,
    credentials: &Credentials,
    shared: bool,
) -> Result<ServerInit> {
    let mut banner = [0u8; 12];
    reader.exact(&mut banner)?;
    let version = Version::negotiate(&banner)?;
    writer.write_all(version.banner())?;
    writer.flush()?;

    let security = if version == Version::V3_3 {
        let chosen = reader.u32()?;
        match chosen {
            0 => return Err(VncError::AuthFailed(reader.text("reason")?)),
            1 | 2 => chosen as u8,
            other => return Err(VncError::UnsupportedSecurity(vec![other.min(255) as u8])),
        }
    } else {
        let count = reader.u8()?;
        if count == 0 {
            return Err(VncError::AuthFailed(reader.text("reason")?));
        }
        let offered = reader.bytes(usize::from(count))?;
        let chosen = auth::choose(&offered, credentials)?;
        writer.write_all(&[chosen])?;
        writer.flush()?;
        chosen
    };

    match security {
        security::NONE => {}
        security::VNC => vnc_auth(reader, writer, credentials)?,
        security::APPLE_DH => apple_dh(reader, writer, credentials)?,
        security::VENCRYPT => vencrypt_auth(reader, writer, credentials)?,
        other => return Err(VncError::UnsupportedSecurity(vec![other])),
    }

    // SecurityResult: always in 3.8; in 3.3 and 3.7 only after a password.
    if version == Version::V3_8 || security != security::NONE {
        let result = reader.u32()?;
        if result != 0 {
            let reason =
                if version == Version::V3_8 { reader.text("reason")? } else { String::new() };
            return Err(VncError::AuthFailed(reason));
        }
    }

    writer.write_all(&[u8::from(shared)])?;
    writer.flush()?;

    let width = reader.u16()?;
    let height = reader.u16()?;
    let mut format = [0u8; 16];
    reader.exact(&mut format)?;
    let name = reader.text("desktop name")?;
    Ok(ServerInit { version, security, width, height, format: PixelFormat::parse(&format), name })
}

fn vnc_auth<R: Read, W: Write>(
    reader: &mut WireReader<R>,
    writer: &mut W,
    credentials: &Credentials,
) -> Result<()> {
    let password =
        credentials.password.as_deref().ok_or(VncError::CredentialsRequired { username: false })?;
    let mut challenge = [0u8; 16];
    reader.exact(&mut challenge)?;
    writer.write_all(&des::vnc_response(password.as_bytes(), challenge))?;
    writer.flush()?;
    Ok(())
}

fn apple_dh<R: Read, W: Write>(
    reader: &mut WireReader<R>,
    writer: &mut W,
    credentials: &Credentials,
) -> Result<()> {
    let (Some(username), Some(password)) = (&credentials.username, &credentials.password) else {
        return Err(VncError::CredentialsRequired { username: true });
    };
    let generator = reader.u16()?;
    let length = usize::from(reader.u16()?);
    if length == 0 || length > ard::MAX_KEY_BYTES {
        return Err(VncError::protocol(format!("Apple DH key of {length} bytes")));
    }
    let prime = reader.bytes(length)?;
    let server_key = reader.bytes(length)?;
    let mut private_key = vec![0u8; length];
    let mut padding = [0u8; 128];
    random(&mut private_key)?;
    random(&mut padding)?;
    let reply =
        ard::response(generator, &prime, &server_key, username, password, &private_key, padding)
            .ok_or_else(|| VncError::protocol("Apple DH parameters"))?;
    writer.write_all(&reply.encrypted_credentials)?;
    writer.write_all(&reply.client_public_key)?;
    writer.flush()?;
    Ok(())
}

fn vencrypt_auth<R: Read, W: Write>(
    reader: &mut WireReader<R>,
    writer: &mut W,
    credentials: &Credentials,
) -> Result<()> {
    let (major, minor) = (reader.u8()?, reader.u8()?);
    if (major, minor) < (0, 2) {
        return Err(VncError::protocol(format!("VeNCrypt {major}.{minor}")));
    }
    writer.write_all(&[0, 2])?;
    writer.flush()?;
    if reader.u8()? != 0 {
        return Err(VncError::protocol("the server refused VeNCrypt 0.2"));
    }
    let count = reader.u8()?;
    let mut offered = Vec::with_capacity(usize::from(count));
    for _ in 0..count {
        offered.push(reader.u32()?);
    }
    let chosen = auth::choose_vencrypt(&offered, credentials)?;
    writer.write_all(&chosen.to_be_bytes())?;
    writer.flush()?;
    match chosen {
        vencrypt::NONE => Ok(()),
        vencrypt::VNC => vnc_auth(reader, writer, credentials),
        // An unknown subtype must never fall through into a plaintext
        // username/password exchange, even if the selector gains new cases.
        _ => Err(VncError::protocol("unsupported VeNCrypt security subtype")),
    }
}

fn random(buf: &mut [u8]) -> Result<()> {
    getrandom::fill(buf).map_err(|error| VncError::Io(std::io::Error::other(error.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_negotiate_like_real_servers() {
        assert_eq!(Version::negotiate(b"RFB 003.008\n").unwrap(), Version::V3_8);
        assert_eq!(Version::negotiate(b"RFB 003.889\n").unwrap(), Version::V3_8, "macOS");
        assert_eq!(Version::negotiate(b"RFB 003.007\n").unwrap(), Version::V3_7);
        assert_eq!(Version::negotiate(b"RFB 003.006\n").unwrap(), Version::V3_3, "UltraVNC 1.0");
        assert_eq!(Version::negotiate(b"RFB 003.003\n").unwrap(), Version::V3_3);
        assert_eq!(Version::negotiate(b"RFB 004.001\n").unwrap(), Version::V3_8);
        assert!(Version::negotiate(b"SSH-2.0-Open").is_err());
    }
}
