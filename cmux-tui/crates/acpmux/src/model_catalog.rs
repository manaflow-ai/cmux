//! ACP select options may contain groups; option values are opaque protocol ids.
use serde_json::Value;

pub fn choices(option: &Value) -> Vec<(String, String)> {
    fn collect(option: &Value, out: &mut Vec<(String, String)>) {
        if let Some(id) = option.get("value").and_then(Value::as_str) {
            out.push((id.to_owned(), option.get("name").and_then(Value::as_str).unwrap_or(id).to_owned()));
        }
        if let Some(children) = option.get("options").and_then(Value::as_array) {
            for child in children { collect(child, out); }
        }
    }
    let mut out = Vec::new();
    collect(option, &mut out);
    out
}

/// Preserve exact ids. DSH also permits the friendly provider/model spelling
/// or a bare model name, but only if that name identifies one advertised route.
pub fn resolve(option: &Value, requested: &str) -> Result<String, String> {
    let options = choices(option);
    if options.iter().any(|(id, _)| id == requested) { return Ok(requested.to_owned()); }
    let matches: Vec<_> = options.iter().filter(|(id, _)| {
        let Ok(parts) = serde_json::from_str::<Vec<String>>(id) else { return false };
        parts.len() == 2 && (parts[1] == requested || format!("{}/{}", parts[0], parts[1]) == requested)
    }).collect();
    match matches.as_slice() {
        [(id, _)] => Ok(id.clone()),
        [] => Ok(requested.to_owned()), // The agent owns validation for other selectors.
        _ => Err(format!("model {requested:?} matches multiple provider routes; use an exact advertised model id")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn grouped_model_ids_are_preserved_and_ambiguous_aliases_fail() {
        let id = r#"["go","flash"]"#;
        let option = json!({"options": [{"group":"go", "name":"Go", "options":[{"value":id,"name":"Flash"}]}]});
        assert_eq!(choices(&option), vec![(id.into(), "Flash".into())]);
        for request in ["flash", "go/flash", id] { assert_eq!(resolve(&option, request).unwrap(), id); }
        let both = json!({"options":[option, {"value":r#"["direct","flash"]"#}]});
        assert!(resolve(&both,"flash").is_err());
        assert_eq!(resolve(&both,id).unwrap(), id);
        let exact = json!({"options":[both, {"value":"flash"}]});
        assert_eq!(resolve(&exact,"flash").unwrap(), "flash");
        assert_eq!(resolve(&json!({"options":[]}),"unknown").unwrap(), "unknown");
    }
}
