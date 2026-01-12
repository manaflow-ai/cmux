//! Wrapped Agent implementation for ACP server.
//!
//! This module manages CLI spawning and Convex persistence for ACP conversations.
//! The actual ACP protocol handling is done by forwarding raw JSON-RPC messages
//! between the iOS client and the underlying CLI.

use std::sync::Arc;

use agent_client_protocol::{ClientSideConnection, ContentBlock};
use anyhow::Result;
use tokio::sync::Mutex;
use tracing::{debug, info};

use super::persistence::{ContentBlock as PersistContentBlock, ConvexClient, MessageRole};
use super::spawner::{AcpProvider, CliSpawner, IsolationMode, SpawnedCli};

/// Wrapper around a CLI ACP connection that persists to Convex.
pub struct WrappedAgent {
    /// Connection to the underlying CLI (claude-code-acp, codex-acp, etc.)
    cli_connection: Arc<Mutex<Option<Arc<ClientSideConnection>>>>,
    /// Convex client for persistence
    convex_client: ConvexClient,
    /// Conversation ID from JWT
    conversation_id: String,
    /// Provider type
    provider: AcpProvider,
    /// Isolation mode
    isolation: IsolationMode,
    /// Working directory
    cwd: std::path::PathBuf,
    /// Environment variables to pass to CLI
    env_vars: Vec<(String, String)>,
    /// Spawned CLI handle
    spawned_cli: Arc<Mutex<Option<SpawnedCli>>>,
    /// Current message ID for streaming
    current_message_id: Arc<Mutex<Option<String>>>,
}

impl WrappedAgent {
    /// Create a new wrapped agent.
    pub fn new(
        convex_client: ConvexClient,
        conversation_id: String,
        provider: AcpProvider,
        isolation: IsolationMode,
        cwd: std::path::PathBuf,
        env_vars: Vec<(String, String)>,
    ) -> Self {
        Self {
            cli_connection: Arc::new(Mutex::new(None)),
            convex_client,
            conversation_id,
            provider,
            isolation,
            cwd,
            env_vars,
            spawned_cli: Arc::new(Mutex::new(None)),
            current_message_id: Arc::new(Mutex::new(None)),
        }
    }

    /// Get the conversation ID.
    pub fn conversation_id(&self) -> &str {
        &self.conversation_id
    }

    /// Get the provider.
    pub fn provider(&self) -> AcpProvider {
        self.provider
    }

    /// Spawn and connect to the underlying CLI.
    pub async fn connect(&self) -> Result<()> {
        let spawner = CliSpawner::new(self.provider, self.cwd.clone(), self.isolation.clone());

        // Add environment variables
        let mut spawner = spawner;
        for (key, value) in &self.env_vars {
            spawner = spawner.with_env(key, value);
        }

        info!(
            provider = %self.provider.display_name(),
            conversation_id = %self.conversation_id,
            "Spawning CLI process"
        );

        let cli = spawner.spawn().await?;

        // Store the spawned CLI
        {
            let mut spawned = self.spawned_cli.lock().await;
            *spawned = Some(cli);
        }

        // TODO: Create ClientSideConnection to the spawned CLI
        // This requires setting up the I/O adapters similar to how
        // the existing acp_client does it with WebSocket

        Ok(())
    }

    /// Convert ACP ContentBlock to persistence ContentBlock.
    fn convert_content_block(block: &ContentBlock) -> PersistContentBlock {
        match block {
            ContentBlock::Text(text) => PersistContentBlock::Text {
                text: text.text.clone(),
            },
            // For other content types, convert to a placeholder
            // TODO: Add proper handling for Image, Audio, ResourceLink, etc.
            _ => PersistContentBlock::Text {
                text: "[Unsupported content type]".to_string(),
            },
        }
    }

    /// Persist user message to Convex.
    pub async fn persist_user_message(&self, content: &[ContentBlock]) -> Result<String> {
        let persist_content: Vec<PersistContentBlock> =
            content.iter().map(Self::convert_content_block).collect();

        let message_id = self
            .convex_client
            .create_message(
                &self.conversation_id,
                MessageRole::User,
                persist_content,
                None,
            )
            .await?;

        debug!(
            message_id = %message_id,
            "Persisted user message"
        );

        Ok(message_id)
    }

    /// Persist text-only user message to Convex.
    pub async fn persist_user_text(&self, text: &str) -> Result<String> {
        let persist_content = vec![PersistContentBlock::Text {
            text: text.to_string(),
        }];

        let message_id = self
            .convex_client
            .create_message(
                &self.conversation_id,
                MessageRole::User,
                persist_content,
                None,
            )
            .await?;

        debug!(
            message_id = %message_id,
            "Persisted user text message"
        );

        Ok(message_id)
    }

    /// Start a new assistant message for streaming.
    pub async fn start_assistant_message(&self) -> Result<String> {
        let message_id = self
            .convex_client
            .create_message(&self.conversation_id, MessageRole::Assistant, vec![], None)
            .await?;

        // Store current message ID for streaming updates
        let mut current_id = self.current_message_id.lock().await;
        *current_id = Some(message_id.clone());

        debug!(
            message_id = %message_id,
            "Started assistant message"
        );

        Ok(message_id)
    }

    /// Append text content to current assistant message.
    pub async fn append_assistant_text(&self, text: &str) -> Result<()> {
        let current_id = self.current_message_id.lock().await;
        let message_id = current_id
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No current message ID"))?;

        let persist_content = vec![PersistContentBlock::Text {
            text: text.to_string(),
        }];

        self.convex_client
            .append_content(message_id, persist_content)
            .await?;

        Ok(())
    }

    /// Append content to current assistant message.
    pub async fn append_assistant_content(&self, content: &[ContentBlock]) -> Result<()> {
        let current_id = self.current_message_id.lock().await;
        let message_id = current_id
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No current message ID"))?;

        let persist_content: Vec<PersistContentBlock> =
            content.iter().map(Self::convert_content_block).collect();

        self.convex_client
            .append_content(message_id, persist_content)
            .await?;

        Ok(())
    }

    /// Update agent info in Convex.
    pub async fn update_agent_info(&self, name: &str, version: &str) -> Result<()> {
        self.convex_client
            .update_agent_info(&self.conversation_id, name, version, None)
            .await
    }

    /// Update conversation status in Convex.
    pub async fn update_status(&self, status: &str, stop_reason: Option<&str>) -> Result<()> {
        self.convex_client
            .update_conversation_status(&self.conversation_id, status, stop_reason)
            .await
    }

    /// Get the underlying CLI connection if available.
    pub async fn get_cli_connection(&self) -> Option<Arc<ClientSideConnection>> {
        let conn = self.cli_connection.lock().await;
        conn.clone()
    }

    /// Get stdin/stdout handles for the spawned CLI.
    /// Returns None if CLI hasn't been spawned yet or handles already taken.
    pub async fn take_cli_io(
        &self,
    ) -> Option<(tokio::process::ChildStdin, tokio::process::ChildStdout)> {
        let mut spawned = self.spawned_cli.lock().await;
        if let Some(cli) = spawned.as_mut() {
            // Take stdin/stdout out of the SpawnedCli
            // Note: This consumes the handles, they can only be taken once
            let stdin = cli.stdin.take()?;
            let stdout = cli.stdout.take()?;
            Some((stdin, stdout))
        } else {
            None
        }
    }
}
