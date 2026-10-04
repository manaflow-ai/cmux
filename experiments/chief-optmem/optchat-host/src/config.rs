use std::fmt;
use std::time::Duration;

use optchat_core::{CompactPrompt, VIEW};

use crate::report::{stderr_reporter, Reporter};
use crate::RETRY;

/// The team subrouter, which speaks the Anthropic Messages API and ignores the key.
pub const DEFAULT_BASE_URL: &str = "http://cmux-lawrences-mac-mini:31415";
/// Environment variable that overrides `DEFAULT_BASE_URL`.
pub const BASE_URL_ENV: &str = "OPTCHAT_ANTHROPIC_BASE_URL";
/// The compactor model: cheap but competent (section 4.2 uses Sonnet).
pub const DEFAULT_MODEL: &str = "claude-sonnet-5-5";

/// How one chat runs. Fixed for the life of the process: the compactor's
/// system prompt heads every cached prefix, so it must not change per call.
#[derive(Clone)]
pub struct Config {
    /// The agent's name in the compactor prompt.
    pub agent: String,
    /// Which compactor prompt (default Taelin's).
    pub prompt: CompactPrompt,
    /// Compactor model id.
    pub model: String,
    /// `output_config.effort`; the spec runs the compactor at medium, since
    /// low effort overshot the size limit much more (section 4.2).
    pub effort: Option<String>,
    /// Base URL of the Messages API (`/v1/messages` is appended).
    pub base_url: String,
    /// Output cap per compactor call; thinking tokens count against it.
    pub max_tokens: u32,
    /// Wall-clock cap on one HTTP call, so a stalled connection cannot hold
    /// a compactor slot forever (it fails and is retried).
    pub http_timeout: Duration,
    /// The view's byte budget.
    pub budget: usize,
    /// Wait before retrying a failed node.
    pub retry: Duration,
    pub reporter: Reporter,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            agent: "OptChat".to_string(),
            prompt: CompactPrompt::Taelin,
            model: DEFAULT_MODEL.to_string(),
            effort: Some("medium".to_string()),
            base_url: std::env::var(BASE_URL_ENV)
                .ok()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| DEFAULT_BASE_URL.to_string()),
            max_tokens: 16_000,
            http_timeout: Duration::from_secs(600),
            budget: VIEW,
            retry: RETRY,
            reporter: stderr_reporter(),
        }
    }
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("agent", &self.agent)
            .field("prompt", &self.prompt.name())
            .field("model", &self.model)
            .field("effort", &self.effort)
            .field("base_url", &self.base_url)
            .field("max_tokens", &self.max_tokens)
            .field("http_timeout", &self.http_timeout)
            .field("budget", &self.budget)
            .field("retry", &self.retry)
            .finish_non_exhaustive()
    }
}
