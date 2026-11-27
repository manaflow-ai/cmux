//! A `multipart/form-data` body, built by hand (RFC 7578): a few text fields and one file.

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};

/// One form field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Part<'a> {
    pub name: &'a str,
    pub value: &'a [u8],
    /// `(filename, content type)` for a file field.
    pub file: Option<(&'a str, &'a str)>,
}

impl<'a> Part<'a> {
    pub fn text(name: &'a str, value: &'a str) -> Self {
        Self { name, value: value.as_bytes(), file: None }
    }

    pub fn file(name: &'a str, filename: &'a str, content_type: &'a str, value: &'a [u8]) -> Self {
        Self { name, value, file: Some((filename, content_type)) }
    }
}

/// The body's `Content-Type` header value.
pub fn content_type(boundary: &str) -> String {
    format!("multipart/form-data; boundary={boundary}")
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && haystack.windows(needle.len()).any(|w| w == needle)
}

/// A boundary that appears in none of the parts' values.
pub fn boundary(parts: &[Part<'_>]) -> String {
    let random = || {
        let mut h = RandomState::new().build_hasher();
        h.write_u8(0);
        h.finish()
    };
    loop {
        let candidate = format!("cmux-voice-{:016x}{:016x}", random(), random());
        if !parts.iter().any(|p| contains(p.value, candidate.as_bytes())) {
            return candidate;
        }
    }
}

/// The body: each part as `--boundary`, its headers and its value, then `--boundary--`.
pub fn body(boundary: &str, parts: &[Part<'_>]) -> Vec<u8> {
    let size: usize =
        parts.iter().fold(64, |n, p| n.saturating_add(p.value.len()).saturating_add(160));
    let mut out = Vec::with_capacity(size);
    for part in parts {
        out.extend_from_slice(b"--");
        out.extend_from_slice(boundary.as_bytes());
        out.extend_from_slice(b"\r\n");
        let name = quote(part.name);
        match part.file {
            Some((filename, content_type)) => {
                out.extend_from_slice(
                    format!(
                        "Content-Disposition: form-data; name=\"{name}\"; filename=\"{}\"\r\nContent-Type: {content_type}\r\n\r\n",
                        quote(filename)
                    )
                    .as_bytes(),
                );
            }
            None => {
                out.extend_from_slice(
                    format!("Content-Disposition: form-data; name=\"{name}\"\r\n\r\n").as_bytes(),
                );
            }
        }
        out.extend_from_slice(part.value);
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(b"--");
    out.extend_from_slice(boundary.as_bytes());
    out.extend_from_slice(b"--\r\n");
    out
}

/// A field or file name with `"`, CR and LF percent-encoded (RFC 7578 4.2).
fn quote(name: &str) -> String {
    name.replace('"', "%22").replace('\r', "%0D").replace('\n', "%0A")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_bytes_are_exact() {
        let parts = [
            Part::file("file", "recording.wav", "audio/wav", b"RIFF\x00\x01WAVE"),
            Part::text("model", "whisper-1"),
            Part::text("response_format", "json"),
        ];
        let got = body("B0", &parts);
        let mut want = Vec::new();
        want.extend_from_slice(
            b"--B0\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n",
        );
        want.extend_from_slice(b"RIFF\x00\x01WAVE\r\n");
        want.extend_from_slice(
            b"--B0\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n",
        );
        want.extend_from_slice(
            b"--B0\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n",
        );
        want.extend_from_slice(b"--B0--\r\n");
        assert_eq!(String::from_utf8_lossy(&got), String::from_utf8_lossy(&want));
        assert_eq!(got, want);
        assert_eq!(content_type("B0"), "multipart/form-data; boundary=B0");
    }

    #[test]
    fn boundary_never_appears_in_a_value_and_names_are_quoted() {
        let parts = [Part::text("a", "cmux-voice-")];
        let b = boundary(&parts);
        assert!(b.starts_with("cmux-voice-") && b.len() > 40);
        assert_ne!(boundary(&parts), b, "fresh each time");
        assert_eq!(quote("a\"b\r\nc"), "a%22b%0D%0Ac");
    }
}
