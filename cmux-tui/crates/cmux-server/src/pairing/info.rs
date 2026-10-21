//! Local facts for the approving person; no subprocess or credential reads.

pub(crate) fn name() -> String {
    #[cfg(unix)]
    {
        let mut buffer = [0u8; 256];
        // SAFETY: the buffer is writable; one byte stays zero for termination.
        if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len() - 1) } == 0
            && let Ok(name) = std::ffi::CStr::from_bytes_until_nul(&buffer)
            && let Ok(name) = name.to_str()
            && !name.is_empty()
        {
            return name.split('.').next().unwrap_or(name).to_owned();
        }
    }
    std::env::var("COMPUTERNAME")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "cmux-server".into())
}

pub(crate) fn os_version() -> String {
    #[cfg(target_os = "macos")]
    {
        let mut buffer = [0u8; 128];
        let mut size = buffer.len();
        // SAFETY: sysctl writes at most size bytes into this live buffer.
        if unsafe {
            libc::sysctlbyname(
                c"kern.osproductversion".as_ptr(),
                buffer.as_mut_ptr().cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0
            && let Ok(value) = std::ffi::CStr::from_bytes_until_nul(&buffer)
            && let Ok(value) = value.to_str()
        {
            return value.into();
        }
    }
    #[cfg(unix)]
    {
        let mut name = std::mem::MaybeUninit::<libc::utsname>::uninit();
        // SAFETY: uname fills the struct on success, including terminated fields.
        if unsafe { libc::uname(name.as_mut_ptr()) } == 0 {
            // SAFETY: the successful uname call initialized the struct.
            let name = unsafe { name.assume_init() };
            // SAFETY: POSIX uname release is a terminated C string.
            if let Ok(value) = unsafe { std::ffi::CStr::from_ptr(name.release.as_ptr()) }.to_str() {
                return value.into();
            }
        }
    }
    String::new()
}
