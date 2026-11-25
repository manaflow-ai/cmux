//! Where a pointer tool lands, and `move_pointer` (a hover).
//!
//! `click` and `move_pointer` read their target the same way
//! ([`Engine::pointer_window`]): an element of a window (element_id), a
//! point in pixels of the agent's latest screenshot of the window (x, y with
//! window_id), or a point in pixels of its latest display screenshot (x, y
//! with no window_id), hit-tested to the top window there.

use serde_json::Value;

use super::{
    CallContext, Engine, TargetApp, ToolOutput, args_f64, args_str, contains, lock, need_f64,
    parse_delivery,
};
use crate::desktop::{PointerTarget, Window};
use crate::policy::PolicyConfig;

type Answer = Result<(ToolOutput, Option<TargetApp>), ToolOutput>;

impl Engine {
    /// The window a pointer tool acts in, and its target when the agent
    /// named a display point (already in global points). With a window_id
    /// the target is mapped after the policy check (a denied app is refused
    /// as such), by [`Engine::pointer_target`]. `tool` names the call in a
    /// refusal.
    pub(super) fn pointer_window(
        &self,
        ctx: &CallContext,
        args: &Value,
        tool: &str,
    ) -> Result<(Window, Option<PointerTarget>), ToolOutput> {
        if let Some(id) = args_str(args, "window_id") {
            let window = self.window(id)?;
            if args_str(args, "element_id").is_none()
                && (args_f64(args, "x").is_none() || args_f64(args, "y").is_none())
            {
                return Err(ToolOutput::error(
                    "invalid_arguments",
                    format!("{tool} needs element_id or x and y"),
                ));
            }
            return Ok((window, None));
        }
        let (x, y) = (need_f64(args, "x")?, need_f64(args, "y")?);
        let key = lock(&self.last_display).get(&ctx.session).cloned().ok_or_else(|| {
            ToolOutput::error(
                "invalid_arguments",
                format!(
                    "{tool} with no window_id uses your latest display screenshot; take one first, or pass window_id"
                ),
            )
        })?;
        let geometry =
            lock(&self.seen).get(&(ctx.session.clone(), key)).map(|(g, _)| *g).ok_or_else(
                || ToolOutput::error("invalid_arguments", "take a display screenshot first"),
            )?;
        let point = geometry.to_global(x, y);
        let window = self
            .windows()?
            .into_iter()
            .find(|w| w.on_screen && !w.minimized && contains(&w.frame, point))
            .ok_or_else(|| ToolOutput::error("target_not_found", "no window at that point"))?;
        let target = PointerTarget::Point { window_id: window.id.clone(), point };
        Ok((window, Some(target)))
    }

    /// `move_pointer`: the pointer onto an element or a point, nothing
    /// pressed. Background by default (the person's pointer stays where it
    /// is); foreground raises the window and moves the real pointer.
    pub(super) fn move_pointer(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Answer {
        let delivery = parse_delivery(args)?;
        let (window, target) = self.pointer_window(ctx, args, "move_pointer")?;
        let app = self.act_on(config, ctx, &window, delivery, true)?;
        let target = match target {
            Some(t) => t,
            None => self.pointer_target(ctx, &window, args)?,
        };
        // The agent's element id (a small id from its last look) to the
        // desktop's, read fresh.
        let target = match target {
            PointerTarget::Element { window_id, .. } => {
                let guarded = self.guard(ctx, "move_pointer", &window, args, None)?;
                PointerTarget::Element {
                    window_id,
                    element_id: guarded.element.unwrap_or_default(),
                }
            }
            point => point,
        };
        if let PointerTarget::Point { point, .. } = &target {
            self.glide(ctx, *point);
        }
        let out =
            self.desktop.move_pointer(&target, delivery).map_err(|e| ToolOutput::desktop(&e))?;
        Ok((self.outcome(ctx, out), Some(app)))
    }
}
