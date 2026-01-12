//! ACP Server module for iOS app integration.
//!
//! This module implements the Agent side of the Agent Client Protocol (ACP),
//! allowing iOS clients to connect and interact with coding CLIs (Claude Code,
//! Codex, Gemini, OpenCode) via WebSocket.
//!
//! Architecture:
//! - iOS App → WebSocket → ACP Server → CLI Spawner → Coding CLI
//! - Conversations are persisted to Convex via HTTP API
//! - Supports multiple isolation modes via bubblewrap namespaces

mod agent;
mod persistence;
mod spawner;
mod websocket;

pub use agent::WrappedAgent;
pub use persistence::ConvexClient;
pub use spawner::{CliSpawner, IsolationMode};
pub use websocket::{acp_websocket_handler, AcpServerState, ApiKeys};
