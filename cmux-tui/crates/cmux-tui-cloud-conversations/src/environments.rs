//! Cloud environment settings through the existing Cloud transport, with the native app's install token.
//! Only these named routes are exposed; the web page cannot supply a URL or headers.

use serde_json::{Value, json};

use super::{CloudConversations, CloudError, HttpReply};

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

/// A refused reply as the error the sheet sees. Effect HttpApi returns a flat
/// `{_tag, code, message}` object (or one under `error`). A code the sheet maps
/// (cmux-platform's `cloud_environment.*` refusals and, since cmux-platform#1046, the vault's
/// `vault.*` save failures) is forwarded alone, shape and length checked, even for a 503. Any
/// other 4xx code becomes `http_<status>`. The message is always ours, never the upstream's: a
/// validation service can quote a submitted write-only value.
fn refused(reply: &HttpReply) -> Result<(), CloudError> {
    if (200..=299).contains(&reply.status) {
        return Ok(());
    }
    let error = reply.body.get("error").unwrap_or(&reply.body);
    if let Some(code) = error.get("code").and_then(Value::as_str).filter(|code| {
        (code.starts_with("cloud_environment.") || code.starts_with("vault."))
            && code.len() <= 128
            && code.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._".contains(&byte))
    }) {
        return Err(CloudError::Rejected {
            code: code.into(),
            message: "Could not save or load the cloud environment. Try again.".into(),
            retryable: reply.status >= 500 || reply.status == 429,
        });
    }
    super::contract::classify(reply).map_err(|error| match error {
        CloudError::Rejected { retryable, .. } => CloudError::Rejected {
            code: format!("http_{}", reply.status),
            message:
                "Could not save or load the cloud environment. Check the fields and try again."
                    .into(),
            retryable,
        },
        other => other,
    })
}

/// A GitHub repository as `owner/name`, for the per-project default's query: an owner of 1 to 39
/// letters, digits and dashes, and a name of 1 to 100 letters, digits, `.`, `_` and `-` (never
/// `.` or `..`). The page names nothing else in the path.
fn repository(value: Option<&Value>) -> Result<(&str, &str), CloudError> {
    let (owner, name) =
        value.and_then(Value::as_str).and_then(|repo| repo.split_once('/')).ok_or_else(invalid)?;
    let owner_ok = (1..=39).contains(&owner.len())
        && owner.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    let name_ok = (1..=100).contains(&name.len())
        && name != "."
        && name != ".."
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
    if owner_ok && name_ok { Ok((owner, name)) } else { Err(invalid()) }
}

/// The fields a PATCH may carry: the original ones, the Codex-style configuration (`repo`, `ref`,
/// `maintenance_script`, `files`, `image`) and `expected_revision`, which makes the platform refuse
/// a save on a record changed since it was read (409 `cloud_environment.revision_conflict`,
/// forwarded as that code). The platform validates them all.
const UPDATE_FIELDS: &[&str] = &[
    "name",
    "setup_script",
    "env_vars",
    "set_secrets",
    "remove_secrets",
    "network",
    "repo",
    "ref",
    "maintenance_script",
    "files",
    "image",
    "expected_revision",
];
const CREATE_FIELDS: &[&str] = &[
    "name",
    "scope",
    "setup_script",
    "env_vars",
    "secrets",
    "network",
    "repo",
    "ref",
    "maintenance_script",
    "files",
    "image",
];

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
                if patch.keys().any(|key| !UPDATE_FIELDS.contains(&key.as_str())) {
                    return Err(invalid());
                }
                // Validation details belong to the platform; preserve null and empty values.
                send("PATCH", &format!("/v1/cloud-environments/{id}"), &json!(patch))?
            }
            // New environment… (the composer's Environment chip): one new environment, with the
            // platform's create fields only; the platform validates them.
            "create" if params.len() == 1 => {
                let environment =
                    params.get("environment").and_then(Value::as_object).ok_or_else(invalid)?;
                if environment
                    .get("name")
                    .and_then(Value::as_str)
                    .is_none_or(|name| name.trim().is_empty())
                    || environment.keys().any(|key| !CREATE_FIELDS.contains(&key.as_str()))
                {
                    return Err(invalid());
                }
                send("POST", "/v1/cloud-environments", &json!(environment))?
            }
            // The project's default environment (the composer's Environment chip,
            // cmux-platform#1144): read the caller's defaults for one repository (personal first,
            // then the team's), or set the personal one (`environment` null removes it). Only a
            // checked `owner/name` reaches the query.
            "default" if params.len() == 1 => {
                let (owner, name) = repository(params.get("repo"))?;
                send(
                    "GET",
                    &format!("/v1/cloud-environments/project-defaults?repo={owner}%2F{name}"),
                    &Value::Null,
                )?
            }
            "setDefault" if params.len() == 2 => {
                let (owner, name) = repository(params.get("repo"))?;
                let environment = match params.get("environment") {
                    Some(Value::Null) => Value::Null,
                    id => Value::String(identifier(id)?.into()),
                };
                send(
                    "PUT",
                    "/v1/cloud-environments/project-defaults",
                    &json!({ "repo": format!("{owner}/{name}"), "environment": environment }),
                )?
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
        refused(&reply)?;
        let mut body = reply.body;
        if let Some(environments) = body.as_array_mut() {
            environments.iter_mut().for_each(redact);
        } else {
            redact(&mut body);
        }
        Ok(body)
    }
}

/// Never forward secret values, even if an upstream reply accidentally includes one. A secret
/// keeps only its name, `updated_at` and its delivery targets: `hosts` (strings) and `header`'s
/// `name` and `format` (strings). Any other field, nested ones included, and any secret that is not
/// an object, is dropped.
fn redact(environment: &mut Value) {
    let Some(secrets) = environment.get_mut("secrets").and_then(Value::as_array_mut) else {
        return;
    };
    secrets.retain(Value::is_object);
    for fields in secrets.iter_mut().filter_map(Value::as_object_mut) {
        fields.retain(|key, _| matches!(key.as_str(), "name" | "updated_at" | "hosts" | "header"));
        if let Some(hosts) = fields.get_mut("hosts") {
            match hosts.as_array_mut() {
                Some(list) => list.retain(Value::is_string),
                None => *hosts = Value::Null,
            }
        }
        // A header is forwarded only whole: its `name` and `format`, both strings, and nothing else.
        if let Some(header) = fields.get_mut("header") {
            *header = match (
                header.get("name").and_then(Value::as_str),
                header.get("format").and_then(Value::as_str),
            ) {
                (Some(name), Some(format)) => json!({ "name": name, "format": format }),
                _ => Value::Null,
            };
        }
        fields.retain(|_, value| !value.is_null());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A save answered with `status` and `body`.
    fn save_refused(status: u16, body: Value) -> CloudError {
        refused(&HttpReply { status, body }).expect_err("a refused save fails")
    }

    #[test]
    fn a_vault_code_reaches_the_sheet_and_an_upstream_message_never_does() {
        for status in [400, 503] {
            let error = save_refused(
                status,
                json!({"_tag": "MachineBadRequest", "code": "vault.secret_without_host",
                       "message": "TOKEN=hunter2 has no host"}),
            );
            let CloudError::Rejected { code, message, retryable } = &error else {
                panic!("{status}: {error:?}");
            };
            assert_eq!(code, "vault.secret_without_host");
            assert_eq!(*retryable, status >= 500);
            assert!(!message.contains("hunter2"), "{message}");
        }
    }

    #[test]
    fn a_code_outside_the_sheets_prefixes_is_not_forwarded_nor_its_message() {
        for (status, body) in [
            (400, json!({"code": "other.thing", "message": "hunter2"})),
            (400, json!({"error": {"code": "other.thing", "message": "hunter2"}})),
            (400, json!({"code": "vault.has space", "message": "hunter2"})),
            (400, json!({"code": format!("vault.{}", "a".repeat(128)), "message": "hunter2"})),
            (503, json!({"code": "other.thing", "message": "hunter2"})),
        ] {
            let error = save_refused(status, body);
            let text = format!("{error:?}");
            assert!(!text.contains("other.thing") && !text.contains("vault."), "{text}");
            assert!(!text.contains("hunter2"), "{text}");
            match error {
                CloudError::Rejected { code, .. } => assert_eq!(code, format!("http_{status}")),
                CloudError::Unavailable(_) => assert_eq!(status, 503),
                other => panic!("{other:?}"),
            }
        }
    }

    #[test]
    fn a_default_names_only_an_owner_and_name_in_its_path() {
        for repo in ["octocat/hello-world", "a-b/c.d_e", "o/n"] {
            assert!(repository(Some(&json!(repo))).is_ok(), "{repo}");
        }
        for repo in [
            json!("octocat"),
            json!("octocat/hello/world"),
            json!("../x"),
            json!("octocat/.."),
            json!("octocat/a?b"),
            json!("octocat/a%2fb"),
            json!("-/"),
            json!(7),
        ] {
            assert!(repository(Some(&repo)).is_err(), "{repo}");
        }
    }

    #[test]
    fn redact_keeps_only_a_secrets_name_dates_hosts_and_header_name_and_format() {
        let mut environment = json!({
            "id": "env_a",
            "secrets": [{
                "name": "TOKEN",
                "updated_at": 3,
                "value": "hunter2",
                "sealed": "v2.abc",
                "hosts": ["api.example.com", {"value": "hunter2"}],
                "header": {
                    "name": "authorization",
                    "format": "Bearer {value}",
                    "value": "hunter2",
                    "nested": {"value": "hunter2"},
                },
            }, "hunter2"],
        });
        redact(&mut environment);
        assert_eq!(
            environment,
            json!({
                "id": "env_a",
                "secrets": [{
                    "name": "TOKEN",
                    "updated_at": 3,
                    "hosts": ["api.example.com"],
                    "header": {"name": "authorization", "format": "Bearer {value}"},
                }],
            })
        );
        assert!(!environment.to_string().contains("hunter2"));
    }

    #[test]
    fn redact_drops_a_partial_header_or_hosts_that_is_not_the_expected_shape() {
        let mut environment = json!({
            "secrets": [
                {"name": "TOKEN", "header": "Bearer hunter2", "hosts": "hunter2"},
                {"name": "PARTIAL", "header": {"name": "authorization"}},
                {"name": "NOT_TEXT", "header": {"name": "authorization", "format": 7}},
            ],
        });
        redact(&mut environment);
        assert_eq!(
            environment,
            json!({"secrets": [{"name": "TOKEN"}, {"name": "PARTIAL"}, {"name": "NOT_TEXT"}]})
        );
    }
}
