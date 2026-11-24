//! `list_alerts` and `dismiss_alert`: the engine side of [`crate::alerts`].
//!
//! Both are refused with `alerts_off` unless `computerUse.alerts` is on, then
//! pass the same mode and origin checks as any call. They name no target app:
//! the alerts' owners stay protected targets for every other tool
//! ([`crate::policy`]), and the only thing done to one is the single
//! accessibility press [`crate::alerts::check`] allowed.

use serde_json::{Value, json};

use super::{CallContext, Engine, TargetApp, ToolOutput, need, set_key};
use crate::alerts::{self, RawAlert};
use crate::policy::{Access, PolicyConfig};

type Answer = Result<(ToolOutput, Option<TargetApp>), ToolOutput>;

impl Engine {
    fn alerts_on(config: &PolicyConfig, tool: &str) -> Result<(), ToolOutput> {
        if config.alerts {
            return Ok(());
        }
        let mut out = ToolOutput::error(alerts::CODE_OFF, alerts::off_message(tool));
        set_key(&mut out.body, "setting", json!(alerts::SETTING));
        Err(out)
    }

    fn read_alerts(&self) -> Result<Vec<RawAlert>, ToolOutput> {
        self.desktop.system_alerts().map_err(|e| ToolOutput::desktop(&e))
    }

    pub(super) fn list_alerts(&self, config: &PolicyConfig, ctx: &CallContext) -> Answer {
        Self::alerts_on(config, "list_alerts")?;
        self.authorize(config, ctx, Access::Observe, None, false)?;
        let listed: Vec<Value> = self.read_alerts()?.iter().map(alerts::to_json).collect();
        Ok((ToolOutput::ok(json!({"alerts": listed})), None))
    }

    pub(super) fn dismiss_alert(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Answer {
        Self::alerts_on(config, "dismiss_alert")?;
        let id = need(args, "alert_id")?;
        let button = need(args, "button")?;
        self.authorize(config, ctx, Access::Act, None, false)?;
        // Read fresh: the decision is made on what the alert says now, not
        // on what an earlier list said.
        let listed = self.read_alerts()?;
        let Some(alert) = listed.iter().find(|a| a.window_id == id) else {
            let ids: Vec<&str> = listed.iter().map(|a| a.window_id.as_str()).collect();
            return Err(ToolOutput::error(
                alerts::CODE_NOT_FOUND,
                format!(
                    "No system alert {id:?} is on screen now (alerts on screen: {ids:?}). Call list_alerts again."
                ),
            ));
        };
        let title = alerts::check(alert, button).map_err(|refused| {
            let mut out = ToolOutput::error(refused.code, refused.message);
            set_key(&mut out.body, "alert", alerts::to_json(alert));
            out
        })?;
        self.desktop.press_alert_button(alert, &title).map_err(|e| ToolOutput::desktop(&e))?;
        // Whether it went away is read back, never assumed.
        let dismissed =
            self.desktop.system_alerts().ok().map(|now| !now.iter().any(|a| a == alert));
        Ok((
            ToolOutput::ok(json!({
                "alert_id": alert.window_id,
                "owner": alert.owner,
                "class": alerts::classify(alert),
                "pressed": title,
                "dismissed": dismissed,
            })),
            None,
        ))
    }
}
