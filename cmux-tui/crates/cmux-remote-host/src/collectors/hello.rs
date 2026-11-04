//! Windows Hello in a host-owned window: `UserConsentVerifier` through
//! `IUserConsentVerifierInterop::RequestVerificationForWindowAsync`, so the
//! consent dialog belongs to the cmux Remote window and names the agent, the
//! workspace and the app. Verified confirms the offered decision; cancelled
//! answers `deny`; no Hello on this machine asks nobody.
//!
//! The window and the request live on a thread of their own that pumps its
//! messages until the operation completes; when another collector answers
//! first the host drops the asking future, which cancels the operation and
//! closes the window. Unverified on a real Windows desktop until a run there.

#![allow(unsafe_code)]

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use async_trait::async_trait;
use windows_sys::Win32::UI::WindowsAndMessaging::{PostThreadMessageW, WM_APP};

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
        let cancel = Arc::new(Cancel::default());
        let (sender, receiver) = tokio::sync::oneshot::channel();
        // The owner window lives on a thread of its own with a message pump:
        // Hello's dialog is modal to it, and a window needs its thread pumping.
        let pumping = Arc::clone(&cancel);
        std::thread::Builder::new()
            .name("cmux-hello".into())
            .spawn(move || {
                let _ = sender.send(verify(&text, &pumping));
            })
            .ok()?;
        // Dropped when another collector answers first (or the question ends): the prompt closes.
        let guard = CancelOnDrop(Some(cancel));
        let verdict = receiver.await.ok()??;
        drop(guard.disarm());
        let decision = match verdict {
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

/// A cross-thread stop for one prompt: a flag and the pump thread to wake.
#[derive(Default)]
struct Cancel {
    stop: AtomicBool,
    thread: AtomicU32,
}

impl Cancel {
    fn request(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let thread = self.thread.load(Ordering::SeqCst);
        if thread != 0 {
            // SAFETY: posting a message to a thread id; a gone thread fails harmlessly.
            unsafe { PostThreadMessageW(thread, WM_APP_WAKE, 0, 0) };
        }
    }

    fn requested(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }
}

struct CancelOnDrop(Option<Arc<Cancel>>);

impl CancelOnDrop {
    fn disarm(mut self) -> Self {
        self.0 = None;
        self
    }
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if let Some(cancel) = self.0.take() {
            cancel.request();
        }
    }
}

const WM_APP_WAKE: u32 = WM_APP + 1;

/// None when Hello cannot ask at all. Runs on its own thread: creates the
/// owner window, starts the verification and pumps messages until it
/// completes or `cancel` asks it to stop (the operation is then cancelled).
fn verify(text: &str, cancel: &Cancel) -> Option<Verdict> {
    use windows::Foundation::{AsyncOperationCompletedHandler, AsyncStatus};
    use windows::Security::Credentials::UI::{
        UserConsentVerificationResult, UserConsentVerifier, UserConsentVerifierAvailability,
    };
    use windows::Win32::System::WinRT::IUserConsentVerifierInterop;
    use windows::core::HSTRING;
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::WindowsAndMessaging::{DispatchMessageW, GetMessageW, MSG, PM_NOREMOVE, PeekMessageW, TranslateMessage};

    // SAFETY: MSG is plain data; all zero is a valid value.
    let mut message: MSG = unsafe { std::mem::zeroed() };
    // SAFETY: a valid MSG out pointer; this creates the thread's message queue.
    unsafe { PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_NOREMOVE) };
    // SAFETY: no preconditions.
    let thread = unsafe { GetCurrentThreadId() };
    cancel.thread.store(thread, Ordering::SeqCst);
    if cancel.requested() {
        return Some(Verdict::NoAnswer);
    }
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
    // Completion wakes the pump (the handler runs on any thread).
    operation
        .SetCompleted(&AsyncOperationCompletedHandler::new(move |_, _| {
            // SAFETY: posting to this prompt's thread; a gone thread fails harmlessly.
            unsafe { PostThreadMessageW(thread, WM_APP_WAKE, 0, 0) };
            Ok(())
        }))
        .ok()?;
    // wakeup-allow: each pass waits for a window message, the completion or a cancel.
    loop {
        if operation.Status().ok()? != AsyncStatus::Started {
            break;
        }
        if cancel.requested() {
            let _ = operation.Cancel();
            drop(window);
            return Some(Verdict::NoAnswer);
        }
        // SAFETY: a valid MSG out pointer; null window = every message of this thread.
        let got = unsafe { GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) };
        if got <= 0 {
            break;
        }
        // SAFETY: a message GetMessageW returned.
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    let result = operation.GetResults().ok();
    drop(window);
    Some(match result? {
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
