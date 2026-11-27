//! The rules Packages/Shared/CmuxVNC (Swift) asks over `vnc_*` JSON ops,
//! with that package's contract where it differs from this crate's own client:
//! the address form people paste (`vnc://user:pass@host`), the keysym of a
//! HID usage, and the security choice that never sends an account password
//! as a VNC password. The Swift package keeps the sockets, the reader and the
//! decoders; these are the decisions it used to make itself.

use crate::auth::security;
use crate::endpoint::BASE_PORT;

/// A parsed address and any credentials a `vnc://` URL carried
/// (VNCEndpoint.parse in Swift).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
}

/// `host`, `host:port`, `host:N` (display N, port 5900 + N below 100),
/// `host::port`, `[v6]:port`, or `vnc://[user[:password]@]host[:port]`;
/// any path or query is dropped. `None`: not an address.
pub fn parse_address(raw: &str) -> Option<Address> {
    let mut text = raw.trim();
    if text.get(..6).is_some_and(|scheme| scheme.eq_ignore_ascii_case("vnc://")) {
        text = text.get(6..).unwrap_or_default();
    }
    if let Some(cut) = text.find(['/', '?']) {
        text = text.get(..cut).unwrap_or_default();
    }
    let (mut username, mut password) = (None, None);
    if let Some(at) = text.rfind('@') {
        let info = text.get(..at).unwrap_or_default();
        text = text.get(at + 1..).unwrap_or_default();
        match info.split_once(':') {
            Some((user, pass)) => {
                username = percent_decode(user);
                password = percent_decode(pass);
            }
            None => username = percent_decode(info),
        }
    }
    let username = username.filter(|s| !s.is_empty());
    let password = password.filter(|s| !s.is_empty());
    if text.is_empty() {
        return None;
    }
    let address = |host: &str, port: u16| Address {
        host: host.to_owned(),
        port,
        username: username.clone(),
        password: password.clone(),
    };
    if let Some(rest) = text.strip_prefix('[')
        && let Some((host, tail)) = rest.split_once(']')
    {
        let port = match tail.strip_prefix(':') {
            Some(raw) => raw.parse::<u16>().ok()?,
            None => BASE_PORT,
        };
        return (!host.is_empty()).then(|| address(host, port));
    }
    if let Some((host, raw)) = text.split_once("::") {
        let port = raw.parse::<u16>().ok()?;
        return (!host.is_empty()).then(|| address(host, port));
    }
    if let Some((host, raw)) = text.rsplit_once(':') {
        let value: i64 = raw.parse().ok()?;
        if host.is_empty() || !(0..=65535).contains(&value) {
            return None;
        }
        let port = if value < 100 { BASE_PORT as i64 + value } else { value };
        return Some(address(host, port as u16));
    }
    Some(address(text, BASE_PORT))
}

/// Foundation's `removingPercentEncoding`: `None` for a bad escape or bytes
/// that are not UTF-8.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while let Some(&byte) = bytes.get(i) {
        if byte == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(byte);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `host:port`, IPv6 hosts in brackets.
pub fn label(host: &str, port: u16) -> String {
    if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") }
}

/// The keysym for a typed character (one grapheme's first scalar): Latin-1
/// as itself, other Unicode in the 0x01000000 plane, newlines and tab as
/// their keys. An empty string is `?`.
pub fn character_keysym(character: &str) -> u32 {
    if matches!(character, "\n" | "\r" | "\r\n") {
        return 0xFF0D;
    }
    if character == "\t" {
        return 0xFF09;
    }
    let value = character.chars().next().map_or(0x3F, u32::from);
    if value <= 0xFF { value } else { 0x0100_0000 | value }
}

/// F1 to F24, clamped.
pub fn function_keysym(number: i64) -> u32 {
    0xFFBE + (number.clamp(1, 24) - 1) as u32
}

/// The keysym of a physical key by USB HID usage (keyboard page 7, as
/// `0x07 << 16 | id` or the bare id), as on a US layout; `None` for a key
/// RFB has no keysym for.
pub fn hid_keysym(usage: u32) -> Option<u32> {
    let page = usage >> 16;
    if page != 0 && page != 7 {
        return None;
    }
    let id = usage & 0xFFFF;
    Some(match id {
        0x04..=0x1D => 0x61 + id - 0x04,
        0x1E..=0x26 => 0x31 + id - 0x1E,
        0x27 => 0x30,
        0x3A..=0x45 => function_keysym(i64::from(id - 0x3A) + 1),
        0x68..=0x73 => function_keysym(i64::from(id - 0x68) + 13),
        0x59..=0x61 => 0xFFB1 + id - 0x59,
        _ => return HID_TABLE.iter().find(|(key, _)| *key == id).map(|(_, sym)| *sym),
    })
}

const HID_TABLE: [(u32, u32); 50] = [
    (0x28, 0xFF0D),
    (0x29, 0xFF1B),
    (0x2A, 0xFF08),
    (0x2B, 0xFF09),
    (0x2C, 0x20),
    (0x2D, 0x2D),
    (0x2E, 0x3D),
    (0x2F, 0x5B),
    (0x30, 0x5D),
    (0x31, 0x5C),
    (0x32, 0x5C),
    (0x33, 0x3B),
    (0x34, 0x27),
    (0x35, 0x60),
    (0x36, 0x2C),
    (0x37, 0x2E),
    (0x38, 0x2F),
    (0x39, 0xFFE5),
    (0x46, 0xFF61),
    (0x47, 0xFF14),
    (0x48, 0xFF13),
    (0x49, 0xFF63),
    (0x4A, 0xFF50),
    (0x4B, 0xFF55),
    (0x4C, 0xFFFF),
    (0x4D, 0xFF57),
    (0x4E, 0xFF56),
    (0x4F, 0xFF53),
    (0x50, 0xFF51),
    (0x51, 0xFF54),
    (0x52, 0xFF52),
    (0x53, 0xFF7F),
    (0x54, 0xFFAF),
    (0x55, 0xFFAA),
    (0x56, 0xFFAD),
    (0x57, 0xFFAB),
    (0x58, 0xFF8D),
    (0x62, 0xFFB0),
    (0x63, 0xFFAE),
    (0x64, 0x3C),
    (0x67, 0xFFBD),
    (0x75, 0xFF6A),
    (0xE0, 0xFFE3),
    (0xE1, 0xFFE1),
    (0xE2, 0xFFE9),
    (0xE3, 0xFFEB),
    (0xE4, 0xFFE4),
    (0xE5, 0xFFE2),
    (0xE6, 0xFFEA),
    (0xE7, 0xFFEC),
];

/// Why no security type was chosen (Swift's `RFBError` cases).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// Apple DH needs a user name and password.
    CredentialsRequired,
    /// VNC authentication needs a password.
    PasswordRequired,
    /// None of the offered types is one this client speaks.
    NoSupportedSecurityType(Vec<u8>),
}

/// Apple DH when a user name is known, then the VNC password, then none. A
/// sign-in with a user name is an account password: it never goes out as a
/// VNC password response (8 bytes, DES, offline-crackable).
pub fn choose_security(
    offered: &[u8],
    has_username: bool,
    has_password: bool,
) -> Result<u8, Refusal> {
    use security::{APPLE_DH, NONE, VNC};
    if offered.contains(&APPLE_DH) && has_password && has_username {
        return Ok(APPLE_DH);
    }
    if offered.contains(&VNC) && has_password && !has_username {
        return Ok(VNC);
    }
    if offered.contains(&NONE) {
        return Ok(NONE);
    }
    if offered.contains(&APPLE_DH) {
        return Err(Refusal::CredentialsRequired);
    }
    if offered.contains(&VNC) {
        return Err(Refusal::PasswordRequired);
    }
    Err(Refusal::NoSupportedSecurityType(offered.to_vec()))
}

/// RFB 3.3's server-chosen type (a 32-bit word: 258 is not type 2): the type,
/// or why the session cannot go on. 0 is the server's refusal, which the
/// caller reads the reason for.
pub fn server_chosen_security(word: u32, has_username: bool) -> Result<u8, Refusal> {
    match word {
        1 => Ok(security::NONE),
        2 if has_username => Err(Refusal::CredentialsRequired),
        2 => Ok(security::VNC),
        other => Err(Refusal::NoSupportedSecurityType(vec![other as u8])),
    }
}

/// The server's minor version from its 12-byte banner (`RFB 003.008\n`;
/// Apple sends 003.889), or `None` for anything that is not RFB 3.x.
pub fn server_minor(banner: &[u8]) -> Option<u32> {
    let text = String::from_utf8_lossy(banner);
    let rest = text.strip_prefix("RFB 003.")?;
    let digits: String = rest.chars().take(3).collect();
    digits.parse().ok()
}

/// The minor this client answers with: 8 for any 8 or later, 7 for 7, else 3.
pub fn client_minor(server_minor: u32) -> u32 {
    match server_minor {
        8.. => 8,
        7 => 7,
        _ => 3,
    }
}

#[cfg(test)]
#[path = "rules_tests.rs"]
mod tests;
