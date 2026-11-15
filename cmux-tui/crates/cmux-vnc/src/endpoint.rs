//! VNC addresses as people type them.

use std::fmt;

/// The first VNC display's TCP port.
pub const BASE_PORT: u16 = 5900;

/// A host and TCP port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.host.contains(':') {
            write!(f, "[{}]:{}", self.host, self.port)
        } else {
            write!(f, "{}:{}", self.host, self.port)
        }
    }
}

impl Endpoint {
    /// Parses the usual forms: `host` (display 0), `host:N` (display N
    /// below 100, else a port), `host::port`, `[v6]:port`, and
    /// `vnc://host[:port]`.
    pub fn parse(text: &str) -> Result<Self, String> {
        let text = text.trim();
        let (text, url) = match text.strip_prefix("vnc://") {
            Some(rest) => (rest.trim_end_matches('/'), true),
            None => (text, false),
        };
        if text.is_empty() {
            return Err("an empty VNC address".into());
        }
        let port = |value: &str, display_form: bool| -> Result<u16, String> {
            let number: u32 =
                value.parse().map_err(|_| format!("bad port or display \"{value}\""))?;
            let port = if display_form && !url && number < 100 {
                u32::from(BASE_PORT) + number
            } else {
                number
            };
            u16::try_from(port)
                .ok()
                .filter(|&p| p > 0)
                .ok_or_else(|| format!("port {port} out of range"))
        };
        if let Some(rest) = text.strip_prefix('[') {
            let (host, tail) = rest.split_once(']').ok_or("an unclosed [ in the address")?;
            let port = match tail {
                "" => BASE_PORT,
                tail => match tail.strip_prefix("::") {
                    Some(raw) => port(raw, false)?,
                    None => port(tail.strip_prefix(':').ok_or("text after ]")?, true)?,
                },
            };
            return Ok(Self { host: host.to_owned(), port });
        }
        if let Some((host, raw)) = text.split_once("::")
            && !raw.contains(':')
        {
            return Ok(Self { host: host.to_owned(), port: port(raw, false)? });
        }
        match text.matches(':').count() {
            0 => Ok(Self { host: text.to_owned(), port: BASE_PORT }),
            1 => {
                let (host, raw) = text.split_once(':').unwrap_or((text, ""));
                Ok(Self { host: host.to_owned(), port: port(raw, true)? })
            }
            // A bare IPv6 address.
            _ => Ok(Self { host: text.to_owned(), port: BASE_PORT }),
        }
    }
}

#[cfg(test)]
mod tests;
