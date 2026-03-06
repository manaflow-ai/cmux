//! Application entry point — creates the AdwApplication and main window.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::model::TabManager;
use crate::socket;
use crate::ui;

/// Thread-safe state shared between GTK main thread and socket server.
/// Both UI callbacks and socket handlers access the same TabManager instance.
pub struct SharedState {
    pub tab_manager: Mutex<TabManager>,
}

impl SharedState {
    pub fn new() -> Self {
        Self {
            tab_manager: Mutex::new(TabManager::new()),
        }
    }

    /// Lock the tab manager, recovering from poisoned mutex.
    pub fn lock_tab_manager(&self) -> std::sync::MutexGuard<'_, TabManager> {
        match self.tab_manager.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                tracing::warn!("TabManager mutex was poisoned, recovering");
                poisoned.into_inner()
            }
        }
    }
}

/// Application state accessible from UI callbacks (single-threaded, GTK main thread).
/// Wraps SharedState so UI and socket server operate on the same data.
pub struct AppState {
    pub shared: Arc<SharedState>,
    pub ghostty_app: RefCell<Option<ghostty_gtk::app::GhosttyApp>>,
}

impl AppState {
    pub fn new(shared: Arc<SharedState>) -> Self {
        Self {
            shared,
            ghostty_app: RefCell::new(None),
        }
    }

    /// Lock the tab manager. Convenience method for UI code.
    pub fn tab_manager(&self) -> std::sync::MutexGuard<'_, TabManager> {
        self.shared.lock_tab_manager()
    }
}

/// Run the GTK application. Returns the exit code.
pub fn run() -> i32 {
    let app = adw::Application::builder()
        .application_id("ai.manaflow.cmux")
        .build();

    let shared = Arc::new(SharedState::new());
    let state = Rc::new(AppState::new(shared.clone()));

    // Start the socket server once during startup (not on every activation)
    {
        let shared_for_socket = shared.clone();
        app.connect_startup(move |_app| {
            let shared = shared_for_socket.clone();
            std::thread::spawn(move || {
                let rt =
                    tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
                rt.block_on(async {
                    if let Err(e) = socket::server::run_socket_server(shared).await {
                        tracing::error!("Socket server error: {}", e);
                    }
                });
            });
        });
    }

    let state_clone = state.clone();
    app.connect_activate(move |app| {
        activate(app, &state_clone);
    });

    app.connect_shutdown(|_app| {
        socket::server::cleanup();
        tracing::info!("Application shutdown");
    });

    app.run().into()
}

fn activate(app: &adw::Application, state: &Rc<AppState>) {
    // Re-present existing window if one already exists (avoids duplicate windows)
    if let Some(window) = app.active_window() {
        window.present();
        return;
    }

    let window = ui::window::create_window(app, state);
    window.present();
}
