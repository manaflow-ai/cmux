use cmux_conversation::{Change, Message, Op, Summary};
use crate::daemon::{ConversationPort, OpError};
use super::wire::Rpc;
pub const SNAPSHOT_TAIL: u32 = 50;
pub const HISTORY_LIMIT: u32 = 200;
pub struct CloudPort<R: Rpc> { _rpc: R, _chief: String }
impl<R: Rpc> CloudPort<R> { pub fn new(rpc: R, chief: String) -> Self { CloudPort { _rpc: rpc, _chief: chief } } }
impl<R: Rpc> ConversationPort for CloudPort<R> {
    fn snapshot(&mut self, _c: &str, _t: u32) -> Result<(Summary, Vec<Message>), OpError> { todo!("red") }
    fn history(&mut self, _c: &str, _b: u64, _l: u32) -> Result<Vec<Message>, OpError> { todo!("red") }
    fn op(&mut self, _c: &str, _k: &str, _o: &Op) -> Result<Option<Change>, OpError> { todo!("red") }
    fn typing(&mut self, _c: &str, _on: bool) -> Result<(), OpError> { todo!("red") }
}
