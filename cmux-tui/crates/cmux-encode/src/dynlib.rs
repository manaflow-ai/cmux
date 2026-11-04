//! Apple frameworks bound at run time. A binary that links a framework loads it, and runs its
//! initializers, at every launch; `cmux` is the CLI agents run constantly, so the frameworks
//! only remote desktop sessions use (VideoToolbox, CoreMedia, CoreVideo, ScreenCaptureKit, ...)
//! are opened with `dlopen` the first time a session needs them, and every symbol is looked up
//! with `dlsym`. The binary then links none of them, so the macOS build on Linux needs no link
//! stub for them either (scripts/ci/macos-stubs).
//!
//! [`framework!`] declares one framework's symbols the way an `extern` block would: functions
//! keep their names and signatures (calls do not change), and each data symbol becomes a
//! function of the same name that returns its value. `available()` loads the framework and
//! every symbol, and says which is missing; call it before the first use: after a failed load
//! every function is a stand-in that returns zero and every data symbol reads as zero.

use std::ffi::{CStr, c_char, c_int, c_void};

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
}

const RTLD_LAZY: c_int = 0x1;
const RTLD_LOCAL: c_int = 0x4;

/// An opened library (never closed: the frameworks stay loaded for the process).
pub struct Library(*mut c_void);

// SAFETY: a dlopen handle is a process-wide token; dlsym on it is thread-safe.
unsafe impl Send for Library {}
// SAFETY: as above.
unsafe impl Sync for Library {}

fn last_error() -> String {
    // SAFETY: dlerror returns a NUL-terminated message or NULL.
    let message = unsafe { dlerror() };
    if message.is_null() {
        return "unknown error".into();
    }
    // SAFETY: non-NULL, NUL-terminated by dlerror's contract.
    unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned()
}

impl Library {
    pub fn open(path: &CStr) -> Result<Self, String> {
        // SAFETY: a NUL-terminated path.
        let handle = unsafe { dlopen(path.as_ptr(), RTLD_LAZY | RTLD_LOCAL) };
        if handle.is_null() {
            return Err(format!("{}: {}", path.to_string_lossy(), last_error()));
        }
        Ok(Self(handle))
    }

    /// The address of `name`.
    pub fn symbol(&self, name: &CStr) -> Result<*mut c_void, String> {
        // SAFETY: a live handle and a NUL-terminated name.
        let address = unsafe { dlsym(self.0, name.as_ptr()) };
        if address.is_null() {
            return Err(format!("{}: {}", name.to_string_lossy(), last_error()));
        }
        Ok(address)
    }
}

/// One framework's functions and data symbols, resolved at first use (module docs).
///
/// ```ignore
/// framework! {
///     pub mod vt = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox" {
///         static kVTCompressionPropertyKey_RealTime: CFStringRef;
///         ref kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;   // its address
///         fn VTSessionSetProperty(s: *mut c_void, key: CFStringRef, value: CFTypeRef) -> OSStatus;
///     }
/// }
/// ```
#[macro_export]
macro_rules! framework {
    (
        $vis:vis mod $module:ident = $path:literal {
            $( static $data:ident: $data_ty:ty; )*
            $( ref $object:ident: $object_ty:ty; )*
            $( fn $function:ident($($arg:ident: $arg_ty:ty),* $(,)?) $(-> $ret:ty)?; )*
        }
    ) => {
        #[allow(non_snake_case, non_upper_case_globals, dead_code, clippy::missing_safety_doc, clippy::too_many_arguments)]
        $vis mod $module {
            use super::*;

            /// Stand-ins for a framework that did not load: they do nothing and return zero
            /// (NULL, 0, false). Zero is success for a status-code function, so callers check
            /// `available()` before the first call; the stand-ins only keep a missed check from
            /// calling through a NULL address.
            mod fallback {
                use super::*;
                $(
                    pub unsafe extern "C" fn $function($(_: $arg_ty),*) $(-> $ret)? {
                        // SAFETY: the return types are plain C values, for which all-zero is valid.
                        unsafe { ::std::mem::zeroed() }
                    }
                )*
            }

            struct Table {
                $( $data: *const $data_ty, )*
                $( $object: *const $object_ty, )*
                $( $function: unsafe extern "C" fn($($arg_ty),*) $(-> $ret)?, )*
            }

            // SAFETY: addresses of a framework's code and constants, which never move or change.
            unsafe impl Send for Table {}
            // SAFETY: as above.
            unsafe impl Sync for Table {}

            /// The resolved symbols, and why loading failed (then every entry is a stand-in).
            static TABLE: ::std::sync::OnceLock<(Table, Option<String>)> = ::std::sync::OnceLock::new();

            fn resolve() -> Result<Table, String> {
                let library = $crate::dynlib::Library::open(
                    ::std::ffi::CStr::from_bytes_with_nul(concat!($path, "\0").as_bytes())
                        .map_err(|e| e.to_string())?,
                )?;
                let symbol = |name: &'static str| -> Result<*mut ::std::ffi::c_void, String> {
                    let name = ::std::ffi::CString::new(name).map_err(|e| e.to_string())?;
                    library.symbol(&name)
                };
                Ok(Table {
                    $( $data: symbol(stringify!($data))?.cast(), )*
                    $( $object: symbol(stringify!($object))?.cast(), )*
                    // SAFETY: the symbol is the function this table declares it to be.
                    $( $function: unsafe {
                        ::std::mem::transmute::<*mut ::std::ffi::c_void, unsafe extern "C" fn($($arg_ty),*) $(-> $ret)?>(
                            symbol(stringify!($function))?,
                        )
                    }, )*
                })
            }

            fn table() -> &'static Table {
                &TABLE
                    .get_or_init(|| match resolve() {
                        Ok(table) => (table, None),
                        Err(error) => (
                            Table {
                                $( $data: ::std::ptr::null(), )*
                                $( $object: ::std::ptr::null(), )*
                                $( $function: fallback::$function, )*
                            },
                            Some(format!("{}: {error}", $path)),
                        ),
                    })
                    .0
            }

            /// Loads the framework and every symbol this module names, once; call it before the
            /// first use (after a failed load the symbols are stand-ins that return zero).
            pub fn available() -> Result<(), String> {
                table();
                match TABLE.get().and_then(|(_, error)| error.clone()) {
                    Some(error) => Err(error),
                    None => Ok(()),
                }
            }

            $(
                pub fn $data() -> $data_ty {
                    let address = table().$data;
                    if address.is_null() {
                        // SAFETY: a plain C value (a pointer or a number): all-zero is valid.
                        return unsafe { ::std::mem::zeroed() };
                    }
                    // SAFETY: a constant the framework exports.
                    unsafe { *address }
                }
            )*
            $(
                /// The symbol's address (NULL when the framework did not load).
                pub fn $object() -> *const $object_ty {
                    table().$object
                }
            )*
            $(
                pub unsafe fn $function($($arg: $arg_ty),*) $(-> $ret)? {
                    // SAFETY: the caller upholds the function's contract, as for an extern fn.
                    unsafe { (table().$function)($($arg),*) }
                }
            )*
        }
    };
}
