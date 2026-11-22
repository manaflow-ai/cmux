//! `fill`: a key typed into a cmux browser tab's field, on the key's hosts only.

use super::*;

pub(super) fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map(|(scheme, rest)| (scheme.to_ascii_lowercase(), rest))?;
    if rest.0 != "https" && rest.0 != "http" {
        return None;
    }
    let authority = rest.1.split(['/', '?', '#']).next()?;
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = host.split(':').next()?;
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

/// A page on `host` may get a key for `hosts`: the same host or a subdomain of one.
pub(in crate::cli) fn host_allowed(host: &str, hosts: &[String]) -> bool {
    hosts.iter().any(|allowed| host == allowed || host.ends_with(&format!(".{allowed}")))
}

/// Types key `name` into a field of a cmux browser tab. With hosts, a page on another host is
/// refused before anything is typed.
pub(in crate::cli) fn fill(
    paths: &Paths,
    vault: &dyn KeyVault,
    app: &dyn App,
    fill: &Fill,
) -> Result<Value, String> {
    let (key, value) = value_of(paths, vault, &fill.name)?;
    let hosts = hosts_of(&key);
    let mut target = json!({});
    if let Some(tab) = &fill.tab {
        set(&mut target, "tab", json!(tab));
    }
    let state = app
        .call("browser.page.state", target.clone(), None)?
        .map_err(|error| refusal("browser.page.state", &error))?;
    let url = state.get("url").and_then(Value::as_str).unwrap_or("");
    let host = url_host(url);
    if !hosts.is_empty() {
        match &host {
            Some(host) if host_allowed(host, &hosts) => {}
            _ => {
                return Err(format!(
                    "key {} is for {}, and the tab shows {}: not filled",
                    fill.name,
                    hosts.join(", "),
                    host.as_deref().unwrap_or("no web page")
                ));
            }
        }
    }
    let mut params = target.clone();
    set(&mut params, "selector", json!(fill.selector));
    set(&mut params, "text", json!(value.as_str()));
    set(&mut params, "secret", json!(true));
    set(&mut params, "secret_hosts", json!(hosts));
    let method = if fill.typing { "browser.page.type" } else { "browser.page.fill" };
    let answer = app.call(method, params, None)?;
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => return Err(mask_text(&refusal(method, &error), &[&value])),
    };
    let tab = answer.get("tab").or_else(|| state.get("tab")).cloned().unwrap_or(Value::Null);
    let place = format!("browser:{} {}", host.as_deref().unwrap_or("page"), fill.selector);
    record(paths, &fill.name, &place, false)?;
    Ok(mask_json(
        &json!({"filled": fill.name, "tab": tab, "host": host, "selector": fill.selector}),
        &[&value],
    ))
}

pub(super) fn refusal(method: &str, error: &Value) -> String {
    format!(
        "{method}: {} {}",
        error.get("code").and_then(Value::as_str).unwrap_or("refused"),
        error.get("message").and_then(Value::as_str).unwrap_or("")
    )
}
