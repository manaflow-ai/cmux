//! Running apps and app launch through NSWorkspace / NSRunningApplication.
//!
//! Plain Objective-C messages through objc2; strings and URLs cross as their
//! toll-free bridged CoreFoundation types.

use std::sync::mpsc;
use std::time::Duration;

use block2::RcBlock;
use objc2::msg_send;
use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::{AnyClass, AnyObject, Bool};

use super::sys::Cf;
use crate::desktop::{DResult, DesktopError};

/// How long launch_app waits for the app to report it started.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(30);

const POLICY_REGULAR: isize = 0;
const POLICY_ACCESSORY: isize = 1;

/// One running app as NSRunningApplication sees it.
#[derive(Clone, Debug)]
pub struct RunningApp {
    pub pid: i32,
    pub bundle_id: Option<String>,
    /// The executable's file name (`executableURL`).
    pub executable: Option<String>,
    pub name: String,
    pub policy: isize,
    pub active: bool,
    pub hidden: bool,
}

impl RunningApp {
    /// The policy identity: the bundle id, else the executable name.
    pub fn id(&self) -> String {
        self.bundle_id
            .clone()
            .filter(|b| !b.is_empty())
            .or_else(|| self.executable.clone())
            .unwrap_or_else(|| format!("pid:{}", self.pid))
    }

    pub fn is_regular(&self) -> bool {
        self.policy == POLICY_REGULAR
    }

    pub fn is_accessory(&self) -> bool {
        self.policy == POLICY_ACCESSORY
    }
}

fn class(name: &std::ffi::CStr) -> DResult<&'static AnyClass> {
    AnyClass::get(name).ok_or_else(|| DesktopError::Failed(format!("{name:?} is not available")))
}

fn ns_string(o: Option<Retained<AnyObject>>) -> Option<String> {
    let o = o?;
    let p: *const AnyObject = &*o;
    Cf::retained(p.cast()).and_then(|s| s.as_string())
}

fn shared_workspace() -> DResult<Retained<AnyObject>> {
    let cls = class(c"NSWorkspace")?;
    // SAFETY: +[NSWorkspace sharedWorkspace] returns the shared instance.
    let ws: Option<Retained<AnyObject>> = unsafe { msg_send![cls, sharedWorkspace] };
    ws.ok_or_else(|| DesktopError::Failed("NSWorkspace is not available".into()))
}

fn describe(app: &AnyObject) -> Option<RunningApp> {
    // SAFETY: app is an NSRunningApplication; each selector exists on it
    // since macOS 10.6 and returns the declared type.
    unsafe {
        let terminated: Bool = msg_send![app, isTerminated];
        if terminated.as_bool() {
            return None;
        }
        let pid: i32 = msg_send![app, processIdentifier];
        if pid <= 0 {
            return None;
        }
        let policy: isize = msg_send![app, activationPolicy];
        let active: Bool = msg_send![app, isActive];
        let hidden: Bool = msg_send![app, isHidden];
        let bundle_id = ns_string(msg_send![app, bundleIdentifier]);
        let url: Option<Retained<AnyObject>> = msg_send![app, executableURL];
        let executable = url
            .and_then(|u| ns_string(msg_send![&*u, lastPathComponent]))
            .filter(|s| !s.is_empty());
        let name = ns_string(msg_send![app, localizedName])
            .filter(|s| !s.is_empty())
            .or_else(|| executable.clone())
            .unwrap_or_default();
        Some(RunningApp {
            pid,
            bundle_id,
            executable,
            name,
            policy,
            active: active.as_bool(),
            hidden: hidden.as_bool(),
        })
    }
}

/// The app of one pid, fresh from the system (also when the workspace's
/// cached list has not caught up yet).
pub fn app_for_pid(pid: i32) -> Option<RunningApp> {
    autoreleasepool(|_| {
        let cls = AnyClass::get(c"NSRunningApplication")?;
        // SAFETY: +runningApplicationWithProcessIdentifier: returns nil or an app.
        let app: Option<Retained<AnyObject>> =
            unsafe { msg_send![cls, runningApplicationWithProcessIdentifier: pid] };
        app.as_deref().and_then(describe)
    })
}

/// The frontmost app's pid, as NSWorkspace knows it.
pub fn frontmost_pid() -> Option<i32> {
    autoreleasepool(|_| {
        let ws = shared_workspace().ok()?;
        // SAFETY: -frontmostApplication returns nil or an NSRunningApplication.
        let app: Option<Retained<AnyObject>> = unsafe { msg_send![&*ws, frontmostApplication] };
        let app = app?;
        // SAFETY: -processIdentifier returns pid_t.
        let pid: i32 = unsafe { msg_send![&*app, processIdentifier] };
        (pid > 0).then_some(pid)
    })
}

/// Asks the system to make `pid` the active app again (the person's app,
/// after another took focus without them). True when the request was taken.
pub fn activate(pid: i32) -> bool {
    autoreleasepool(|_| {
        let Some(cls) = AnyClass::get(c"NSRunningApplication") else { return false };
        // SAFETY: +runningApplicationWithProcessIdentifier: returns nil or an app.
        let app: Option<Retained<AnyObject>> =
            unsafe { msg_send![cls, runningApplicationWithProcessIdentifier: pid] };
        let Some(app) = app else { return false };
        // SAFETY: -activateWithOptions: takes NSApplicationActivationOptions (0: none).
        let ok: Bool = unsafe { msg_send![&*app, activateWithOptions: 0usize] };
        ok.as_bool()
    })
}

/// A running, not terminated app with `bundle_id`.
fn running(bundle_id: &str) -> Option<RunningApp> {
    autoreleasepool(|_| {
        let cls = AnyClass::get(c"NSRunningApplication")?;
        let id = Cf::string(bundle_id)?;
        let id_obj: *const AnyObject = id.ptr().cast();
        // SAFETY: +runningApplicationsWithBundleIdentifier: takes an NSString
        // (toll-free bridged CFString) and returns an NSArray.
        let list: Option<Retained<AnyObject>> =
            unsafe { msg_send![cls, runningApplicationsWithBundleIdentifier: id_obj] };
        let list = list?;
        // SAFETY: -count on an NSArray.
        let count: usize = unsafe { msg_send![&*list, count] };
        (0..count).find_map(|i| {
            // SAFETY: i < count; -objectAtIndex: returns an NSRunningApplication.
            let app: Option<Retained<AnyObject>> = unsafe { msg_send![&*list, objectAtIndex: i] };
            app.as_deref().and_then(describe)
        })
    })
}

/// Launches the app with `bundle_id` without activating it, and returns it
/// once it runs. An app that already runs with a window on screen is
/// returned as it is, with no open request: LaunchServices would send it a
/// reopen event, which apps answer by showing (and often activating) a
/// window. One with no window gets the reopen, so the agent has a window to
/// work in; the engine's focus guard puts back any activation it causes.
pub fn launch(bundle_id: &str) -> DResult<RunningApp> {
    if let Some(app) = running(bundle_id)
        && super::cgwindows::on_screen().iter().any(|w| w.pid == app.pid && w.is_app_window())
    {
        return Ok(app);
    }
    let rx = autoreleasepool(|_| start_launch(bundle_id))?;
    match rx.recv_timeout(LAUNCH_TIMEOUT) {
        Ok(Ok(pid)) => app_for_pid(pid).ok_or_else(|| {
            DesktopError::Failed(format!("{bundle_id} started (pid {pid}) and quit at once"))
        }),
        Ok(Err(message)) => {
            Err(DesktopError::Failed(format!("could not open {bundle_id}: {message}")))
        }
        Err(_) => Err(DesktopError::Failed(format!(
            "{bundle_id} did not finish launching in {} s",
            LAUNCH_TIMEOUT.as_secs()
        ))),
    }
}

type LaunchResult = Result<i32, String>;

fn start_launch(bundle_id: &str) -> DResult<mpsc::Receiver<LaunchResult>> {
    let ws = shared_workspace()?;
    let id = Cf::string(bundle_id).ok_or_else(|| DesktopError::Failed("bad bundle id".into()))?;
    let id_obj: *const AnyObject = id.ptr().cast();
    // SAFETY: -URLForApplicationWithBundleIdentifier: takes an NSString
    // (a CFString is toll-free bridged) and returns nil or an NSURL.
    let url: Option<Retained<AnyObject>> =
        unsafe { msg_send![&*ws, URLForApplicationWithBundleIdentifier: id_obj] };
    let url = url.ok_or_else(|| {
        DesktopError::TargetNotFound(format!("no installed app has the bundle id {bundle_id}"))
    })?;
    let config_cls = class(c"NSWorkspaceOpenConfiguration")?;
    // SAFETY: +configuration returns a new configuration; -setActivates:
    // takes a BOOL (macOS 10.15+).
    let config: Option<Retained<AnyObject>> = unsafe { msg_send![config_cls, configuration] };
    let config =
        config.ok_or_else(|| DesktopError::Failed("NSWorkspaceOpenConfiguration failed".into()))?;
    // Not activated; and no LaunchServices UI (a first-launch or update
    // prompt is a modal panel that takes the person's keyboard): such a
    // launch fails with a message instead.
    unsafe {
        let _: () = msg_send![&*config, setActivates: Bool::NO];
        let _: () = msg_send![&*config, setAddsToRecentItems: Bool::NO];
        let _: () = msg_send![&*config, setPromptsUserIfNeeded: Bool::NO];
    }
    let (tx, rx) = mpsc::channel::<LaunchResult>();
    let block = RcBlock::new(move |app: *mut AnyObject, error: *mut AnyObject| {
        let result = if app.is_null() {
            // SAFETY: error is nil or an NSError for the duration of the call.
            let message = unsafe { error.as_ref() }
                .and_then(|e| ns_string(unsafe { msg_send![e, localizedDescription] }))
                .unwrap_or_else(|| "unknown error".into());
            Err(message)
        } else {
            // SAFETY: app is a live NSRunningApplication for the call.
            Ok(unsafe { msg_send![&*app, processIdentifier] })
        };
        let _ = tx.send(result);
    });
    // SAFETY: the completion handler block has the signature
    // void (^)(NSRunningApplication *, NSError *); NSWorkspace copies it.
    unsafe {
        let _: () = msg_send![
            &*ws,
            openApplicationAtURL: &*url,
            configuration: &*config,
            completionHandler: &*block
        ];
    }
    Ok(rx)
}
