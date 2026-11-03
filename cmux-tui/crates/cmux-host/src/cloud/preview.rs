//! Preview requests from the machine's work user. Only the root agent selects
//! the machine, team and platform origin; its install bearer never leaves it.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const REQUEST_KEY: &str = "preview";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PreviewOperation {
    List,
    Url,
    Share,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ShareAudience {
    Link,
    Team,
    User(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewAsk {
    pub operation: PreviewOperation,
    pub port: Option<u16>,
    pub audience: Option<ShareAudience>,
    /// Include the private owner bootstrap capability only by explicit request.
    #[serde(default)]
    pub bootstrap: bool,
}

impl PreviewAsk {
    pub fn from_json(value: &Value) -> Result<Self, String> {
        let ask: Self = serde_json::from_value(value.clone()).map_err(|_| {
            "Pass only operation, port and audience; this machine selects its own identity."
                .to_owned()
        })?;
        ask.validate()?;
        Ok(ask)
    }

    pub fn validate(&self) -> Result<(), String> {
        let valid = match self.operation {
            PreviewOperation::List => {
                self.port.is_none() && self.audience.is_none() && !self.bootstrap
            }
            PreviewOperation::Url => self.port.is_some_and(|p| p > 0) && self.audience.is_none(),
            PreviewOperation::Share => {
                self.port.is_some_and(|p| p > 0)
                    && !self.bootstrap
                    && match &self.audience {
                        Some(ShareAudience::Link | ShareAudience::Team) => true,
                        Some(ShareAudience::User(id)) => {
                            !id.is_empty() && id.len() <= 256 && !id.chars().any(char::is_control)
                        }
                        None => false,
                    }
            }
        };
        if valid {
            Ok(())
        } else {
            Err("Use ls, url --port N, or share --port N with one audience.".to_owned())
        }
    }

    pub fn to_line(&self) -> String {
        json!({ REQUEST_KEY: self }).to_string()
    }
}

/// Refresh before selecting a port, so a stopped listener never yields an old URL.
pub fn answer(
    ask: &PreviewAsk,
    machine: &str,
    team: &str,
    mut send: impl FnMut(&str, &str, &Value) -> super::sender::Answer,
) -> Value {
    use super::github::refusal;
    use super::sender::Answer;
    if let Err(why) = ask.validate() {
        return refusal("request.invalid", &why);
    }
    let path = format!("/v1/cloud/machines/{machine}/previews/refresh");
    let inventory = match send("POST", &path, &json!({})) {
        Answer::Http { status: 200, body } => body,
        Answer::Http { body, .. } => {
            return refusal(
                body.pointer("/error/code")
                    .and_then(Value::as_str)
                    .unwrap_or("preview.unavailable"),
                "The preview could not be refreshed. Check this machine's connection and retry.",
            );
        }
        Answer::Transport => {
            return refusal(
                "preview.unreachable",
                "The preview service did not answer. Retry the preview request.",
            );
        }
    };
    if inventory.get("machine").and_then(Value::as_str) != Some(machine)
        || !inventory.get("previews").is_some_and(Value::is_array)
    {
        return refusal(
            "preview.bad_answer",
            "The preview service returned another machine or an invalid inventory.",
        );
    }
    if ask.operation == PreviewOperation::List {
        return match plain_inventory(&inventory) {
            Ok(value) => json!({"ok": true, "value": value}),
            Err(why) => refusal("preview.bad_answer", &why),
        };
    }
    let preview = inventory.get("previews").and_then(Value::as_array).and_then(|rows| {
        rows.iter().find(|row| row.get("port").and_then(Value::as_u64) == ask.port.map(u64::from))
    });
    let Some(preview) = preview else {
        return refusal(
            "preview.not_listening",
            "Start the server on that port, then run the preview command again.",
        );
    };
    if ask.operation == PreviewOperation::Url {
        return match preview_row(preview, ask.bootstrap) {
            Ok(value) => json!({"ok": true, "value": value}),
            Err(why) => refusal("preview.bad_answer", &why),
        };
    }
    let (Some(port), Some(audience)) = (ask.port, ask.audience.as_ref()) else {
        return refusal("request.invalid", "A port and audience are required.");
    };
    let base = format!("/v1/cloud/machines/{machine}/previews/{port}");
    let (method, path, body) = match audience {
        // Leave expiry/use limits to the platform's link policy.
        ShareAudience::Link => ("POST", format!("{base}/links"), json!({})),
        ShareAudience::Team => ("PUT", format!("{base}/grants"), json!({"kind":"team", "id":team})),
        ShareAudience::User(id) => {
            ("PUT", format!("{base}/grants"), json!({"kind":"user", "id":id}))
        }
    };
    let shared = match send(method, &path, &body) {
        Answer::Http { status: 200..=299, body } => body,
        Answer::Http { body, .. } => {
            return refusal(
                body.pointer("/error/code")
                    .and_then(Value::as_str)
                    .unwrap_or("preview.share_failed"),
                "The preview could not be shared. Check the recipient and retry.",
            );
        }
        Answer::Transport => {
            return refusal(
                "preview.unreachable",
                "The preview service did not answer. Retry the preview request.",
            );
        }
    };
    // A recipient must authenticate as themselves. Never pass on the owner's
    // short-lived bootstrap credential when creating a person/team grant.
    let url = if ask.audience == Some(ShareAudience::Link) {
        shared.get("url")
    } else {
        preview.get("origin")
    };
    let Some(url) = url.and_then(Value::as_str).filter(|url| {
        !url.chars().any(|c| c.is_control() || c.is_whitespace())
            && url::Url::parse(url).is_ok_and(|url| {
                url.scheme() == "https"
                    && url.host_str().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
            })
    }) else {
        return refusal("preview.bad_answer", "The preview service returned no shared URL.");
    };
    let mut value = json!({"port":ask.port, "url":url});
    if ask.audience == Some(ShareAudience::Link) {
        if let Some(id) = shared.pointer("/link/linkId") {
            value["linkId"] = id.clone();
        }
    }
    json!({"ok":true, "value":value})
}

/// A plain address never carries a private bootstrap capability, even in JSON.
pub fn preview_row(row: &Value, bootstrap: bool) -> Result<Value, String> {
    let source = row
        .get("origin")
        .or_else(|| row.get("url"))
        .and_then(Value::as_str)
        .ok_or_else(|| "The preview has no address.".to_owned())?;
    if source.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("The preview has an invalid address.".to_owned());
    }
    let parsed =
        url::Url::parse(source).map_err(|_| "The preview has an invalid address.".to_owned())?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err("The preview has an invalid address.".to_owned());
    }
    let origin = parsed.origin().ascii_serialization();
    let address = if bootstrap {
        row.get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| "The preview has no bootstrap URL.".to_owned())?
    } else {
        &origin
    };
    if bootstrap {
        let parsed = url::Url::parse(address)
            .map_err(|_| "The preview has an invalid bootstrap URL.".to_owned())?;
        if address.chars().any(|c| c.is_control() || c.is_whitespace())
            || parsed.origin().ascii_serialization() != origin
            || !parsed.username().is_empty()
            || parsed.password().is_some()
        {
            return Err("The preview has an invalid bootstrap URL.".to_owned());
        }
    }
    let mut result = json!({"port":row.get("port"), "url":address, "origin":origin});
    for key in ["expiresAt", "expires_at"] {
        if let Some(value) = row.get(key) {
            result[key] = value.clone();
        }
    }
    Ok(result)
}

/// Lists never expose owner bootstrap URLs or unrecognized credential fields.
pub fn plain_inventory(inventory: &Value) -> Result<Value, String> {
    let rows = inventory
        .get("previews")
        .and_then(Value::as_array)
        .ok_or_else(|| "The preview service returned an invalid inventory.".to_owned())?;
    let rows = rows.iter().map(|row| preview_row(row, false)).collect::<Result<Vec<_>, _>>()?;
    let mut result = json!({"machine":inventory.get("machine"), "previews":rows});
    for key in ["listening", "unavailable"] {
        if let Some(value) = inventory.get(key) {
            result[key] = value.clone();
        }
    }
    Ok(result)
}

/// One bounded request to the root agent, returning only the preview result.
#[cfg(unix)]
pub fn ask_agent(socket: &std::path::Path, ask: &PreviewAsk) -> Result<Value, String> {
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    ask.validate()?;
    let mut stream = UnixStream::connect(socket).map_err(|e| {
        format!("Cloud preview agent unavailable: {e}; update or reconnect this machine.")
    })?;
    stream.set_read_timeout(Some(Duration::from_secs(240))).map_err(|e| e.to_string())?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
    stream.write_all(format!("{}\n", ask.to_line()).as_bytes()).map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream.take(1024 * 1024)).read_line(&mut line).map_err(|e| e.to_string())?;
    let reply: Value = serde_json::from_str(&line).map_err(|_| {
        "The Cloud agent returned an invalid preview answer; update this machine.".to_owned()
    })?;
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        return reply
            .get("value")
            .cloned()
            .ok_or_else(|| "No preview result in the agent answer.".to_owned());
    }
    Err(reply
        .pointer("/error/message")
        .and_then(Value::as_str)
        .unwrap_or("The Cloud agent refused the preview request; update this machine and retry.")
        .to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_asks_cannot_select_identity_or_api() {
        let base = json!({"operation":"url", "port":3000});
        assert!(PreviewAsk::from_json(&base).is_ok());
        for key in ["machine", "team", "origin", "token", "path"] {
            let mut request = base.clone();
            request.as_object_mut().unwrap().insert(key.into(), json!("other"));
            assert!(PreviewAsk::from_json(&request).is_err(), "{key}");
        }
    }

    #[test]
    fn preview_asks_require_a_port_and_one_share_audience() {
        for bad in [
            json!({"operation":"url"}),
            json!({"operation":"url", "port":0}),
            json!({"operation":"url", "port":65536}),
            json!({"operation":"share", "port":3000}),
            json!({"operation":"share", "port":3000, "audience":{"user":""}}),
            json!({"operation":"list", "port":3000}),
        ] {
            assert!(PreviewAsk::from_json(&bad).is_err(), "{bad}");
        }
        for audience in [json!("link"), json!("team"), json!({"user":"user_one"})] {
            assert!(
                PreviewAsk::from_json(
                    &json!({"operation":"share", "port":3000, "audience":audience})
                )
                .is_ok()
            );
        }
    }
}
