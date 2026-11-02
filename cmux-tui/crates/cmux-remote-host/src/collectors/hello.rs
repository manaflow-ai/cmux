//! Windows Hello in a host-owned window: `UserConsentVerifier` through
//! `IUserConsentVerifierInterop::RequestVerificationForWindowAsync`, so the
//! consent dialog belongs to the cmux Remote window and names the agent, the
//! workspace and the app. Verified confirms the offered decision; cancelled
//! answers `deny`; no Hello on this machine asks nobody.

#![allow(unsafe_code)]

use async_trait::async_trait;

use crate::approval::{ApprovalRequest, Decision};
use crate::approver::{ApproverDecision, LocalCollector};

pub struct WindowsHello;

/// The text the Hello dialog shows.
pub fn message(request: &ApprovalRequest, offered: Decision) -> String {
    let scope = match offered {
        Decision::Once => "for this action",
        Decision::Session => "for this agent session",
        Decision::Always => "always, for this cmux",
        Decision::Deny => "",
    };
    format!(
        "Allow {} in {} to use {} {scope}? (cmux Computer Use)",
        request.agent, request.workspace, request.target.name
    )
}

#[async_trait]
impl LocalCollector for WindowsHello {
    fn name(&self) -> &'static str {
        "windows-hello"
    }

    async fn ask(&self, request: &ApprovalRequest, offered: Decision) -> Option<ApproverDecision> {
        if offered == Decision::Deny {
            return None;
        }
        let text = message(request, offered);
        let decision = match tokio::task::spawn_blocking(move || verify(&text)).await.ok()?? {
            Verdict::Verified => offered,
            Verdict::Canceled => Decision::Deny,
            // Busy, retries exhausted, not set up: nobody answered here; the phone still can.
            Verdict::NoAnswer => return None,
        };
        Some(ApproverDecision {
            decision,
            digest: request.digest.clone(),
            via: "windows-hello".into(),
        })
    }
}

enum Verdict {
    Verified,
    Canceled,
    NoAnswer,
}

/// None when Hello cannot ask at all.
fn verify(text: &str) -> Option<Verdict> {
    use windows::Security::Credentials::UI::{
        UserConsentVerificationResult, UserConsentVerifier, UserConsentVerifierAvailability,
    };
    use windows::Win32::System::WinRT::IUserConsentVerifierInterop;
    use windows::core::HSTRING;

    let availability = UserConsentVerifier::CheckAvailabilityAsync().ok()?.get().ok()?;
    if availability != UserConsentVerifierAvailability::Available {
        return None;
    }
    let window = OwnerWindow::create()?;
    let interop = windows::core::factory::<UserConsentVerifier, IUserConsentVerifierInterop>().ok()?;
    let operation: windows::Foundation::IAsyncOperation<UserConsentVerificationResult> = unsafe {
        // SAFETY: a live window this thread owns until the operation completes.
        interop.RequestVerificationForWindowAsync(windows::Win32::Foundation::HWND(window.0), &HSTRING::from(text))
    }
    .ok()?;
    let result = operation.get().ok()?;
    drop(window);
    Some(match result {
        UserConsentVerificationResult::Verified => Verdict::Verified,
        UserConsentVerificationResult::Canceled => Verdict::Canceled,
        _ => Verdict::NoAnswer,
    })
}

/// A small top-level window titled "cmux Remote" that owns the Hello dialog.
struct OwnerWindow(*mut core::ffi::c_void);

impl OwnerWindow {
    fn create() -> Option<Self> {
        use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
        use windows_sys::Win32::UI::WindowsAndMessaging::{
            CW_USEDEFAULT, CreateWindowExW, DefWindowProcW, RegisterClassW, SW_SHOWNORMAL, ShowWindow, WNDCLASSW,
            WS_CAPTION, WS_EX_TOPMOST, WS_POPUP,
        };
        let class: Vec<u16> = "cmuxRemoteApproval\0".encode_utf16().collect();
        let title: Vec<u16> = "cmux Remote\0".encode_utf16().collect();
        // SAFETY: the module handle of this executable.
        let instance = unsafe { GetModuleHandleW(std::ptr::null()) };
        // SAFETY: WNDCLASSW is plain data; unset fields are zero.
        let mut window_class: WNDCLASSW = unsafe { std::mem::zeroed() };
        window_class.lpfnWndProc = Some(DefWindowProcW);
        window_class.hInstance = instance;
        window_class.lpszClassName = class.as_ptr();
        // SAFETY: a valid class; registering twice fails harmlessly.
        unsafe { RegisterClassW(&window_class) };
        // SAFETY: a registered class and NUL-terminated strings.
        let window = unsafe {
            CreateWindowExW(
                WS_EX_TOPMOST,
                class.as_ptr(),
                title.as_ptr(),
                WS_POPUP | WS_CAPTION,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                360,
                120,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                instance,
                std::ptr::null(),
            )
        };
        if window.is_null() {
            return None;
        }
        // SAFETY: a window this thread created.
        unsafe { ShowWindow(window, SW_SHOWNORMAL) };
        Some(Self(window))
    }
}

impl Drop for OwnerWindow {
    fn drop(&mut self) {
        // SAFETY: a window this thread created.
        unsafe { windows_sys::Win32::UI::WindowsAndMessaging::DestroyWindow(self.0) };
    }
}
