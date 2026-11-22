//! Host terminal input: the interruptible crossterm reader, the classified
//! `TerminalInput` the event loop consumes, and the host input ingress, reader
//! thread, runtime and shutdown handshake that feed it.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Sender as SyncSender, TrySendError};
use crossterm::event::{Event, KeyEvent, MouseEvent, MouseEventKind};

use crate::app::events::AppEvent;
use crate::app::{
    DEFERRED_INPUT_CAPACITY, DEFERRED_INPUT_FIXED_BYTES, MAX_DEFERRED_INPUT_BYTES, RenderAction,
    deferred_paste_bytes,
};
use crate::config::Action;
use crate::keys;

pub(super) const CROSSTERM_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(super) fn read_crossterm_event(
    timeout: Option<Duration>,
    poll: impl FnMut(Duration) -> std::io::Result<bool>,
    read: impl FnMut() -> std::io::Result<Event>,
) -> std::io::Result<Option<Event>> {
    read_crossterm_event_with_clock(timeout, poll, read, Instant::now)
}

pub(super) fn read_crossterm_event_with_clock(
    timeout: Option<Duration>,
    mut poll: impl FnMut(Duration) -> std::io::Result<bool>,
    mut read: impl FnMut() -> std::io::Result<Event>,
    mut now: impl FnMut() -> Instant,
) -> std::io::Result<Option<Event>> {
    // Keep the input thread interruptible even when no graphics response is
    // pending. A single normalized poll avoids separate timed and untimed
    // branches drifting apart as the reader evolves.
    const MAX_INTERRUPTED_RETRIES: u8 = 8;
    let poll_timeout =
        timeout.map_or(CROSSTERM_POLL_INTERVAL, |timeout| timeout.min(CROSSTERM_POLL_INTERVAL));
    let deadline = now() + poll_timeout;
    let mut interrupted: u8 = 0;
    loop {
        let remaining = deadline.saturating_duration_since(now());
        match poll(remaining) {
            Ok(false) => return Ok(None),
            Ok(true) => break,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                if remaining.is_zero() {
                    return Ok(None);
                }
                interrupted = interrupted.saturating_add(1);
                if interrupted >= MAX_INTERRUPTED_RETRIES {
                    return Err(error);
                }
            }
            Err(error) => return Err(error),
        }
    }
    interrupted = 0;
    loop {
        match read() {
            Ok(event) => return Ok(Some(event)),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                interrupted = interrupted.saturating_add(1);
                if interrupted >= MAX_INTERRUPTED_RETRIES {
                    return Err(error);
                }
            }
            Err(error) => return Err(error),
        }
    }
}

#[derive(Debug, Clone)]
pub(super) enum TerminalInput {
    Keyboard(keys::KeyboardInput),
    FrontendAction { action: Action, prefix: KeyEvent },
    ClearHistoryKey(keys::KeyboardInput),
    Mouse(MouseEvent),
    Paste(String),
    FocusGained,
    FocusLost,
    Resize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum InputClass {
    Keyboard,
    FrontendAction,
    ClearHistoryKey,
    Mouse,
    Paste,
    Focus,
    Resize,
}

impl InputClass {
    pub(super) const fn is_routable(self) -> bool {
        matches!(
            self,
            Self::Keyboard
                | Self::FrontendAction
                | Self::ClearHistoryKey
                | Self::Mouse
                | Self::Paste
        )
    }

    pub(super) const fn is_keyboard_or_paste(self) -> bool {
        matches!(self, Self::Keyboard | Self::FrontendAction | Self::ClearHistoryKey | Self::Paste)
    }

    pub(super) const fn is_keyboard_command(self) -> bool {
        matches!(self, Self::Keyboard | Self::FrontendAction | Self::ClearHistoryKey)
    }
}

pub(super) enum KeyboardIngress {
    Routed(TerminalInput),
    Handled(RenderAction),
    Ignored,
}

impl From<Event> for TerminalInput {
    fn from(event: Event) -> Self {
        Self::from_event(event)
    }
}

impl TerminalInput {
    pub(super) fn from_event(event: Event) -> Self {
        match event {
            Event::Key(key) => Self::Keyboard(key.into()),
            Event::EnhancedKey(key) => Self::Keyboard(key.into()),
            Event::Mouse(mouse) => Self::Mouse(mouse),
            Event::Paste(text) => Self::Paste(text),
            Event::FocusGained => Self::FocusGained,
            Event::FocusLost => Self::FocusLost,
            Event::Resize(_, _) => Self::Resize,
        }
    }

    pub(super) const fn class(&self) -> InputClass {
        match self {
            Self::Keyboard(_) => InputClass::Keyboard,
            Self::FrontendAction { .. } => InputClass::FrontendAction,
            Self::ClearHistoryKey(_) => InputClass::ClearHistoryKey,
            Self::Mouse(_) => InputClass::Mouse,
            Self::Paste(_) => InputClass::Paste,
            Self::FocusGained | Self::FocusLost => InputClass::Focus,
            Self::Resize => InputClass::Resize,
        }
    }

    pub(super) fn is_routable(&self) -> bool {
        self.class().is_routable()
    }

    pub(super) fn is_keyboard_or_paste(&self) -> bool {
        self.class().is_keyboard_or_paste()
    }

    pub(super) fn is_keyboard_command(&self) -> bool {
        self.class().is_keyboard_command()
    }

    pub(super) fn retained_bytes(&self) -> usize {
        match self {
            Self::Keyboard(key) | Self::ClearHistoryKey(key) => {
                DEFERRED_INPUT_FIXED_BYTES.saturating_add(key.associated_text_bytes())
            }
            Self::Paste(text) => deferred_paste_bytes(text),
            _ => DEFERRED_INPUT_FIXED_BYTES,
        }
    }
}

pub(super) fn host_event_retained_bytes(event: &Event) -> usize {
    match event {
        Event::EnhancedKey(key) => DEFERRED_INPUT_FIXED_BYTES.saturating_add(key.text.len()),
        Event::Paste(text) => deferred_paste_bytes(text),
        Event::Key(_)
        | Event::Mouse(_)
        | Event::FocusGained
        | Event::FocusLost
        | Event::Resize(..) => DEFERRED_INPUT_FIXED_BYTES,
    }
}

#[derive(Default)]
pub(super) struct HostInputIngressState {
    pub(super) events: VecDeque<HostInputMessage>,
    pub(super) retained_bytes: usize,
    pub(super) wake_queued: bool,
    pub(super) closed: bool,
}

pub(super) enum HostInputMessage {
    Event(Event),
    Failed(String),
}

impl HostInputMessage {
    pub(super) fn retained_bytes(&self) -> usize {
        match self {
            Self::Event(event) => host_event_retained_bytes(event),
            Self::Failed(error) => DEFERRED_INPUT_FIXED_BYTES.saturating_add(error.len()),
        }
    }

    fn is_passive_motion(&self) -> bool {
        matches!(self, Self::Event(Event::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. })))
    }

    fn is_resize(&self) -> bool {
        matches!(self, Self::Event(Event::Resize(..)))
    }
}

#[derive(Default)]
pub(super) struct HostInputIngress {
    pub(super) state: Mutex<HostInputIngressState>,
    pub(super) space_available: Condvar,
}

impl HostInputIngress {
    pub(super) fn send(&self, event: Event) -> Result<bool, ()> {
        self.enqueue(HostInputMessage::Event(event))
    }

    pub(super) fn fail(&self, error: String) -> Result<bool, ()> {
        self.enqueue(HostInputMessage::Failed(error))
    }

    pub(super) fn enqueue(&self, event: HostInputMessage) -> Result<bool, ()> {
        let retained_bytes = event.retained_bytes();
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(());
        }
        if event.is_passive_motion()
            && state.events.back().is_some_and(HostInputMessage::is_passive_motion)
        {
            let previous_bytes =
                state.events.back().map(HostInputMessage::retained_bytes).unwrap_or(0);
            state.retained_bytes =
                state.retained_bytes.saturating_sub(previous_bytes).saturating_add(retained_bytes);
            *state.events.back_mut().unwrap() = event;
            return Ok(false);
        }
        // Crossterm can report several intermediate sizes while a terminal is
        // being resized. Keep only the latest adjacent resize so the app
        // always applies the final dimensions instead of spending queue space
        // on stale events.
        if event.is_resize() && state.events.back().is_some_and(HostInputMessage::is_resize) {
            let previous_bytes =
                state.events.back().map(HostInputMessage::retained_bytes).unwrap_or(0);
            state.retained_bytes =
                state.retained_bytes.saturating_sub(previous_bytes).saturating_add(retained_bytes);
            *state.events.back_mut().unwrap() = event;
            return Ok(false);
        }
        while !state.closed
            && (state.events.len() >= DEFERRED_INPUT_CAPACITY
                || (!state.events.is_empty()
                    && state.retained_bytes.saturating_add(retained_bytes)
                        > MAX_DEFERRED_INPUT_BYTES))
        {
            state = self.space_available.wait(state).unwrap();
        }
        if state.closed {
            return Err(());
        }
        let wake = !state.wake_queued;
        state.wake_queued = true;
        state.retained_bytes = state.retained_bytes.saturating_add(retained_bytes);
        state.events.push_back(event);
        Ok(wake)
    }

    pub(super) fn pop_if(
        &self,
        accept: impl FnOnce(&HostInputMessage) -> bool,
    ) -> Option<HostInputMessage> {
        let mut state = self.state.lock().unwrap();
        if !accept(state.events.front()?) {
            return None;
        }
        let event = state.events.pop_front().unwrap();
        state.retained_bytes = state.retained_bytes.saturating_sub(event.retained_bytes());
        if state.events.is_empty() {
            state.wake_queued = false;
        }
        drop(state);
        self.space_available.notify_one();
        Some(event)
    }

    pub(super) fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.space_available.notify_all();
    }

    pub(super) fn is_closed(&self) -> bool {
        self.state.lock().unwrap().closed
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.state.lock().unwrap().events.len()
    }
}

pub(super) struct HostInputRuntime {
    pub(super) ingress: Arc<HostInputIngress>,
    pub(super) reader: Arc<HostInputReaderControl>,
}

impl HostInputRuntime {
    pub(super) fn new() -> Self {
        Self {
            ingress: Arc::new(HostInputIngress::default()),
            reader: Arc::new(HostInputReaderControl::default()),
        }
    }

    pub(super) fn producer(&self, events: SyncSender<AppEvent>) -> HostInputProducer {
        HostInputProducer { ingress: self.ingress.clone(), events }
    }

    pub(super) fn pop_if(
        &self,
        accept: impl FnOnce(&HostInputMessage) -> bool,
    ) -> Option<HostInputMessage> {
        self.ingress.pop_if(accept)
    }

    pub(super) fn attach_reader(&self, reader: JoinHandle<()>) {
        let mut state = self.reader.state.lock().unwrap();
        assert!(!state.shutting_down, "host input reader cannot attach during shutdown");
        assert!(state.reader.is_none(), "host input reader can only be attached once");
        state.reader_thread = Some(reader.thread().id());
        state.reader = Some(reader);
    }

    pub(super) fn shutdown_control(&self) -> HostInputShutdown {
        HostInputShutdown { ingress: self.ingress.clone(), reader: self.reader.clone() }
    }

    pub(super) fn shutdown(&self) {
        self.shutdown_control().shutdown();
    }
}

impl Drop for HostInputRuntime {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[derive(Clone)]
pub(super) struct HostInputShutdown {
    pub(super) ingress: Arc<HostInputIngress>,
    pub(super) reader: Arc<HostInputReaderControl>,
}

impl HostInputShutdown {
    pub(super) fn shutdown(&self) {
        self.ingress.close();
        // The reader checks the closed ingress before each read. The
        // crossterm wrapper caps every poll at CROSSTERM_POLL_INTERVAL and
        // only calls read after poll reports a ready event, so joining here
        // cannot wait on an idle terminal read.
        let current_thread = std::thread::current().id();
        let reader = {
            let mut state = self.reader.state.lock().unwrap();
            if state.complete {
                return;
            }
            if state.shutting_down {
                if state.reader_thread == Some(current_thread) {
                    return;
                }
                while !state.complete {
                    state = self.reader.complete.wait(state).unwrap();
                }
                return;
            }
            state.shutting_down = true;
            state.reader.take()
        };
        if let Some(reader) = reader
            && reader.thread().id() != current_thread
        {
            let _ = reader.join();
        }
        let mut state = self.reader.state.lock().unwrap();
        state.complete = true;
        self.reader.complete.notify_all();
    }
}

#[derive(Default)]
pub(super) struct HostInputReaderControl {
    pub(super) state: Mutex<HostInputReaderState>,
    complete: Condvar,
}

#[derive(Default)]
pub(super) struct HostInputReaderState {
    reader: Option<JoinHandle<()>>,
    reader_thread: Option<std::thread::ThreadId>,
    shutting_down: bool,
    complete: bool,
}

pub(super) struct HostInputProducer {
    pub(super) ingress: Arc<HostInputIngress>,
    pub(super) events: SyncSender<AppEvent>,
}

impl HostInputProducer {
    pub(super) fn send(&self, event: Event) -> bool {
        self.publish(self.ingress.send(event))
    }

    pub(super) fn fail(&self, error: String) {
        let _ = self.publish(self.ingress.fail(error));
    }

    fn publish(&self, result: Result<bool, ()>) -> bool {
        let Ok(wake) = result else { return false };
        if !wake {
            return true;
        }
        // This is only a wake hint. Keep it nonblocking so shutdown can join
        // the reader even when the app event channel is full.
        match self.events.try_send(AppEvent::HostInputReady) {
            Ok(()) => true,
            Err(TrySendError::Full(AppEvent::HostInputReady)) => {
                // A full channel already has queued work. The event loop
                // drains retained host input before each wait and after every
                // queued event, so this wake hint is redundant.
                true
            }
            Err(TrySendError::Disconnected(AppEvent::HostInputReady)) => {
                self.ingress.close();
                false
            }
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                unreachable!("host-input wake returned a different event")
            }
        }
    }
}
