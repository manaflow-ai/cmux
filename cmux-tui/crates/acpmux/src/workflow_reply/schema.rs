use super::AttemptKey;
use jsonschema::{Retrieve, Uri, Validator};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReplyIssue {
    InvalidJson(String),
    SchemaMismatch { instance_path: String, schema_path: String, message: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ReplyDecision {
    Ignore,
    Accept(Value),
    Correct { prompt: String, issues: Vec<ReplyIssue> },
    Fail { issues: Vec<ReplyIssue> },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("invalid workflow reply schema: {0}")]
pub struct SchemaError(pub String);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReplyState {
    pub key: AttemptKey,
    pub last_sequence: Option<u64>,
    pub correction_requested: bool,
    pub finished: bool,
}

impl ReplyState {
    pub fn new(key: AttemptKey) -> Self {
        Self { key, last_sequence: None, correction_requested: false, finished: false }
    }
}

pub struct ReplyPolicy {
    state: ReplyState,
    schema: Value,
    validator: Validator,
}

impl ReplyPolicy {
    /// Compile before starting an agent. The run journal must pin `schema` with
    /// the activity's prompt and options; restoring state never resets the one
    /// correction allowance.
    pub fn new(schema: &Value, state: ReplyState) -> Result<Self, SchemaError> {
        let validator = jsonschema::options()
            .with_retriever(NoExternalSchemas)
            .build(schema)
            .map_err(|error| SchemaError(error.to_string()))?;
        Ok(Self { state, schema: schema.clone(), validator })
    }

    pub fn state(&self) -> &ReplyState {
        &self.state
    }

    /// Fence a restarted agent's replies while preserving its correction budget.
    /// The daemon journals the new incarnation before it dispatches that agent.
    pub fn rebind(&mut self, key: AttemptKey) -> bool {
        if self.state.finished
            || key.activity_id != self.state.key.activity_id
            || key.generation <= self.state.key.generation
        {
            return false;
        }
        self.state.key = key;
        self.state.last_sequence = None;
        true
    }

    /// Observe one exact final-reply event, identified by its persisted sequence
    /// in this incarnation's event stream. Replaying the event has no new effect.
    pub fn observe(&mut self, key: &AttemptKey, sequence: u64, text: &str) -> ReplyDecision {
        if self.state.finished
            || key != &self.state.key
            || self.state.last_sequence.is_some_and(|last| sequence <= last)
        {
            return ReplyDecision::Ignore;
        }
        self.state.last_sequence = Some(sequence);
        let issues = match serde_json::from_str::<Value>(text) {
            Ok(value) => {
                let issues: Vec<_> = self
                    .validator
                    .iter_errors(&value)
                    .map(|error| ReplyIssue::SchemaMismatch {
                        instance_path: error.instance_path.to_string(),
                        schema_path: error.schema_path.to_string(),
                        message: error.to_string(),
                    })
                    .collect();
                if issues.is_empty() {
                    self.state.finished = true;
                    return ReplyDecision::Accept(value);
                }
                issues
            }
            Err(error) => vec![ReplyIssue::InvalidJson(error.to_string())],
        };
        if self.state.correction_requested {
            self.state.finished = true;
            return ReplyDecision::Fail { issues };
        }
        self.state.correction_requested = true;
        let details = issues
            .iter()
            .map(|issue| match issue {
                ReplyIssue::InvalidJson(message) => format!("Invalid JSON: {message}"),
                ReplyIssue::SchemaMismatch { instance_path, schema_path, message } => {
                    format!("At {instance_path:?} (schema {schema_path:?}): {message}")
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        let prompt = format!(
            "Your final reply did not match the required JSON schema. Return only corrected JSON. \
             This is the one correction attempt.\nValidation errors:\n{details}\n\
             Required schema:\n{}",
            self.schema
        );
        ReplyDecision::Correct { prompt, issues }
    }
}

/// An explicit retriever keeps this policy offline even if another crate enables
/// jsonschema's HTTP/file features in the shared dependency graph. In-document
/// references remain available through the validator's own resource registry.
struct NoExternalSchemas;

impl Retrieve for NoExternalSchemas {
    fn retrieve(
        &self,
        uri: &Uri<String>,
    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        Err(format!("workflow reply schemas cannot retrieve external resource {uri}").into())
    }
}
