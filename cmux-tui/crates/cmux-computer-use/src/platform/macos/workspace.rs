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

/// The bundle ids of every installed app known by `name` (case-insensitive):
/// its localized display name in the person's language ("Systemeinstellungen"
/// on a German Mac), its bundle name, and its file name, across the app
/// folders, plus the app LaunchServices finds by that name. Several ids for a
/// shared name; none for an unknown one. The index is rebuilt after
/// NAME_INDEX_TTL, so installed and removed apps show up.
pub fn apps_named(name: &str) -> Vec<String> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    use std::time::Instant;
    // (built at, folder index, answers so far: a menu walk asks once per item
    // and per sibling, so LaunchServices is asked once per name per TTL).
    type Index = (Instant, HashMap<String, Vec<String>>, HashMap<String, Vec<String>>);
    static INDEX: OnceLock<Mutex<Option<Index>>> = OnceLock::new();
    let key = name.trim().to_lowercase();
    if key.is_empty() {
        return Vec::new();
    }
    let cell = INDEX.get_or_init(|| Mutex::new(None));
    {
        let mut guard = cell.lock().unwrap_or_else(|e| e.into_inner());
        if guard.as_ref().is_none_or(|(at, _, _)| at.elapsed() > NAME_INDEX_TTL) {
            *guard = Some((Instant::now(), build_name_index(), HashMap::new()));
        }
        if let Some(hit) = guard.as_ref().and_then(|(_, _, answers)| answers.get(&key)) {
            return hit.clone();
        }
    }
    let mut ids = {
        let guard = cell.lock().unwrap_or_else(|e| e.into_inner());
        guard.as_ref().and_then(|(_, index, _)| index.get(&key).cloned()).unwrap_or_default()
    };
    if let Some(id) = launch_services_id(name.trim())
        && !ids.contains(&id)
    {
        ids.push(id);
    }
    if let Some((_, _, answers)) = cell.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        answers.insert(key, ids.clone());
    }
    ids
}

/// How long the app-name index is reused.
const NAME_INDEX_TTL: Duration = Duration::from_secs(60);

fn app_folders() -> Vec<std::path::PathBuf> {
    let mut dirs: Vec<std::path::PathBuf> = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Cryptexes/App/System/Applications",
        "/System/Library/CoreServices",
        "/System/Library/CoreServices/Applications",
    ]
    .iter()
    .map(std::path::PathBuf::from)
    .collect();
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(std::path::PathBuf::from(home).join("Applications"));
    }
    dirs
}

fn build_name_index() -> std::collections::HashMap<String, Vec<String>> {
    let mut map: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    let mut add = |name: &str, id: &str| {
        let key = name.trim().to_lowercase();
        if key.is_empty() || id.is_empty() {
            return;
        }
        let ids = map.entry(key).or_default();
        if !ids.iter().any(|x| x == id) {
            ids.push(id.to_string());
        }
    };
    autoreleasepool(|_| {
        let Ok(fm_cls) = class(c"NSFileManager") else { return };
        let Ok(bundle_cls) = class(c"NSBundle") else { return };
        // SAFETY: +defaultManager returns the shared file manager.
        let fm: Option<Retained<AnyObject>> = unsafe { msg_send![fm_cls, defaultManager] };
        let Some(fm) = fm else { return };
        for dir in app_folders() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("app") {
                    continue;
                }
                let Some(p) = path.to_str().and_then(Cf::string) else { continue };
                let p_obj: *const AnyObject = p.ptr().cast();
                // SAFETY: +bundleWithPath: takes an NSString; nil or an NSBundle.
                let bundle: Option<Retained<AnyObject>> = unsafe { msg_send![bundle_cls, bundleWithPath: p_obj] };
                let Some(bundle) = bundle else { continue };
                let Some(id) = ns_string(unsafe { msg_send![&*bundle, bundleIdentifier] }) else { continue };
                // The localized display name, without .app (-displayNameAtPath:).
                if let Some(display) = ns_string(unsafe { msg_send![&*fm, displayNameAtPath: p_obj] }) {
                    add(display.strip_suffix(".app").unwrap_or(&display), &id);
                }
                for key in [c"CFBundleDisplayName", c"CFBundleName"] {
                    let Some(k) = key.to_str().ok().and_then(Cf::string) else { continue };
                    let k_obj: *const AnyObject = k.ptr().cast();
                    // SAFETY: -objectForInfoDictionaryKey: returns nil or an object; only a string is read.
                    let value: Option<Retained<AnyObject>> =
                        unsafe { msg_send![&*bundle, objectForInfoDictionaryKey: k_obj] };
                    if let Some(v) = value.and_then(|v| ns_string(Some(v))) {
                        add(&v, &id);
                    }
                }
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    add(stem, &id);
                }
            }
        }
    });
    map
}

/// The bundle id of the app LaunchServices finds by name, if any.
fn launch_services_id(name: &str) -> Option<String> {
    autoreleasepool(|_| {
        let ws = shared_workspace().ok()?;
        let n = Cf::string(name)?;
        let n_obj: *const AnyObject = n.ptr().cast();
        // SAFETY: -fullPathForApplication: takes an NSString and returns nil
        // or an NSString path.
        let path: Option<Retained<AnyObject>> = unsafe { msg_send![&*ws, fullPathForApplication: n_obj] };
        let path = path?;
        let bundle_cls = class(c"NSBundle").ok()?;
        // SAFETY: +bundleWithPath: takes an NSString; -bundleIdentifier returns nil or an NSString.
        let bundle: Option<Retained<AnyObject>> = unsafe { msg_send![bundle_cls, bundleWithPath: &*path] };
        let bundle = bundle?;
        ns_string(unsafe { msg_send![&*bundle, bundleIdentifier] })
    })
}
