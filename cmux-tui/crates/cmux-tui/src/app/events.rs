//! The app event channel: `AppEvent`, the bounded cancelable session event
//! sender, and the session event and owner reload workers that post to it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use cmux_tui_core::{Mux, MuxEvent, SurfaceId};
use crossbeam_channel::{Sender as SyncSender, TrySendError, bounded as sync_channel};
use crossterm::event::Event;

use crate::app::host_input::TerminalInput;
use crate::app::session_mutation::{MutationImpact, SessionMutationOutcome};
use crate::app::surface_sync::SurfaceAttachOutcome;
use crate::app::{MachineControllerCompletion, Selection};
use crate::browser_input::BrowserResizeFailure;
#[cfg(test)]
use crate::machine::MachineUiState;
use crate::machine::MachineUpdate;
use crate::pty_input::PtyOperationFailure;
use crate::session::{ClientInfo, SidebarPluginSurface, TreeView};

pub(super) enum AppEvent {
    SessionScoped {
        generation: u64,
        event: Box<AppEvent>,
    },
    Mux(MuxEvent),
    OwnerConfigReloadRequested,
    MuxTitlesReady,
    MuxSubscriptionRecovered {
        recovery_generation: u64,
        destination_generation: u64,
        result: Result<TreeView, String>,
    },
    MuxRecoveryComplete {
        recovery_generation: u64,
    },
    HostInputReady,
    HostInputFailed(String),
    Input(Event),
    NormalizedInput(TerminalInput),
    BrowserResizeFailed(BrowserResizeFailure),
    GraphicsWriterReady,
    PtyFailuresReady,
    /// A status bar command segment produced new output; redraw the bar.
    StatusCommandsUpdated,
    PtyOperationFailed(PtyOperationFailure),
    ClearHistorySucceeded {
        surface: SurfaceId,
        input_revision: u64,
        selection_at_invocation: Option<Selection>,
        selection_generation: u64,
    },
    SessionMutationSettled {
        outcome: SessionMutationOutcome,
        impact: MutationImpact,
    },
    SurfaceAttachSettled {
        outcome: SurfaceAttachOutcome,
    },
    RemoteTreeUpdated {
        refresh_sequence: u64,
        destination_generation: u64,
        result: Result<TreeView, String>,
    },
    ClientsUpdated {
        generation: u64,
        result: Result<Vec<ClientInfo>, String>,
    },
    SidebarPluginUpdated {
        status: SidebarPluginSurface,
        relaunch: bool,
    },
    #[cfg(test)]
    MachineUiUpdated(Box<MachineUiState>),
    MachineUpdatedForGeneration {
        generation: u64,
        update: Box<MachineUpdate>,
    },
    MachineControllerCompleted(Box<MachineControllerCompletion>),
}

/// Cancellation-aware sender used by every worker tied to one mux session.
/// Production senders wrap events with a generation; unit-level OrderedSession
/// tests use an unscoped sender to keep their focused assertions small.
#[derive(Clone)]
pub(super) struct SessionEventSender {
    pub(super) tx: SyncSender<AppEvent>,
    pub(super) generation: Option<u64>,
    pub(super) surface_filter: Option<SurfaceId>,
    pub(super) cancellation: EventCancellation,
}

/// A cancellation signal that wakes every sender waiting for capacity.
/// Crossbeam's bounded channel gives the event queue a select-like send, while
/// dropping its sole sender broadcasts cancellation to all cloned receivers.
#[derive(Clone)]
pub(super) struct EventCancellation {
    pub(super) stop: Arc<AtomicBool>,
    pub(super) receiver: crossbeam_channel::Receiver<()>,
    pub(super) sender: Arc<Mutex<Option<SyncSender<()>>>>,
}

impl EventCancellation {
    pub(super) fn new() -> Self {
        let (sender, receiver) = sync_channel(0);
        Self {
            stop: Arc::new(AtomicBool::new(false)),
            receiver,
            sender: Arc::new(Mutex::new(Some(sender))),
        }
    }

    pub(super) fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
        self.sender.lock().unwrap().take();
    }
}

pub(super) enum SessionTrySendError {
    Full,
    Disconnected,
}

impl SessionEventSender {
    pub(super) fn scoped(
        tx: SyncSender<AppEvent>,
        generation: u64,
        surface_filter: Option<SurfaceId>,
        cancellation: EventCancellation,
    ) -> Self {
        Self { tx, generation: Some(generation), surface_filter, cancellation }
    }

    #[cfg(test)]
    pub(super) fn unscoped(tx: SyncSender<AppEvent>) -> Self {
        Self { tx, generation: None, surface_filter: None, cancellation: EventCancellation::new() }
    }

    #[cfg(test)]
    pub(super) fn filtered(tx: SyncSender<AppEvent>, surface: SurfaceId) -> Self {
        Self {
            tx,
            generation: None,
            surface_filter: Some(surface),
            cancellation: EventCancellation::new(),
        }
    }

    pub(super) fn accepts_mux_event(&self, event: &MuxEvent) -> bool {
        let Some(filter) = self.surface_filter else { return true };
        match event {
            MuxEvent::SurfaceOutput(surface)
            | MuxEvent::SurfaceExited(surface)
            | MuxEvent::Bell(surface) => *surface == filter,
            MuxEvent::SurfaceResized { surface, .. }
            | MuxEvent::SurfaceResizeFailed { surface, .. }
            | MuxEvent::AgentChanged { surface, .. }
            | MuxEvent::TitleChanged { surface, .. }
            | MuxEvent::ScrollChanged { surface, .. } => *surface == filter,
            MuxEvent::Notification(notification) => {
                notification.surface.is_none_or(|surface| surface == filter)
            }
            _ => true,
        }
    }

    fn wrap(&self, event: AppEvent) -> AppEvent {
        match self.generation {
            Some(generation) => AppEvent::SessionScoped { generation, event: Box::new(event) },
            None => event,
        }
    }

    pub(super) fn try_send(&self, event: AppEvent) -> Result<(), SessionTrySendError> {
        if self.cancellation.stop.load(Ordering::Acquire) {
            return Err(SessionTrySendError::Disconnected);
        }
        match self.tx.try_send(self.wrap(event)) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(SessionTrySendError::Full),
            Err(TrySendError::Disconnected(_)) => Err(SessionTrySendError::Disconnected),
        }
    }

    pub(super) fn send(&self, event: AppEvent) -> Result<(), ()> {
        send_bounded_cancelable(&self.tx, self.wrap(event), &self.cancellation)
    }
}

/// Enqueue on a bounded channel while allowing cancellation to interrupt a
/// producer that is waiting for capacity. There is no polling delay and no
/// per-send helper thread.
pub(super) fn send_bounded_cancelable<T>(
    tx: &SyncSender<T>,
    value: T,
    cancellation: &EventCancellation,
) -> Result<(), ()> {
    if cancellation.stop.load(Ordering::Acquire) {
        return Err(());
    }
    crossbeam_channel::select_biased! {
        recv(cancellation.receiver) -> _ => Err(()),
        send(tx, value) -> result => result.map_err(|_| ()),
    }
}

pub(super) struct SessionEventWorker {
    pub(super) cancellation: EventCancellation,
    pub(super) start: Arc<AtomicBool>,
    pub(super) stop: Arc<Mutex<Option<cmux_tui_core::MuxEventReceiver>>>,
    pub(super) mux: Option<JoinHandle<()>>,
}

impl SessionEventWorker {
    pub(super) fn activate(&self) {
        self.start.store(true, Ordering::Release);
    }

    pub(super) fn stop_and_join(&mut self) {
        self.cancellation.cancel();
        self.activate();
        // Closing the receiver wakes a worker blocked in recv(). This avoids
        // polling the session event mailbox on a fixed 100 ms timer.
        if let Some(stop) = self.stop.lock().unwrap().take() {
            stop.close();
        }
        if let Some(mux) = self.mux.take() {
            let _ = mux.join();
        }
    }
}

impl Drop for SessionEventWorker {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

pub(super) struct OwnerReloadWorker {
    pub(super) stop: Option<cmux_tui_core::MuxEventReceiver>,
    pub(super) cancellation: EventCancellation,
    pub(super) thread: Option<JoinHandle<()>>,
}

impl OwnerReloadWorker {
    pub(super) fn spawn(mux: &Mux, tx: SyncSender<AppEvent>) -> std::io::Result<Self> {
        let events = mux.subscribe_config_reload();
        let stop = events.clone();
        let cancellation = EventCancellation::new();
        let worker_cancellation = cancellation.clone();
        let thread =
            std::thread::Builder::new().name("owner-config-reload".into()).spawn(move || {
                while !worker_cancellation.stop.load(Ordering::Acquire) {
                    let Ok(event) = events.recv() else { return };
                    if !matches!(event, MuxEvent::ConfigReloadRequested) {
                        continue;
                    }
                    if send_bounded_cancelable(
                        &tx,
                        AppEvent::OwnerConfigReloadRequested,
                        &worker_cancellation,
                    )
                    .is_err()
                    {
                        return;
                    }
                }
            })?;
        Ok(Self { stop: Some(stop), cancellation, thread: Some(thread) })
    }

    pub(super) fn stop_and_join(&mut self) {
        self.cancellation.cancel();
        if let Some(stop) = self.stop.take() {
            stop.close();
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for OwnerReloadWorker {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}
