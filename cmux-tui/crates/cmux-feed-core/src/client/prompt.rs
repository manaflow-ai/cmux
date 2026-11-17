//! The typed view of an item's prompt (Swift `FeedPrompt` and
//! `FeedWireDecode.prompt`): what the row content, the choice check and the
//! GitHub actions read. The item keeps the prompt's JSON; this is derived
//! from it on demand, and an unknown kind is `Custom`.

use serde_json::Value;

/// One choice option.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChoiceOption {
    pub id: String,
    pub label: String,
}

/// One choice question (two to eight options).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChoiceQuestion {
    pub id: String,
    pub question: String,
    pub options: Vec<ChoiceOption>,
    pub multi: bool,
    pub allow_other: bool,
}

/// `approve`'s action type; an unknown one reads as `custom`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApproveType {
    Command,
    Edit,
    Tool,
    Network,
    Install,
    Custom,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Prompt {
    Notice,
    Question {
        question: String,
    },
    Choice {
        questions: Vec<ChoiceQuestion>,
    },
    Approve {
        action: ApproveType,
        summary: String,
        command: Option<String>,
    },
    Confirm {
        statement: String,
    },
    SignIn {
        origin: String,
    },
    Passkey {
        origin: String,
        rp_id: Option<String>,
    },
    Review {
        subject: String,
        reference: String,
    },
    Input,
    File {
        purpose: String,
    },
    Handoff {
        reason: String,
        resume_hint: Option<String>,
    },
    /// `x-<publisher>.<name>` or any kind this client does not know.
    Custom,
}

fn text(object: &Value, key: &str) -> String {
    object.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn optional(object: &Value, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn flag(object: &Value, key: &str) -> bool {
    object.get(key).and_then(Value::as_bool).unwrap_or(false)
}

impl Prompt {
    /// The typed prompt of `kind` with `prompt` (an object; anything else
    /// reads as `{}`).
    pub fn parse(kind: &str, prompt: &Value) -> Self {
        match kind {
            "notice" => Prompt::Notice,
            "question" => Prompt::Question { question: text(prompt, "question") },
            "choice" => Prompt::Choice {
                questions: prompt
                    .get("questions")
                    .and_then(Value::as_array)
                    .map(|questions| questions.iter().map(choice_question).collect())
                    .unwrap_or_default(),
            },
            "approve" => {
                let action = prompt.get("action").cloned().unwrap_or(Value::Null);
                let kind = match action.get("type").and_then(Value::as_str) {
                    Some("command") => ApproveType::Command,
                    Some("edit") => ApproveType::Edit,
                    Some("tool") => ApproveType::Tool,
                    Some("network") => ApproveType::Network,
                    Some("install") => ApproveType::Install,
                    _ => ApproveType::Custom,
                };
                Prompt::Approve {
                    action: kind,
                    summary: text(&action, "summary"),
                    command: optional(&action, "command"),
                }
            }
            "confirm" => Prompt::Confirm { statement: text(prompt, "statement") },
            "sign-in" => Prompt::SignIn { origin: text(prompt, "origin") },
            "passkey" => {
                Prompt::Passkey { origin: text(prompt, "origin"), rp_id: optional(prompt, "rp_id") }
            }
            "review" => Prompt::Review {
                subject: optional(prompt, "subject").unwrap_or_else(|| "document".to_owned()),
                reference: text(prompt, "ref"),
            },
            "input" => Prompt::Input,
            "file" => Prompt::File { purpose: text(prompt, "purpose") },
            "handoff" => Prompt::Handoff {
                reason: text(prompt, "reason"),
                resume_hint: optional(prompt, "resume_hint"),
            },
            _ => Prompt::Custom,
        }
    }
}

fn choice_question(question: &Value) -> ChoiceQuestion {
    ChoiceQuestion {
        id: text(question, "id"),
        question: text(question, "question"),
        options: question
            .get("options")
            .and_then(Value::as_array)
            .map(|options| {
                options
                    .iter()
                    .map(|option| ChoiceOption {
                        id: text(option, "id"),
                        label: text(option, "label"),
                    })
                    .collect()
            })
            .unwrap_or_default(),
        multi: flag(question, "multi"),
        allow_other: flag(question, "allow_other"),
    }
}
