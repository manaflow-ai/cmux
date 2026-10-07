//! Placeholder (red commit).

use cmux_rd_proto::BulkFrame;

pub const INITIAL_CREDIT: u64 = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BulkCredit {
    pub transfer: u64,
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BulkError {
    Duplicate(u64),
    OutOfOrder { transfer: u64, expected: u64, got: u64 },
    Finished(u64),
}

#[derive(Debug)]
pub struct Accepted {
    pub bytes: Vec<u8>,
    pub credit: Option<BulkCredit>,
}

#[derive(Debug, Default)]
pub struct BulkSender;

impl BulkSender {
    pub fn new(_interval_us: u64) -> Self {
        Self
    }
    pub fn queue(&mut self, _transfer: u64, _data: Vec<u8>) -> Result<(), BulkError> {
        Ok(())
    }
    pub fn on_credit(&mut self, _transfer: u64, _offset: u64) {}
    pub fn next_frame(&mut self, _now_us: u64, _media_waiting: bool) -> Option<BulkFrame> {
        None
    }
    pub fn next_deadline_us(&self) -> Option<u64> {
        None
    }
    pub fn is_idle(&self) -> bool {
        true
    }
}

#[derive(Debug, Default)]
pub struct BulkReceiver;

impl BulkReceiver {
    pub fn new() -> Self {
        Self
    }
    pub fn accept(&mut self, _frame: &BulkFrame) -> Result<Accepted, BulkError> {
        Err(BulkError::Finished(0))
    }
    pub fn finish(&mut self, _transfer: u64) {}
}
