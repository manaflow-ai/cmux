//! Deferred input: the bounded queue of input that waits behind an ordered
//! session mutation, its admission accounting, and the replay outcome types.

use std::collections::VecDeque;

use cmux_tui_core::SurfaceId;
use crossterm::event::MouseEvent;
use ghostty_vt::{CursorShape, Rgb};

use crate::app::RenderAction;
use crate::app::host_input::TerminalInput;
use crate::app::pointer::route::PointerRouteIdentity;

#[derive(Clone, Debug, PartialEq)]
pub(in crate::app) struct DeferredPointerInput {
    pub(in crate::app) focus_generation: u64,
    pub(in crate::app) pointer_map_generation: u64,
    pub(in crate::app) route: Option<PointerRouteIdentity>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::app) enum OuterCursorSpec {
    Reset,
    Terminal { color: Rgb, shape: CursorShape, blinking: bool },
}

#[derive(Clone)]
pub(in crate::app) struct DeferredInput {
    pub(in crate::app) event: TerminalInput,
    pub(in crate::app) admission: DeferredInputAdmission,
    pub(in crate::app) pointer: Option<DeferredPointerInput>,
    pub(in crate::app) sequence: u64,
}

#[derive(Default)]
pub(in crate::app) struct DeferredInputQueue {
    pub(in crate::app) inputs: VecDeque<DeferredInput>,
    pub(in crate::app) retained_bytes: usize,
}

impl DeferredInputQueue {
    pub(in crate::app) fn is_empty(&self) -> bool {
        self.inputs.is_empty()
    }

    pub(in crate::app) fn len(&self) -> usize {
        self.inputs.len()
    }

    pub(in crate::app) fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }

    pub(in crate::app) fn iter(&self) -> impl Iterator<Item = &DeferredInput> {
        self.inputs.iter()
    }

    pub(in crate::app) fn front(&self) -> Option<&DeferredInput> {
        self.inputs.front()
    }

    pub(in crate::app) fn back(&self) -> Option<&DeferredInput> {
        self.inputs.back()
    }

    #[cfg(test)]
    pub(in crate::app) fn get(&self, index: usize) -> Option<&DeferredInput> {
        self.inputs.get(index)
    }

    pub(in crate::app) fn push_back(&mut self, input: DeferredInput) {
        self.retained_bytes = self.retained_bytes.saturating_add(input.event.retained_bytes());
        self.inputs.push_back(input);
    }

    pub(in crate::app) fn pop_front(&mut self) -> Option<DeferredInput> {
        let input = self.inputs.pop_front()?;
        self.retained_bytes = self.retained_bytes.saturating_sub(input.event.retained_bytes());
        Some(input)
    }

    pub(in crate::app) fn insert(&mut self, index: usize, input: DeferredInput) {
        self.retained_bytes = self.retained_bytes.saturating_add(input.event.retained_bytes());
        self.inputs.insert(index, input);
    }

    pub(in crate::app) fn replace_back(&mut self, input: DeferredInput) {
        let previous_bytes = self
            .inputs
            .back()
            .expect("replace_back requires an existing input")
            .event
            .retained_bytes();
        self.retained_bytes = self
            .retained_bytes
            .saturating_sub(previous_bytes)
            .saturating_add(input.event.retained_bytes());
        *self.inputs.back_mut().unwrap() = input;
    }

    pub(in crate::app) fn clear(&mut self) {
        self.inputs.clear();
        self.retained_bytes = 0;
    }

    pub(in crate::app) fn retain(&mut self, mut keep: impl FnMut(&DeferredInput) -> bool) {
        self.inputs.retain(|input| keep(input));
        self.retained_bytes = self.inputs.iter().map(|input| input.event.retained_bytes()).sum();
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) struct DeferredInputAdmission {
    pub(in crate::app) destination: Option<SurfaceId>,
    pub(in crate::app) destination_intent: Option<u64>,
    pub(in crate::app) semantic_dependency: Option<u64>,
    pub(in crate::app) semantic_result: Option<u64>,
    pub(in crate::app) sidebar_focus_intent: bool,
    pub(in crate::app) pairing_request: Option<u64>,
    pub(in crate::app) client_owned: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::app) enum SemanticDestinationOutcome {
    Pending,
    Resolved(SurfaceId),
    Failed,
}

#[derive(Clone, Debug)]
pub(in crate::app) struct ReplayedInputContext {
    pub(in crate::app) pointer: Option<DeferredPointerInput>,
    pub(in crate::app) admission: Option<DeferredInputAdmission>,
}

#[derive(Clone, Copy)]
pub(in crate::app) struct PendingPointerMotion {
    pub(in crate::app) event: MouseEvent,
    pub(in crate::app) destination: Option<SurfaceId>,
    pub(in crate::app) focus_generation: u64,
    pub(in crate::app) sequence: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::app) enum PointerRoutePhase {
    Fresh,
    GraphicsRenderPending,
    GraphicsProcessingPending,
    PaintPending,
    DrawPending,
}

impl PointerRoutePhase {
    pub(in crate::app) fn with_action(self, action: RenderAction) -> Self {
        match action {
            RenderAction::Draw => Self::DrawPending,
            RenderAction::Paint if self != Self::DrawPending => Self::PaintPending,
            RenderAction::Graphics if !matches!(self, Self::PaintPending | Self::DrawPending) => {
                Self::GraphicsRenderPending
            }
            _ => self,
        }
    }

    pub(in crate::app) fn invalidates_all_pointer_routes(self) -> bool {
        matches!(self, Self::PaintPending | Self::DrawPending)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::app) enum DeferredReplayDisposition {
    Drained,
    Blocked,
    RenderBoundary,
    Yield,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::app) struct DeferredReplayOutcome {
    pub(in crate::app) action: RenderAction,
    pub(in crate::app) disposition: DeferredReplayDisposition,
}
