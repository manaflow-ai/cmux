//! The loading-indicator flags of `workspace status set` (and of the
//! `cmux status` shorthand, cli/status.rs): plans/cmux-next/status-indicators.md
//! section 5.
//!
//! An entry set from inside a cmux terminal is owned by that terminal unless
//! `--owner none` is given, so closing the terminal never leaves a stale spinner,
//! and it is about that terminal (`target_terminal`) so its tab shows it.

use serde_json::{Map, Number, Value, json};

use super::super::{Flags, UsageError, validate_one_of, validate_prefixed_id};

pub(crate) const STATES: &[&str] = &["busy", "success", "error", "waiting", "info"];
pub(crate) const STYLES: &[&str] = &["arc", "native", "dot", "none"];

pub(super) fn insert(
    fields: &mut Map<String, Value>,
    flags: &mut Flags,
    caller_terminal: Option<String>,
) -> Result<(), UsageError> {
    let state = flags.take("state");
    if let Some(state) = &state {
        validate_one_of("--state", state, STATES)?;
        fields.insert("state".into(), Value::String(state.clone()));
    }
    if let Some(progress) = flags.take("progress") {
        let value = parse_progress(&progress)?;
        if state.as_deref().is_some_and(|state| state != "busy") {
            return Err(UsageError::new("--progress needs --state busy"));
        }
        fields.entry("state").or_insert_with(|| Value::String("busy".into()));
        fields.insert("progress".into(), value);
    }
    if let Some(style) = flags.take("style") {
        validate_one_of("--style", &style, STYLES)?;
        fields.insert("style".into(), Value::String(style));
    }
    if let Some(ttl) = flags.take("ttl") {
        fields.insert("ttl_ms".into(), json!(parse_duration_ms("--ttl", &ttl)?));
    }
    for (flag, field) in [("exit-code", "exit_code"), ("duration-ms", "duration_ms")] {
        if let Some(value) = flags.take(flag) {
            let number = value
                .parse::<i64>()
                .map_err(|_| UsageError::new(format!("--{flag} must be an integer")))?;
            fields.insert(field.into(), json!(number));
        }
    }
    let mut owner = Map::new();
    if let Some(pid) = flags.take("pid") {
        let pid = pid
            .parse::<u32>()
            .ok()
            .filter(|pid| *pid > 1)
            .ok_or_else(|| UsageError::new("--pid must be a process id above 1"))?;
        owner.insert("pid".into(), json!(pid));
    }
    // `--target-terminal` names the terminal the status is about from
    // outside it; inside a terminal it defaults to the caller's own.
    if let Some(terminal) = flags.take("target-terminal") {
        validate_prefixed_id("terminal", "term", &terminal)?;
        fields.insert("target_terminal".into(), Value::String(terminal));
    }
    let keep = match flags.take("owner").as_deref() {
        None | Some("terminal") => false,
        Some("none") => true,
        Some(_) => return Err(UsageError::new("--owner takes terminal or none")),
    };
    if let Some(terminal) = caller_terminal {
        validate_prefixed_id("terminal", "term", &terminal)?;
        if !keep {
            owner.insert("terminal".into(), Value::String(terminal.clone()));
        }
        fields.entry("target_terminal").or_insert(Value::String(terminal));
    }
    if !owner.is_empty() && fields.contains_key("state") {
        fields.insert("owner".into(), Value::Object(owner));
    } else if owner.contains_key("pid") {
        return Err(UsageError::new("--pid needs --state"));
    }
    Ok(())
}

/// `0.4` or `40%`.
fn parse_progress(text: &str) -> Result<Value, UsageError> {
    let value = match text.strip_suffix('%') {
        Some(percent) => percent.parse::<f64>().map(|value| value / 100.0),
        None => text.parse::<f64>(),
    };
    value
        .ok()
        .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))
        .and_then(Number::from_f64)
        .map(Value::Number)
        .ok_or_else(|| UsageError::new("--progress must be 0 to 1 or 0% to 100%"))
}

/// `1500ms`, `30s`, `5m`, `2h`, or bare seconds.
pub(crate) fn parse_duration_ms(flag: &str, text: &str) -> Result<u64, UsageError> {
    let (number, unit) = match text.find(|character: char| character.is_ascii_alphabetic()) {
        Some(index) => text.split_at(index),
        None => (text, "s"),
    };
    let scale = match unit {
        "ms" => 1.0,
        "s" => 1_000.0,
        "m" => 60_000.0,
        "h" => 3_600_000.0,
        _ => {
            return Err(UsageError::new(format!(
                "{flag} takes a duration such as 30s, 5m or 1500ms"
            )));
        }
    };
    number
        .parse::<f64>()
        .ok()
        .map(|value| value * scale)
        .filter(|ms| ms.is_finite() && *ms >= 1.0 && *ms <= 7.0 * 86_400_000.0)
        .map(|ms| ms.round() as u64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be between 1ms and 7 days")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_and_progress_parse_every_spelling() {
        assert_eq!(parse_duration_ms("--ttl", "30").unwrap(), 30_000);
        assert_eq!(parse_duration_ms("--ttl", "1500ms").unwrap(), 1_500);
        assert_eq!(parse_duration_ms("--ttl", "5m").unwrap(), 300_000);
        assert_eq!(parse_duration_ms("--ttl", "2h").unwrap(), 7_200_000);
        assert!(parse_duration_ms("--ttl", "8d").is_err());
        assert!(parse_duration_ms("--ttl", "0s").is_err());
        assert_eq!(parse_progress("40%").unwrap(), json!(0.4));
        assert_eq!(parse_progress("0.25").unwrap(), json!(0.25));
        assert!(parse_progress("140%").is_err());
    }
}
