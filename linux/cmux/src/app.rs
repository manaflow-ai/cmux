//! Application entry point — creates the AdwApplication and main window.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use ghostty_sys::*;
use gtk4::prelude::*;
use libadwaita as adw;
use tokio::sync::mpsc::UnboundedSender;

/// Lock a mutex, recovering from poisoning rather than panicking.
/// Prevents cascading panics when one thread panics while holding a lock.
pub fn lock_or_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| {
        tracing::error!("Mutex was poisoned, recovering");
        poisoned.into_inner()
    })
}

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
        gl_surface.set_panel_id(panel_id);

        if let Some(app) = self.ghostty_app.borrow().as_ref() {
            gl_surface.initialize(app.raw(), working_directory, None);
        }

        self.terminal_cache
            .borrow_mut()
            .insert(panel_id, gl_surface.clone());
        gl_surface
    }

    pub fn send_input_to_panel(&self, panel_id: Uuid, text: &str) -> bool {
        let surface = if let Some(surface) = self.terminal_cache.borrow().get(&panel_id).cloned() {
            surface
        } else {
            let working_directory = {
                let tab_manager = lock_or_recover(&self.shared.tab_manager);
                let Some(workspace) = tab_manager.find_workspace_with_panel(panel_id) else {
                    return false;
                };
                let Some(panel) = workspace.panel(panel_id) else {
                    return false;
                };
                if panel.panel_type != crate::model::PanelType::Terminal {
                    return false;
                }
                panel.directory.clone()
            };
            self.terminal_surface_for(panel_id, working_directory.as_deref())
        };

        surface.send_text(text)
    }

    pub fn close_panel(&self, panel_id: Uuid, process_alive: bool) -> bool {
        {
            let mut tab_manager = lock_or_recover(&self.shared.tab_manager);
            let Some(workspace) = tab_manager.find_workspace_with_panel_mut(panel_id) else {
                return false;
            };
            if !workspace.remove_panel(panel_id) {
                return false;
            }
            let empty_workspace_id = workspace.is_empty().then_some(workspace.id);
            if let Some(workspace_id) = empty_workspace_id {
                tab_manager.remove_by_id(workspace_id);
            }
        }

        self.terminal_cache.borrow_mut().remove(&panel_id);
        self.shared.notify_ui_refresh();
        tracing::debug!(%panel_id, process_alive, "closed terminal panel");
        true
    }

    pub fn prune_terminal_cache(&self) {
        let live_panels: HashSet<Uuid> = {
            let tab_manager = lock_or_recover(&self.shared.tab_manager);
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
    SurfacePwd { panel_id: Uuid, pwd: String },
    SurfaceTitle { panel_id: Uuid, title: String },
}

/// Thread-safe state shared between GTK main thread and socket server.
/// The socket server reads/writes through this, then signals the GTK main thread
/// via glib channels for UI updates.
pub struct SharedState {
    pub tab_manager: Mutex<TabManager>,
    pub notifications: Mutex<NotificationStore>,
    ui_event_tx: Mutex<Option<UnboundedSender<UiEvent>>>,
}

impl SharedState {
    pub fn new() -> Self {
        Self {
            tab_manager: Mutex::new(TabManager::new()),
            notifications: Mutex::new(NotificationStore::new()),
            ui_event_tx: Mutex::new(None),
        }
    }

    pub fn install_ui_event_sender(&self, sender: UnboundedSender<UiEvent>) {
        *lock_or_recover(&self.ui_event_tx) = Some(sender);
    }

    pub fn send_ui_event(&self, event: UiEvent) -> bool {
        lock_or_recover(&self.ui_event_tx)
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
    let state = Rc::new(AppState::new(shared.clone()));

    {
        let shared_for_socket = shared.clone();
        app.connect_startup(move |_app| {
            let shared = shared_for_socket.clone();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
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
        *GHOSTTY_APP_PTR.lock().unwrap() = SendAppPtr(std::ptr::null_mut());
        *SHARED_STATE.lock().unwrap() = None;
        GHOSTTY_TICK_PENDING.store(false, Ordering::Release);
        socket::server::cleanup();
        tracing::info!("Application shutdown");
    });

    app.run().into()
}

fn activate(app: &adw::Application, state: &Rc<AppState>) {
    if let Some(window) = app.active_window() {
        window.present();
        return;
    }

    let (ui_event_tx, ui_event_rx) = tokio::sync::mpsc::unbounded_channel();
    state.shared.install_ui_event_sender(ui_event_tx);

    init_ghostty(state);

    // Force dark color scheme for the window so that ghostty's
    // background-opacity blends against a dark surface, matching
    // the native ghostty behavior with window-theme = dark.
    adw::StyleManager::default().set_color_scheme(adw::ColorScheme::ForceDark);

    // Create the main window
    let window = ui::window::create_window(app, state, ui_event_rx);
    window.present();
}

/// Initialize the ghostty embedded runtime and store it in AppState.
fn init_ghostty(state: &Rc<AppState>) {
    if state.ghostty_app.borrow().is_some() {
        return;
    }

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
            *SHARED_STATE.lock().unwrap() = Some(state.shared.clone());
            *state.ghostty_app.borrow_mut() = Some(ghostty_app);
            *state._callbacks.borrow_mut() = Some(callbacks);
        }
        Err(e) => {
            tracing::error!("Failed to create GhosttyApp: {}", e);
        }
    }
}

/// Sync the system dark/light mode to the ghostty runtime so that
/// color-scheme-aware features (e.g. `window-theme = auto`) work correctly.
/// Without this, Ghostty defaults to light mode, causing a brighter background.
fn sync_color_scheme(state: &Rc<AppState>) {
    let style = adw::StyleManager::default();
    let scheme = if style.is_dark() {
        ghostty_color_scheme_e::GHOSTTY_COLOR_SCHEME_DARK
    } else {
        ghostty_color_scheme_e::GHOSTTY_COLOR_SCHEME_LIGHT
    };
    if let Some(app) = state.ghostty_app.borrow().as_ref() {
        app.set_color_scheme(scheme);
    }
}

/// Callback handler that bridges ghostty events to the GTK main loop.
struct CmuxCallbackHandler;

impl ghostty_gtk::callbacks::GhosttyCallbackHandler for CmuxCallbackHandler {
    fn on_wakeup(&self) {
        if (*GHOSTTY_APP_PTR.lock().unwrap()).is_null() {
            return;
        }

        if GHOSTTY_TICK_PENDING.swap(true, Ordering::AcqRel) {
            return;
        }

        glib::MainContext::default().invoke_with_priority(glib::Priority::DEFAULT, move || {
            GHOSTTY_TICK_PENDING.store(false, Ordering::Release);
            let app_ptr = *GHOSTTY_APP_PTR.lock().unwrap();
            if app_ptr.is_null() {
                return;
            }

            #[cfg(feature = "link-ghostty")]
            unsafe {
                ghostty_app_tick(app_ptr.get());
            }
            #[cfg(not(feature = "link-ghostty"))]
            let _ = ();
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
                            let _ = ghostty_gtk::callbacks::queue_render_from_userdata(userdata);
                        }
                    }
                }
                true
            }
            ghostty_action_tag_e::GHOSTTY_ACTION_SET_TITLE => {
                if target.tag == ghostty_target_tag_e::GHOSTTY_TARGET_SURFACE {
                    #[cfg(feature = "link-ghostty")]
                    unsafe {
                        let title_s = action.action.set_title;
                        if !title_s.title.is_null() {
                            let title = std::ffi::CStr::from_ptr(title_s.title)
                                .to_string_lossy()
                                .into_owned();
                            let surface_ptr = target.target.surface;
                            let userdata = ghostty_surface_userdata(surface_ptr);
                            dispatch_surface_metadata(userdata, move |panel_id, shared| {
                                let mut tm = lock_or_recover(&shared.tab_manager);
                                if let Some(ws) = tm.find_workspace_with_panel_mut(panel_id) {
                                    ws.process_title = title;
                                }
                                shared.notify_ui_refresh();
                            });
                        }
                    }
                }
                true
            }
            ghostty_action_tag_e::GHOSTTY_ACTION_PWD => {
                if target.tag == ghostty_target_tag_e::GHOSTTY_TARGET_SURFACE {
                    #[cfg(feature = "link-ghostty")]
                    unsafe {
                        let pwd_s = action.action.pwd;
                        if !pwd_s.pwd.is_null() {
                            let pwd = std::ffi::CStr::from_ptr(pwd_s.pwd)
                                .to_string_lossy()
                                .into_owned();
                            let surface_ptr = target.target.surface;
                            let userdata = ghostty_surface_userdata(surface_ptr);
                            dispatch_surface_metadata(userdata, move |panel_id, shared| {
                                let mut tm = lock_or_recover(&shared.tab_manager);
                                if let Some(ws) = tm.find_workspace_with_panel_mut(panel_id) {
                                    ws.current_directory = pwd;
                                }
                                shared.notify_ui_refresh();
                            });
                        }
                    }
                }
                true
            }
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

/// Dispatch a metadata update from a ghostty surface callback to the main thread.
/// Resolves the surface's panel_id via its userdata, then calls `f` with the
/// panel_id and shared state.
fn dispatch_surface_metadata<F>(userdata: *mut std::os::raw::c_void, f: F)
where
    F: FnOnce(Uuid, &SharedState) + Send + 'static,
{
    let weak = unsafe { ghostty_gtk::callbacks::surface_from_callback_userdata(userdata) };
    let Some(surface) = weak else { return };
    let Some(panel_id) = surface.panel_id() else { return };

    glib::MainContext::default().invoke(move || {
        let guard = SHARED_STATE.lock().unwrap();
        if let Some(ref shared) = *guard {
            f(panel_id, shared);
        }
    });
}

static GHOSTTY_APP_PTR: Mutex<SendAppPtr> = Mutex::new(SendAppPtr(std::ptr::null_mut()));
static GHOSTTY_TICK_PENDING: AtomicBool = AtomicBool::new(false);
static SHARED_STATE: Mutex<Option<Arc<SharedState>>> = Mutex::new(None);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn close_panel_removes_last_workspace() {
        let shared = Arc::new(SharedState::new());
        let state = AppState::new(shared.clone());
        let panel_id = shared
            .tab_manager
            .lock()
            .unwrap()
            .selected()
            .and_then(|workspace| workspace.focused_panel_id)
            .expect("workspace should have a focused panel");

        assert!(state.close_panel(panel_id, false));
        assert!(shared.tab_manager.lock().unwrap().is_empty());
    }

    #[test]
    fn close_panel_returns_false_for_unknown_panel() {
        let state = AppState::new(Arc::new(SharedState::new()));
        assert!(!state.close_panel(Uuid::new_v4(), true));
    }
}
