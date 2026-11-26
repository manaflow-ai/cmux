//! The scene motion contract (`cmux.motion/1`, js/ABI.md "Motion"): the typed vocabulary of the
//! props an app declares so the host animates for it (`animation`, `loop`, `transition`,
//! `contentTransition`), and the one normalizer every renderer relies on.
//!
//! The web renderer (`webviews/src/apps/scene/motionProps.ts`) and the native one
//! (`CmuxNextApps/Scene/AppSceneNode+Motion.swift`) each parsed these props on their own and did not
//! agree on the edges: a spring without `dampingFraction` sprang on the web and did not move
//! natively, an unknown `curve` eased out on the web and did not move natively. The app host now
//! runs [`sanitize_scene_ops`] on every scene batch, next to the particles validator: a valid value
//! leaves the VM in its canonical form (defaults filled in, numbers clamped to the contract's
//! ranges), an invalid one as `null` with a log line naming the node and the prop. Both renderers
//! then only ever see a value they read the same way.
//!
//! The tables here are the SDK's too: `cmux_extension_sdk::motion` re-exports this module, so a
//! tool, a test or an agent can check a motion value without running cmux.

use serde_json::{Map, Value, json};

/// The contract's name and major version.
pub const SCHEMA: &str = "cmux.motion/1";

/// `animation` tokens: the motion scale's steps (`smooth`, `snappy`, `none`), the chrome's
/// design-token springs (`move`, `appear`, `disappear`), the fade-in curve (`fade`) and the one
/// spring that overshoots (`bouncy`).
pub const MOTION_TOKENS: &[&str] =
    &["smooth", "snappy", "none", "move", "appear", "disappear", "fade", "bouncy"];
/// Timed curves (`{duration, curve}`); the first is the default.
pub const CURVES: &[&str] = &["easeOut", "easeInOut", "linear"];
/// `transition` values: in when a render adds the node after the first frame, out when it removes it.
pub const TRANSITIONS: &[&str] = &["opacity", "slide", "scale", "move", "pop"];
/// `contentTransition` values on Text.
pub const CONTENT_TRANSITIONS: &[&str] = &["numericText", "opacity"];
/// `loop` effects and their default periods in seconds.
pub const LOOP_EFFECTS: &[(&str, f64)] = &[
    ("pulse", 1.2),
    ("breathe", 3.0),
    ("spin", 2.0),
    ("float", 3.0),
    ("wiggle", 0.6),
    ("bounce", 0.9),
    ("shimmer", 1.6),
];

/// Spring `response` and timed `duration`, seconds.
pub const TIME_RANGE: (f64, f64) = (0.05, 10.0);
/// Spring `dampingFraction` (1 is critically damped, no overshoot; under 1 overshoots).
pub const DAMPING_RANGE: (f64, f64) = (0.3, 1.0);
/// Loop `period`, seconds.
pub const LOOP_PERIOD_RANGE: (f64, f64) = (0.05, 60.0);
/// Loop `amount`, a multiplier on the effect's amplitude (negative turns `spin` counterclockwise).
pub const LOOP_AMOUNT_RANGE: (f64, f64) = (-10.0, 10.0);

/// How a prop change animates.
#[derive(Clone, Debug, PartialEq)]
pub enum Motion {
    /// One of [`MOTION_TOKENS`].
    Token(&'static str),
    /// A spring, both values clamped.
    Spring { response: f64, damping_fraction: f64 },
    /// A timed curve, the duration clamped; `curve` is one of [`CURVES`].
    Timed { duration: f64, curve: &'static str },
}

impl Motion {
    /// Reads an `animation` value; `Err` names what is wrong.
    pub fn parse(value: &Value) -> Result<Self, String> {
        if let Some(name) = value.as_str() {
            return known(MOTION_TOKENS, name).map(Self::Token).ok_or_else(|| {
                format!("unknown motion token {name:?} (one of {})", MOTION_TOKENS.join(" "))
            });
        }
        let fields = value.as_object().ok_or("a motion is a token, {spring} or {duration}")?;
        if let Some(spring) = fields.get("spring") {
            only_keys(fields, &["spring"])?;
            let spring = spring.as_object().ok_or("spring is {response, dampingFraction?}")?;
            only_keys(spring, &["response", "dampingFraction"])?;
            let response = finite(spring.get("response"), "spring.response")?
                .ok_or("spring.response is required")?;
            let damping =
                finite(spring.get("dampingFraction"), "spring.dampingFraction")?.unwrap_or(1.0);
            return Ok(Self::Spring {
                response: clamp(response, TIME_RANGE),
                damping_fraction: clamp(damping, DAMPING_RANGE),
            });
        }
        if fields.contains_key("duration") {
            only_keys(fields, &["duration", "curve"])?;
            let duration =
                finite(fields.get("duration"), "duration")?.ok_or("duration is a number")?;
            let curve = match fields.get("curve") {
                None | Some(Value::Null) => CURVES[0],
                Some(Value::String(name)) => known(CURVES, name).ok_or_else(|| {
                    format!("unknown curve {name:?} (one of {})", CURVES.join(" "))
                })?,
                Some(_) => return Err("curve is a string".into()),
            };
            return Ok(Self::Timed { duration: clamp(duration, TIME_RANGE), curve });
        }
        Err("a motion object has spring or duration".into())
    }

    /// The canonical wire value.
    pub fn to_value(&self) -> Value {
        match self {
            Self::Token(name) => json!(name),
            Self::Spring { response, damping_fraction } => {
                json!({"spring": {"response": response, "dampingFraction": damping_fraction}})
            }
            Self::Timed { duration, curve } => json!({"duration": duration, "curve": curve}),
        }
    }
}

/// A host-run looping effect.
#[derive(Clone, Debug, PartialEq)]
pub struct Loop {
    /// One of [`LOOP_EFFECTS`].
    pub effect: &'static str,
    /// Seconds; the effect's default when the app gives none.
    pub period: f64,
    pub amount: f64,
}

impl Loop {
    /// Reads a `loop` value; `Err` names what is wrong.
    pub fn parse(value: &Value) -> Result<Self, String> {
        let fields = value.as_object().ok_or("a loop is {effect, period?, amount?}")?;
        only_keys(fields, &["effect", "period", "amount"])?;
        let name = fields.get("effect").and_then(Value::as_str).ok_or("loop.effect is a string")?;
        let &(effect, default_period) =
            LOOP_EFFECTS.iter().find(|(e, _)| *e == name).ok_or_else(|| {
                let names: Vec<&str> = LOOP_EFFECTS.iter().map(|(e, _)| *e).collect();
                format!("unknown loop effect {name:?} (one of {})", names.join(" "))
            })?;
        let period = finite(fields.get("period"), "loop.period")?.unwrap_or(default_period);
        let amount = finite(fields.get("amount"), "loop.amount")?.unwrap_or(1.0);
        Ok(Self {
            effect,
            period: clamp(period, LOOP_PERIOD_RANGE),
            amount: clamp(amount, LOOP_AMOUNT_RANGE),
        })
    }

    /// The canonical wire value.
    pub fn to_value(&self) -> Value {
        json!({"effect": self.effect, "period": self.period, "amount": self.amount})
    }
}

/// Checks one motion prop by name and returns its canonical value; `Ok(None)` for a prop this
/// contract does not own.
pub fn normalize_prop(key: &str, value: &Value) -> Option<Result<Value, String>> {
    let token = |table: &[&'static str]| match value.as_str() {
        Some(name) if known(table, name).is_some() => Ok(value.clone()),
        _ => Err(format!("{value} is not one of {}", table.join(" "))),
    };
    Some(match key {
        "animation" => Motion::parse(value).map(|m| m.to_value()),
        "loop" => Loop::parse(value).map(|l| l.to_value()),
        "transition" => token(TRANSITIONS),
        "contentTransition" => token(CONTENT_TRANSITIONS),
        _ => return None,
    })
}

/// Normalizes the motion props of every op in a scene batch in place: a valid value in its
/// canonical form, an invalid one as `null` (no motion, as an unknown value always drew). `null`
/// stays `null` (an update's delete). Returns one log line per refused prop.
pub fn sanitize_scene_ops(ops: &mut Value) -> Vec<String> {
    let mut refused = Vec::new();
    let Some(list) = ops.as_array_mut() else { return refused };
    for op in list {
        let id = op.get("id").and_then(Value::as_str).unwrap_or("?").to_string();
        let Some(props) = op.get_mut("props").and_then(Value::as_object_mut) else { continue };
        for (key, value) in props.iter_mut() {
            if value.is_null() {
                continue;
            }
            match normalize_prop(key, value) {
                None => {}
                Some(Ok(canonical)) => *value = canonical,
                Some(Err(error)) => {
                    refused.push(format!("node {id}: {key} refused ({SCHEMA}): {error}"));
                    *value = Value::Null;
                }
            }
        }
    }
    refused
}

fn known(table: &[&'static str], name: &str) -> Option<&'static str> {
    table.iter().copied().find(|t| *t == name)
}

fn clamp(value: f64, (low, high): (f64, f64)) -> f64 {
    value.clamp(low, high)
}

fn finite(value: Option<&Value>, what: &str) -> Result<Option<f64>, String> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_f64() {
            Some(n) if n.is_finite() => Ok(Some(n)),
            _ => Err(format!("{what} is a finite number")),
        },
    }
}

fn only_keys(map: &Map<String, Value>, allowed: &[&str]) -> Result<(), String> {
    match map.keys().find(|k| !allowed.contains(&k.as_str())) {
        Some(key) => Err(format!("unknown key {key:?} (allowed: {})", allowed.join(" "))),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canonical(key: &str, value: Value) -> Result<Value, String> {
        normalize_prop(key, &value).expect("a motion prop")
    }

    #[test]
    fn tokens_pass_through() {
        for token in MOTION_TOKENS {
            assert_eq!(canonical("animation", json!(token)), Ok(json!(token)));
        }
        assert!(canonical("animation", json!("wobbly")).is_err());
    }

    #[test]
    fn spring_fills_damping_and_clamps() {
        assert_eq!(
            canonical("animation", json!({"spring": {"response": 0.3}})),
            Ok(json!({"spring": {"response": 0.3, "dampingFraction": 1.0}}))
        );
        assert_eq!(
            canonical("animation", json!({"spring": {"response": 99, "dampingFraction": 0}})),
            Ok(json!({"spring": {"response": 10.0, "dampingFraction": 0.3}}))
        );
        assert!(canonical("animation", json!({"spring": {}})).is_err());
        assert!(canonical("animation", json!({"spring": {"response": 0.3, "mass": 1}})).is_err());
    }

    #[test]
    fn timed_curve_defaults_and_refuses_unknown() {
        assert_eq!(
            canonical("animation", json!({"duration": 0.2})),
            Ok(json!({"duration": 0.2, "curve": "easeOut"}))
        );
        assert_eq!(
            canonical("animation", json!({"duration": 0, "curve": "linear"})),
            Ok(json!({"duration": 0.05, "curve": "linear"}))
        );
        assert!(canonical("animation", json!({"duration": 0.2, "curve": "bezier"})).is_err());
        assert!(canonical("animation", json!({"duration": "fast"})).is_err());
    }

    #[test]
    fn loop_fills_period_and_clamps_amount() {
        assert_eq!(
            canonical("loop", json!({"effect": "pulse"})),
            Ok(json!({"effect": "pulse", "period": 1.2, "amount": 1.0}))
        );
        assert_eq!(
            canonical("loop", json!({"effect": "spin", "period": 1000, "amount": -50})),
            Ok(json!({"effect": "spin", "period": 60.0, "amount": -10.0}))
        );
        assert!(canonical("loop", json!({"effect": "explode"})).is_err());
    }

    #[test]
    fn transitions_are_tokens() {
        for t in TRANSITIONS {
            assert_eq!(canonical("transition", json!(t)), Ok(json!(t)));
        }
        assert!(canonical("transition", json!("zoom")).is_err());
        assert!(canonical("contentTransition", json!("numericText")).is_ok());
        assert!(normalize_prop("opacity", &json!(1)).is_none());
    }

    #[test]
    fn batch_rewrites_in_place_and_keeps_deletes() {
        let mut ops = json!([
            {"op": "create", "id": "a", "type": "Text", "props": {
                "text": "hi", "animation": {"spring": {"response": 0.2}}, "transition": "zoom"}},
            {"op": "update", "id": "b", "props": {"loop": null, "animation": "move"}},
            {"op": "remove", "id": "c"}
        ]);
        let refused = sanitize_scene_ops(&mut ops);
        assert_eq!(refused.len(), 1);
        assert!(refused[0].contains("node a: transition"), "{refused:?}");
        assert_eq!(
            ops[0]["props"]["animation"],
            json!({"spring": {"response": 0.2, "dampingFraction": 1.0}})
        );
        assert_eq!(ops[0]["props"]["transition"], Value::Null);
        assert_eq!(ops[0]["props"]["text"], json!("hi"));
        assert_eq!(ops[1]["props"]["loop"], Value::Null);
        assert_eq!(ops[1]["props"]["animation"], json!("move"));
    }

    /// The SDK's TypeScript types (js/src/view.ts) list the same vocabulary as these tables.
    #[test]
    fn typescript_types_match() {
        let view = include_str!("../js/src/view.ts");
        let union = |name: &str| -> Vec<String> {
            let start = view
                .find(&format!("export type {name} ="))
                .unwrap_or_else(|| panic!("{name} in view.ts"));
            let line = &view[start..];
            let line = &line[..line.find('\n').unwrap_or(line.len())];
            line.split('"').skip(1).step_by(2).map(str::to_string).collect()
        };
        let effects: Vec<String> = LOOP_EFFECTS.iter().map(|(e, _)| e.to_string()).collect();
        assert_eq!(union("LoopEffect"), effects);
        assert_eq!(
            union("Transition"),
            TRANSITIONS.iter().map(|t| t.to_string()).collect::<Vec<_>>()
        );
        let motion_start = view.find("export type Motion =").expect("Motion in view.ts");
        let motion = &view[motion_start
            ..motion_start + view[motion_start..].find("export type Offset").expect("Offset")];
        let tokens: Vec<&str> = motion
            .lines()
            .filter(|l| l.trim_start().starts_with("| \""))
            .flat_map(|l| l.split('"').skip(1).step_by(2))
            .collect();
        assert_eq!(tokens, MOTION_TOKENS);
        for curve in CURVES {
            assert!(motion.contains(&format!("\"{curve}\"")), "{curve} in Motion");
        }
    }
}
