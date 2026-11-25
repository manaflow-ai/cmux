//! Starting apps without bringing them to the front where Windows allows.
//!
//! - An executable (a name the shell resolves through App Paths and PATH,
//!   or a full path) starts with ShellExecuteEx and SW_SHOWNOACTIVATE, so
//!   its first window shows without taking focus (apps that activate
//!   themselves on start still can).
//! - A packaged app (an AUMID) starts through the shell's activation
//!   manager. Windows always brings a packaged app to the front; there is no
//!   background start for it, which the outcome's app says by `frontmost`.
//! - Never a URI, a protocol handler, a script or a shortcut, and never with
//!   arguments: `launch_app` starts apps, it does not run commands.

use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Com::{
    CLSCTX_LOCAL_SERVER, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE, CoCreateInstance,
    CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Threading::{GetProcessId, WaitForInputIdle};
use windows::Win32::UI::Shell::{
    AO_NOERRORUI, ApplicationActivationManager, IApplicationActivationManager, SEE_MASK_FLAG_NO_UI,
    SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW,
};
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNOACTIVATE;
use windows::core::{HSTRING, PCWSTR, w};

use super::pure::{self, AppId};
use super::win::{self, NameCache};
use crate::desktop::{App, DResult, DesktopError};

/// How long a start waits for the app's first input idle.
const INPUT_IDLE_MS: u32 = 5000;

/// COM for the shell calls, on this thread for the call only.
struct Com(bool);

impl Com {
    fn init() -> Self {
        // SAFETY: balanced by Drop when it succeeded.
        let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) };
        Com(hr.is_ok())
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY: pairs the successful CoInitializeEx above.
            unsafe { CoUninitialize() };
        }
    }
}

fn app_for(pid: u32, fallback_id: &str, names: &NameCache) -> App {
    let (id, name) = match win::exe_path(pid) {
        Some(path) => (pure::exe_id(&path), names.name_for(&path)),
        None => (pure::exe_id(fallback_id), pure::exe_display_name(fallback_id)),
    };
    App { id, name, pid, frontmost: false, hidden: false }
}

pub fn launch(app_id: &str, names: &NameCache) -> DResult<App> {
    let parsed = pure::parse_app_id(app_id).map_err(DesktopError::Unsupported)?;
    let _com = Com::init();
    match parsed {
        AppId::Aumid(aumid) => {
            // SAFETY: COM calls in this thread's apartment.
            let pid = unsafe {
                let manager: IApplicationActivationManager =
                    CoCreateInstance(&ApplicationActivationManager, None, CLSCTX_LOCAL_SERVER)
                        .map_err(|e| {
                            DesktopError::Failed(format!(
                                "the shell's activation manager is unavailable: {e}"
                            ))
                        })?;
                manager
                    .ActivateApplication(
                        &HSTRING::from(aumid.as_str()),
                        PCWSTR::null(),
                        AO_NOERRORUI,
                    )
                    .map_err(|e| {
                        DesktopError::TargetNotFound(format!("packaged app {aumid:?}: {e}"))
                    })?
            };
            let mut app = app_for(pid, &aumid, names);
            app.frontmost = true;
            Ok(app)
        }
        AppId::Exe(file) => {
            let wide = HSTRING::from(file.as_str());
            let mut info = SHELLEXECUTEINFOW {
                cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
                fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI,
                lpVerb: w!("open"),
                lpFile: PCWSTR(wide.as_ptr()),
                nShow: SW_SHOWNOACTIVATE.0,
                ..Default::default()
            };
            // SAFETY: `info` and the strings it points to outlive the call;
            // the process handle is closed below.
            unsafe {
                ShellExecuteExW(&mut info).map_err(|e| {
                    DesktopError::TargetNotFound(format!("could not start {file:?}: {e}"))
                })?;
                if info.hProcess.is_invalid() {
                    // The shell handed the start to a running instance (DDE).
                    return Ok(App {
                        id: pure::exe_id(&file),
                        name: pure::exe_display_name(&file),
                        pid: 0,
                        frontmost: false,
                        hidden: false,
                    });
                }
                let pid = GetProcessId(info.hProcess);
                WaitForInputIdle(info.hProcess, INPUT_IDLE_MS);
                let _ = CloseHandle(info.hProcess);
                Ok(app_for(pid, &file, names))
            }
        }
    }
}
