use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use futures_util::SinkExt;
use futures_util::StreamExt;
use http::HeaderValue;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio_tungstenite::MaybeTlsStream;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct ResponsesWsConfig {
    pub base_url: String,
    pub api_key: String,
    pub organization: Option<String>,
    pub project: Option<String>,
    pub openai_beta: Option<String>,
    pub idle_timeout: Duration,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseCreate {
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_response_id: Option<String>,
    pub input: Vec<Value>,
    pub tools: Vec<Value>,
    pub tool_choice: String,
    pub parallel_tool_calls: bool,
    pub store: bool,
    pub stream: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub include: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_cache_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_metadata: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
enum ClientFrame {
    #[serde(rename = "response.create")]
    ResponseCreate {
        #[serde(flatten)]
        payload: Box<ResponseCreate>,
    },
    #[serde(rename = "response.processed")]
    ResponseProcessed { response_id: String },
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentStreamEvent {
    UpstreamConnected,
    UpstreamFrame {
        event_type: String,
    },
    AssistantDelta {
        delta: String,
    },
    OutputItemDone {
        item: Value,
    },
    Completed {
        response_id: String,
        token_usage: Option<Value>,
    },
}

#[derive(Debug, Clone)]
pub struct ResponseOutcome {
    pub response_id: String,
    pub assistant_text: String,
    pub output_items: Vec<Value>,
    pub token_usage: Option<Value>,
}

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[derive(Debug)]
pub struct ResponsesWsClient {
    config: ResponsesWsConfig,
    websocket_url: String,
    socket: Mutex<Option<Ws>>,
}

impl ResponsesWsClient {
    pub fn new(config: ResponsesWsConfig) -> Result<Self> {
        if config.api_key.trim().is_empty() {
            return Err(anyhow!("OPENAI_API_KEY is required"));
        }
        let websocket_url = responses_websocket_url(&config.base_url)?;
        Ok(Self {
            config,
            websocket_url,
            socket: Mutex::new(None),
        })
    }

    pub async fn create_response<F>(
        &self,
        payload: ResponseCreate,
        mut on_event: F,
    ) -> Result<ResponseOutcome>
    where
        F: FnMut(AgentStreamEvent) + Send,
    {
        let mut guard = self.socket.lock().await;
        if guard.is_none() {
            *guard = Some(self.connect().await?);
            on_event(AgentStreamEvent::UpstreamConnected);
        }

        let request = ClientFrame::ResponseCreate {
            payload: Box::new(payload),
        };
        let request_text = serde_json::to_string(&request)?;
        let Some(socket) = guard.as_mut() else {
            return Err(anyhow!("websocket unavailable after connect"));
        };

        if let Err(err) = socket.send(Message::Text(request_text.into())).await {
            *guard = None;
            return Err(anyhow!("failed to send response.create: {err}"));
        }

        let mut assistant_text = String::new();
        let mut output_items = Vec::new();
        let (completed_response_id, token_usage) = loop {
            let message = match tokio::time::timeout(self.config.idle_timeout, socket.next()).await
            {
                Ok(Some(Ok(message))) => message,
                Ok(Some(Err(err))) => {
                    *guard = None;
                    return Err(anyhow!("websocket read failed: {err}"));
                }
                Ok(None) => {
                    *guard = None;
                    return Err(anyhow!("websocket closed before response.completed"));
                }
                Err(_) => {
                    *guard = None;
                    return Err(anyhow!("idle timeout waiting for websocket event"));
                }
            };

            match message {
                Message::Text(text) => {
                    let value: Value = match serde_json::from_str(&text) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if let Some(err) = response_error(&value) {
                        return Err(anyhow!(err));
                    }

                    let event_type = value
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_string();
                    on_event(AgentStreamEvent::UpstreamFrame {
                        event_type: event_type.clone(),
                    });

                    match event_type.as_str() {
                        "response.output_text.delta" => {
                            if let Some(delta) = value.get("delta").and_then(Value::as_str) {
                                assistant_text.push_str(delta);
                                on_event(AgentStreamEvent::AssistantDelta {
                                    delta: delta.to_string(),
                                });
                            }
                        }
                        "response.output_item.done" => {
                            if let Some(item) = value.get("item").cloned() {
                                if let Some(text) = message_item_text(&item)
                                    && assistant_text.is_empty()
                                {
                                    assistant_text.push_str(&text);
                                }
                                output_items.push(item.clone());
                                on_event(AgentStreamEvent::OutputItemDone { item });
                            }
                        }
                        "response.completed" => {
                            let response = value.get("response").cloned().unwrap_or(Value::Null);
                            let response_id = response
                                .get("id")
                                .and_then(Value::as_str)
                                .map(ToString::to_string)
                                .or_else(|| {
                                    value
                                        .get("response_id")
                                        .and_then(Value::as_str)
                                        .map(ToString::to_string)
                                })
                                .unwrap_or_else(|| {
                                    format!("local-missing-response-id-{}", Uuid::new_v4())
                                });
                            let token_usage = response.get("usage").cloned();
                            on_event(AgentStreamEvent::Completed {
                                response_id: response_id.clone(),
                                token_usage: token_usage.clone(),
                            });
                            break (response_id, token_usage);
                        }
                        _ => {}
                    }
                }
                Message::Ping(payload) => {
                    if let Err(err) = socket.send(Message::Pong(payload)).await {
                        *guard = None;
                        return Err(anyhow!("failed to send websocket pong: {err}"));
                    }
                }
                Message::Close(frame) => {
                    *guard = None;
                    return Err(anyhow!(
                        "websocket closed by server before completion: {frame:?}"
                    ));
                }
                Message::Binary(_) => return Err(anyhow!("unexpected binary websocket frame")),
                Message::Pong(_) | Message::Frame(_) => {}
            }
        };

        Ok(ResponseOutcome {
            response_id: completed_response_id,
            assistant_text,
            output_items,
            token_usage,
        })
    }

    pub async fn send_response_processed(&self, response_id: &str) -> Result<()> {
        let mut guard = self.socket.lock().await;
        let Some(socket) = guard.as_mut() else {
            return Ok(());
        };
        let frame = ClientFrame::ResponseProcessed {
            response_id: response_id.to_string(),
        };
        let text = serde_json::to_string(&frame)?;
        if let Err(err) = socket.send(Message::Text(text.into())).await {
            *guard = None;
            return Err(anyhow!("failed to send response.processed: {err}"));
        }
        Ok(())
    }

    async fn connect(&self) -> Result<Ws> {
        let mut request = self
            .websocket_url
            .as_str()
            .into_client_request()
            .context("building websocket request")?;
        let headers = request.headers_mut();
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {}", self.config.api_key))
                .context("building authorization header")?,
        );
        if let Some(value) = &self.config.organization {
            headers.insert(
                "OpenAI-Organization",
                HeaderValue::from_str(value).context("building OpenAI-Organization header")?,
            );
        }
        if let Some(value) = &self.config.project {
            headers.insert(
                "OpenAI-Project",
                HeaderValue::from_str(value).context("building OpenAI-Project header")?,
            );
        }
        if let Some(value) = &self.config.openai_beta {
            headers.insert(
                "OpenAI-Beta",
                HeaderValue::from_str(value).context("building OpenAI-Beta header")?,
            );
        }

        let (socket, _response) =
            tokio::time::timeout(self.config.idle_timeout, connect_async(request))
                .await
                .context("timed out connecting to OpenAI Responses WebSocket")?
                .context("connecting to OpenAI Responses WebSocket")?;
        Ok(socket)
    }
}

fn responses_websocket_url(base_url: &str) -> Result<String> {
    let base = base_url.trim_end_matches('/');
    let with_path = if base.ends_with("/responses") {
        base.to_string()
    } else {
        format!("{base}/responses")
    };
    if let Some(rest) = with_path.strip_prefix("https://") {
        Ok(format!("wss://{rest}"))
    } else if let Some(rest) = with_path.strip_prefix("http://") {
        Ok(format!("ws://{rest}"))
    } else if with_path.starts_with("ws://") || with_path.starts_with("wss://") {
        Ok(with_path)
    } else {
        Err(anyhow!("unsupported base URL scheme: {base_url}"))
    }
}

fn response_error(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("error") {
        return None;
    }
    let message = value
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .or_else(|| value.get("message").and_then(Value::as_str))
        .unwrap_or("OpenAI websocket error");
    Some(message.to_string())
}

fn message_item_text(item: &Value) -> Option<String> {
    if item.get("type").and_then(Value::as_str) != Some("message") {
        return None;
    }
    let content = item.get("content")?.as_array()?;
    let mut out = String::new();
    for part in content {
        if let Some(text) = part
            .get("text")
            .and_then(Value::as_str)
            .or_else(|| part.get("output_text").and_then(Value::as_str))
        {
            out.push_str(text);
        }
    }
    (!out.is_empty()).then_some(out)
}

pub fn user_message(text: &str) -> Value {
    json!({
        "type": "message",
        "role": "user",
        "content": [{"type": "input_text", "text": text}]
    })
}

pub fn function_call_output(call_id: &str, output: String) -> Value {
    json!({
        "type": "function_call_output",
        "call_id": call_id,
        "output": output
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn websocket_url_rewrites_https_responses() {
        assert_eq!(
            responses_websocket_url("https://api.openai.com/v1").unwrap(),
            "wss://api.openai.com/v1/responses"
        );
        assert_eq!(
            responses_websocket_url("https://chatgpt.com/backend-api/codex/responses").unwrap(),
            "wss://chatgpt.com/backend-api/codex/responses"
        );
    }
}
