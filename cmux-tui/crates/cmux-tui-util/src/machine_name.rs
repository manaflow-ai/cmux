//! This machine's name for `identify.machine_name` (capability
//! `session-identity-v1`) and the home session's registry row.

/// Longest reported machine name, in bytes.
pub const MAX_MACHINE_NAME_BYTES: usize = 255;

/// The launch variable that names a fixture machine: the cmux-next app passes
/// it to its daemon under PR capture and in the media tours
/// (`AppEnvironment.fixtureMachineNameKey`), so screenshots never show the CI
/// host's name.
pub const FIXTURE_MACHINE_NAME_ENV: &str = "CMUX_NEXT_FIXTURE_MACHINE_NAME";

/// This machine's host name, bounded and free of control characters, for
/// `identify.machine_name` and the home session row; the fixture name
/// (`FIXTURE_MACHINE_NAME_ENV`) when the environment gives one.
pub fn machine_name() -> String {
    pick(std::env::var(FIXTURE_MACHINE_NAME_ENV).ok(), host_name)
}

/// The fixture name when it is not blank, else `host`'s, bounded and free of
/// control characters, or `localhost`.
fn pick(fixture: Option<String>, host: impl FnOnce() -> Option<String>) -> String {
    let raw = fixture.filter(|name| !name.trim().is_empty()).or_else(host).unwrap_or_default();
    let mut name: String = raw.chars().filter(|ch| !ch.is_control()).collect();
    while name.len() > MAX_MACHINE_NAME_BYTES {
        name.pop();
    }
    let name = name.trim().to_string();
    if name.is_empty() { "localhost".to_string() } else { name }
}

#[cfg(unix)]
fn host_name() -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname writes at most
    // that many bytes and the result is read only up to the first NUL.
    let status = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if status != 0 {
        return None;
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    Some(String::from_utf8_lossy(&buffer[..end]).into_owned())
}

#[cfg(not(unix))]
fn host_name() -> Option<String> {
    std::env::var("COMPUTERNAME").ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fixture_name_replaces_the_host_name() {
        let host = || Some("build-host.local".to_string());
        assert_eq!(pick(Some("Studio Mac".into()), host), "Studio Mac");
        assert_eq!(pick(Some("  ".into()), host), "build-host.local");
        assert_eq!(pick(None, host), "build-host.local");
        assert_eq!(pick(None, || None), "localhost");
    }

    #[test]
    fn a_fixture_name_is_cleaned_like_a_host_name() {
        assert_eq!(pick(Some(" Studio\u{7}Mac ".into()), || None), "StudioMac");
        assert_eq!(pick(Some("x".repeat(300)), || None).len(), MAX_MACHINE_NAME_BYTES);
    }
}
