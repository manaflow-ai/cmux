//! Tasks tools: the `task.*` entries of the Tasks catalog whose MCP exposure
//! is `default` (plans/cmux-next/tasks.md section 3 and section 14 item 4).
//! Schemas, names and docs come from `cmux_tasks_core::catalog`; a call goes
//! to the local Tasks owner through the same client as `cmux task`.

use cmux_tasks_core::catalog::{self, Class, Entry, Expose};
use serde_json::{Map, Value, json};

use super::transport::{CallFailure, FailureKind};

/// The argument that carries a mutation's idempotency key.
const KEY: &str = "idempotency_key";

pub(super) struct TaskTool {
    pub name: String,
    pub entry: &'static Entry,
}

impl TaskTool {
    pub fn mutation(&self) -> bool {
        self.entry.class == Class::Mutation
    }

    pub fn descriptor_json(&self) -> Value {
        let mut schema = self.entry.input_schema();
        if self.mutation()
            && let Some(properties) = schema["properties"].as_object_mut()
        {
            properties.insert(
                KEY.to_owned(),
                json!({"type": "string", "description": "Retry key: a failed call reports the key to retry with, so the change cannot apply twice."}),
            );
        }
        json!({"name": self.name, "description": self.entry.docs, "inputSchema": schema})
    }

    /// The op params and the idempotency key (minted for a mutation that
    /// sends none, so a failure can report it). A key that is not a string
    /// is refused: replacing it would turn a retry into a second change.
    pub fn split(&self, arguments: &Map<String, Value>) -> Result<(Value, Option<String>), Value> {
        let mut params = arguments.clone();
        let key = match params.remove(KEY) {
            None | Some(Value::Null) => None,
            Some(Value::String(key)) => Some(key),
            Some(_) => {
                return Err(json!({
                    "code": "usage",
                    "message": "idempotency_key must be a string",
                    "details": {},
                    "retryable": false,
                }));
            }
        };
        let key = self.mutation().then(|| key.unwrap_or_else(|| cmux_tasks::owner::mint("idem_")));
        Ok((Value::Object(params), key))
    }
}

/// Every default-exposed Tasks tool. Streams (`task.subscribe`) are not tools.
pub(super) fn tools() -> Vec<TaskTool> {
    catalog::all()
        .iter()
        .filter(|entry| entry.mcp == Expose::Default && entry.class != Class::Stream)
        .map(|entry| TaskTool { name: entry.mcp_name(), entry })
        .collect()
}

pub(super) fn find(name: &str) -> Option<TaskTool> {
    tools().into_iter().find(|tool| tool.name == name)
}

/// A Tasks owner error as a tool failure. Before the request reached the
/// owner nothing ran; after it, a lost answer to a mutation may have applied.
pub(super) fn failure(
    error: &cmux_tasks::protocol::ErrorBody,
    sent: bool,
    key: Option<String>,
) -> CallFailure {
    use cmux_tasks::protocol::ErrorCode;
    let lost = matches!(
        error.code,
        ErrorCode::OwnerUnreachable | ErrorCode::Timeout | ErrorCode::Internal
    );
    let kind = match (sent, lost, key.is_some()) {
        (false, _, _) => FailureKind::NotRun,
        (true, true, true) => FailureKind::InProgress,
        (true, true, false) => FailureKind::NotRun,
        (true, false, _) => FailureKind::Rejected,
    };
    let code = serde_json::to_value(&error.code).unwrap_or(Value::Null);
    CallFailure {
        kind,
        error: json!({
            "code": code,
            "message": error.message,
            "details": {},
            "retryable": lost,
        }),
        idempotency_key: key,
    }
}

/// Runs one Tasks op on the local owner (the CLI's own path).
pub(super) fn call_local(
    op: &str,
    params: Value,
    key: Option<String>,
) -> Result<Value, CallFailure> {
    use cmux_tasks::protocol::{ErrorBody, ErrorCode};
    let owner = match cmux_tasks::owner::resolve(None, None) {
        Ok(cmux_tasks::owner::Owner::Local(owner)) => owner,
        Ok(cmux_tasks::owner::Owner::TeamVm { team }) => {
            let error = ErrorBody::new(
                ErrorCode::OwnerUnreachable,
                format!("team {team} lives in its team VM"),
            );
            return Err(failure(&error, false, key));
        }
        Err(message) => {
            return Err(failure(&ErrorBody::new(ErrorCode::Usage, message), false, key));
        }
    };
    let credential = std::env::var("CMUX_LAUNCH_CREDENTIAL").ok().filter(|c| !c.is_empty());
    let mut conn = cmux_tasks::client::Conn::open(
        &owner,
        credential.as_deref(),
        cmux_tasks::cli::DEFAULT_PREFIX,
    )
    .map_err(|error| failure(&error, false, key.clone()))?;
    conn.call(op, params, key.clone())
        .map(|(value, _)| value)
        .map_err(|error| failure(&error, true, key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tasks::protocol::{ErrorBody, ErrorCode};

    #[test]
    fn default_tools_have_catalog_schemas_and_mutations_take_a_key() {
        let tools = tools();
        let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        for expected in ["task_list", "task_get", "task_create", "task_update", "task_comment_add"]
        {
            assert!(names.contains(&expected), "{expected} missing from {names:?}");
        }
        assert!(!names.contains(&"task_subscribe"), "streams are not tools");
        assert!(!names.contains(&"task_delete"), "destructive ops are opt-in");
        let create = find("task_create").unwrap();
        let descriptor = create.descriptor_json();
        assert!(descriptor["inputSchema"]["properties"][KEY].is_object());
        let list = find("task_list").unwrap().descriptor_json();
        assert!(list["inputSchema"]["properties"].get(KEY).is_none(), "reads forbid a key");
    }

    #[test]
    fn a_mutation_gets_a_key_and_a_read_never_does() {
        let mut arguments = Map::new();
        arguments.insert("title".to_owned(), json!("t"));
        let (params, key) = find("task_create").unwrap().split(&arguments).unwrap();
        assert_eq!(params, json!({"title": "t"}));
        assert!(key.unwrap().starts_with("idem_"));
        arguments.insert(KEY.to_owned(), json!("idem_given"));
        let (params, key) = find("task_create").unwrap().split(&arguments).unwrap();
        assert_eq!(params, json!({"title": "t"}), "the key is not an op param");
        assert_eq!(key.as_deref(), Some("idem_given"));
        let (_, key) = find("task_list").unwrap().split(&Map::new()).unwrap();
        assert_eq!(key, None);
        arguments.insert(KEY.to_owned(), json!(7));
        assert!(
            find("task_create").unwrap().split(&arguments).is_err(),
            "a non-string key is refused"
        );
    }

    #[test]
    fn failures_report_whether_the_change_may_have_run() {
        let lost = ErrorBody::new(ErrorCode::OwnerUnreachable, "gone");
        assert_eq!(failure(&lost, false, Some("k".into())).kind, FailureKind::NotRun);
        assert_eq!(failure(&lost, true, Some("k".into())).kind, FailureKind::InProgress);
        let rejected = ErrorBody::new(ErrorCode::Conflict, "stale");
        let failure = failure(&rejected, true, Some("k".into()));
        assert_eq!(failure.kind, FailureKind::Rejected);
        assert_eq!(failure.error["code"], "conflict");
        assert_eq!(failure.idempotency_key.as_deref(), Some("k"));
    }
}
