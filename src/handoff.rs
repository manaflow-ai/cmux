//! Local CodeRouter handoff input.
//!
//! cmux authenticates the native caller, obtains a short-lived handoff lease,
//! and passes the lease to `cr` through an inherited pipe.  The lease is never
//! accepted from an ordinary environment variable or a command argument.

use std::env;
use std::io::Read;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::cli::Error;

/// The environment variable contains only a file-descriptor number.  It does
/// not contain a lease or any other credential.
pub const HANDOFF_FD_ENV: &str = "CODEROUTER_HANDOFF_FD";

/// The protocol uses a 32-byte random value encoded as unpadded base64url.
/// Keep the read bound below the server's 2 KiB handoff body bound.
const MAX_HANDOFF_INPUT_BYTES: usize = 2 * 1024;
const HANDOFF_READ_TIMEOUT: Duration = Duration::from_secs(2);
const LEASE_PREFIX: &str = "crh_";
const LEASE_SUFFIX_LENGTH: usize = 43;

/// Return whether the caller requested the inherited-FD handoff path.
///
/// This deliberately checks only the non-secret descriptor marker.  A lease
/// in an environment variable is never accepted.
pub fn requested() -> bool {
    env::var_os(HANDOFF_FD_ENV).is_some()
}

/// Consume one handoff lease from the inherited descriptor, if requested.
///
/// The returned value is zeroized when dropped.  Reading the descriptor takes
/// ownership of it, so it is closed as soon as this function returns (or
/// fails).  No fallback to a saved Stack session is allowed after a requested
/// handoff fails.
pub fn take_lease() -> Result<Option<Zeroizing<String>>, Error> {
    let Some(raw_fd) = env::var_os(HANDOFF_FD_ENV) else {
        return Ok(None);
    };
    let raw_fd = raw_fd
        .to_str()
        .ok_or_else(|| Error::Backend("coderouter handoff descriptor is invalid".into()))?;
    // cmux's native contract reserves descriptor 3 for this one frame.  A
    // fixed descriptor prevents an ambient caller from selecting an unrelated
    // inherited file that may contain a different credential.
    if raw_fd != "3" {
        return Err(Error::Backend(
            "coderouter handoff descriptor is invalid".into(),
        ));
    }
    let fd = 3;

    #[cfg(unix)]
    {
        read_fd(fd).map(Some)
    }

    #[cfg(not(unix))]
    {
        let _ = fd;
        Err(Error::Backend(
            "coderouter handoff requires an inherited file descriptor on this platform".into(),
        ))
    }
}

#[cfg(unix)]
fn read_fd(fd: i32) -> Result<Zeroizing<String>, Error> {
    use std::fs::File;
    use std::os::fd::{AsRawFd, FromRawFd};

    // SAFETY: the descriptor is supplied by the authenticated cmux parent and
    // is consumed exactly once. `File` owns and closes it on every path.
    let mut file = unsafe { File::from_raw_fd(fd) };
    let deadline = Instant::now() + HANDOFF_READ_TIMEOUT;
    // Allocate the full bounded frame once. This prevents reallocation from
    // leaving an older copy of the lease in freed heap memory.
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_HANDOFF_INPUT_BYTES));
    let mut chunk = Zeroizing::new([0_u8; 512]);
    loop {
        wait_for_readable(file.as_raw_fd(), deadline)?;
        match file.read(&mut chunk[..]) {
            Ok(0) => break,
            Ok(count) => {
                if bytes.len().saturating_add(count) > MAX_HANDOFF_INPUT_BYTES {
                    return Err(Error::Backend("coderouter handoff is too large".into()));
                }
                bytes.extend_from_slice(&chunk[..count]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(_) => return Err(Error::Backend("could not read coderouter handoff".into())),
        }
    }
    // cmux closes its writer before exec. Requiring EOF within the same read
    // deadline lets this check reject trailing bytes even when they arrive
    // after the first newline.
    let frame_end = bytes
        .iter()
        .position(|byte| *byte == b'\n')
        .ok_or_else(|| Error::Backend("coderouter handoff is missing its final newline".into()))?;
    if frame_end + 1 != bytes.len() {
        return Err(Error::Backend(
            "coderouter handoff has extra frame data".into(),
        ));
    }
    let lease = std::str::from_utf8(&bytes[..frame_end])
        .map_err(|_| Error::Backend("coderouter handoff is not valid UTF-8".into()))?;
    if !is_valid_lease(lease) {
        return Err(Error::Backend("coderouter handoff lease is invalid".into()));
    }
    Ok(Zeroizing::new(lease.to_owned()))
}

#[cfg(unix)]
fn wait_for_readable(fd: i32, deadline: Instant) -> Result<(), Error> {
    #[repr(C)]
    struct PollFd {
        fd: i32,
        events: i16,
        revents: i16,
    }
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    unsafe extern "C" {
        fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
    }
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Backend("coderouter handoff read timed out".into()));
        }
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128).max(1) as i32;
        let mut descriptor = PollFd {
            fd,
            events: POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd and remains
        // valid for the duration of the call.
        let result = unsafe { poll(&mut descriptor, 1, timeout_ms) };
        if result < 0 {
            continue;
        }
        if result == 0 {
            return Err(Error::Backend("coderouter handoff read timed out".into()));
        }
        if descriptor.revents & (POLLIN | POLLHUP) != 0 {
            return Ok(());
        }
        if descriptor.revents & (POLLERR | POLLNVAL) != 0 {
            return Err(Error::Backend("could not read coderouter handoff".into()));
        }
    }
}

/// Validate the wire syntax without ever including the value in an error.
pub fn is_valid_lease(value: &str) -> bool {
    let Some(suffix) = value.strip_prefix(LEASE_PREFIX) else {
        return false;
    };
    suffix.len() == LEASE_SUFFIX_LENGTH
        && suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_exact_protocol_lease_syntax() {
        assert!(is_valid_lease(
            "crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg"
        ));
        assert!(!is_valid_lease("crh_short"));
        assert!(!is_valid_lease(
            "crt_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk"
        ));
        assert!(!is_valid_lease(
            "crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef="
        ));
        assert!(!is_valid_lease(
            "crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg\n"
        ));
    }

    #[cfg(unix)]
    #[test]
    fn reads_one_newline_and_zeroizes_the_lease_container() {
        use std::io::Write;
        use std::os::fd::FromRawFd;

        let mut descriptors = [0_i32; 2];
        // Keep this test dependency-free.  `std::os::unix::net` does not
        // expose an anonymous pipe, so use the platform libc symbol locally.
        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }
        assert_eq!(unsafe { pipe(descriptors.as_mut_ptr()) }, 0);
        let mut writer = unsafe { std::fs::File::from_raw_fd(descriptors[1]) };
        writer
            .write_all(b"crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg\n")
            .unwrap();
        drop(writer);

        let value = read_fd(descriptors[0]).unwrap();
        assert!(is_valid_lease(&value));
    }

    #[cfg(unix)]
    #[test]
    fn valid_frame_with_open_writer_times_out() {
        use std::io::Write;
        use std::os::fd::FromRawFd;
        use std::time::Instant;

        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }

        let mut descriptors = [0_i32; 2];
        assert_eq!(unsafe { pipe(descriptors.as_mut_ptr()) }, 0);
        let mut writer = unsafe { std::fs::File::from_raw_fd(descriptors[1]) };
        writer
            .write_all(b"crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg\n")
            .unwrap();

        let started = Instant::now();
        let error = read_fd(descriptors[0]).unwrap_err();
        drop(writer);
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn partial_open_writer_times_out_and_closes_the_read_descriptor() {
        use std::io::Write;
        use std::os::fd::FromRawFd;
        use std::time::Instant;

        let mut descriptors = [0_i32; 2];
        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }
        assert_eq!(unsafe { pipe(descriptors.as_mut_ptr()) }, 0);
        let mut writer = unsafe { std::fs::File::from_raw_fd(descriptors[1]) };
        writer.write_all(b"crh_partial").unwrap();

        let started = Instant::now();
        let error = read_fd(descriptors[0]).unwrap_err();
        drop(writer);
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn missing_newline_and_extra_frame_data_are_rejected() {
        use std::io::Write;
        use std::os::fd::FromRawFd;

        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }

        let mut missing = [0_i32; 2];
        assert_eq!(unsafe { pipe(missing.as_mut_ptr()) }, 0);
        let mut writer = unsafe { std::fs::File::from_raw_fd(missing[1]) };
        writer
            .write_all(b"crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg")
            .unwrap();
        drop(writer);
        assert!(
            read_fd(missing[0])
                .unwrap_err()
                .to_string()
                .contains("newline")
        );

        let mut extra = [0_i32; 2];
        assert_eq!(unsafe { pipe(extra.as_mut_ptr()) }, 0);
        let mut writer = unsafe { std::fs::File::from_raw_fd(extra[1]) };
        writer
            .write_all(b"crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg\nsecond")
            .unwrap();
        drop(writer);
        assert!(
            read_fd(extra[0])
                .unwrap_err()
                .to_string()
                .contains("extra frame")
        );
    }

    #[cfg(unix)]
    #[test]
    fn delayed_trailing_bytes_before_eof_are_rejected() {
        use std::io::Write;
        use std::os::fd::FromRawFd;

        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }

        let mut descriptors = [0_i32; 2];
        assert_eq!(unsafe { pipe(descriptors.as_mut_ptr()) }, 0);
        let read_descriptor = descriptors[0];
        let write_descriptor = descriptors[1];
        let writer = std::thread::spawn(move || {
            let mut writer = unsafe { std::fs::File::from_raw_fd(write_descriptor) };
            writer
                .write_all(b"crh_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg\n")
                .unwrap();
            std::thread::sleep(Duration::from_millis(50));
            writer.write_all(b"extra").unwrap();
        });

        let error = read_fd(read_descriptor).unwrap_err();
        writer.join().unwrap();
        assert!(error.to_string().contains("extra frame"));
    }
}
