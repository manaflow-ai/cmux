//! The session's state: session 0, a locked workstation or the secure
//! desktop (UAC, sign-in, Ctrl+Alt+Del) leave no input desktop this process
//! can use. Protected OS authentication UI is never usable, so we refuse
//! instead of acting on whatever is reachable.

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::Registry::{HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RegGetValueW};
use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, GetUserObjectInformationW,
    OpenInputDesktop, UOI_NAME,
};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::core::{PCWSTR, w};

use crate::desktop::{DResult, DesktopError};

pub struct SessionState {
    pub session_id: u32,
    /// The input desktop's name (`Default` when the person is signed in and
    /// unlocked; `Winlogon` on the lock or UAC screen), or `None` when this
    /// process cannot open it (which is also the secure desktop).
    pub desktop: Option<String>,
}

impl SessionState {
    pub fn interactive(&self) -> bool {
        self.session_id != 0
            && self.desktop.as_deref().is_some_and(|d| d.eq_ignore_ascii_case("Default"))
    }
}

pub fn current() -> SessionState {
    let mut session_id = 0u32;
    // SAFETY: an out pointer to a local.
    let _ = unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session_id) };
    SessionState { session_id, desktop: input_desktop_name() }
}

fn input_desktop_name() -> Option<String> {
    // SAFETY: the handle is closed below; the buffer outlives the call.
    unsafe {
        let desk = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS).ok()?;
        let mut buf = [0u16; 128];
        let mut needed = 0u32;
        let got = GetUserObjectInformationW(
            HANDLE(desk.0),
            UOI_NAME,
            Some(buf.as_mut_ptr().cast()),
            (buf.len() * 2) as u32,
            Some(&mut needed),
        );
        let _ = CloseDesktop(desk);
        got.ok()?;
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..len]))
    }
}

/// Refuses an action or a capture while there is no usable input desktop.
pub fn require_interactive() -> DResult<()> {
    let s = current();
    if s.interactive() {
        return Ok(());
    }
    Err(DesktopError::Unsupported(match (s.session_id, s.desktop) {
        (0, _) => "this process runs in session 0, which has no desktop".into(),
        (_, Some(name)) => format!(
            "the workstation is locked or a secure screen ({name}) is showing; Computer Use never acts on protected sign-in or UAC UI"
        ),
        (_, None) => "the workstation is locked or a secure screen (sign-in, UAC) is showing; Computer Use never acts on protected sign-in or UAC UI".into(),
    }))
}

fn reg_string(value: PCWSTR) -> Option<String> {
    let key = w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    let mut buf = [0u16; 256];
    let mut size = (buf.len() * 2) as u32;
    // SAFETY: the buffer and its size describe the same local array.
    let err = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key,
            value,
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr().cast()),
            Some(&mut size),
        )
    };
    if err.is_err() {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

/// `Windows 11 Pro 24H2 (build 26100)`. ProductName still says "Windows 10"
/// on Windows 11, so the build number decides.
pub fn os_version() -> String {
    let product = reg_string(w!("ProductName")).unwrap_or_else(|| "Windows".into());
    let display = reg_string(w!("DisplayVersion")).unwrap_or_default();
    let build = reg_string(w!("CurrentBuild")).unwrap_or_default();
    let product = match build.parse::<u32>() {
        Ok(b) if b >= 22000 => product.replacen("Windows 10", "Windows 11", 1),
        _ => product,
    };
    format!("{product} {display} (build {build})").replace("  ", " ")
}
