//! The focus guard: no Computer Use call may change the person's frontmost
//! app, key window or window order.
//!
//! Prevention comes first and lives in the desktops (background routes never
//! activate or raise; actions that open menus tracking the person's pointer
//! are refused). This is the cure for what an app does on its own anyway: an
//! app that activates itself on launch (`NSApp.activate` in
//! `applicationDidFinishLaunching`), on a posted mouse-down, on an
//! accessibility focus write, or orders a window above the person's.
//!
//! Every acting call in background delivery:
//!
//! 1. takes a [`FocusSnapshot`] and the person's input count before acting;
//! 2. checks again right after acting (for `launch_app`, every
//!    [`TAIL_STEP`] for [`LAUNCH_TAIL`], since apps activate themselves a
//!    little after they report launched) and again after the settle wait;
//! 3. puts focus back ([`Desktop::restore_focus`]) when it moved and the
//!    person made no input meanwhile, and the change is the call's own: the
//!    new frontmost app is the target, this process, or (when a detector
//!    watches the person's input) any app at all;
//! 4. reports it in the result as `focus` and in the audit log.
//!
//! It never fights the person: any deliberate input of theirs during the
//! call leaves focus where it went. Foreground delivery (asked for, it
//! raises the window on purpose) is not guarded.
//!
//! cua-driver (MIT, read as a reference only) re-activates the prior app
//! from an NSWorkspace activation observer for any activation while a lease
//! is held, with no notion of who caused it; this guard instead attributes
//! the change (person input counter, target pids) before it acts.

use super::*;
use crate::desktop::FocusSnapshot;

/// How long `launch_app` keeps watching for the app's own late activation.
pub(super) const LAUNCH_TAIL: Duration = Duration::from_millis(1000);
/// How often it looks during that tail.
pub(super) const TAIL_STEP: Duration = Duration::from_millis(100);

/// One guarded call's starting point.
pub(super) struct FocusGuard {
    before: FocusSnapshot,
    /// The person's input count before the call (`None`: nothing watches).
    inputs: Option<u64>,
    /// Pids the call acts on: the target window's app; for `launch_app`,
    /// the app it started.
    targets: Vec<u32>,
    /// The target window ids.
    target_windows: Vec<String>,
    launch: bool,
}

/// What became of the person's focus during one call.
#[derive(Clone, Debug, PartialEq)]
pub(super) enum FocusReport {
    /// Unchanged.
    Kept,
    /// It moved without the person and was put back; `from` is the app
    /// that took it (or raised a window over theirs).
    Restored { from: String },
    /// The person moved it themselves (their input during the call): left alone.
    PersonMoved { to: String },
    /// It moved and stayed: why it was not put back.
    NotRestored { to: String, reason: String },
}

impl FocusReport {
    pub(super) fn to_json(&self) -> Value {
        match self {
            FocusReport::Kept => json!({"kept": true}),
            FocusReport::Restored { from } => json!({"kept": true, "restored_from": from}),
            FocusReport::PersonMoved { to } => {
                json!({"kept": false, "moved_by": "person", "moved_to": to})
            }
            FocusReport::NotRestored { to, reason } => {
                json!({"kept": false, "moved_to": to, "not_restored": reason})
            }
        }
    }

    /// Adds `focus` to a result: always on success, and on a failure only
    /// when focus did not simply stay.
    pub(super) fn attach(&self, out: &mut ToolOutput) {
        if (!out.is_error || *self != FocusReport::Kept) && out.body.is_object() {
            out.body["focus"] = self.to_json();
        }
    }

    /// Two readings of one call: the later change wins, and a change is
    /// never hidden by a later reading that found focus as it was.
    fn then(self, later: FocusReport) -> FocusReport {
        if later == FocusReport::Kept { self } else { later }
    }
}

/// Whether `now` differs from `before` in a way that disturbs the person.
fn moved(before: &FocusSnapshot, now: &FocusSnapshot, targets: &[u32]) -> bool {
    if now.pid != before.pid {
        return true;
    }
    if let (Some(b), Some(n)) = (&before.window_id, &now.window_id)
        && b != n
    {
        return true;
    }
    // A target ordered a window above the person's without activating.
    !targets.contains(&before.pid)
        && now.top_pid != before.top_pid
        && now.top_pid.is_some_and(|p| targets.contains(&p))
}

impl Engine {
    /// The guard for an acting call in background delivery, or `None`
    /// (nothing acts, foreground delivery, or the desktop cannot tell).
    pub(super) fn focus_begin(&self, tool: &tools::Tool, args: &Value) -> Option<FocusGuard> {
        if !tool.acts() || asks_foreground(args) {
            return None;
        }
        let before = self.desktop.focus_snapshot()?;
        let inputs = self.takeover.input_count();
        let window = args_str(args, "window_id");
        let targets = window
            .and_then(|id| self.desktop.window(id).ok().flatten())
            .map(|w| vec![w.pid])
            .unwrap_or_default();
        Some(FocusGuard {
            before,
            inputs,
            targets,
            target_windows: window.map(|w| vec![w.to_string()]).unwrap_or_default(),
            launch: tool.name == "launch_app",
        })
    }

    /// The check right after the desktop acted. `launch_app` keeps
    /// watching for [`LAUNCH_TAIL`]: apps activate themselves a little after
    /// LaunchServices reports them launched.
    pub(super) fn focus_after_action(&self, g: &mut FocusGuard, out: &ToolOutput) -> FocusReport {
        if g.launch
            && !out.is_error
            && let Some(pid) = out.body.get("pid").and_then(Value::as_u64)
        {
            g.targets.push(pid as u32);
        }
        let mut report = self.focus_check(g);
        if g.launch && !out.is_error {
            let start = (self.clock)();
            while (self.clock)().saturating_sub(start) < LAUNCH_TAIL {
                (self.sleep)(TAIL_STEP);
                report = report.then(self.focus_check(g));
            }
        }
        report
    }

    /// The check after the settle wait (or at once, for a call with none).
    pub(super) fn focus_after_settle(
        &self,
        g: &FocusGuard,
        earlier: Option<FocusReport>,
    ) -> FocusReport {
        earlier.unwrap_or(FocusReport::Kept).then(self.focus_check(g))
    }

    fn focus_check(&self, g: &FocusGuard) -> FocusReport {
        let Some(now) = self.desktop.focus_snapshot() else { return FocusReport::Kept };
        if !moved(&g.before, &now, &g.targets) {
            return FocusReport::Kept;
        }
        let taker = self.focus_taker(g, &now);
        let after = self.takeover.input_count();
        let watched = g.inputs.is_some() && after.is_some();
        let person = match (g.inputs, after) {
            (Some(a), Some(b)) => b > a,
            // No counter: the person counts as active while the takeover
            // rule says they are (errs toward leaving focus alone).
            _ => !self.takeover.wait_idle(Duration::ZERO),
        };
        if person {
            return FocusReport::PersonMoved { to: now.app_id };
        }
        let own = std::process::id();
        let attributable = g.targets.contains(&now.pid)
            || now.pid == own
            || (now.pid == g.before.pid
                && now.window_id.as_ref().is_some_and(|w| g.target_windows.contains(w)))
            || (now.pid == g.before.pid && now.top_pid.is_some_and(|p| g.targets.contains(&p)));
        if !watched && !attributable {
            return FocusReport::NotRestored {
                to: now.app_id,
                reason: "focus went to an app this call did not act on, and nothing watches the person's input to tell whether they moved it".into(),
            };
        }
        match self.desktop.restore_focus(&g.before) {
            Ok(true) => FocusReport::Restored { from: taker },
            Ok(false) => FocusReport::NotRestored {
                to: now.app_id,
                reason: "the person's app did not take focus back".into(),
            },
            Err(e) => FocusReport::NotRestored { to: now.app_id, reason: e.to_string() },
        }
    }

    /// The app that took focus (or raised a window over the person's).
    fn focus_taker(&self, g: &FocusGuard, now: &FocusSnapshot) -> String {
        let window_moved =
            matches!((&g.before.window_id, &now.window_id), (Some(b), Some(n)) if b != n);
        if now.pid != g.before.pid || window_moved {
            return now.app_id.clone();
        }
        let Some(top) = now.top_pid else { return now.app_id.clone() };
        self.desktop
            .list_apps()
            .ok()
            .and_then(|apps| apps.into_iter().find(|a| a.pid == top).map(|a| a.id))
            .unwrap_or_else(|| format!("pid:{top}"))
    }
}

/// Whether the call (or any step of a batch) asks for foreground delivery,
/// which raises the window on purpose.
fn asks_foreground(args: &Value) -> bool {
    let fg = |v: &Value| v.get("delivery").and_then(Value::as_str) == Some("foreground");
    fg(args) || args.get("actions").and_then(Value::as_array).is_some_and(|a| a.iter().any(fg))
}
