//! Overlays (`presentation.overlay`): an app's `cmux.pane/1` scene drawn in a
//! floating panel over the window. Only the person opens one: a mount whose
//! context names the `overlay` surface needs origin `user`, which the
//! server admits only from the verified cmux app connection (Gate A2,
//! request-origin.md). An app, a script, the CLI, MCP or an agent asking
//! for it is refused, so no extension can put a panel in front of the
//! person on its own.

use serde_json::Value;

use super::catalog::Package;
use super::mirror::Origin;
use super::supervisor::ApiError;

/// The mount context's `surface` that asks for an overlay.
pub(crate) const SURFACE: &str = "overlay";
/// The only interface an overlay draws.
pub(crate) const INTERFACE: &str = "cmux.pane/1";

/// Whether a mount `context` asks for an overlay.
pub(crate) fn asks(context: &Value) -> bool {
    context.get("surface").and_then(Value::as_str) == Some(SURFACE)
}

/// Refuses an overlay open that is not the person's own gesture, or of an app
/// that declares no overlay. Every other mount passes.
pub(crate) fn admit(
    package: &Package,
    interface: &str,
    context: &Value,
    origin: Origin,
) -> Result<(), ApiError> {
    if !asks(context) {
        return Ok(());
    }
    if interface != INTERFACE || package.manifest.pointer("/presentation/overlay").is_none() {
        return Err(ApiError::new(
            "apps.overlay_undeclared",
            format!(
                "{} declares no overlay: add presentation.overlay and implement {INTERFACE}",
                package.id
            ),
        ));
    }
    if origin != Origin::User {
        return Err(ApiError::new(
            "apps.overlay_gesture",
            "an overlay opens only from the person's own gesture (a click or a palette pick in cmux)",
        ));
    }
    Ok(())
}
