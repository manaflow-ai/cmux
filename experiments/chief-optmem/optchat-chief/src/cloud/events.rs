use cmux_conversation::{Change, Message, Summary};
use serde_json::Value;
pub enum CloudSignal { Changed(Change), Resynced { summary: Summary, messages: Vec<Message> }, State { live: bool, state: String, reason: Option<String> }, SessionNeeded(String) }
pub fn map_event(_raw: &Value, _conversation: &str, _chief: &str) -> Option<CloudSignal> { todo!("red") }
