use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::openai_ws;
use crate::openai_ws::ResponsesWsClient;
use crate::output_store::OutputStore;
use crate::storage::HandoffResponse;
use crate::storage::SessionFileResponse;
use crate::storage::SessionMeta;
use crate::storage::SessionStatus;
use crate::storage::SessionStore;
use crate::storage::now_ms;
use crate::storage::preview;
use crate::tools::SessionToolContext;
use crate::tools::ToolRuntime;

const DEFAULT_MAX_STEPS: usize = 32;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionRequest {
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionResponse {
    pub session_id: Uuid,
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnRequest {
    pub input: String,
    pub model: Option<String>,
    pub instructions: Option<String>,
    pub reasoning_effort: Option<String>,
    pub max_steps: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TurnResult {
    pub session_id: Uuid,
    pub response_id: Option<String>,
    pub assistant_text: String,
    pub steps: usize,
    pub token_usage: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    UserInput {
        session_id: Uuid,
        input: String,
    },
    TurnStarted {
        session_id: Uuid,
    },
    Upstream {
        event: openai_ws::AgentStreamEvent,
    },
    ToolStarted {
        name: String,
        call_id: String,
    },
    ToolCompleted {
        name: String,
        call_id: String,
        output: Value,
    },
    TurnCompleted {
        result: TurnResult,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone)]
struct SessionState {
    cwd: PathBuf,
    env: HashMap<String, String>,
    previous_response_id: Option<String>,
}

#[derive(Debug)]
pub struct AgentRuntime {
    default_model: String,
    openai: Arc<ResponsesWsClient>,
    tools: ToolRuntime,
    session_store: SessionStore,
    sessions: RwLock<HashMap<Uuid, SessionState>>,
}

#[derive(Debug, Clone)]
struct ToolCall {
    call_id: String,
    name: String,
    arguments: String,
}

impl AgentRuntime {
    pub async fn new(
        default_model: String,
        output_store: OutputStore,
        session_store: SessionStore,
        openai: Arc<ResponsesWsClient>,
    ) -> Result<Self> {
        let sessions = session_store
            .list_sessions()
            .await?
            .into_iter()
            .map(|meta| {
                (
                    meta.session_id,
                    SessionState {
                        cwd: meta.cwd,
                        env: HashMap::new(),
                        previous_response_id: meta.previous_response_id,
                    },
                )
            })
            .collect();
        Ok(Self {
            default_model,
            openai,
            tools: ToolRuntime::new(output_store),
            session_store,
            sessions: RwLock::new(sessions),
        })
    }

    pub async fn create_session(
        &self,
        request: CreateSessionRequest,
    ) -> Result<CreateSessionResponse> {
        let cwd = match request.cwd {
            Some(path) if path.is_absolute() => path,
            Some(path) => std::env::current_dir()?.join(path),
            None => std::env::current_dir()?,
        };
        let cwd = cwd
            .canonicalize()
            .with_context(|| format!("canonicalizing cwd {}", cwd.display()))?;
        let session_id = Uuid::new_v4();
        self.session_store
            .create_session(session_id, cwd.clone())
            .await?;
        self.sessions.write().await.insert(
            session_id,
            SessionState {
                cwd: cwd.clone(),
                env: request.env,
                previous_response_id: None,
            },
        );
        Ok(CreateSessionResponse { session_id, cwd })
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionMeta>> {
        self.session_store.list_sessions().await
    }

    pub async fn read_handoff(&self, session_id: Uuid) -> Result<HandoffResponse> {
        Ok(HandoffResponse {
            session_id,
            handoff: self.session_store.read_handoff(session_id).await?,
        })
    }

    pub async fn open_trajectory(&self, session_id: Uuid) -> Result<SessionFileResponse> {
        self.session_store.open_trajectory(session_id).await
    }

    pub async fn open_handoff(&self, session_id: Uuid) -> Result<SessionFileResponse> {
        self.session_store.open_handoff(session_id).await
    }

    pub async fn run_turn<F>(
        &self,
        session_id: Uuid,
        request: TurnRequest,
        mut emit: F,
    ) -> Result<TurnResult>
    where
        F: FnMut(AgentEvent) + Send,
    {
        let result = self.run_turn_inner(session_id, request, &mut emit).await;
        if let Err(err) = &result {
            let event = AgentEvent::Error {
                message: err.to_string(),
            };
            let _ = self.emit_event(session_id, &mut emit, event).await;
        }
        result
    }

    async fn run_turn_inner<F>(
        &self,
        session_id: Uuid,
        request: TurnRequest,
        emit: &mut F,
    ) -> Result<TurnResult>
    where
        F: FnMut(AgentEvent) + Send,
    {
        if !self.sessions.read().await.contains_key(&session_id) {
            return Err(anyhow!("unknown session `{session_id}`"));
        }
        self.emit_event(
            session_id,
            emit,
            AgentEvent::UserInput {
                session_id,
                input: request.input.clone(),
            },
        )
        .await?;
        self.emit_event(session_id, emit, AgentEvent::TurnStarted { session_id })
            .await?;
        let session = self
            .sessions
            .read()
            .await
            .get(&session_id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown session `{session_id}`"))?;
        let tool_context = SessionToolContext {
            cwd: session.cwd,
            env: session.env,
        };

        let model = request
            .model
            .clone()
            .unwrap_or_else(|| self.default_model.clone());
        let instructions = request.instructions.unwrap_or_else(default_instructions);
        let reasoning = request.reasoning_effort.as_ref().map(|effort| {
            json!({
                "effort": effort
            })
        });
        let max_steps = request.max_steps.unwrap_or(DEFAULT_MAX_STEPS);
        let mut previous_response_id = session.previous_response_id;
        let mut input = vec![openai_ws::user_message(&request.input)];
        let mut final_text = String::new();
        let mut final_token_usage = None;
        let mut steps = 0;

        let mut hit_step_limit = true;

        for _ in 0..max_steps {
            steps += 1;
            let payload = openai_ws::ResponseCreate {
                model: model.clone(),
                instructions: Some(instructions.clone()),
                previous_response_id: previous_response_id.clone(),
                input,
                tools: ToolRuntime::tool_specs(),
                tool_choice: "auto".to_string(),
                parallel_tool_calls: false,
                store: false,
                stream: true,
                include: if reasoning.is_some() {
                    vec!["reasoning.encrypted_content".to_string()]
                } else {
                    Vec::new()
                },
                reasoning: reasoning.clone(),
                prompt_cache_key: Some(session_id.to_string()),
                client_metadata: Some(json!({
                    "cmux_component": "codex-lite",
                    "cmux_session_id": session_id.to_string()
                })),
            };
            let mut upstream_events = Vec::new();
            let response_result = self
                .openai
                .create_response(payload, |event| {
                    upstream_events.push(event.clone());
                    emit(AgentEvent::Upstream { event });
                })
                .await;
            for event in upstream_events {
                self.session_store
                    .append_event(session_id, &AgentEvent::Upstream { event })
                    .await?;
            }
            let outcome = response_result?;
            let _ = self
                .openai
                .send_response_processed(&outcome.response_id)
                .await;

            previous_response_id = Some(outcome.response_id.clone());
            final_text = outcome.assistant_text.clone();
            final_token_usage = outcome.token_usage.clone();

            let tool_calls = extract_tool_calls(&outcome.output_items);
            if tool_calls.is_empty() {
                hit_step_limit = false;
                break;
            }

            let mut tool_outputs = Vec::with_capacity(tool_calls.len());
            for call in tool_calls {
                self.emit_event(
                    session_id,
                    emit,
                    AgentEvent::ToolStarted {
                        name: call.name.clone(),
                        call_id: call.call_id.clone(),
                    },
                )
                .await?;
                let output_text = self
                    .tools
                    .call(&tool_context, &call.name, &call.arguments)
                    .await;
                let output_json = serde_json::from_str(&output_text).unwrap_or_else(|_| {
                    json!({
                        "status": "ok",
                        "text": output_text
                    })
                });
                self.emit_event(
                    session_id,
                    emit,
                    AgentEvent::ToolCompleted {
                        name: call.name,
                        call_id: call.call_id.clone(),
                        output: output_json,
                    },
                )
                .await?;
                tool_outputs.push(openai_ws::function_call_output(&call.call_id, output_text));
            }
            input = tool_outputs;
        }

        if hit_step_limit {
            return Err(anyhow!("turn exceeded max_steps={max_steps}"));
        }

        self.sessions
            .write()
            .await
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("unknown session `{session_id}`"))?
            .previous_response_id = previous_response_id.clone();

        let result = TurnResult {
            session_id,
            response_id: previous_response_id,
            assistant_text: final_text,
            steps,
            token_usage: final_token_usage,
        };
        self.emit_event(
            session_id,
            emit,
            AgentEvent::TurnCompleted {
                result: result.clone(),
            },
        )
        .await?;
        Ok(result)
    }

    async fn emit_event<F>(&self, session_id: Uuid, emit: &mut F, event: AgentEvent) -> Result<()>
    where
        F: FnMut(AgentEvent) + Send,
    {
        self.session_store.append_event(session_id, &event).await?;
        self.apply_event_to_meta(session_id, &event).await?;
        emit(event);
        Ok(())
    }

    async fn apply_event_to_meta(&self, session_id: Uuid, event: &AgentEvent) -> Result<()> {
        let mut meta = self.session_store.read_meta(session_id).await?;
        meta.updated_at_unix_ms = now_ms();
        match event {
            AgentEvent::UserInput { input, .. } => {
                meta.status = SessionStatus::Running;
                meta.current_tool = None;
                meta.last_handoff_preview = Some(preview(input, 180));
            }
            AgentEvent::TurnStarted { .. } => {
                meta.status = SessionStatus::Running;
                meta.current_tool = None;
            }
            AgentEvent::ToolStarted { name, .. } => {
                meta.status = SessionStatus::Running;
                meta.current_tool = Some(name.clone());
            }
            AgentEvent::ToolCompleted { .. } => {
                meta.current_tool = None;
            }
            AgentEvent::TurnCompleted { result } => {
                meta.status = SessionStatus::Idle;
                meta.previous_response_id = result.response_id.clone();
                meta.current_tool = None;
                meta.last_handoff_preview = Some(preview(&result.assistant_text, 240));
                self.session_store
                    .write_handoff(session_id, &handoff_markdown(&meta, result))
                    .await?;
            }
            AgentEvent::Error { message } => {
                meta.status = SessionStatus::Error;
                meta.current_tool = None;
                meta.last_handoff_preview = Some(preview(message, 240));
            }
            AgentEvent::Upstream { .. } => {}
        }
        self.session_store.write_meta(&meta).await
    }
}

fn handoff_markdown(meta: &SessionMeta, result: &TurnResult) -> String {
    let response_id = result.response_id.as_deref().unwrap_or("none");
    let token_usage = result
        .token_usage
        .as_ref()
        .map(Value::to_string)
        .unwrap_or_else(|| "null".to_string());
    format!(
        "# Handoff\n\nSession: `{}`\nCwd: `{}`\nResponse: `{}`\nSteps: `{}`\nToken usage: `{}`\n\n{}\n",
        meta.session_id,
        meta.cwd.display(),
        response_id,
        result.steps,
        token_usage,
        result.assistant_text
    )
}

fn extract_tool_calls(items: &[Value]) -> Vec<ToolCall> {
    items
        .iter()
        .filter_map(|item| {
            let item_type = item.get("type").and_then(Value::as_str)?;
            if item_type != "function_call" {
                return None;
            }
            let call_id = item
                .get("call_id")
                .and_then(Value::as_str)
                .or_else(|| item.get("id").and_then(Value::as_str))?
                .to_string();
            let name = item.get("name").and_then(Value::as_str)?.to_string();
            let arguments = item
                .get("arguments")
                .and_then(Value::as_str)
                .or_else(|| item.get("input").and_then(Value::as_str))
                .unwrap_or("{}")
                .to_string();
            Some(ToolCall {
                call_id,
                name,
                arguments,
            })
        })
        .collect()
}

fn default_instructions() -> String {
    [
        "You are a lightweight coding agent running inside cmux-codex-lite.",
        "Prefer structured tools over shell syntax. Use exec with argv directly for rg, git, cargo, xcodebuild, and other commands.",
        "Tool output is stored losslessly. Large outputs are returned as blob refs; use search_output or read_output for exact slices.",
        "Make focused edits with apply_patch. Do not print whole large files when a ref or slice is enough.",
    ]
    .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_function_calls_from_response_items() {
        let calls = extract_tool_calls(&[json!({
            "type": "function_call",
            "call_id": "call_1",
            "name": "exec",
            "arguments": "{\"argv\":[\"pwd\"]}"
        })]);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].call_id, "call_1");
        assert_eq!(calls[0].name, "exec");
    }
}
