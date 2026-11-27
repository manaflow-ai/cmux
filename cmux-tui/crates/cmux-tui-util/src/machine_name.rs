//! This machine's name for `identify.machine_name` (capability
//! `session-identity-v1`) and the home session's registry row.

/// Longest reported machine name, in bytes.
pub const MAX_MACHINE_NAME_BYTES: usize = 255;

/// This machine's host name, bounded and free of control characters, for
/// `identify.machine_name` and the home session row.
pub fn machine_name() -> String {
    let raw = host_name().unwrap_or_default();
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
