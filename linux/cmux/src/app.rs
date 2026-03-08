//! Application entry point — creates the AdwApplication and main window.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use ghostty_sys::*;
use gtk4::prelude::*;
use libadwaita as adw;

use crate::model::TabManager;
use crate::notifications::NotificationStore;
use crate::socket;
use crate::ui;
use uuid::Uuid;

/// Shared application state accessible from UI callbacks (single-threaded, GTK main thread).
pub struct AppState {
    pub shared: Arc<SharedState>,
    pub ghostty_app: RefCell<Option<ghostty_gtk::app::GhosttyApp>>,
    pub terminal_cache: RefCell<HashMap<Uuid, ghostty_gtk::surface::GhosttyGlSurface>>,
    /// Stored to keep the callbacks alive for the lifetime of the app.
    _callbacks: RefCell<Option<ghostty_gtk::callbacks::RuntimeCallbacks>>,
}

impl AppState {
    pub fn new(shared: Arc<SharedState>) -> Self {
        Self {
            shared,
            ghostty_app: RefCell::new(None),
            terminal_cache: RefCell::new(HashMap::new()),
            _callbacks: RefCell::new(None),
        }
    }

    pub fn terminal_surface_for(
        &self,
        panel_id: Uuid,
        working_directory: Option<&str>,
    ) -> ghostty_gtk::surface::GhosttyGlSurface {
        if let Some(surface) = self.terminal_cache.borrow().get(&panel_id) {
            return surface.clone();
        }

        let gl_surface = ghostty_gtk::surface::GhosttyGlSurface::new();
        gl_surface.set_hexpand(true);
        gl_surface.set_vexpand(true);

        if let Some(app) = self.ghostty_app.borrow().as_ref() {
            gl_surface.initialize(app.raw(), working_directory, None);
        }

        self.terminal_cache
            .borrow_mut()
            .insert(panel_id, gl_surface.clone());
        gl_surface
    }

    pub fn send_input_to_panel(&self, panel_id: Uuid, text: &str) -> bool {
        let surface = self.terminal_cache.borrow().get(&panel_id).cloned();
        let Some(surface) = surface else {
            return false;
        };

        surface.send_text(text);
        true
    }

    pub fn prune_terminal_cache(&self) {
        let live_panels: HashSet<Uuid> = {
            let tab_manager = self.shared.tab_manager.lock().unwrap();
            tab_manager
                .iter()
                .flat_map(|workspace| workspace.panels.values())
                .filter(|panel| panel.panel_type == crate::model::PanelType::Terminal)
                .map(|panel| panel.id)
                .collect()
        };

        self.terminal_cache
            .borrow_mut()
            .retain(|panel_id, _| live_panels.contains(panel_id));
    }
}

/// Messages from background tasks that require a UI refresh.
#[derive(Clone, Debug)]
pub enum UiEvent {
    Refresh,
    SendInput { panel_id: Uuid, text: String },
}

/// Thread-safe state shared between GTK main thread and socket server.
/// The socket server reads/writes through this, then signals the GTK main thread
/// via glib channels for UI updates.
pub struct SharedState {
    pub tab_manager: Mutex<TabManager>,
    pub notifications: Mutex<NotificationStore>,
    ui_event_tx: Mutex<Option<Sender<UiEvent>>>,
}

impl SharedState {
    pub fn new() -> Self {
        Self {
            tab_manager: Mutex::new(TabManager::new()),
            notifications: Mutex::new(NotificationStore::new()),
            ui_event_tx: Mutex::new(None),
        }
    }

    pub fn install_ui_event_sender(&self, sender: Sender<UiEvent>) {
        *self.ui_event_tx.lock().unwrap() = Some(sender);
    }

    pub fn send_ui_event(&self, event: UiEvent) -> bool {
        self.ui_event_tx
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|sender| sender.send(event).is_ok())
    }

    pub fn notify_ui_refresh(&self) {
        let _ = self.send_ui_event(UiEvent::Refresh);
    }
}

/// Run the GTK application. Returns the exit code.
pub fn run() -> i32 {
    let app = adw::Application::builder()
        .application_id("ai.manaflow.cmux")
        .build();

    let shared = Arc::new(SharedState::new());
    let state = Rc::new(AppState::new(shared));

    let state_clone = state.clone();
    app.connect_activate(move |app| {
        activate(app, &state_clone);
    });

    app.connect_shutdown(|_app| {
        *GHOSTTY_APP_PTR.lock().unwrap() = SendAppPtr(std::ptr::null_mut());
        GHOSTTY_TICK_PENDING.store(false, Ordering::Release);
        socket::server::cleanup();
        tracing::info!("Application shutdown");
    });

    app.run().into()
}

fn activate(app: &adw::Application, state: &Rc<AppState>) {
    let (ui_event_tx, ui_event_rx) = std::sync::mpsc::channel();
    state.shared.install_ui_event_sender(ui_event_tx);

    // Start the socket server in a background tokio runtime
    let shared_for_socket = state.shared.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
        rt.block_on(async {
            if let Err(e) = socket::server::run_socket_server(shared_for_socket).await {
                tracing::error!("Socket server error: {}", e);
            }
        });
    });

    // Initialize ghostty runtime
    init_ghostty(state);

    // Create the main window
    let window = ui::window::create_window(app, state, ui_event_rx);
    window.present();
}

/// Initialize the ghostty embedded runtime and store it in AppState.
fn init_ghostty(state: &Rc<AppState>) {
    if let Err(e) = ghostty_gtk::app::GhosttyApp::init() {
        tracing::error!("Failed to init ghostty: {}", e);
        return;
    }

    let handler = CmuxCallbackHandler;

    let callbacks = ghostty_gtk::callbacks::RuntimeCallbacks::new(Box::new(handler));

    match ghostty_gtk::app::GhosttyApp::new(&callbacks) {
        Ok(ghostty_app) => {
            tracing::info!("Ghostty app initialized successfully");
            *GHOSTTY_APP_PTR.lock().unwrap() = SendAppPtr(ghostty_app.raw());
            *state.ghostty_app.borrow_mut() = Some(ghostty_app);
            *state._callbacks.borrow_mut() = Some(callbacks);
        }
        Err(e) => {
            tracing::error!("Failed to create GhosttyApp: {}", e);
        }
    }
}

/// Callback handler that bridges ghostty events to the GTK main loop.
struct CmuxCallbackHandler;

impl ghostty_gtk::callbacks::GhosttyCallbackHandler for CmuxCallbackHandler {
    fn on_wakeup(&self) {
        let app_ptr = *GHOSTTY_APP_PTR.lock().unwrap();
        if app_ptr.is_null() {
            return;
        }

        if GHOSTTY_TICK_PENDING.swap(true, Ordering::AcqRel) {
            return;
        }

        glib::MainContext::default().invoke_with_priority(glib::Priority::DEFAULT, move || {
            GHOSTTY_TICK_PENDING.store(false, Ordering::Release);

            #[cfg(feature = "link-ghostty")]
            unsafe {
                ghostty_app_tick(app_ptr.get());
            }
            #[cfg(not(feature = "link-ghostty"))]
            let _ = app_ptr;
        });
    }

    fn on_action(&self, target: ghostty_target_s, action: ghostty_action_s) -> bool {
        match action.tag {
            ghostty_action_tag_e::GHOSTTY_ACTION_RENDER => {
                // The target surface wants a re-render.
                if target.tag == ghostty_target_tag_e::GHOSTTY_TARGET_SURFACE {
                    let surface_ptr = unsafe { target.target.surface };
                    if !surface_ptr.is_null() {
                        #[cfg(feature = "link-ghostty")]
                        unsafe {
                            let userdata = ghostty_surface_userdata(surface_ptr);
                            if !userdata.is_null() {
                                let widget: gtk4::GLArea =
                                    glib::translate::from_glib_none(userdata as *mut _);
                                widget.queue_render();
                            }
                        }
                    }
                }
                true
            }
            ghostty_action_tag_e::GHOSTTY_ACTION_SET_TITLE => true,
            _ => {
                tracing::trace!("Unhandled ghostty action: {:?}", action.tag as u32);
                false
            }
        }
    }
}

#[derive(Clone, Copy)]
struct SendAppPtr(ghostty_app_t);

unsafe impl Send for SendAppPtr {}
unsafe impl Sync for SendAppPtr {}

impl SendAppPtr {
    #[cfg(feature = "link-ghostty")]
    fn get(self) -> ghostty_app_t {
        self.0
    }

    fn is_null(self) -> bool {
        self.0.is_null()
    }
}

static GHOSTTY_APP_PTR: Mutex<SendAppPtr> = Mutex::new(SendAppPtr(std::ptr::null_mut()));
static GHOSTTY_TICK_PENDING: AtomicBool = AtomicBool::new(false);
