//! Owns model/config option lookup helpers and the dashboard URL formatter.

use super::*;

/// Browser URL for the dashboard, with the listener's token (a `--token`
/// value for this run, else the saved one) in the fragment: a browser never
/// sends a fragment to a server or in a Referer, so the token stays out of
/// request logs. The page moves it out of the address bar.
pub fn web_url(cfg: &crate::config::Config) -> Option<String> {
    let w = cfg.web_listener()?;
    let host = w.listen.replace("0.0.0.0", "127.0.0.1").replace("[::]", "[::1]");
    Some(match cfg.web_token_override.as_ref().or(w.token.as_ref()) {
        Some(t) => format!("http://{host}/#token={t}"),
        None => format!("http://{host}/"),
    })
}

/// `web_url` opening one session: `?session=<id>` before the fragment.
pub fn web_url_for_session(url: &str, session: &str) -> String {
    let (base, fragment) = url.split_once('#').map_or((url, None), |(b, f)| (b, Some(f)));
    let joiner = if base.contains('?') { '&' } else { '?' };
    match fragment {
        Some(f) => format!("{base}{joiner}session={session}#{f}"),
        None => format!("{base}{joiner}session={session}"),
    }
}

/// Current value of a select config option, by id.
pub fn current_option(m: &SessionMeta, id: &str) -> Option<String> {
    let opts = m.config_options.as_ref().and_then(Value::as_array)?;
    opts.iter()
        .find(|o| o.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|o| o.get("currentValue").and_then(Value::as_str).map(str::to_owned))
}

/// The effort a Claude Code session (re)starts with: its Reasoning level, or
/// `ultracode` while that switch is on.
pub fn current_effort(m: &SessionMeta) -> Option<String> {
    if current_option(m, crate::claude_stdio::ULTRACODE_OPTION).as_deref() == Some("on") {
        return Some("ultracode".into());
    }
    current_option(m, "effort")
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

#[cfg(test)]
mod web_url_tests {
    use super::web_url_for_session;

    #[test]
    fn a_session_link_puts_the_session_in_the_query_and_keeps_the_fragment() {
        let url = web_url_for_session("http://127.0.0.1:1/#token=t", "s1");
        assert_eq!(url, "http://127.0.0.1:1/?session=s1#token=t");
        assert_eq!(web_url_for_session("http://h/", "s1"), "http://h/?session=s1");
        assert_eq!(
            web_url_for_session("http://h/?a=1#token=t", "s"),
            "http://h/?a=1&session=s#token=t"
        );
    }
}
