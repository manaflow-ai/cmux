//! Safe ownership boundary around Ghostty's configuration-only C ABI.
//!
//! This crate is the only cmux component allowed to discover Ghostty config
//! files. It returns one bounded canonical byte snapshot and never exposes raw
//! ConfigKit handles to its callers.

use std::fmt;

pub const MAXIMUM_RESOLVED_CONFIG_LENGTH: usize = 256 * 1_024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    UnsupportedPlatform,
    Initialization(String),
    LockPoisoned,
    Allocation,
    Diagnostics { count: u32, messages: Vec<String> },
    Serialization,
    TooLarge { length: usize },
    InvalidUtf8(String),
    ContainsNul,
    InvalidPath,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedPlatform => formatter.write_str("GhosttyConfigKit requires macOS"),
            Self::Initialization(message) => {
                write!(formatter, "GhosttyConfigKit initialization failed: {message}")
            }
            Self::LockPoisoned => formatter.write_str("GhosttyConfigKit resolver lock is poisoned"),
            Self::Allocation => formatter.write_str("GhosttyConfigKit could not allocate config"),
            Self::Diagnostics { count, messages } => {
                write!(formatter, "Ghostty config has {count} diagnostic(s)")?;
                if !messages.is_empty() {
                    write!(formatter, ": {}", messages.join("; "))?;
                }
                Ok(())
            }
            Self::Serialization => {
                formatter.write_str("GhosttyConfigKit could not serialize resolved config")
            }
            Self::TooLarge { length } => write!(
                formatter,
                "resolved Ghostty config is {length} bytes; maximum is {MAXIMUM_RESOLVED_CONFIG_LENGTH}"
            ),
            Self::InvalidUtf8(message) => {
                write!(formatter, "resolved Ghostty config is not UTF-8: {message}")
            }
            Self::ContainsNul => formatter.write_str("resolved Ghostty config contains NUL"),
            Self::InvalidPath => formatter.write_str("Ghostty config path is not valid C text"),
        }
    }
}

impl std::error::Error for Error {}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{CStr, CString, c_char, c_int, c_void};
    use std::slice;
    use std::sync::{Mutex, OnceLock};

    use super::{Error, MAXIMUM_RESOLVED_CONFIG_LENGTH};

    const MAXIMUM_DIAGNOSTIC_COUNT: u32 = 32;
    const MAXIMUM_DIAGNOSTIC_CHARACTERS: usize = 1_024;
    static CONFIG_LOCK: Mutex<()> = Mutex::new(());
    static INITIALIZATION: OnceLock<Result<Initialization, String>> = OnceLock::new();

    type GhosttyConfig = *mut c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct GhosttyDiagnostic {
        message: *const c_char,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct GhosttyString {
        ptr: *const c_char,
        len: usize,
        sentinel: bool,
    }

    unsafe extern "C" {
        fn ghostty_config_init(argc: usize, argv: *mut *mut c_char) -> c_int;
        fn ghostty_config_new() -> GhosttyConfig;
        fn ghostty_config_free(config: GhosttyConfig);
        fn ghostty_config_load_default_files(config: GhosttyConfig);
        fn ghostty_config_load_file(config: GhosttyConfig, absolute_path: *const c_char);
        fn ghostty_config_load_recursive_files(config: GhosttyConfig);
        fn ghostty_config_finalize(config: GhosttyConfig);
        fn ghostty_config_diagnostics_count(config: GhosttyConfig) -> u32;
        fn ghostty_config_get_diagnostic(config: GhosttyConfig, index: u32) -> GhosttyDiagnostic;
        fn ghostty_config_serialize(config: GhosttyConfig) -> GhosttyString;
        fn ghostty_string_free(value: GhosttyString);
    }

    struct OwnedConfig(GhosttyConfig);

    impl Drop for OwnedConfig {
        fn drop(&mut self) {
            unsafe { ghostty_config_free(self.0) };
        }
    }

    struct OwnedString(GhosttyString);

    impl Drop for OwnedString {
        fn drop(&mut self) {
            unsafe { ghostty_string_free(self.0) };
        }
    }

    struct Initialization {
        _argument: CString,
        _arguments: Box<[usize]>,
    }

    pub(super) fn resolve_builtin() -> Result<Vec<u8>, Error> {
        resolve(|_| {})
    }

    pub(super) fn resolve_default_files() -> Result<Vec<u8>, Error> {
        resolve(|config| unsafe {
            ghostty_config_load_default_files(config);
            ghostty_config_load_recursive_files(config);
        })
    }

    #[cfg(test)]
    pub(super) fn resolve_file(path: &std::path::Path) -> Result<Vec<u8>, Error> {
        use std::os::unix::ffi::OsStrExt as _;

        let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::InvalidPath)?;
        resolve(|config| unsafe {
            ghostty_config_load_file(config, path.as_ptr());
            ghostty_config_load_recursive_files(config);
        })
    }

    fn resolve(load: impl FnOnce(GhosttyConfig)) -> Result<Vec<u8>, Error> {
        let _guard = CONFIG_LOCK.lock().map_err(|_| Error::LockPoisoned)?;
        initialize()?;
        let config = unsafe { ghostty_config_new() };
        if config.is_null() {
            return Err(Error::Allocation);
        }
        let config = OwnedConfig(config);
        load(config.0);
        unsafe { ghostty_config_finalize(config.0) };
        let diagnostic_count = unsafe { ghostty_config_diagnostics_count(config.0) };
        if diagnostic_count != 0 {
            return Err(Error::Diagnostics {
                count: diagnostic_count,
                messages: diagnostics(config.0, diagnostic_count),
            });
        }

        let serialized = OwnedString(unsafe { ghostty_config_serialize(config.0) });
        if serialized.0.ptr.is_null() {
            return Err(Error::Serialization);
        }
        let bytes =
            unsafe { slice::from_raw_parts(serialized.0.ptr.cast::<u8>(), serialized.0.len) };
        validate_serialized(bytes)
    }

    fn initialize() -> Result<(), Error> {
        match INITIALIZATION.get_or_init(|| {
            let argument = CString::new("cmux-terminal-backend").unwrap();
            let mut arguments = vec![argument.as_ptr() as usize].into_boxed_slice();
            let status = unsafe {
                ghostty_config_init(arguments.len(), arguments.as_mut_ptr().cast::<*mut c_char>())
            };
            (status == 0)
                .then_some(Initialization { _argument: argument, _arguments: arguments })
                .ok_or_else(|| format!("status {status}"))
        }) {
            Ok(_) => Ok(()),
            Err(message) => Err(Error::Initialization(message.clone())),
        }
    }

    fn diagnostics(config: GhosttyConfig, count: u32) -> Vec<String> {
        (0..count.min(MAXIMUM_DIAGNOSTIC_COUNT))
            .filter_map(|index| {
                let diagnostic = unsafe { ghostty_config_get_diagnostic(config, index) };
                if diagnostic.message.is_null() {
                    return None;
                }
                let message = unsafe { CStr::from_ptr(diagnostic.message) }.to_string_lossy();
                Some(message.chars().take(MAXIMUM_DIAGNOSTIC_CHARACTERS).collect())
            })
            .collect()
    }

    fn validate_serialized(bytes: &[u8]) -> Result<Vec<u8>, Error> {
        if bytes.len() > MAXIMUM_RESOLVED_CONFIG_LENGTH {
            return Err(Error::TooLarge { length: bytes.len() });
        }
        std::str::from_utf8(bytes).map_err(|error| Error::InvalidUtf8(error.to_string()))?;
        if bytes.contains(&0) {
            return Err(Error::ContainsNul);
        }
        Ok(bytes.to_vec())
    }

    #[cfg(test)]
    mod tests {
        use std::time::{SystemTime, UNIX_EPOCH};

        use super::*;

        #[test]
        fn explicit_config_is_canonicalized_without_source_directives() {
            let directory = std::env::temp_dir().join(format!(
                "cmux-ghostty-config-{}-{}",
                std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
            ));
            std::fs::create_dir_all(&directory).unwrap();
            let root = directory.join("root.ghostty");
            std::fs::write(&root, "font-size = 17.5\nconfig-file = child.ghostty\n").unwrap();
            std::fs::write(directory.join("child.ghostty"), "background = 123456\n").unwrap();

            let resolved = resolve_file(&root).unwrap();
            let text = std::str::from_utf8(&resolved).unwrap();
            assert!(text.contains("font-size = 17.5"));
            assert!(text.contains("background = #123456"));
            assert!(!text.contains("config-file"));
            let _ = std::fs::remove_dir_all(directory);
        }

        #[test]
        fn serialized_config_bounds_are_enforced_before_copy() {
            assert!(matches!(
                validate_serialized(&vec![b'x'; MAXIMUM_RESOLVED_CONFIG_LENGTH + 1]),
                Err(Error::TooLarge { .. })
            ));
            assert!(matches!(validate_serialized(&[0xff]), Err(Error::InvalidUtf8(_))));
            assert_eq!(validate_serialized(b"font-size = 13\n").unwrap(), b"font-size = 13\n");
        }

        #[test]
        fn invalid_explicit_config_is_rejected_before_serialization() {
            let path = std::env::temp_dir().join(format!(
                "cmux-ghostty-invalid-{}-{}.ghostty",
                std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
            ));
            std::fs::write(&path, "font-size = definitely-not-a-number\n").unwrap();

            let error = resolve_file(&path).unwrap_err();
            assert!(matches!(error, Error::Diagnostics { count, .. } if count > 0));
            let _ = std::fs::remove_file(path);
        }
    }
}

#[cfg(target_os = "macos")]
pub fn resolve_default_files() -> Result<Vec<u8>, Error> {
    macos::resolve_default_files()
}

#[cfg(target_os = "macos")]
pub fn resolve_builtin() -> Result<Vec<u8>, Error> {
    macos::resolve_builtin()
}

#[cfg(not(target_os = "macos"))]
pub fn resolve_default_files() -> Result<Vec<u8>, Error> {
    Err(Error::UnsupportedPlatform)
}

#[cfg(not(target_os = "macos"))]
pub fn resolve_builtin() -> Result<Vec<u8>, Error> {
    Err(Error::UnsupportedPlatform)
}
