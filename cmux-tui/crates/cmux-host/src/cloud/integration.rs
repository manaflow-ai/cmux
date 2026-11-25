//! Short-lived broker tokens for non-GitHub integrations.
//!
//! The machine asks the platform broker for a scoped token as its bound install.
//! The broker owns the vendor OAuth grant and returns only a short-lived token, so
//! Slack, Linear and VM-provider credentials never become machine files.

use crate::json::JsonField;
use serde_json::{Map, Value, json};

use super::sender::Answer;

pub const TOKEN_PATH_PREFIX: &str = "/v1/integrations/";
pub const REQUEST_KEY: &str = "integration_token";
const MAX_PROVIDER: usize = 32;
const MAX_SCOPE: usize = 96;
const MAX_SCOPES: usize = 32;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenAsk {
    pub provider: String,
    pub scopes: Vec<String>,
    pub label: Option<String>,
}

fn valid_atom(value: &str, max: usize) -> bool {
    !value.is_empty()
        && value.len() <= max
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:/-".contains(&b))
}

fn valid_provider(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_PROVIDER
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.')
}

fn valid_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

pub fn path(provider: &str) -> String {
    format!("{TOKEN_PATH_PREFIX}{provider}/token")
}

pub fn from_json(value: &Value) -> Result<TokenAsk, String> {
    let provider = value.field("provider").as_str().unwrap_or("");
    if !valid_provider(provider) {
        return Err("provider must be a non-empty integration name".to_owned());
    }
    let Some(scopes) =
        value.field("scopes").as_array().filter(|s| !s.is_empty() && s.len() <= MAX_SCOPES)
    else {
        return Err("scopes must contain 1-32 entries".to_owned());
    };
    let mut checked = Vec::with_capacity(scopes.len());
    for scope in scopes {
        let Some(scope) = scope.as_str().filter(|s| valid_atom(s, MAX_SCOPE)) else {
            return Err("each scope must be a non-empty integration name".to_owned());
        };
        checked.push(scope.to_owned());
    }
    let label = match value.field("label") {
        Value::Null => None,
        Value::String(label) if valid_label(label) => Some(label.clone()),
        _ => return Err("label must be 1-64 of [A-Za-z0-9._-]".to_owned()),
    };
    Ok(TokenAsk { provider: provider.to_owned(), scopes: checked, label })
}

impl TokenAsk {
    pub fn api_body(&self) -> Value {
        let mut body = Map::new();
        body.insert("scopes".to_owned(), json!(self.scopes));
        if let Some(label) = &self.label {
            body.insert("label".to_owned(), json!(label));
        }
        Value::Object(body)
    }

    pub fn describe(&self) -> String {
        format!("{} {}", self.provider, self.scopes.join(","))
    }
}

pub fn token(value: &str) -> bool {
    !value.is_empty() && value.len() <= 4096 && value.bytes().all(|b| b.is_ascii_graphic())
}

pub fn reply_for(ask: &TokenAsk, answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } => {
            let token = body.field("token").as_str().filter(|t| token(t));
            let expires = body.field("expires_at").as_str().filter(|e| !e.is_empty());
            let provider = body.field("provider").as_str().filter(|p| *p == ask.provider);
            let token_id = body
                .field("token_id")
                .as_str()
                .filter(|id| id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()));
            match (token, expires, provider, token_id) {
                (Some(token), Some(expires), Some(provider), Some(token_id)) => {
                    json!({"ok":true,"token":token,"expires_at":expires,"provider":provider,"scopes":ask.scopes,"token_id":token_id})
                }
                _ => super::github::refusal(
                    "integration.bad_answer",
                    "the API's answer lacks a token, expiry, provider or token_id",
                ),
            }
        }
        Answer::Http { status, body } => {
            let error = body.field("error");
            let code = error
                .field("code")
                .as_str()
                .map_or_else(|| format!("http.{status}"), str::to_owned);
            let message: String =
                error.field("message").as_str().unwrap_or("").chars().take(300).collect();
            json!({"ok":false,"status":status,"error":{"code":code,"message":message}})
        }
        Answer::Transport => {
            super::github::refusal("integration.unreachable", "the cmux Cloud API did not answer")
        }
    }
}

pub fn note_for(ask: &TokenAsk, reply: &Value) -> String {
    let outcome = if *reply.field("ok") == true {
        "minted".to_owned()
    } else {
        format!("refused {}", reply.field("error").field("code").as_str().unwrap_or("?"))
    };
    format!("integration token {}: {outcome}", ask.describe())
}
