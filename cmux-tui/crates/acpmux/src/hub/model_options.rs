//! Owns model/config option lookup helpers and the dashboard URL formatter.

use super::*;

/// Browser URL for the dashboard, with the listener's token in the query
/// string (a `--token` value for this run, else the saved one).
pub fn web_url(cfg: &crate::config::Config) -> Option<String> {
    let w = cfg.web_listener()?;
    let host = w.listen.replace("0.0.0.0", "127.0.0.1").replace("[::]", "[::1]");
    Some(match cfg.web_token_override.as_ref().or(w.token.as_ref()) {
        Some(t) => format!("http://{host}/?token={t}"),
        None => format!("http://{host}/"),
    })
}

/// Current value of a select config option, by id.
pub fn current_option(m: &SessionMeta, id: &str) -> Option<String> {
    let opts = m.config_options.as_ref().and_then(Value::as_array)?;
    opts.iter()
        .find(|o| o.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|o| o.get("currentValue").and_then(Value::as_str).map(str::to_owned))
}

/// The option id a harness uses for thinking effort, given the name a
/// client asked for. `effort` is the portable name; Codex calls it
/// `reasoning_effort`.
pub fn resolve_config_id(m: &SessionMeta, id: &str) -> String {
    let ids: Vec<String> = m
        .config_options
        .as_ref()
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|o| o.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    if ids.iter().any(|x| x == id) {
        return id.to_owned();
    }
    if matches!(id, "effort" | "thinking" | "reasoning" | "reasoning_effort") {
        for cand in ["effort", "reasoning_effort", "thinking", "reasoning", "thought_level"] {
            if ids.iter().any(|x| x == cand) {
                return cand.to_owned();
            }
        }
    }
    id.to_owned()
}

pub fn current_model(m: &SessionMeta) -> Option<String> {
    if let Some(r) = &m.model_request {
        return Some(r.clone());
    }
    if let Some(opts) = m.config_options.as_ref().and_then(Value::as_array) {
        for o in opts {
            if o.get("id").and_then(Value::as_str) == Some("model")
                && let Some(v) = o.get("currentValue").and_then(Value::as_str)
            {
                return Some(v.to_owned());
            }
        }
    }
    m.models
        .as_ref()
        .and_then(|x| x.get("currentModelId"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}
