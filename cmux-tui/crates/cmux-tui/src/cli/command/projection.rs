//! `cmux projection` commands.

use super::*;

pub(super) fn parse_projection(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["show"] => {
            insert_selector_or_current(
                selectors,
                flags,
                "projection-id",
                "frontend_projection",
                "projection",
            )?;
            request(ResourceOperation::FrontendProjectionGet, selectors, flags, Map::new())
        }
        [selector, "show"] => {
            selectors.insert("frontend_projection", "projection", selector)?;
            request(ResourceOperation::FrontendProjectionGet, selectors, flags, Map::new())
        }
        ["put"] => {
            insert_selector_or_current(
                selectors,
                flags,
                "projection-id",
                "frontend_projection",
                "projection",
            )?;
            let params = projection_put_fields(flags)?;
            request(ResourceOperation::FrontendProjectionPut, selectors, flags, params)
        }
        [selector, "put"] => {
            selectors.insert("frontend_projection", "projection", selector)?;
            let params = projection_put_fields(flags)?;
            request(ResourceOperation::FrontendProjectionPut, selectors, flags, params)
        }
        _ => usage("projection action"),
    }
}

fn projection_put_fields(flags: &mut Flags) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    params.insert("projection".into(), parse_json_flag(flags, "projection")?);
    for (flag, field) in
        [("frontend-id", "frontend_id"), ("window-id", "window_id"), ("generation", "generation")]
    {
        let value = flags.required(flag)?;
        validate_bounded_text(&format!("--{flag}"), &value)?;
        params.insert(field.into(), Value::String(value));
    }
    if let Some(revision) = flags.take("expected-projection-revision") {
        validate_decimal("--expected-projection-revision", &revision)?;
        params.insert("expected_projection_revision".into(), Value::String(revision));
    }
    Ok(params)
}
