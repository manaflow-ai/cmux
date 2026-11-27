//! The agent chat transcript's look tokens and named looks
//! (`agentPane.display.transcriptLook`, `agentPane.display.transcriptTokens`;
//! docs/cmux-next/transcript-customization.md).
//!
//! The table is schemas/transcript-look/transcript-look.json, which the chat
//! page imports too. A token is a choice or a number with a range; a look
//! sets any subset of them; `cmux` (the default) sets none. This module is
//! the one checker: `cmux settings set` refuses a tokens object with an
//! unknown token or a value out of range (the `transcript_tokens` domain),
//! `cmux theme check` reports it, and [`resolve`] gives the values a look
//! and its overrides draw with.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;
use serde_json::Value;

static SOURCE: &str = include_str!("../../../../schemas/transcript-look/transcript-look.json");

/// The look that sets no token: the chat as it draws today.
pub const DEFAULT_LOOK: &str = "cmux";

#[derive(Debug, Clone, Deserialize)]
pub struct Spec {
    pub version: u32,
    pub tokens: Vec<Token>,
    pub looks: Vec<Look>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Token {
    pub name: String,
    pub kind: TokenKind,
    #[serde(default)]
    pub choices: Vec<String>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub unit: Option<String>,
    pub default: Value,
    pub description: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenKind {
    Choice,
    Number,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Look {
    pub name: String,
    pub title: String,
    pub description: String,
    pub tokens: serde_json::Map<String, Value>,
}

/// The embedded table. It is checked by this crate's tests, so a bad edit
/// fails CI, never a running app.
pub fn spec() -> &'static Spec {
    static SPEC: OnceLock<Spec> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(SOURCE).unwrap_or(Spec {
            version: 0,
            tokens: Vec::new(),
            looks: Vec::new(),
        })
    })
}

pub fn token(name: &str) -> Option<&'static Token> {
    spec().tokens.iter().find(|token| token.name == name)
}

pub fn look(name: &str) -> Option<&'static Look> {
    spec().looks.iter().find(|look| look.name == name)
}

impl Token {
    /// Why `value` is no value of this token, or `None` when it is one.
    pub fn refusal(&self, value: &Value) -> Option<String> {
        match self.kind {
            TokenKind::Choice => match value.as_str() {
                Some(text) if self.choices.iter().any(|choice| choice == text) => None,
                _ => Some(format!("{} takes one of {}", self.name, self.choices.join(", "))),
            },
            TokenKind::Number => {
                let (min, max) = (self.min.unwrap_or(f64::MIN), self.max.unwrap_or(f64::MAX));
                match value.as_f64() {
                    Some(number) if number.is_finite() && number >= min && number <= max => None,
                    _ => Some(format!("{} takes a number from {min} to {max}", self.name)),
                }
            }
        }
    }
}

/// Every problem with a tokens object, as (token, why); empty when it is valid.
pub fn problems(overrides: &Value) -> Vec<(String, String)> {
    let Some(members) = overrides.as_object() else {
        return vec![(String::new(), "an object of token names to values".to_string())];
    };
    members
        .iter()
        .filter_map(|(name, value)| match token(name) {
            None => Some((name.clone(), format!("{name} is no transcript look token"))),
            Some(token) => token.refusal(value).map(|why| (name.clone(), why)),
        })
        .collect()
}

/// Whether `agentPane.display.transcriptTokens` may hold `value`.
pub fn accepts_tokens(value: &Value) -> bool {
    problems(value).is_empty()
}

/// The token values a look and its overrides draw with: each valid override,
/// else the look's value. A token neither sets is absent (the chat's own
/// default). An unknown look reads as [`DEFAULT_LOOK`].
pub fn resolve(look_name: &str, overrides: &Value) -> BTreeMap<String, Value> {
    let mut values = BTreeMap::new();
    if let Some(look) = look(look_name) {
        for (name, value) in &look.tokens {
            values.insert(name.clone(), value.clone());
        }
    }
    if let Some(members) = overrides.as_object() {
        for (name, value) in members {
            if token(name).is_some_and(|token| token.refusal(value).is_none()) {
                values.insert(name.clone(), value.clone());
            }
        }
    }
    values
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_table_parses_and_every_look_is_valid() {
        let spec: Spec = serde_json::from_str(SOURCE).expect("transcript-look.json parses");
        assert_eq!(spec.version, 1);
        assert!(spec.tokens.len() >= 10);
        for token in &spec.tokens {
            assert!(
                token.refusal(&token.default).is_none(),
                "{}'s default is one of its values",
                token.name
            );
            match token.kind {
                TokenKind::Choice => assert!(!token.choices.is_empty() && token.min.is_none()),
                TokenKind::Number => assert!(token.choices.is_empty() && token.min < token.max),
            }
        }
        for look in &spec.looks {
            let tokens = Value::Object(look.tokens.clone());
            assert!(problems(&tokens).is_empty(), "{}: {:?}", look.name, problems(&tokens));
        }
        let names: Vec<_> = spec.looks.iter().map(|look| look.name.as_str()).collect();
        assert_eq!(names, ["cmux", "claude", "codex", "studio"]);
    }

    #[test]
    fn cmux_sets_no_token() {
        assert!(look(DEFAULT_LOOK).is_some_and(|look| look.tokens.is_empty()));
        assert!(resolve(DEFAULT_LOOK, &json!({})).is_empty());
        assert!(resolve("no-such-look", &json!({})).is_empty());
    }

    #[test]
    fn an_override_wins_and_a_bad_one_is_dropped() {
        let values = resolve(
            "codex",
            &json!({"userMessage.radius": 4, "timestamps": "sometimes", "nope": 1, "rowSpacing": 9}),
        );
        assert_eq!(values["userMessage.radius"], json!(4));
        assert_eq!(values["timestamps"], json!("off"));
        assert!(!values.contains_key("nope"));
        assert!(!values.contains_key("rowSpacing"));
    }

    #[test]
    fn the_tokens_row_refuses_unknown_tokens_and_out_of_range_values() {
        assert!(accepts_tokens(&json!({})));
        assert!(accepts_tokens(&json!({"userMessage.style": "plain", "userMessage.fill": 0})));
        assert!(!accepts_tokens(&json!({"userMessage.style": "square"})));
        assert!(!accepts_tokens(&json!({"userMessage.fill": 0.5})));
        assert!(!accepts_tokens(&json!({"userMessage.fill": "0.1"})));
        assert!(!accepts_tokens(&json!({"avatar": "on"})));
        assert!(!accepts_tokens(&json!([])));
    }
}
