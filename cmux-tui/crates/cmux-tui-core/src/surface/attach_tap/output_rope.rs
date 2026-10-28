//! A slow viewer's queued output: adjacent chunks merged without copying the
//! chunks other viewers share.

use super::{AttachFrame, AttachFrameMerge};
use bytes::Bytes;
use std::mem::size_of;

/// Output chunks at most this long merge by copy; longer ones merge by
/// handle. Mojo's BigBuffer splits the same way: inline up to
/// `kMaxInlineBytes`, shared above it (mojo/public/cpp/base/big_buffer.h).
pub(in crate::surface) const OUTPUT_ROPE_COPY_MAX_BYTES: usize = 4 * 1024;

/// One piece of an [`OutputRope`] after its head.
#[derive(Debug)]
enum RopePart {
    /// A chunk other viewers may hold too.
    Shared(Bytes),
    /// Small adjacent chunks copied together, so a flood of short reads costs
    /// its bytes and not a handle per read.
    Copied(Vec<u8>),
}

impl RopePart {
    fn bytes(&self) -> &[u8] {
        match self {
            Self::Shared(bytes) => bytes,
            Self::Copied(bytes) => bytes,
        }
    }

    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Shared(bytes) => bytes.len(),
                Self::Copied(bytes) => bytes.capacity(),
            }
    }
}

/// Output a viewer has not taken yet, in stream order. The reader merges a
/// chunk into it under the terminal lock without copying a shared chunk; the
/// viewer joins the pieces on its own thread when it takes them.
#[derive(Debug)]
pub(in crate::surface) struct OutputRope {
    head: Bytes,
    rest: Vec<RopePart>,
    /// Bytes after `head`.
    rest_len: usize,
    /// [`RopePart::retained_bytes`] summed over `rest`.
    rest_retained: usize,
    /// The key press the run echoes (0: none).
    flow: u64,
}

impl OutputRope {
    pub(in crate::surface) fn new(head: Bytes, flow: u64) -> Self {
        Self { head, rest: Vec::new(), rest_len: 0, rest_retained: 0, flow }
    }

    pub(in crate::surface) fn len(&self) -> usize {
        self.head.len() + self.rest_len
    }

    /// Pieces the viewer joins when it takes the run (1: no join).
    #[cfg(test)]
    pub(in crate::surface) fn pieces(&self) -> usize {
        1 + self.rest.len()
    }

    /// The viewer's backlog cost. An unmerged chunk counts exactly as the
    /// same [`AttachFrame`]; each merged piece adds its bytes (a copied piece
    /// its capacity) and its own size. Every viewer counts a shared chunk in
    /// full, so a stuck viewer stays bounded by its own budget.
    pub(in crate::surface) fn retained_bytes(&self) -> usize {
        size_of::<AttachFrame>() + self.head.len() + self.rest_retained
    }

    /// Append `next` when it is plain output of a compatible flow and the
    /// merged run fits `max_retained_bytes`. Each key press keeps its own
    /// output event: the echoes of two flows never merge into one.
    pub(in crate::surface) fn merge(
        &mut self,
        next: AttachFrame,
        max_retained_bytes: usize,
    ) -> AttachFrameMerge {
        let (next, next_flow) = match next {
            AttachFrame::Output(next) => (next, 0),
            AttachFrame::FlowOutput { output, flow } => (output, flow),
            other => return AttachFrameMerge::Unmerged(other),
        };
        if self.flow != 0 && next_flow != 0 {
            return AttachFrameMerge::Unmerged(AttachFrame::with_flow(next, next_flow));
        }
        let appended = if next.len() <= OUTPUT_ROPE_COPY_MAX_BYTES {
            self.append_copied(&next, max_retained_bytes)
        } else {
            self.append_shared(next, max_retained_bytes)
        };
        if !appended {
            return AttachFrameMerge::Overflow;
        }
        if self.flow == 0 {
            self.flow = next_flow;
        }
        AttachFrameMerge::Merged
    }

    fn append_shared(&mut self, next: Bytes, max_retained_bytes: usize) -> bool {
        let part = RopePart::Shared(next);
        let cost = part.retained_bytes();
        let fits = self
            .retained_bytes()
            .checked_add(cost)
            .is_some_and(|required| required <= max_retained_bytes);
        if !fits || self.rest.try_reserve(1).is_err() {
            return false;
        }
        self.push(part);
        true
    }

    /// Copy `next` into the last copied piece, growing it the way a `Vec`
    /// grows but never past the budget, or start a copied piece.
    fn append_copied(&mut self, next: &[u8], max_retained_bytes: usize) -> bool {
        let others = self.retained_bytes();
        if let Some(RopePart::Copied(last)) = self.rest.last_mut() {
            let capacity = last.capacity();
            // The run's cost without the last piece's buffer.
            let Some(max_capacity) = max_retained_bytes.checked_sub(others - capacity) else {
                return false;
            };
            let Some(required) = last.len().checked_add(next.len()) else { return false };
            if required > max_capacity {
                return false;
            }
            if required > capacity {
                let desired = capacity.saturating_mul(2).max(required).min(max_capacity);
                if last.try_reserve_exact(desired - last.len()).is_err()
                    || last.capacity() > max_capacity
                {
                    return false;
                }
            }
            last.extend_from_slice(next);
            self.rest_retained = self.rest_retained - capacity + last.capacity();
            self.rest_len += next.len();
            return true;
        }
        let Some(max_capacity) = others
            .checked_add(size_of::<RopePart>())
            .and_then(|fixed| max_retained_bytes.checked_sub(fixed))
        else {
            return false;
        };
        if next.len() > max_capacity {
            return false;
        }
        let desired = next.len().max(OUTPUT_ROPE_COPY_MAX_BYTES).min(max_capacity);
        let mut copied = Vec::new();
        if copied.try_reserve_exact(desired).is_err()
            || copied.capacity() > max_capacity
            || self.rest.try_reserve(1).is_err()
        {
            return false;
        }
        copied.extend_from_slice(next);
        self.push(RopePart::Copied(copied));
        true
    }

    fn push(&mut self, part: RopePart) {
        self.rest_len += part.bytes().len();
        self.rest_retained += part.retained_bytes();
        self.rest.push(part);
    }

    /// The run as one frame. An unmerged chunk is handed over as is; a merged
    /// run is joined into one buffer, the only copy a slow viewer costs.
    pub(in crate::surface) fn into_frame(self) -> AttachFrame {
        if self.rest.is_empty() {
            return AttachFrame::with_flow(self.head, self.flow);
        }
        let mut joined = Vec::with_capacity(self.len());
        joined.extend_from_slice(&self.head);
        for part in &self.rest {
            joined.extend_from_slice(part.bytes());
        }
        AttachFrame::with_flow(Bytes::from(joined), self.flow)
    }
}
