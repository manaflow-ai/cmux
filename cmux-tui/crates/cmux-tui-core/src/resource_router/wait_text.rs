//! The text a `terminal.wait` pattern matches: the rendered viewport, or
//! with `new` (`terminal-wait-new-v1`) only what is printed below the
//! cursor's line as the wait starts, so the echo of a just-typed command and
//! older output never match. Both the daemon's wait worker and the router's
//! wait read through this one type.

use ghostty_vt::TrackedScreenPoint;
use serde_json::{Map, Value};

use super::resource_operation_error;
use crate::Surface;
use crate::resource::ResourceError;

/// What one `terminal.wait` reads on each check. With `new` it holds a
/// tracked row of the terminal's page list, released under the terminal
/// lock when the wait ends (as every other access to it is).
pub(crate) struct WaitText<'a> {
    surface: &'a Surface,
    anchor: Option<TrackedScreenPoint>,
}

impl<'a> WaitText<'a> {
    /// The wait's text source for the request `fields`: an anchor on the
    /// cursor's line now when `new` is true, else the rendered viewport.
    pub(crate) fn start(
        surface: &'a Surface,
        fields: &Map<String, Value>,
    ) -> Result<Self, ResourceError> {
        let anchor = if fields.get("new").and_then(Value::as_bool).unwrap_or(false) {
            Some(
                surface
                    .try_with_terminal(|terminal| terminal.anchor_cursor_line())
                    .map_err(resource_operation_error)?
                    .map_err(|error| resource_operation_error(error.into()))?,
            )
        } else {
            None
        };
        Ok(Self { surface, anchor })
    }

    /// The text to match now: the viewport's rows, or the logical lines
    /// printed after the anchored line.
    pub(crate) fn read(&self) -> Result<String, ResourceError> {
        self.surface
            .try_with_terminal(|terminal| match &self.anchor {
                Some(anchor) => terminal.text_after_anchor(anchor),
                None => terminal.viewport_text(),
            })
            .map_err(resource_operation_error)?
            .map_err(|error| resource_operation_error(error.into()))
    }
}

impl Drop for WaitText<'_> {
    fn drop(&mut self) {
        if let Some(anchor) = self.anchor.take() {
            let _ = self.surface.try_with_terminal(move |_| drop(anchor));
        }
    }
}
