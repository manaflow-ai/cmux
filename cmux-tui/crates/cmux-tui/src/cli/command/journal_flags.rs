//! Session journal flags: a subscription's start, cursor and filter
//! (`--from`, `--kinds`, `--regex`, ...) and a hook's context on an appended event.

use super::*;

pub(super) fn add_journal_subscription(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    default_start: Option<&str>,
    follow: bool,
) -> Result<(), UsageError> {
    let explicit_start = flags.take("from");
    if let Some(start) = explicit_start.as_deref() {
        validate_one_of("--from", start, &["tail", "beginning"])?;
    }
    let session_id = flags.take("cursor-session");
    let sequence = flags.take("sequence");
    match (session_id, sequence) {
        (None, None) => {
            if let Some(start) = explicit_start.or_else(|| default_start.map(str::to_owned)) {
                params.insert("start".into(), Value::String(start));
            }
        }
        (Some(session_id), Some(sequence)) if explicit_start.is_none() => {
            validate_prefixed_id("session", "session", &session_id)?;
            validate_decimal("--sequence", &sequence)?;
            params.insert("cursor".into(), json!({"generation":session_id,"revision":sequence}));
        }
        (Some(_), Some(_)) => {
            return Err(UsageError::new("--from cannot be combined with a journal cursor"));
        }
        _ => {
            return Err(UsageError::new(
                "--cursor-session and --sequence must be supplied together",
            ));
        }
    }
    if !follow {
        params.insert("follow".into(), Value::Bool(false));
    }

    let mut filter = Map::new();
    if let Some(kinds) = flags.take("kinds") {
        let kinds = comma_separated("--kinds", &kinds)?;
        for kind in &kinds {
            validate_cli_journal_kind(kind)?;
        }
        filter.insert("kinds".into(), Value::Array(kinds.into_iter().map(Value::String).collect()));
    }
    if let Some(classes) = flags.take("classes") {
        let classes = comma_separated("--classes", &classes)?;
        for class in &classes {
            validate_one_of("--classes", class, &["state", "observation", "effect", "checkpoint"])?;
        }
        filter.insert(
            "classes".into(),
            Value::Array(classes.into_iter().map(Value::String).collect()),
        );
    }
    if let Some(subjects) = flags.take("subjects") {
        let subjects = comma_separated("--subjects", &subjects)?
            .into_iter()
            .map(|subject| {
                let (kind, id) = subject
                    .split_once(':')
                    .ok_or_else(|| UsageError::new("--subjects entries must use <kind>:<id>"))?;
                if kind.is_empty()
                    || id.is_empty()
                    || !kind.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
                    })
                {
                    return Err(UsageError::new(
                        "--subjects entries must use a lowercase <kind>:<id>",
                    ));
                }
                Ok(json!({"kind":kind,"id":id}))
            })
            .collect::<Result<Vec<_>, UsageError>>()?;
        filter.insert("subjects".into(), Value::Array(subjects));
    }
    if let Some(sensitivity) = flags.take("max-sensitivity") {
        validate_one_of("--max-sensitivity", &sensitivity, &["public", "metadata", "sensitive"])?;
        filter.insert("max_sensitivity".into(), Value::String(sensitivity));
    }
    let regex = flags.take("regex");
    let regex_field = flags.take("regex-field");
    let ignore_case = flags.boolean("ignore-case");
    match (regex, regex_field, ignore_case) {
        (Some(pattern), field, ignore_case) => {
            if pattern.is_empty() || pattern.len() > 1024 {
                return Err(UsageError::new("--regex must contain 1 to 1024 UTF-8 bytes"));
            }
            let field = field.unwrap_or_else(|| "record".into());
            validate_one_of(
                "--regex-field",
                &field,
                &["kind", "subjects", "payload", "record", "terminal_output"],
            )?;
            filter.insert(
                "regex".into(),
                json!({
                    "pattern":pattern,
                    "field":field,
                    "case_sensitive":!ignore_case,
                }),
            );
        }
        (None, Some(_), _) => {
            return Err(UsageError::new("--regex-field requires --regex"));
        }
        (None, None, true) => {
            return Err(UsageError::new("--ignore-case requires --regex"));
        }
        (None, None, false) => {}
    }
    if !filter.is_empty() {
        params.insert("filter".into(), Value::Object(filter));
    }
    Ok(())
}

fn validate_cli_journal_kind(kind: &str) -> Result<(), UsageError> {
    let base = kind.strip_suffix(".*").unwrap_or(kind);
    if base.is_empty()
        || kind.contains('*') != kind.ends_with(".*")
        || base.split('.').any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        Err(UsageError::new("--kinds entries must be dotted names with an optional terminal .*"))
    } else {
        Ok(())
    }
}

pub(super) fn apply_journal_hook_context(
    event: &mut Value,
    hook_id: Option<&str>,
    causation_id: Option<&str>,
    correlation_id: Option<&str>,
) -> Result<(), UsageError> {
    let hook_id = hook_id.filter(|value| !value.is_empty());
    let causation_id = causation_id.filter(|value| !value.is_empty());
    let correlation_id = correlation_id.filter(|value| !value.is_empty());
    if hook_id.is_none() && causation_id.is_none() && correlation_id.is_none() {
        return Ok(());
    }
    let object = event
        .as_object_mut()
        .ok_or_else(|| UsageError::new("--event-json must contain a JSON object"))?;
    if let Some(causation_id) = causation_id
        && object.get("causation_id").is_none_or(Value::is_null)
    {
        object.insert("causation_id".into(), Value::String(causation_id.into()));
    }
    if let Some(correlation_id) = correlation_id
        && object.get("correlation_id").is_none_or(Value::is_null)
    {
        object.insert("correlation_id".into(), Value::String(correlation_id.into()));
    }
    if let Some(hook_id) = hook_id {
        let subjects = object.entry("subjects").or_insert_with(|| Value::Array(Vec::new()));
        let subjects = subjects
            .as_array_mut()
            .ok_or_else(|| UsageError::new("--event-json subjects must contain a JSON array"))?;
        let already_present = subjects.iter().any(|subject| {
            subject.get("kind").and_then(Value::as_str) == Some("hook")
                && subject.get("id").and_then(Value::as_str) == Some(hook_id)
        });
        if !already_present {
            subjects.push(json!({"kind":"hook","id":hook_id}));
        }
    }
    Ok(())
}
