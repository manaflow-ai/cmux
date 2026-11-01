//! Cloud environment settings through the existing Cloud transport, with the native app's install token.
//! Only these named routes are exposed; the web page cannot supply a URL or headers.

use serde_json::{Value, json};

use super::{CloudConversations, CloudError};

fn invalid() -> CloudError {
    CloudError::BadRequest(
        "Invalid cloud environment request. Check the fields and try again.".into(),
    )
}

fn identifier(value: Option<&Value>) -> Result<&str, CloudError> {
    value
        .and_then(Value::as_str)
        .filter(|id| {
            (1..=128).contains(&id.len())
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        })
        .ok_or_else(invalid)
}

impl CloudConversations {
    pub fn environment(
        &self,
        action: &str,
        parameters: &Value,
        origin: &str,
        access_token: &str,
    ) -> Result<Value, CloudError> {
        // The verified native app supplies the existing platform resolver's origin and a
        // freshly minted cmux install token. Neither is a page parameter or a Home lease.
        let base = url::Url::parse(origin).map_err(|_| invalid())?;
        if !super::platform::accepts_environment_origin(&base)
            || access_token.is_empty()
            || access_token.len() > 8192
        {
            return Err(invalid());
        }
        let send = |method: &str, path: &str, body: &Value| {
            self.backend()
                .platform(
                    method,
                    &format!("{}{path}", origin.trim_end_matches('/')),
                    access_token,
                    body,
                )
                .map_err(|_| {
                    CloudError::Unavailable("The cloud environment could not be reached.".into())
                })
        };
        let params = parameters.as_object().ok_or_else(invalid)?;
        let reply = match action {
            "list" if params.is_empty() => send("GET", "/v1/cloud-environments", &Value::Null)?,
            "get" if params.len() == 1 => {
                let id = identifier(params.get("id"))?;
                send("GET", &format!("/v1/cloud-environments/{id}"), &Value::Null)?
            }
            "update" if params.len() == 2 => {
                let id = identifier(params.get("id"))?;
                let patch = params.get("patch").and_then(Value::as_object).ok_or_else(invalid)?;
                if patch.keys().any(|key| {
                    ![
                        "name",
                        "setup_script",
                        "env_vars",
                        "set_secrets",
                        "remove_secrets",
                        "network",
                    ]
                    .contains(&key.as_str())
                }) {
                    return Err(invalid());
                }
                // Validation details belong to the platform; preserve null and empty values.
                send("PATCH", &format!("/v1/cloud-environments/{id}"), &json!(patch))?
            }
            "derive" => {
                if params.keys().any(|key| !["repo", "ref", "environment"].contains(&key.as_str()))
                    || params.get("repo").and_then(Value::as_str).is_none_or(|s| s.is_empty())
                {
                    return Err(invalid());
                }
                send("POST", "/v1/environments/derive", parameters)?
            }
            _ => return Err(invalid()),
        };
        // Effect HttpApi returns a flat {_tag, code, message} object. Preserve
        // its typed environment failures even for 503 (secret storage unavailable).
        // Never forward messages, which may reflect a submitted write-only value.
        if !(200..=299).contains(&reply.status) {
            let error = reply.body.get("error").unwrap_or(&reply.body);
            if let Some(code) = error.get("code").and_then(Value::as_str).filter(|code| {
                code.starts_with("cloud_environment.")
                    && code.len() <= 128
                    && code
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"._".contains(&byte))
            }) {
                return Err(CloudError::Rejected {
                    code: code.into(),
                    message: "Could not save or load the cloud environment. Try again.".into(),
                    retryable: reply.status >= 500 || reply.status == 429,
                });
            }
        }
        super::contract::classify(&reply).map_err(|error| match error {
            // A validation service can quote an invalid submitted value. Never echo one
            // from a request that may contain a write-only secret; the UI maps the code.
            CloudError::Rejected { code, retryable, .. } => CloudError::Rejected {
                code,
                message:
                    "Could not save or load the cloud environment. Check the fields and try again."
                        .into(),
                retryable,
            },
            other => other,
        })?;
        let mut body = reply.body;
        // Never forward secret values, even if an upstream reply accidentally includes one.
        fn redact(environment: &mut Value) {
            if let Some(secrets) = environment.get_mut("secrets").and_then(Value::as_array_mut) {
                for secret in secrets {
                    if let Some(fields) = secret.as_object_mut() {
                        fields.retain(|key, _| key == "name" || key == "updated_at");
                    }
                }
            }
        }
        if let Some(environments) = body.as_array_mut() {
            environments.iter_mut().for_each(redact);
        } else {
            redact(&mut body);
        }
        Ok(body)
    }
}
