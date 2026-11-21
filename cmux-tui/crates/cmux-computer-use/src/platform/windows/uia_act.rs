//! Semantic actions on UI Automation elements: press (Invoke, Toggle,
//! SelectionItem, ExpandCollapse, then MSAA's default action), values,
//! expand and collapse, increment and decrement. None of them activates
//! the window, except `focus`, which is refused unless the window is
//! already in front.

use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::{GA_ROOT, GetAncestor, GetForegroundWindow};
use windows::core::BSTR;

use super::uia::{COLLAPSED, EXPANDED, INVOKE_DEADLINE, LEAF, State, Uia, center_of, uia_error};
use super::win::Hwnd;
use crate::desktop::{ActionOutcome, DResult, DesktopError};

/// Where typed text for an element goes.
pub enum TextTarget {
    /// The element is (or has focus in) this child window: post WM_CHAR.
    Window(Hwnd),
    /// The element has no window of its own and no focus: append through
    /// its Value pattern (the background route that needs no focus).
    AppendValue,
}

fn pattern<T: windows::core::Interface>(
    el: &IUIAutomationElement,
    id: UIA_PATTERN_ID,
) -> Option<T> {
    // SAFETY: a COM call on this thread's element.
    unsafe { el.GetCurrentPatternAs::<T>(id) }.ok()
}

fn with_cursor(mut out: ActionOutcome, el: &IUIAutomationElement, id: &str) -> ActionOutcome {
    if let Ok(p) = center_of(el, id) {
        out.cursor_at = Some(p);
    }
    out
}

fn toggle_state(p: &IUIAutomationTogglePattern) -> Option<ToggleState> {
    // SAFETY: a COM call on this thread's object.
    unsafe { p.CurrentToggleState() }.ok()
}

fn press_now(state: &State, hwnd: Hwnd, id: &str) -> DResult<ActionOutcome> {
    let el = state.element(hwnd, id)?;
    let err = |e| uia_error(e, id, "the press");
    // SAFETY: COM calls on this thread's element and its patterns.
    unsafe {
        if let Some(p) = pattern::<IUIAutomationInvokePattern>(&el, UIA_InvokePatternId) {
            p.Invoke().map_err(err)?;
            return Ok(with_cursor(ActionOutcome::delivered("uia_invoke"), &el, id));
        }
        if let Some(p) = pattern::<IUIAutomationTogglePattern>(&el, UIA_TogglePatternId) {
            let before = toggle_state(&p);
            p.Toggle().map_err(err)?;
            let after = toggle_state(&p);
            let out = if before.is_some() && after != before {
                ActionOutcome::confirmed("uia_toggle")
            } else {
                ActionOutcome::delivered("uia_toggle")
            };
            return Ok(with_cursor(out, &el, id));
        }
        if let Some(p) =
            pattern::<IUIAutomationSelectionItemPattern>(&el, UIA_SelectionItemPatternId)
        {
            p.Select().map_err(err)?;
            let out = if p.CurrentIsSelected().is_ok_and(|s| s.as_bool()) {
                ActionOutcome::confirmed("uia_select")
            } else {
                ActionOutcome::delivered("uia_select")
            };
            return Ok(with_cursor(out, &el, id));
        }
        if let Some(p) =
            pattern::<IUIAutomationExpandCollapsePattern>(&el, UIA_ExpandCollapsePatternId)
        {
            match p.CurrentExpandCollapseState().map(|s| s.0) {
                Ok(COLLAPSED) => p.Expand().map_err(err)?,
                Ok(LEAF) | Err(_) => {}
                Ok(_) => p.Collapse().map_err(err)?,
            }
            return Ok(with_cursor(ActionOutcome::delivered("uia_expand_collapse"), &el, id));
        }
        if let Some(p) =
            pattern::<IUIAutomationLegacyIAccessiblePattern>(&el, UIA_LegacyIAccessiblePatternId)
            && p.CurrentDefaultAction().is_ok_and(|a| !a.is_empty())
        {
            p.DoDefaultAction().map_err(err)?;
            return Ok(with_cursor(ActionOutcome::delivered("msaa_default_action"), &el, id));
        }
    }
    Err(DesktopError::Unsupported(format!(
        "element {id} has no press action (no Invoke, Toggle, SelectionItem, ExpandCollapse or default action); click its point instead"
    )))
}

fn expand_collapse(state: &State, hwnd: Hwnd, id: &str, expand: bool) -> DResult<ActionOutcome> {
    let el = state.element(hwnd, id)?;
    let p = pattern::<IUIAutomationExpandCollapsePattern>(&el, UIA_ExpandCollapsePatternId)
        .ok_or_else(|| {
            DesktopError::Unsupported(format!("element {id} cannot expand or collapse"))
        })?;
    let err = |e| uia_error(e, id, "expand/collapse");
    // SAFETY: COM calls on this thread's pattern.
    unsafe {
        if expand { p.Expand() } else { p.Collapse() }.map_err(err)?;
        let now = p.CurrentExpandCollapseState().map(|s| s.0);
        let done = matches!((expand, now), (true, Ok(EXPANDED)) | (false, Ok(COLLAPSED)));
        let route = if expand { "uia_expand" } else { "uia_collapse" };
        let out =
            if done { ActionOutcome::confirmed(route) } else { ActionOutcome::delivered(route) };
        Ok(with_cursor(out, &el, id))
    }
}

fn step(state: &State, hwnd: Hwnd, id: &str, up: bool) -> DResult<ActionOutcome> {
    let el = state.element(hwnd, id)?;
    let p = pattern::<IUIAutomationRangeValuePattern>(&el, UIA_RangeValuePatternId).ok_or_else(
        || DesktopError::Unsupported(format!("element {id} has no range value to step")),
    )?;
    let err = |e| uia_error(e, id, "the step");
    // SAFETY: COM calls on this thread's pattern.
    unsafe {
        let (value, min, max) = (
            p.CurrentValue().map_err(err)?,
            p.CurrentMinimum().map_err(err)?,
            p.CurrentMaximum().map_err(err)?,
        );
        let mut small = p.CurrentSmallChange().unwrap_or(0.0);
        if small <= 0.0 || !small.is_finite() {
            small = ((max - min) / 10.0).max(1.0);
        }
        let target =
            if up { value + small } else { value - small }.clamp(min.min(max), max.max(min));
        p.SetValue(target).map_err(err)?;
        let now = p.CurrentValue().unwrap_or(value);
        let out = if (now - target).abs() < 1e-9 {
            ActionOutcome::confirmed("uia_range_value")
        } else {
            ActionOutcome::delivered("uia_range_value")
        };
        Ok(with_cursor(out, &el, id))
    }
}

fn set_value_now(state: &State, hwnd: Hwnd, id: &str, value: &str) -> DResult<ActionOutcome> {
    let el = state.element(hwnd, id)?;
    let err = |e| uia_error(e, id, "setting the value");
    // SAFETY: COM calls on this thread's element and its patterns.
    unsafe {
        if let Some(p) = pattern::<IUIAutomationValuePattern>(&el, UIA_ValuePatternId)
            && !p.CurrentIsReadOnly().is_ok_and(|r| r.as_bool())
        {
            p.SetValue(&BSTR::from(value)).map_err(err)?;
            let out = if p.CurrentValue().is_ok_and(|v| v == value) {
                ActionOutcome::confirmed("uia_set_value")
            } else {
                ActionOutcome::delivered("uia_set_value")
            };
            return Ok(with_cursor(out, &el, id));
        }
        if let Some(p) = pattern::<IUIAutomationRangeValuePattern>(&el, UIA_RangeValuePatternId)
            && !p.CurrentIsReadOnly().is_ok_and(|r| r.as_bool())
        {
            let n: f64 = value.trim().parse().map_err(|_| {
                DesktopError::Unsupported(format!("element {id} takes a number, not {value:?}"))
            })?;
            p.SetValue(n).map_err(err)?;
            let out = if p.CurrentValue().is_ok_and(|v| (v - n).abs() < 1e-9) {
                ActionOutcome::confirmed("uia_range_value")
            } else {
                ActionOutcome::delivered("uia_range_value")
            };
            return Ok(with_cursor(out, &el, id));
        }
    }
    Err(DesktopError::Unsupported(format!(
        "element {id} has no settable value (read-only, or no Value pattern)"
    )))
}

impl Uia {
    pub fn press(&self, hwnd: Hwnd, id: &str) -> DResult<ActionOutcome> {
        let id = id.to_string();
        self.run_with(
            INVOKE_DEADLINE,
            || {
                Ok(ActionOutcome {
                    note:
                        "the press has not returned yet: the app is likely showing a modal dialog"
                            .into(),
                    ..ActionOutcome::delivered("uia_invoke")
                })
            },
            move |state| press_now(state, hwnd, &id),
        )
    }

    pub fn perform(&self, hwnd: Hwnd, id: &str, action: &str) -> DResult<ActionOutcome> {
        match action {
            "press" | "confirm" => self.press(hwnd, id),
            "expand" | "collapse" => {
                let (id, expand) = (id.to_string(), action == "expand");
                self.run(move |state| expand_collapse(state, hwnd, &id, expand))
            }
            "increment" | "decrement" => {
                let (id, up) = (id.to_string(), action == "increment");
                self.run(move |state| step(state, hwnd, &id, up))
            }
            "select" => {
                let id = id.to_string();
                self.run(move |state| {
                    let el = state.element(hwnd, &id)?;
                    let p = pattern::<IUIAutomationSelectionItemPattern>(
                        &el,
                        UIA_SelectionItemPatternId,
                    )
                    .ok_or_else(|| {
                        DesktopError::Unsupported(format!("element {id} cannot be selected"))
                    })?;
                    // SAFETY: COM calls on this thread's pattern.
                    unsafe {
                        p.Select().map_err(|e| uia_error(e, &id, "select"))?;
                        let ok = p.CurrentIsSelected().is_ok_and(|s| s.as_bool());
                        let out = if ok {
                            ActionOutcome::confirmed("uia_select")
                        } else {
                            ActionOutcome::delivered("uia_select")
                        };
                        Ok(with_cursor(out, &el, &id))
                    }
                })
            }
            "focus" => {
                // SAFETY: plain query.
                if unsafe { GetForegroundWindow() } != hwnd.get() {
                    return Err(DesktopError::Unsupported(
                        "focusing an element brings its window to the front; it is only done when the window is already in front (or with foreground typing)".into(),
                    ));
                }
                self.focus(hwnd, id)?;
                Ok(ActionOutcome::delivered("uia_focus"))
            }
            other => Err(DesktopError::Unsupported(format!(
                "action {other:?} is not available on Windows; use one the element lists (press, select, expand, collapse, increment, decrement, focus)"
            ))),
        }
    }

    pub fn set_value(&self, hwnd: Hwnd, id: &str, value: &str) -> DResult<ActionOutcome> {
        let (id, value) = (id.to_string(), value.to_string());
        self.run(move |state| set_value_now(state, hwnd, &id, &value))
    }

    /// Focuses the element (foreground typing only: it may activate the window).
    pub fn focus(&self, hwnd: Hwnd, id: &str) -> DResult<()> {
        let id = id.to_string();
        self.run(move |state| {
            let el = state.element(hwnd, &id)?;
            // SAFETY: a COM call on this thread's element.
            unsafe { el.SetFocus() }.map_err(|e| uia_error(e, &id, "focusing the element"))
        })
    }

    pub fn text_target(&self, hwnd: Hwnd, id: &str) -> DResult<TextTarget> {
        let id = id.to_string();
        self.run(move |state| {
            let el = state.element(hwnd, &id)?;
            // SAFETY: COM calls on this thread's element; plain window queries.
            unsafe {
                if let Ok(own) = el.CurrentNativeWindowHandle()
                    && !own.is_invalid()
                    && GetAncestor(own, GA_ROOT) == hwnd.get()
                {
                    return Ok(TextTarget::Window(Hwnd::from(own)));
                }
                if el.CurrentHasKeyboardFocus().is_ok_and(|f| f.as_bool()) {
                    return Ok(TextTarget::Window(super::input::focus_of(hwnd)?));
                }
                if let Some(p) = pattern::<IUIAutomationValuePattern>(&el, UIA_ValuePatternId)
                    && !p.CurrentIsReadOnly().is_ok_and(|r| r.as_bool())
                {
                    return Ok(TextTarget::AppendValue);
                }
            }
            Err(DesktopError::Unsupported(format!(
                "element {id} has no window of its own, is not focused and has no writable value; type without element_id into the focused control, or use foreground delivery"
            )))
        })
    }

    /// Appends `text` to the element's value (Value pattern), confirmed by
    /// reading it back.
    pub fn append_value(&self, hwnd: Hwnd, id: &str, text: &str) -> DResult<ActionOutcome> {
        let (id, text) = (id.to_string(), text.to_string());
        self.run(move |state| {
            let el = state.element(hwnd, &id)?;
            let p = pattern::<IUIAutomationValuePattern>(&el, UIA_ValuePatternId)
                .ok_or_else(|| DesktopError::Unsupported(format!("element {id} has no value")))?;
            // SAFETY: COM calls on this thread's pattern.
            unsafe {
                let before = p.CurrentValue().map(|v| v.to_string()).unwrap_or_default();
                let want = format!("{before}{text}");
                p.SetValue(&BSTR::from(want.as_str()))
                    .map_err(|e| uia_error(e, &id, "typing through the value"))?;
                let ok = p.CurrentValue().is_ok_and(|v| v == want.as_str());
                let mut out = if ok {
                    ActionOutcome::confirmed("uia_set_value")
                } else {
                    ActionOutcome::delivered("uia_set_value")
                };
                out.note = "appended through the element's Value pattern (no keystrokes)".into();
                Ok(with_cursor(out, &el, &id))
            }
        })
    }
}
