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

/// Shared application state accessible from UI callbacks (single-threaded, GTK main thread).
pub struct AppState {
    pub tab_manager: RefCell<TabManager>,
    pub ghostty_app: RefCell<Option<ghostty_gtk::app::GhosttyApp>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            tab_manager: RefCell::new(TabManager::new()),
            ghostty_app: RefCell::new(None),
        }
    }
}

/// Thread-safe state shared between GTK main thread and socket server.
/// The socket server reads/writes through this, then signals the GTK main thread
/// via glib channels for UI updates.
pub struct SharedState {
    pub tab_manager: Mutex<TabManager>,
}

impl SharedState {
    pub fn new() -> Self {
        Self {
            tab_manager: Mutex::new(TabManager::new()),
        }
    }
}

/// Run the GTK application. Returns the exit code.
pub fn run() -> i32 {
    let app = adw::Application::builder()
        .application_id("ai.manaflow.cmux")
        .build();

    let state = Rc::new(AppState::new());
    let shared = Arc::new(SharedState::new());

    let state_clone = state.clone();
    let shared_clone = shared.clone();
    app.connect_activate(move |app| {
        activate(app, &state_clone, &shared_clone);
    });

    app.connect_shutdown(|_app| {
        socket::server::cleanup();
        tracing::info!("Application shutdown");
    });

    app.run().into()
}

fn activate(app: &adw::Application, state: &Rc<AppState>, shared: &Arc<SharedState>) {
    // Start the socket server in a background tokio runtime
    let shared_for_socket = shared.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
        rt.block_on(async {
            if let Err(e) = socket::server::run_socket_server(shared_for_socket).await {
                tracing::error!("Socket server error: {}", e);
            }
        });
    });

    // Create the main window
    let window = ui::window::create_window(app, state);
    window.present();
}
