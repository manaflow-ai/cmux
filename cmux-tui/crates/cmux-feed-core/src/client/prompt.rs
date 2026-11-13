//! The typed view of an item's prompt (Swift `FeedPrompt` and
//! `FeedWireDecode.prompt`): what the row content, the choice check and the
//! GitHub actions read. The item keeps the prompt's JSON; this is derived
//! from it on demand, and an unknown kind is `Custom`.

use cmux_json::JsonGet as _;
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

impl Prompt {
    /// The typed prompt of `kind` with `prompt` (an object; anything else
    /// reads as `{}`).
    pub fn parse(kind: &str, prompt: &Value) -> Self {
        match kind {
            "notice" => Prompt::Notice,
            "question" => {
                Prompt::Question { question: prompt.get_string("question").unwrap_or_default() }
            }
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
                    summary: action.get_string("summary").unwrap_or_default(),
                    command: action.get_string("command"),
                }
            }
            "confirm" => {
                Prompt::Confirm { statement: prompt.get_string("statement").unwrap_or_default() }
            }
            "sign-in" => Prompt::SignIn { origin: prompt.get_string("origin").unwrap_or_default() },
            "passkey" => Prompt::Passkey {
                origin: prompt.get_string("origin").unwrap_or_default(),
                rp_id: prompt.get_string("rp_id"),
            },
            "review" => Prompt::Review {
                subject: prompt.get_string("subject").unwrap_or_else(|| "document".to_owned()),
                reference: prompt.get_string("ref").unwrap_or_default(),
            },
            "input" => Prompt::Input,
            "file" => Prompt::File { purpose: prompt.get_string("purpose").unwrap_or_default() },
            "handoff" => Prompt::Handoff {
                reason: prompt.get_string("reason").unwrap_or_default(),
                resume_hint: prompt.get_string("resume_hint"),
            },
            _ => Prompt::Custom,
        }
    }
}

fn choice_question(question: &Value) -> ChoiceQuestion {
    ChoiceQuestion {
        id: question.get_string("id").unwrap_or_default(),
        question: question.get_string("question").unwrap_or_default(),
        options: question
            .get("options")
            .and_then(Value::as_array)
            .map(|options| {
                options
                    .iter()
                    .map(|option| ChoiceOption {
                        id: option.get_string("id").unwrap_or_default(),
                        label: option.get_string("label").unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default(),
        multi: question.get_bool("multi").unwrap_or(false),
        allow_other: question.get_bool("allow_other").unwrap_or(false),
    }
}
