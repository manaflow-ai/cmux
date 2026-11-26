//! Subagent Limit… on a chat: how many of a chat's sub-sessions acpmux runs
//! at once (`_acpmux/subsession/limits` `maxRunning`). A chat's own value
//! comes first, then its workspace's, then `agents.subsessions.maxRunning`.
//! The dialog reads the current value, asks for a number or Use Default, and
//! sends it; a number sets the value, `null` clears it.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The request method.
pub const METHOD: &str = "_acpmux/subsession/limits";
/// The field's id in the dialog's answer.
pub const FIELD: &str = "maxRunning";
/// The Set button's id.
pub const SET_BUTTON: &str = "set";
/// The Use Default button's id.
pub const DEFAULT_BUTTON: &str = "useDefault";
/// The settings row's range (`agents.subsessions.maxRunning`).
pub const RANGE: (i64, i64) = (1, 1000);

/// What the person chose in the dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Change {
    Set(i64),
    UseDefault,
}

/// The request's params for one chat: `change` absent reads, a number sets,
/// Use Default sends `null` (clears).
pub fn params(session: &str, change: Option<Change>) -> Value {
    let mut params = Map::new();
    params.insert("sessionId".into(), Value::String(session.to_owned()));
    match change {
        None => {}
        Some(Change::Set(value)) => {
            params.insert("maxRunning".into(), Value::from(value));
        }
        Some(Change::UseDefault) => {
            params.insert("maxRunning".into(), Value::Null);
        }
    }
    Value::Object(params)
}

/// The limit as acpmux reports it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Current {
    /// The chat's own value; `None` when it uses the next one down.
    pub own: Option<i64>,
    /// The value in effect.
    pub effective: Option<i64>,
    /// Sub-sessions running a turn now, and the ones waiting for a slot.
    pub running: Option<i64>,
    pub queued: Option<i64>,
}

/// A JSON number as an integer (NSNumber's `intValue`: a fraction truncates).
fn int(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value.as_i64().or_else(|| value.as_f64().map(|f| f as i64))
}

impl Current {
    /// The current value from a read's reply; `None` when acpmux has no run
    /// limit (an acpmux from before `maxRunning` answers without it).
    pub fn from_reply(reply: &Value) -> Option<Self> {
        let limits = reply.get("subsessionLimits")?.as_object()?;
        let effective = int(limits.get("maxRunning"))?;
        let own = (limits.get("maxRunningSource").and_then(Value::as_str) == Some("session"))
            .then_some(effective);
        Some(Self {
            own,
            effective: Some(effective),
            running: int(limits.get("running")),
            queued: int(limits.get("queued")),
        })
    }
}

/// What the dialog shows for `current`, the strings left to the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Dialog {
    /// The field's placeholder: the value in effect, else the global setting.
    pub placeholder: String,
    /// The field's text: the chat's own value, else empty.
    pub initial: String,
    /// The running and waiting counts line, when acpmux sent both.
    pub status: Option<(i64, i64)>,
}

/// The dialog for `current` with the global `setting`.
pub fn dialog(current: &Current, setting: i64) -> Dialog {
    Dialog {
        placeholder: current.effective.unwrap_or(setting).to_string(),
        initial: current.own.map(|own| own.to_string()).unwrap_or_default(),
        status: current.running.zip(current.queued),
    }
}

/// The dialog's answer, as the app read it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    #[serde(default)]
    pub button: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub dismissal: bool,
    #[serde(default)]
    pub cancel: bool,
}

/// The decision for an answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// The person cancelled: nothing is sent.
    Cancelled,
    Change(Change),
    /// The field is not a whole number in the range.
    Invalid,
}

/// Swift's `Int(String)`: an optional sign and ASCII digits, nothing else.
fn whole(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// The change for `answer`: cancelled for a dismissal, Cancel or an unknown
/// button; Use Default; Set with an empty field uses the default too; else a
/// whole number in `range`, or invalid.
pub fn decide(answer: &Answer, range: (i64, i64)) -> Decision {
    if answer.dismissal || answer.cancel {
        return Decision::Cancelled;
    }
    match answer.button.as_deref() {
        Some(DEFAULT_BUTTON) => return Decision::Change(Change::UseDefault),
        Some(SET_BUTTON) => {}
        _ => return Decision::Cancelled,
    }
    let text = answer.text.as_deref().unwrap_or("").trim();
    if text.is_empty() {
        return Decision::Change(Change::UseDefault);
    }
    match whole(text) {
        Some(value) if (range.0..=range.1).contains(&value) => Decision::Change(Change::Set(value)),
        _ => Decision::Invalid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn set(text: &str) -> Decision {
        decide(
            &Answer {
                button: Some(SET_BUTTON.into()),
                text: Some(text.into()),
                ..Answer::default()
            },
            RANGE,
        )
    }

    // SubagentLimitTests: a number sets, the edges hold.
    #[test]
    fn numbers_set() {
        assert_eq!(set(" 12 "), Decision::Change(Change::Set(12)));
        assert_eq!(set("1000"), Decision::Change(Change::Set(1000)));
        assert_eq!(set("1"), Decision::Change(Change::Set(1)));
        assert_eq!(set("+5"), Decision::Change(Change::Set(5)));
        assert_eq!(set("\n7\t"), Decision::Change(Change::Set(7)));
    }

    #[test]
    fn empty_set_uses_default() {
        assert_eq!(set(""), Decision::Change(Change::UseDefault));
        assert_eq!(set("   "), Decision::Change(Change::UseDefault));
        let no_text = Answer { button: Some(SET_BUTTON.into()), ..Answer::default() };
        assert_eq!(decide(&no_text, RANGE), Decision::Change(Change::UseDefault));
    }

    #[test]
    fn default_button_ignores_the_field() {
        let answer = Answer {
            button: Some(DEFAULT_BUTTON.into()),
            text: Some("7".into()),
            ..Answer::default()
        };
        assert_eq!(decide(&answer, RANGE), Decision::Change(Change::UseDefault));
    }

    #[test]
    fn bad_numbers_are_invalid() {
        for text in ["0", "1001", "-3", "2.5", "many", "1 2", "+", "-", "99999999999999999999"] {
            assert_eq!(set(text), Decision::Invalid, "{text}");
        }
    }

    #[test]
    fn cancel_dismissal_and_unknown_buttons_send_nothing() {
        let cancel = Answer { button: Some("cancel".into()), cancel: true, ..Answer::default() };
        assert_eq!(decide(&cancel, RANGE), Decision::Cancelled);
        let dismissal = Answer {
            dismissal: true,
            button: Some(SET_BUTTON.into()),
            text: Some("3".into()),
            ..Answer::default()
        };
        assert_eq!(decide(&dismissal, RANGE), Decision::Cancelled);
        let other =
            Answer { button: Some("other".into()), text: Some("3".into()), ..Answer::default() };
        assert_eq!(decide(&other, RANGE), Decision::Cancelled);
        assert_eq!(decide(&Answer::default(), RANGE), Decision::Cancelled);
    }

    #[test]
    fn a_custom_range_bounds_the_number() {
        let answer = Answer {
            button: Some(SET_BUTTON.into()),
            text: Some("20".into()),
            ..Answer::default()
        };
        assert_eq!(decide(&answer, (1, 10)), Decision::Invalid);
        assert_eq!(decide(&answer, (1, 20)), Decision::Change(Change::Set(20)));
    }

    #[test]
    fn params_read_set_and_clear() {
        assert_eq!(params("s1", None), json!({"sessionId": "s1"}));
        assert_eq!(params("s1", Some(Change::Set(4))), json!({"sessionId": "s1", "maxRunning": 4}));
        assert_eq!(
            params("s1", Some(Change::UseDefault)),
            json!({"sessionId": "s1", "maxRunning": null})
        );
    }

    #[test]
    fn a_session_value_is_its_own() {
        let reply = json!({"subsessionLimits": {"maxRunning": 3, "maxRunningSource": "session", "running": 2, "queued": 1}});
        assert_eq!(
            Current::from_reply(&reply),
            Some(Current { own: Some(3), effective: Some(3), running: Some(2), queued: Some(1) })
        );
    }

    #[test]
    fn an_inherited_value_is_not_its_own() {
        let reply =
            json!({"subsessionLimits": {"maxRunning": 12, "maxRunningSource": "workspace"}});
        assert_eq!(
            Current::from_reply(&reply),
            Some(Current { own: None, effective: Some(12), running: None, queued: None })
        );
        let no_source = json!({"subsessionLimits": {"maxRunning": 12}});
        assert_eq!(Current::from_reply(&no_source).unwrap().own, None);
    }

    #[test]
    fn a_reply_without_max_running_has_no_limit() {
        assert_eq!(Current::from_reply(&json!({"subsessionLimits": {"running": 1}})), None);
        assert_eq!(Current::from_reply(&json!({"subsessionLimits": {"maxRunning": "3"}})), None);
        assert_eq!(Current::from_reply(&json!({"subsessionLimits": 3})), None);
        assert_eq!(Current::from_reply(&json!({})), None);
        assert_eq!(Current::from_reply(&json!(null)), None);
    }

    #[test]
    fn fractions_truncate_like_int_value() {
        let reply = json!({"subsessionLimits": {"maxRunning": 3.9, "running": 1.2}});
        let current = Current::from_reply(&reply).unwrap();
        assert_eq!((current.effective, current.running), (Some(3), Some(1)));
    }

    #[test]
    fn the_dialog_shows_own_else_placeholder() {
        let own = Current { own: Some(3), effective: Some(3), running: Some(2), queued: Some(0) };
        assert_eq!(
            dialog(&own, 8),
            Dialog { placeholder: "3".into(), initial: "3".into(), status: Some((2, 0)) }
        );
        let inherited = Current { own: None, effective: Some(12), running: Some(1), queued: None };
        assert_eq!(
            dialog(&inherited, 8),
            Dialog { placeholder: "12".into(), initial: String::new(), status: None }
        );
        assert_eq!(
            dialog(&Current::default(), 8),
            Dialog { placeholder: "8".into(), initial: String::new(), status: None }
        );
    }
}
