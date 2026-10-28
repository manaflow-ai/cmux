//! The worker's sandbox: compiled by the daemon, applied by the worker
//! before the first ring byte.
//!
//! Chrome's model (`sandbox/mac/seatbelt_exec.cc`, `sandbox/mac/seatbelt.cc`):
//! the browser compiles the Seatbelt profile (`Seatbelt::Compile`, which is
//! `sandbox_compile_string`) and sends the compiled policy to the child,
//! which applies it (`Seatbelt::ApplyCompiledProfile`, `sandbox_apply`)
//! before it reads any untrusted input. The child never needs to read the
//! profile source or resolve parameters itself. The cmux daemon calls
//! [`compile_policy`] and sends the result in the BOOTSTRAP frame; the
//! worker calls [`apply`] and only then receives rings.
//!
//! The profile denies by default, as Chrome's utility profiles do: no
//! `mach-lookup`, `iokit-open`, `sysctl-write`, `process-fork`,
//! `process-exec`, network or socket creation, and no file reads except
//! `/usr/lib` and the dyld shared cache. What the worker still does works on
//! descriptors it already holds: reads and writes on its socket and mmap of
//! the segments it receives.
//!
//! Linux gets seccomp-bpf plus landlock with p01-process-211; until then
//! [`compile_policy`] there returns [`SandboxPolicy::Unsandboxed`], the
//! worker's HELLO says so, and the broker decides.

/// The Seatbelt profile (SBPL) of a VT worker.
pub const SEATBELT_PROFILE: &str = r#"(version 1)
(deny default)
(allow file-read*
  (subpath "/usr/lib")
  (subpath "/System/Library/dyld")
  (subpath "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld")
  (subpath "/private/var/db/dyld"))
(allow sysctl-read)
(allow process-info* (target self))
(allow signal (target self))
(deny mach-lookup)
(deny iokit-open)
(deny sysctl-write)
(deny process-fork)
(deny process-exec*)
(deny network*)
"#;

/// What the daemon sends the worker to apply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SandboxPolicy {
    /// No sandbox: only where the platform's sandbox has not landed yet
    /// (Linux). A macOS worker refuses it.
    Unsandboxed,
    /// A compiled Seatbelt profile (the bytes `sandbox_compile_string` made).
    Seatbelt(Vec<u8>),
}

/// The sandbox a worker runs under, as its HELLO reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SandboxMechanism {
    None = 0,
    Seatbelt = 1,
}

impl SandboxMechanism {
    pub fn from_wire(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::None),
            1 => Some(Self::Seatbelt),
            _ => None,
        }
    }
}

/// A sandbox that could not be compiled or applied. The worker exits on
/// any of these before it touches a ring.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SandboxError {
    /// `sandbox_compile_string` refused the profile.
    Compile(String),
    /// `sandbox_apply` failed.
    Apply(i32),
    /// This platform cannot apply the policy it was sent.
    Unsupported,
    /// A macOS worker was told to run unsandboxed.
    UnsandboxedRefused,
    /// An empty compiled profile.
    EmptyPolicy,
}

impl std::fmt::Display for SandboxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Compile(message) => write!(f, "compile the worker sandbox: {message}"),
            Self::Apply(code) => write!(f, "apply the worker sandbox: {code}"),
            Self::Unsupported => f.write_str("this platform cannot apply that sandbox"),
            Self::UnsandboxedRefused => f.write_str("a macOS worker never runs unsandboxed"),
            Self::EmptyPolicy => f.write_str("empty compiled sandbox profile"),
        }
    }
}

impl std::error::Error for SandboxError {}

/// The daemon's side: the policy to send a new worker.
pub fn compile_policy() -> Result<SandboxPolicy, SandboxError> {
    #[cfg(target_os = "macos")]
    {
        seatbelt::compile(SEATBELT_PROFILE).map(SandboxPolicy::Seatbelt)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(SandboxPolicy::Unsandboxed)
    }
}

/// The worker's side: apply `policy` to this process, for good.
pub fn apply(policy: &SandboxPolicy) -> Result<SandboxMechanism, SandboxError> {
    match policy {
        SandboxPolicy::Unsandboxed if cfg!(target_os = "macos") => {
            Err(SandboxError::UnsandboxedRefused)
        }
        SandboxPolicy::Unsandboxed => Ok(SandboxMechanism::None),
        SandboxPolicy::Seatbelt(compiled) if compiled.is_empty() => Err(SandboxError::EmptyPolicy),
        #[cfg(target_os = "macos")]
        SandboxPolicy::Seatbelt(compiled) => {
            seatbelt::apply_compiled(compiled).map(|()| SandboxMechanism::Seatbelt)
        }
        #[cfg(not(target_os = "macos"))]
        SandboxPolicy::Seatbelt(_) => Err(SandboxError::Unsupported),
    }
}

#[cfg(target_os = "macos")]
mod seatbelt {
    //! libsandbox's compile and apply calls, declared as Chrome's
    //! `sandbox/mac/seatbelt.cc` declares them.

    use std::ffi::{CStr, CString, c_char, c_int, c_void};

    use super::SandboxError;

    /// `sandbox_profile_t`: a compiled profile.
    #[repr(C)]
    struct SandboxProfile {
        builtin: *mut c_char,
        data: *const u8,
        size: usize,
    }

    #[link(name = "sandbox")]
    unsafe extern "C" {
        fn sandbox_create_params() -> *mut c_void;
        fn sandbox_free_params(params: *mut c_void);
        fn sandbox_compile_string(
            profile: *const c_char,
            params: *mut c_void,
            error: *mut *mut c_char,
        ) -> *mut SandboxProfile;
        fn sandbox_free_profile(profile: *mut SandboxProfile);
        fn sandbox_apply(profile: *mut SandboxProfile) -> c_int;
        fn sandbox_free_error(error: *mut c_char);
    }

    pub(super) fn compile(source: &str) -> Result<Vec<u8>, SandboxError> {
        let source = CString::new(source)
            .map_err(|_| SandboxError::Compile("profile has a NUL byte".to_owned()))?;
        // SAFETY: returns a new parameter set or null; freed below.
        let params = unsafe { sandbox_create_params() };
        if params.is_null() {
            return Err(SandboxError::Compile("sandbox_create_params failed".to_owned()));
        }
        let mut error: *mut c_char = std::ptr::null_mut();
        // SAFETY: `source` is a live C string, `params` a live parameter set
        // and `error` a writable local the call may fill.
        let profile = unsafe { sandbox_compile_string(source.as_ptr(), params, &mut error) };
        // SAFETY: frees the parameter set made above; the compiled profile
        // does not borrow it.
        unsafe { sandbox_free_params(params) };
        if profile.is_null() {
            let message = if error.is_null() {
                "sandbox_compile_string failed".to_owned()
            } else {
                // SAFETY: a non-null error is a NUL-terminated string the
                // library owns until sandbox_free_error.
                let text = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
                // SAFETY: frees the error string the call returned.
                unsafe { sandbox_free_error(error) };
                text
            };
            return Err(SandboxError::Compile(message));
        }
        // SAFETY: a non-null profile points at `size` bytes of compiled
        // policy at `data`, live until sandbox_free_profile.
        let compiled = unsafe {
            let profile = &*profile;
            if profile.data.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(profile.data, profile.size).to_vec()
            }
        };
        // SAFETY: frees the profile the compile returned.
        unsafe { sandbox_free_profile(profile) };
        if compiled.is_empty() {
            return Err(SandboxError::EmptyPolicy);
        }
        Ok(compiled)
    }

    pub(super) fn apply_compiled(compiled: &[u8]) -> Result<(), SandboxError> {
        let mut profile = SandboxProfile {
            builtin: std::ptr::null_mut(),
            data: compiled.as_ptr(),
            size: compiled.len(),
        };
        // SAFETY: `profile` describes `compiled`, which outlives the call;
        // sandbox_apply reads it and keeps no pointer to it.
        let result = unsafe { sandbox_apply(&mut profile) };
        if result == 0 { Ok(()) } else { Err(SandboxError::Apply(result)) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_profile_denies_by_default_and_names_every_denied_class() {
        assert!(SEATBELT_PROFILE.contains("(deny default)"));
        for denied in [
            "(deny mach-lookup)",
            "(deny iokit-open)",
            "(deny sysctl-write)",
            "(deny process-fork)",
            "(deny process-exec*)",
            "(deny network*)",
        ] {
            assert!(SEATBELT_PROFILE.contains(denied), "{denied}");
        }
        assert!(!SEATBELT_PROFILE.contains("(allow file-write"));
        assert!(!SEATBELT_PROFILE.contains("(allow mach"));
    }

    #[test]
    fn an_empty_compiled_policy_is_refused() {
        assert_eq!(apply(&SandboxPolicy::Seatbelt(Vec::new())), Err(SandboxError::EmptyPolicy));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn linux_reports_no_sandbox_until_seccomp_lands() {
        assert_eq!(compile_policy(), Ok(SandboxPolicy::Unsandboxed));
        assert_eq!(apply(&SandboxPolicy::Unsandboxed), Ok(SandboxMechanism::None));
        assert_eq!(apply(&SandboxPolicy::Seatbelt(vec![1])), Err(SandboxError::Unsupported));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_profile_compiles_and_a_macos_worker_refuses_no_sandbox() {
        let SandboxPolicy::Seatbelt(compiled) = compile_policy().expect("compile") else {
            panic!("macOS compiles a Seatbelt policy");
        };
        assert!(!compiled.is_empty());
        assert_eq!(apply(&SandboxPolicy::Unsandboxed), Err(SandboxError::UnsandboxedRefused));
    }
}
