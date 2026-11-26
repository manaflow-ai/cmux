//! `cmux-screen-sharing __webrtc-host <executable> [args...]`: runs the iPhone viewer's WebRTC
//! screen host (the cmux app's own executable in its `--screen-stream-host` mode; Swift,
//! `MacScreenStreamChild` in CmuxNextMacScreen) as this helper's ordinary child, on this
//! helper's stdin, stdout and stderr, and exits with its status.
//!
//! The app starts this helper's verified copy with macOS responsibility disclaimed, so the helper
//! is its own responsible process; a child it spawns stays the helper's responsibility. macOS
//! therefore checks the child's Screen Recording and Accessibility against the helper's grants,
//! never the app's, and a grant made while cmux runs reaches the next session with no relaunch
//! (plans/cmux-next/screen-sharing-helper.md).
//!
//! SECURITY: the child gets this helper's grants. When this helper is signed by a team (every
//! NIGHTLY, RC and release), the child is started suspended and runs only when its running code
//! satisfies `anchor apple generic` and this helper's own Team ID, its signing identifier is a cmux
//! app's (`com.cmuxterm.app*`) and its only argument is `--screen-stream-host`; otherwise it is
//! refused, or killed before it runs an instruction. The check covers the child's main executable
//! (the app's stub); the code it loads from the bundle's frameworks is the app's own exposure too,
//! since the app's entitlements disable library validation (a replaced framework in a copied app
//! runs under the app's grants today as well). An ad hoc (local) helper has no team to compare and runs the child as is:
//! its grants are keyed to its own cdhash, so they are a dev build's alone.

/// The hidden mode word (the app's `MacScreenStreamProcess`).
pub const MODE: &str = "__webrtc-host";

/// The only argument a team-signed helper passes its child (the app's `MacScreenStreamChild.flag`).
pub const CHILD_FLAG: &str = "--screen-stream-host";

/// The signing identifiers a team-signed helper runs: cmux app builds (release, NIGHTLY, RC, tags).
pub const CHILD_IDENTIFIER_PREFIX: &str = "com.cmuxterm.app";

/// Runs the child to its end; the process exit code.
pub fn run(args: &[String]) -> i32 {
    let Some((executable, rest)) = args.split_first().filter(|(path, _)| path.starts_with('/'))
    else {
        eprintln!("usage: cmux-screen-sharing {MODE} /path/to/executable [args...]");
        return 2;
    };
    match platform::run(executable, rest) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("cmux-screen-sharing {MODE}: {e}");
            1
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{c_char, c_void, CString};
    use std::ptr;

    type CFTypeRef = *const c_void;
    type CFIndex = isize;
    type OSStatus = i32;

    const UTF8: u32 = 0x0800_0100;
    /// `kSecCSSigningInformation`.
    const SIGNING_INFORMATION: u32 = 1 << 1;
    /// `kCFNumberSInt32Type`.
    const NUMBER_SINT32: CFIndex = 3;

    #[repr(C)]
    struct Opaque {
        _private: [u8; 0],
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFTypeDictionaryKeyCallBacks: Opaque;
        static kCFTypeDictionaryValueCallBacks: Opaque;
        fn CFNumberCreate(allocator: CFTypeRef, kind: CFIndex, value: *const c_void) -> CFTypeRef;
        fn CFDictionaryCreate(
            allocator: CFTypeRef,
            keys: *const CFTypeRef,
            values: *const CFTypeRef,
            count: CFIndex,
            key_callbacks: *const Opaque,
            value_callbacks: *const Opaque,
        ) -> CFTypeRef;
        fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFStringCreateWithBytes(
            allocator: CFTypeRef,
            bytes: *const u8,
            length: CFIndex,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        fn CFStringGetCString(
            string: CFTypeRef,
            buffer: *mut c_char,
            size: CFIndex,
            encoding: u32,
        ) -> u8;
        fn CFStringGetTypeID() -> usize;
        fn CFGetTypeID(object: CFTypeRef) -> usize;
        fn CFRelease(object: CFTypeRef);
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecCodeInfoTeamIdentifier: CFTypeRef;
        static kSecCodeInfoIdentifier: CFTypeRef;
        fn SecCodeCopySelf(flags: u32, code: *mut CFTypeRef) -> OSStatus;
        fn SecCodeCopyStaticCode(code: CFTypeRef, flags: u32, out: *mut CFTypeRef) -> OSStatus;
        fn SecCodeCopySigningInformation(
            code: CFTypeRef,
            flags: u32,
            information: *mut CFTypeRef,
        ) -> OSStatus;
        fn SecCodeCopyGuestWithAttributes(
            host: CFTypeRef,
            attributes: CFTypeRef,
            flags: u32,
            guest: *mut CFTypeRef,
        ) -> OSStatus;
        fn SecCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> OSStatus;
        fn SecRequirementCreateWithString(
            text: CFTypeRef,
            flags: u32,
            requirement: *mut CFTypeRef,
        ) -> OSStatus;
    }

    /// An owned Core Foundation reference, released on drop.
    struct Owned(CFTypeRef);

    impl Owned {
        fn new(object: CFTypeRef, what: &str) -> Result<Self, String> {
            if object.is_null() {
                Err(format!("{what} failed"))
            } else {
                Ok(Self(object))
            }
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: `self.0` is a non-null object this wrapper owns once.
            unsafe { CFRelease(self.0) };
        }
    }

    fn status(result: OSStatus, what: &str) -> Result<(), String> {
        if result == 0 {
            Ok(())
        } else {
            Err(format!("{what} returned {result}"))
        }
    }

    /// Spawns `executable` suspended on this process's stdio, checks its code, lets it run and
    /// waits for it; its exit code (128 + the signal for a child a signal ended).
    pub(super) fn run(executable: &str, args: &[String]) -> Result<i32, String> {
        let team = own_team()?;
        if team.is_some() && args != [super::CHILD_FLAG] {
            // SECURITY: a signed helper lends its grants to the stream host only, never to any
            // other mode of a team-signed program.
            return Err(format!(
                "refused: the child's arguments must be exactly {}",
                super::CHILD_FLAG
            ));
        }
        let pid = spawn_suspended(executable, args)?;
        if let Some(team) = team.as_deref() {
            if let Err(e) = check_child(pid, team) {
                // SAFETY: `pid` is our unreaped child; the kill cannot reach another process.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                let _ = wait(pid);
                return Err(format!("{executable} is not signed by this helper's team: {e}"));
            }
        }
        // SAFETY: as above: our own unreaped, suspended child.
        unsafe { libc::kill(pid, libc::SIGCONT) };
        wait(pid)
    }

    fn spawn_suspended(executable: &str, args: &[String]) -> Result<libc::pid_t, String> {
        let program = CString::new(executable).map_err(|_| "the path holds a NUL")?;
        let mut argv_owned = vec![program.clone()];
        for arg in args {
            argv_owned.push(CString::new(arg.as_str()).map_err(|_| "an argument holds a NUL")?);
        }
        let mut argv: Vec<*mut c_char> =
            argv_owned.iter().map(|arg| arg.as_ptr().cast_mut()).collect();
        argv.push(ptr::null_mut());
        // SAFETY: plain C structures, initialized and destroyed in this scope; every pointer
        // passed (the path, argv, environ) is live and NUL-terminated for the call.
        unsafe {
            let mut attributes: libc::posix_spawnattr_t = ptr::null_mut();
            if libc::posix_spawnattr_init(&raw mut attributes) != 0 {
                return Err("posix_spawnattr_init failed".into());
            }
            libc::posix_spawnattr_setflags(
                &raw mut attributes,
                libc::POSIX_SPAWN_START_SUSPENDED as libc::c_short,
            );
            let mut pid: libc::pid_t = 0;
            unsafe extern "C" {
                static environ: *const *mut c_char;
            }
            let result = libc::posix_spawn(
                &raw mut pid,
                program.as_ptr(),
                ptr::null(),
                &raw const attributes,
                argv.as_ptr(),
                environ,
            );
            libc::posix_spawnattr_destroy(&raw mut attributes);
            if result != 0 {
                return Err(format!(
                    "{executable} did not start: {}",
                    std::io::Error::from_raw_os_error(result)
                ));
            }
            Ok(pid)
        }
    }

    fn wait(pid: libc::pid_t) -> Result<i32, String> {
        let mut status: libc::c_int = 0;
        loop {
            // SAFETY: `pid` is our child; `status` is a valid out-pointer.
            if unsafe { libc::waitpid(pid, &raw mut status, 0) } >= 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(format!("waitpid: {error}"));
            }
        }
        if libc::WIFEXITED(status) {
            Ok(libc::WEXITSTATUS(status))
        } else if libc::WIFSIGNALED(status) {
            Ok(128 + libc::WTERMSIG(status))
        } else {
            Ok(1)
        }
    }

    /// This helper's own Team ID; None when it has none (ad hoc).
    fn own_team() -> Result<Option<String>, String> {
        let mut code: CFTypeRef = ptr::null();
        // SAFETY: the out-pointer is valid.
        status(unsafe { SecCodeCopySelf(0, &raw mut code) }, "SecCodeCopySelf")?;
        let code = Owned::new(code, "SecCodeCopySelf")?;
        let mut static_code: CFTypeRef = ptr::null();
        // SAFETY: `code.0` is live; the out-pointer is valid.
        status(
            unsafe { SecCodeCopyStaticCode(code.0, 0, &raw mut static_code) },
            "SecCodeCopyStaticCode",
        )?;
        let static_code = Owned::new(static_code, "SecCodeCopyStaticCode")?;
        let mut information: CFTypeRef = ptr::null();
        // SAFETY: `static_code.0` is live; the out-pointer is valid.
        status(
            unsafe {
                SecCodeCopySigningInformation(
                    static_code.0,
                    SIGNING_INFORMATION,
                    &raw mut information,
                )
            },
            "SecCodeCopySigningInformation",
        )?;
        let information = Owned::new(information, "SecCodeCopySigningInformation")?;
        // SAFETY: the dictionary is live and the key a framework constant; the value is borrowed
        // and copied before `information` drops.
        let team =
            unsafe { string(CFDictionaryGetValue(information.0, kSecCodeInfoTeamIdentifier)) };
        match team {
            Some(team) if plain_team(&team) => Ok(Some(team)),
            Some(team) => Err(format!("unexpected Team ID {team:?}")),
            None => Ok(None),
        }
    }

    /// A Team ID is ten upper-case letters or digits; anything else never goes into a requirement.
    pub(super) fn plain_team(team: &str) -> bool {
        team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    }

    /// The suspended child's running code satisfies Apple's anchor and `team`.
    fn check_child(pid: libc::pid_t, team: &str) -> Result<(), String> {
        let value: i32 = pid;
        // SAFETY: `value` is live for the call; CFNumber copies it.
        let number = Owned::new(
            unsafe { CFNumberCreate(ptr::null(), NUMBER_SINT32, (&raw const value).cast()) },
            "CFNumberCreate",
        )?;
        // `kSecGuestAttributePid` is the string "pid" (Security/SecCode.h). Made here rather than linked:
        // the fleet's macOS cross SDK does not export the symbol, so linking it broke every fleet app build.
        let pid_key = b"pid";
        // SAFETY: the bytes are live for the call; CFString copies them.
        let pid_key = Owned::new(
            unsafe {
                CFStringCreateWithBytes(
                    ptr::null(),
                    pid_key.as_ptr(),
                    pid_key.len() as CFIndex,
                    UTF8,
                    0,
                )
            },
            "CFStringCreateWithBytes",
        )?;
        let keys = [pid_key.0];
        let values = [number.0];
        // SAFETY: one live key and value; the standard callbacks retain them.
        let attributes = Owned::new(
            unsafe {
                CFDictionaryCreate(
                    ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    1,
                    &raw const kCFTypeDictionaryKeyCallBacks,
                    &raw const kCFTypeDictionaryValueCallBacks,
                )
            },
            "CFDictionaryCreate",
        )?;
        let mut guest: CFTypeRef = ptr::null();
        // SAFETY: a null host is the system; `attributes.0` is live; the out-pointer is valid.
        status(
            unsafe { SecCodeCopyGuestWithAttributes(ptr::null(), attributes.0, 0, &raw mut guest) },
            "SecCodeCopyGuestWithAttributes",
        )?;
        let guest = Owned::new(guest, "SecCodeCopyGuestWithAttributes")?;
        let text = format!("anchor apple generic and certificate leaf[subject.OU] = \"{team}\"");
        // SAFETY: the bytes are live for the call; CFString copies them.
        let text = Owned::new(
            unsafe {
                CFStringCreateWithBytes(ptr::null(), text.as_ptr(), text.len() as CFIndex, UTF8, 0)
            },
            "CFStringCreateWithBytes",
        )?;
        let mut requirement: CFTypeRef = ptr::null();
        // SAFETY: `text.0` is live; the out-pointer is valid.
        status(
            unsafe { SecRequirementCreateWithString(text.0, 0, &raw mut requirement) },
            "SecRequirementCreateWithString",
        )?;
        let requirement = Owned::new(requirement, "SecRequirementCreateWithString")?;
        // SAFETY: both references are live owned objects.
        status(unsafe { SecCodeCheckValidity(guest.0, 0, requirement.0) }, "SecCodeCheckValidity")?;
        // The identifier is read only once the signature is valid, so it is the signed one.
        let mut information: CFTypeRef = ptr::null();
        // SAFETY: `guest.0` is live; the out-pointer is valid.
        status(
            unsafe { SecCodeCopySigningInformation(guest.0, 0, &raw mut information) },
            "SecCodeCopySigningInformation",
        )?;
        let information = Owned::new(information, "SecCodeCopySigningInformation")?;
        // SAFETY: the dictionary is live and the key a framework constant; the value is copied.
        let identifier =
            unsafe { string(CFDictionaryGetValue(information.0, kSecCodeInfoIdentifier)) };
        match identifier {
            Some(id) if cmux_app_identifier(&id) => Ok(()),
            other => Err(format!("its signing identifier {other:?} is not a cmux app's")),
        }
    }

    /// `com.cmuxterm.app` itself or one of its dotted children (`.nightly`, `.debug.TAG`).
    pub(super) fn cmux_app_identifier(id: &str) -> bool {
        let prefix = super::CHILD_IDENTIFIER_PREFIX;
        id == prefix || id.strip_prefix(prefix).is_some_and(|rest| rest.starts_with('.'))
    }

    /// # Safety
    /// `object` is null or a live Core Foundation object.
    unsafe fn string(object: CFTypeRef) -> Option<String> {
        // SAFETY: the caller passes null or a live object.
        if object.is_null() || unsafe { CFGetTypeID(object) != CFStringGetTypeID() } {
            return None;
        }
        let mut buffer = [0 as c_char; 256];
        // SAFETY: the buffer is valid for its length.
        let copied = unsafe {
            CFStringGetCString(object, buffer.as_mut_ptr(), buffer.len() as CFIndex, UTF8)
        };
        if copied == 0 {
            return None;
        }
        // SAFETY: CFStringGetCString wrote a NUL-terminated string.
        let text = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) };
        text.to_str().ok().map(str::to_string)
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    pub(super) fn run(_executable: &str, _args: &[String]) -> Result<i32, String> {
        Err("macOS only".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_relative_or_missing_executable_is_refused_before_anything_starts() {
        assert_eq!(run(&[]), 2);
        assert_eq!(run(&["cmux".into(), "--screen-stream-host".into()]), 2);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn only_a_plain_team_id_goes_into_the_requirement() {
        assert!(platform::plain_team("ABCDE12345"));
        assert!(!platform::plain_team("abcde12345"));
        assert!(!platform::plain_team("ABCDE\" or 1"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn only_a_cmux_app_identifier_is_a_child() {
        assert!(platform::cmux_app_identifier("com.cmuxterm.app"));
        assert!(platform::cmux_app_identifier("com.cmuxterm.app.nightly"));
        assert!(platform::cmux_app_identifier("com.cmuxterm.app.debug.my-tag"));
        assert!(!platform::cmux_app_identifier("com.cmuxterm.appx"));
        assert!(!platform::cmux_app_identifier("com.cmuxterm.cli"));
        assert!(!platform::cmux_app_identifier("cmux-server-helper"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_child_runs_on_this_process_stdio_and_its_status_comes_back() {
        // The test binary is ad hoc signed (no team): the child runs unchecked.
        assert_eq!(run(&["/bin/sh".into(), "-c".into(), "exit 7".into()]), 7);
        assert_eq!(run(&["/usr/bin/true".into()]), 0);
    }
}
