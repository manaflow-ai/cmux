//! The owner of cmux NEXT's background ready copy decisions.
//!
//! The setting `app.backgroundReady` (off by default) lets a Cmd-Q leave the
//! process running with no window, so the next open shows a ready app instead
//! of a cold launch ("how can we improve those? startup in background maybe?",
//! Leo, 2026-11-17). Every rule of that copy lives here: whether a quit stays
//! hidden, how the hidden copy holds its windows, whether the login item is
//! registered, whether the login-time pre-read agent is registered, what a
//! launch does, when the hidden copy exits for an update
//! and whether Chromium warms up. Swift is only the window and AppKit glue: it
//! reads its inputs, calls these rules through the C ABI in [`ffi`]
//! (cmux-app-ffi/include/cmux_background_ready.h, module CCmuxBackgroundReadyFFI in the app
//! FFI library) and carries out the answer. With the mode Off every rule gives
//! the answer the app had before the setting existed.

pub mod ffi;

/// `app.backgroundReady`: whether, and from when, a ready copy waits in the background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Mode {
    /// The shipped default: a quit quits, as before the setting.
    Off = 0,
    /// A Cmd-Q hides the app; the copy waits until the next open.
    AfterQuit = 1,
    /// As AfterQuit, and a login item starts a hidden copy at login.
    AfterQuitAndLogin = 2,
    /// Nothing stays running: a quit quits, and at login a LaunchAgent runs
    /// a small reader (cmux-launch-preread) that reads the app's code into
    /// the page cache and exits, so the first open after a reboot reads it
    /// from memory instead of disk. It never starts the app.
    WarmAtLogin = 3,
}

impl Mode {
    /// The setting's JSON value. Anything else, a missing value included, is
    /// Off: an unreadable setting never keeps a process the user did not ask for.
    pub fn parse(value: Option<&[u8]>) -> Self {
        match value {
            Some(b"afterQuit") => Mode::AfterQuit,
            Some(b"afterQuitAndLogin") => Mode::AfterQuitAndLogin,
            Some(b"warmAtLogin") => Mode::WarmAtLogin,
            _ => Mode::Off,
        }
    }

    /// An unknown value from the C side is Off, for the same reason.
    pub fn from_u8(value: u8) -> Self {
        match value {
            1 => Mode::AfterQuit,
            2 => Mode::AfterQuitAndLogin,
            3 => Mode::WarmAtLogin,
            _ => Mode::Off,
        }
    }

    /// The two modes that keep a hidden copy after a Cmd-Q. Off and
    /// WarmAtLogin quit as before the setting.
    pub fn stays_after_quit(self) -> bool {
        matches!(self, Mode::AfterQuit | Mode::AfterQuitAndLogin)
    }
}

/// Where a quit came from: the Swift `QuitOrigin` cases
/// (Sources/CmuxNextDaemonService/QuitChoice.swift).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum QuitOrigin {
    /// Cmd-Q, the app menu's Quit or the Dock's Quit.
    Interactive = 0,
    /// A quit the user named outright: Quit Completely, Restart to Update.
    Explicit = 1,
    /// The CLI or the control socket.
    Scripted = 2,
    /// Log out, restart or shut down.
    PowerOff = 3,
    /// SIGTERM, SIGINT or SIGHUP.
    Signal = 4,
}

impl QuitOrigin {
    /// None for a value Swift does not send: the caller exits on it.
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(QuitOrigin::Interactive),
            1 => Some(QuitOrigin::Explicit),
            2 => Some(QuitOrigin::Scripted),
            3 => Some(QuitOrigin::PowerOff),
            4 => Some(QuitOrigin::Signal),
            _ => None,
        }
    }
}

/// What the quit does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum QuitAction {
    Exit = 0,
    StayHidden = 1,
}

/// Stay hidden only for a plain Cmd-Q with a mode that keeps a copy
/// ([`Mode::stays_after_quit`]: not Off, not WarmAtLogin) and nothing that
/// needs the process gone. Every other origin is a request to end this
/// process: Quit Completely and Restart to Update (explicit) say so by name,
/// a script that quits the app expects it gone (scripted), the system cannot
/// log out or shut down while an app refuses to end (powerOff), and a signal
/// is the process's end. An update that installs on quit needs the process to
/// exit for the installer to run, and Quit Completely set for this quit wins
/// over the setting.
pub fn on_quit(
    mode: Mode,
    origin: Option<QuitOrigin>,
    update_installs_on_quit: bool,
    quit_completely: bool,
) -> QuitAction {
    if mode.stays_after_quit()
        && origin == Some(QuitOrigin::Interactive)
        && !update_installs_on_quit
        && !quit_completely
    {
        QuitAction::StayHidden
    } else {
        QuitAction::Exit
    }
}

/// How the hidden copy holds what the user had open.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum HiddenPlan {
    /// Order the windows out and keep their controllers and pages; showing is
    /// ordering them in, the fastest open. The default.
    KeepWindows = 0,
    /// Close the windows as a user close and release their pages. Chromium
    /// stays initialised but idle, since CEF cannot initialise twice in one
    /// process; showing reopens the closed windows.
    CloseWindows = 1,
    /// No window was ever built and Chromium never started: the process the
    /// login item started.
    NativeOnly = 2,
}

/// The measurement override (CMUX_NEXT_BACKGROUND_READY_PLAN, read by Swift):
/// "keep" or "close"; anything else is no override.
pub fn parse_plan_override(value: Option<&[u8]>) -> Option<HiddenPlan> {
    match value {
        Some(b"keep") => Some(HiddenPlan::KeepWindows),
        Some(b"close") => Some(HiddenPlan::CloseWindows),
        _ => None,
    }
}

/// A login-started copy has nothing to keep, so it is NativeOnly whatever the
/// override says. Otherwise the override picks (it exists to measure both
/// plans on one build), and the default keeps the windows: the open is an
/// order-in with no page to rebuild. The mode does not change the plan: it is
/// asked only once the quit stayed hidden.
pub fn hidden_plan(
    _mode: Mode,
    started_at_login: bool,
    plan_override: Option<HiddenPlan>,
) -> HiddenPlan {
    if started_at_login {
        HiddenPlan::NativeOnly
    } else {
        plan_override.unwrap_or(HiddenPlan::KeepWindows)
    }
}

/// Only AfterQuitAndLogin starts a copy at login, so only it registers the
/// login item; every other mode unregisters it, so turning the setting down
/// takes the item away.
pub fn registers_login_item(mode: Mode) -> bool {
    mode == Mode::AfterQuitAndLogin
}

/// Only WarmAtLogin registers the pre-read LaunchAgent (the bundle's
/// `Contents/Library/LaunchAgents/com.cmux.launch-preread.plist`, label
/// [`preread_agent_label`]); every other mode unregisters it, so switching
/// to any other value, Off included, takes the agent away. AfterQuitAndLogin
/// needs no pre-read: its login item starts the app itself, which reads the
/// same pages; AfterQuit starts nothing at login.
pub fn registers_preread_agent(mode: Mode) -> bool {
    mode == Mode::WarmAtLogin
}

/// The pre-read agent's launchd label for the app whose bundle id is
/// `bundle_id`: one per build, so two channels installed side by side
/// (stable, NIGHTLY, a tagged DEV build) each register their own agent and
/// unregistering one leaves the other. scripts/cmux-next/bundle-server-helper.sh
/// stamps the same label into the bundle's plist.
pub fn preread_agent_label(bundle_id: &str) -> String {
    format!("{bundle_id}.launch-preread")
}

/// Quit Completely (the menu row that ends a hidden copy) is offered only
/// while a mode keeps one: WarmAtLogin keeps nothing running, so a quit is
/// already complete.
pub fn offers_quit_completely(mode: Mode) -> bool {
    mode.stays_after_quit()
}

/// What a launch does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum LaunchAction {
    /// The ordinary launch: windows and the Chromium warm-up.
    Normal = 0,
    /// The login item's launch: no window and no Chromium warm-up, so login
    /// pays for the native process only.
    StartHidden = 1,
    /// A login launch while the mode is not AfterQuitAndLogin (WarmAtLogin
    /// included: it never starts the app, only the reader): the
    /// registration is stale (the setting changed while the app was not
    /// running to unregister it). Unregister and exit, so a user who turned it
    /// off never gets a process at login again.
    ExitAndUnregister = 2,
}

/// A launch the user made (Dock, Finder, `open`) is always Normal, whatever the
/// mode: the setting changes what a quit and a login do, never an open.
pub fn at_launch(mode: Mode, launched_as_login_item: bool) -> LaunchAction {
    match (launched_as_login_item, mode) {
        (false, _) => LaunchAction::Normal,
        (true, Mode::AfterQuitAndLogin) => LaunchAction::StartHidden,
        (true, _) => LaunchAction::ExitAndUnregister,
    }
}

/// A hidden copy with a staged update quits, so the installer runs and the next
/// open is the new version; a hidden copy would otherwise keep the old one
/// running indefinitely. A shown copy waits for the user's own quit, as before.
pub fn exits_for_update(_mode: Mode, hidden: bool, update_staged: bool) -> bool {
    hidden && update_staged
}

/// The login-started copy (NativeOnly) skips the Chromium warm-up until it is
/// first shown: login pays for no browser. Every other plan already has
/// Chromium initialised, and a shown copy needs it.
pub fn starts_chromium_warmup(plan: Option<HiddenPlan>, shown: bool) -> bool {
    plan != Some(HiddenPlan::NativeOnly) || shown
}

impl HiddenPlan {
    /// None for a value this crate never returns.
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(HiddenPlan::KeepWindows),
            1 => Some(HiddenPlan::CloseWindows),
            2 => Some(HiddenPlan::NativeOnly),
            _ => None,
        }
    }
}
