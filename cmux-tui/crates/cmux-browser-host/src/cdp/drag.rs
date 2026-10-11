//! `input.drag` on Chromium: HTML5 drag and drop through CDP drag
//! interception (as Playwright does). While `Input.setInterceptDrags` is on,
//! a drag the page starts is not handed to the system: Chromium reports its
//! data (`Input.dragIntercepted`) and the driver plays `dragenter`,
//! `dragover` and `drop` with `Input.dispatchDragEvent`. The drag's data
//! stays in this call (driver-protocol.md `input.drag`: never the system's
//! drag pasteboard).

use super::driver::{INTERNAL_TIMEOUT, Inner, Session};
use super::keys::{modifier_bits, mouse_button};
use crate::protocol::{DriverError, timeout_of};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long a move waits for the page's renderer to start the drag after
/// the move's reply (one animation frame, bounded).
const DRAG_START_WAIT: Duration = Duration::from_millis(500);

impl Inner {
    pub(super) fn drag(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let modifiers = modifier_bits(params)?;
        let (button, bit) = mouse_button(params.get("button").and_then(Value::as_str))?;
        let path = params
            .get("path")
            .and_then(Value::as_array)
            .and_then(|points| {
                points
                    .iter()
                    .map(|p| Some((p.get("x")?.as_f64()?, p.get("y")?.as_f64()?)))
                    .collect::<Option<Vec<_>>>()
            })
            .filter(|points| !points.is_empty())
            .ok_or_else(|| {
                DriverError::invalid("path: expected [{ x, y }, ...] with one point or more")
            })?;
        self.set_drag_data(&session.target_id, None);
        self.send_until(&session, "Input.setInterceptDrags", json!({"enabled": true}), deadline)?;
        let result = self.drag_along(&session, &path, (button, bit), modifiers, deadline);
        let _ = self.send_until(
            &session,
            "Input.setInterceptDrags",
            json!({"enabled": false}),
            deadline.max(Instant::now() + INTERNAL_TIMEOUT),
        );
        self.set_drag_data(&session.target_id, None);
        result.map(|()| Value::Null)
    }

    fn drag_along(
        &self,
        session: &Session,
        path: &[(f64, f64)],
        (button, bit): (&str, i64),
        modifiers: i64,
        deadline: Instant,
    ) -> Result<(), DriverError> {
        let mouse = |kind: &str, (x, y): (f64, f64), buttons: i64| {
            let mut event = json!({"type": kind, "x": x, "y": y, "modifiers": modifiers,
                "buttons": buttons, "button": if kind == "mouseMoved" && buttons == 0 { "none" } else { button }});
            if kind != "mouseMoved" {
                event["clickCount"] = json!(1);
            }
            self.set_mouse(&session.target_id, (x, y), buttons);
            self.send_until(session, "Input.dispatchMouseEvent", event, deadline)
        };
        let drag = |kind: &str, (x, y): (f64, f64), data: &Value| {
            self.send_until(
                session,
                "Input.dispatchDragEvent",
                json!({"type": kind, "x": x, "y": y, "data": data, "modifiers": modifiers}),
                deadline,
            )
        };
        let start = path[0];
        mouse("mouseMoved", start, 0)?;
        mouse("mousePressed", start, bit)?;
        let mut data: Option<Value> = None;
        let mut last = start;
        for &point in &path[1..] {
            last = point;
            if let Some(data) = &data {
                self.set_mouse(&session.target_id, point, bit);
                drag("dragOver", point, data)?;
                continue;
            }
            mouse("mouseMoved", point, bit)?;
            data = self.intercepted_drag(session);
            if let Some(data) = &data {
                drag("dragEnter", point, data)?;
                drag("dragOver", point, data)?;
            }
        }
        match &data {
            // The drop ends the drag; the page gets no mouseup (as with a
            // drag the system runs).
            Some(data) => {
                drag("drop", last, data)?;
                self.set_mouse(&session.target_id, last, 0);
            }
            None => {
                mouse("mouseReleased", last, 0)?;
            }
        }
        Ok(())
    }

    /// The drag the page started on the last move, if any: Chromium can
    /// report it after the move's reply, so one animation frame of the page
    /// is awaited (bounded) when it has not come yet.
    fn intercepted_drag(&self, session: &Session) -> Option<Value> {
        let taken = |inner: &Self| {
            inner.lock().tabs.get_mut(&session.target_id).and_then(|tab| tab.drag_data.take())
        };
        if let Some(data) = taken(self) {
            return Some(data);
        }
        let _ = self.conn.call(
            Some(&session.session_id),
            "Runtime.evaluate",
            json!({"expression": "new Promise((r) => requestAnimationFrame(() => r(0)))", "awaitPromise": true, "returnByValue": true}),
            DRAG_START_WAIT,
        );
        taken(self)
    }

    fn set_drag_data(&self, target_id: &str, data: Option<Value>) {
        if let Some(tab) = self.lock().tabs.get_mut(target_id) {
            tab.drag_data = data;
        }
    }

    fn set_mouse(&self, target_id: &str, at: (f64, f64), buttons: i64) {
        if let Some(tab) = self.lock().tabs.get_mut(target_id) {
            tab.mouse = at;
            tab.buttons = buttons;
        }
    }
}
