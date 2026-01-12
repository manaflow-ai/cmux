//! Convex HTTP API client for persisting conversations.

use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tracing::{debug, error};

/// Convex HTTP API client for conversation persistence.
#[derive(Clone)]
pub struct ConvexClient {
    http_client: Client,
    convex_url: String,
    admin_key: String,
}

/// Content block types matching ACP ContentBlock.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ContentBlock {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image {
        data: Option<String>,
        #[serde(rename = "mimeType")]
        mime_type: Option<String>,
    },
    #[serde(rename = "resource_link")]
    ResourceLink {
        uri: String,
        name: Option<String>,
        description: Option<String>,
    },
}

/// Tool call status.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolCallStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

/// Tool call tracking.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
    pub status: ToolCallStatus,
    pub result: Option<String>,
}

/// Message role.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    User,
    Assistant,
}

/// Create message request.
#[derive(Debug, Serialize)]
struct CreateMessageRequest {
    #[serde(rename = "conversationId")]
    conversation_id: String,
    role: MessageRole,
    content: Vec<ContentBlock>,
    #[serde(rename = "toolCalls", skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<ToolCall>>,
}

/// Update tool call request.
#[derive(Debug, Serialize)]
struct UpdateToolCallRequest {
    #[serde(rename = "messageId")]
    message_id: String,
    #[serde(rename = "toolCallId")]
    tool_call_id: String,
    status: ToolCallStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<String>,
}

/// Append content request.
#[derive(Debug, Serialize)]
struct AppendContentRequest {
    #[serde(rename = "messageId")]
    message_id: String,
    content: Vec<ContentBlock>,
}

/// Update conversation status request.
#[derive(Debug, Serialize)]
struct UpdateStatusRequest {
    #[serde(rename = "conversationId")]
    conversation_id: String,
    status: String,
    #[serde(rename = "stopReason", skip_serializing_if = "Option::is_none")]
    stop_reason: Option<String>,
}

/// Convex mutation response.
#[derive(Debug, Deserialize)]
struct ConvexMutationResponse {
    status: String,
    value: Option<serde_json::Value>,
    #[serde(rename = "errorMessage")]
    error_message: Option<String>,
}

impl ConvexClient {
    /// Create a new Convex client.
    pub fn new(convex_url: impl Into<String>, admin_key: impl Into<String>) -> Self {
        Self {
            http_client: Client::new(),
            convex_url: convex_url.into(),
            admin_key: admin_key.into(),
        }
    }

    /// Call a Convex mutation via HTTP.
    async fn call_mutation(
        &self,
        function_path: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value> {
        let url = format!("{}/api/mutation", self.convex_url);

        debug!(
            function = %function_path,
            "Calling Convex mutation"
        );

        let response = self
            .http_client
            .post(&url)
            .header("Authorization", format!("Convex {}", self.admin_key))
            .json(&json!({
                "path": function_path,
                "args": args,
            }))
            .send()
            .await
            .context("Failed to send request to Convex")?;

        let status = response.status();
        let body: ConvexMutationResponse = response
            .json()
            .await
            .context("Failed to parse Convex response")?;

        if body.status != "success" {
            let error_msg = body
                .error_message
                .unwrap_or_else(|| format!("Unknown error (status: {})", status));
            error!(
                function = %function_path,
                error = %error_msg,
                "Convex mutation failed"
            );
            anyhow::bail!("Convex mutation failed: {}", error_msg);
        }

        Ok(body.value.unwrap_or(serde_json::Value::Null))
    }

    /// Create a new message in a conversation.
    pub async fn create_message(
        &self,
        conversation_id: &str,
        role: MessageRole,
        content: Vec<ContentBlock>,
        tool_calls: Option<Vec<ToolCall>>,
    ) -> Result<String> {
        let args = serde_json::to_value(CreateMessageRequest {
            conversation_id: conversation_id.to_string(),
            role,
            content,
            tool_calls,
        })?;

        let result = self
            .call_mutation("conversationMessages:create", args)
            .await?;

        // Message ID is returned as a string
        result
            .as_str()
            .map(|s| s.to_string())
            .context("Expected message ID in response")
    }

    /// Append content to an existing message (for streaming).
    pub async fn append_content(&self, message_id: &str, content: Vec<ContentBlock>) -> Result<()> {
        let args = serde_json::to_value(AppendContentRequest {
            message_id: message_id.to_string(),
            content,
        })?;

        self.call_mutation("conversationMessages:appendContent", args)
            .await?;

        Ok(())
    }

    /// Update a tool call status.
    pub async fn update_tool_call(
        &self,
        message_id: &str,
        tool_call_id: &str,
        status: ToolCallStatus,
        result: Option<String>,
    ) -> Result<()> {
        let args = serde_json::to_value(UpdateToolCallRequest {
            message_id: message_id.to_string(),
            tool_call_id: tool_call_id.to_string(),
            status,
            result,
        })?;

        self.call_mutation("conversationMessages:updateToolCall", args)
            .await?;

        Ok(())
    }

    /// Update conversation status.
    pub async fn update_conversation_status(
        &self,
        conversation_id: &str,
        status: &str,
        stop_reason: Option<&str>,
    ) -> Result<()> {
        let args = serde_json::to_value(UpdateStatusRequest {
            conversation_id: conversation_id.to_string(),
            status: status.to_string(),
            stop_reason: stop_reason.map(|s| s.to_string()),
        })?;

        self.call_mutation("conversations:updateStatus", args)
            .await?;

        Ok(())
    }

    /// Update conversation agent info.
    pub async fn update_agent_info(
        &self,
        conversation_id: &str,
        name: &str,
        version: &str,
        title: Option<&str>,
    ) -> Result<()> {
        let args = json!({
            "conversationId": conversation_id,
            "agentInfo": {
                "name": name,
                "version": version,
                "title": title,
            }
        });

        self.call_mutation("conversations:updateAgentInfo", args)
            .await?;

        Ok(())
    }

    /// Update conversation modes.
    pub async fn update_modes(
        &self,
        conversation_id: &str,
        current_mode_id: &str,
        available_modes: Vec<(String, String, Option<String>)>,
    ) -> Result<()> {
        let modes: Vec<serde_json::Value> = available_modes
            .into_iter()
            .map(|(id, name, description)| {
                json!({
                    "id": id,
                    "name": name,
                    "description": description,
                })
            })
            .collect();

        let args = json!({
            "conversationId": conversation_id,
            "modes": {
                "currentModeId": current_mode_id,
                "availableModes": modes,
            }
        });

        self.call_mutation("conversations:updateModes", args)
            .await?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_content_block_serialization() {
        let block = ContentBlock::Text {
            text: "Hello".to_string(),
        };
        let json = serde_json::to_string(&block).expect("Serialization failed");
        assert!(json.contains("\"type\":\"text\""));
        assert!(json.contains("\"text\":\"Hello\""));
    }

    #[test]
    fn test_message_role_serialization() {
        let role = MessageRole::User;
        let json = serde_json::to_string(&role).expect("Serialization failed");
        assert_eq!(json, "\"user\"");

        let role = MessageRole::Assistant;
        let json = serde_json::to_string(&role).expect("Serialization failed");
        assert_eq!(json, "\"assistant\"");
    }
}
