//! Scroll-offset writer handoff of the split compositor (r9;
//! remote-tab-protocol.md section 5.3, vectors
//! `schemas/remote-tab/scroll-writer.json`).
//!
//! One writer per scroller at a time: the client while a user gesture runs,
//! the server otherwise. The handover is an explicit message in both
//! directions, so the two ends never write the same offset at once.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Writer {
    Server,
    Client { gesture: u32 },
}

/// Host state of one scroller (offsets on one axis, CSS px).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scroller {
    pub writer: Writer,
    pub offset: f64,
    pub max: f64,
    /// A programmatic offset deferred while the client writes.
    pub pending: Option<f64>,
    /// Sequence number of the last `rb.scroll.offset` the host sent.
    pub seq: u32,
}

impl Scroller {
    pub fn new(offset: f64, max: f64) -> Self {
        let max = max.max(0.0);
        Self { writer: Writer::Server, offset: offset.clamp(0.0, max), max, pending: None, seq: 0 }
    }

    fn clamp(&self, offset: f64) -> f64 {
        offset.clamp(0.0, self.max)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ScrollInput {
    Claim { gesture: u32 },
    Update { gesture: u32, offset: f64 },
    Release { gesture: u32, offset: f64 },
    Programmatic { offset: f64 },
    Extent { max: f64 },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum ScrollEffect {
    /// Set the offset in the page (Blink fires scroll events).
    ApplyToPage { offset: f64 },
    /// Send `rb.scroll.offset` to the client.
    SendOffset { offset: f64, seq: u32 },
    /// Tell the writing client the new scroll extent.
    SendExtent { max: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollReject {
    NotWriter,
}

impl Scroller {
    /// Applies one input. On a reject the state is unchanged.
    pub fn apply(&mut self, input: ScrollInput) -> Result<Vec<ScrollEffect>, ScrollReject> {
        let effects = Vec::new();
        let _ = input;
        Ok(effects)
    }

    fn require_writer(&self, gesture: u32) -> Result<(), ScrollReject> {
        if self.writer == (Writer::Client { gesture }) { Ok(()) } else { Err(ScrollReject::NotWriter) }
    }
}
