use serde_json::Value;
use crate::daemon::OpError;
pub trait Rpc: Send { fn call(&mut self, cmd: &str, params: Value) -> Result<Value, OpError>; }
pub fn reply_error(_reply: &Value) -> OpError { todo!("red") }
