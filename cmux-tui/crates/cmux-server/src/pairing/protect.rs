//! Windows keys use current-user DPAPI; Unix keys require the private file.

use crate::error::{Error, Result};

#[cfg(not(windows))]
const POSIX: &str = "posix-private-file-v1";
#[cfg(windows)]
const DPAPI: &str = "windows-dpapi-user-v1";

pub(super) fn supported(protection: &str) -> bool {
    #[cfg(windows)]
    {
        protection == DPAPI
    }
    #[cfg(not(windows))]
    {
        protection == POSIX
    }
}

pub(super) fn seal(bytes: &[u8]) -> Result<(&'static str, Vec<u8>)> {
    #[cfg(windows)]
    {
        Ok((DPAPI, windows::crypt(bytes, true)?))
    }
    #[cfg(not(windows))]
    {
        Ok((POSIX, bytes.to_vec()))
    }
}

pub(super) fn open(protection: &str, bytes: &[u8]) -> Result<Vec<u8>> {
    #[cfg(windows)]
    if protection == DPAPI {
        return windows::crypt(bytes, false);
    }
    #[cfg(not(windows))]
    if protection == POSIX {
        return Ok(bytes.to_vec());
    }
    Err(Error::verification("server.pair.key_protection_mismatch"))
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::ffi::c_void;

    #[repr(C)]
    struct Blob {
        len: u32,
        data: *mut u8,
    }

    #[link(name = "crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            input: *const Blob,
            description: *const u16,
            entropy: *const Blob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            input: *const Blob,
            description: *mut *mut u16,
            entropy: *const Blob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }

    pub(super) fn crypt(bytes: &[u8], seal: bool) -> Result<Vec<u8>> {
        let input = Blob {
            len: u32::try_from(bytes.len())
                .map_err(|_| Error::verification("server.pair.key_protection_failed"))?,
            data: bytes.as_ptr().cast_mut(),
        };
        let mut output = Blob { len: 0, data: std::ptr::null_mut() };
        // SAFETY: input lives across the call; optional parameters are null.
        // DPAPI allocates output with LocalAlloc. UI is forbidden (flag 1).
        let ok = unsafe {
            if seal {
                CryptProtectData(
                    &input,
                    std::ptr::null(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    1,
                    &mut output,
                )
            } else {
                CryptUnprotectData(
                    &input,
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    1,
                    &mut output,
                )
            }
        };
        if ok == 0 || output.data.is_null() {
            return Err(Error::verification("server.pair.key_protection_failed"));
        }
        // SAFETY: successful DPAPI output is a live buffer of output.len bytes.
        let result =
            unsafe { std::slice::from_raw_parts(output.data, output.len as usize).to_vec() };
        // SAFETY: DPAPI's allocation must be released with LocalFree once.
        unsafe {
            LocalFree(output.data.cast());
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_pairing_key_protection_roundtrips_and_refuses_another_protection_kind() {
        let plaintext = b"owned fixture private material";
        let (kind, bytes) = seal(plaintext).unwrap();
        assert_eq!(open(kind, &bytes).unwrap(), plaintext);
        assert!(open("unknown-protection", &bytes).is_err());
        #[cfg(windows)]
        assert_ne!(bytes, plaintext);
    }
}
