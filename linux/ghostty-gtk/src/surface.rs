//! GhosttyGlSurface — a GtkGLArea-based widget that hosts a ghostty terminal.
//!
//! This is the core rendering widget. It:
//! - Creates a GtkGLArea for OpenGL rendering
//! - Connects keyboard, mouse, scroll, and IME event controllers
//! - Forwards all events to the ghostty surface via FFI
//! - Manages the ghostty_surface_t lifecycle

use ghostty_sys::*;
use glib::translate::IntoGlib;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use std::cell::{Cell, RefCell};
use std::os::raw::{c_char, c_void};
use std::ptr;

use crate::keys;

// -----------------------------------------------------------------------
// GObject subclass for the GL surface widget
// -----------------------------------------------------------------------

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GhosttyGlSurface {
        pub(super) surface: Cell<ghostty_surface_t>,
        pub(super) app: Cell<ghostty_app_t>,
        pub(super) title: RefCell<String>,
        pub(super) im_context: RefCell<Option<gtk4::IMMulticontext>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GhosttyGlSurface {
        const NAME: &'static str = "GhosttyGlSurface";
        type Type = super::GhosttyGlSurface;
        type ParentType = gtk4::GLArea;
    }

    impl ObjectImpl for GhosttyGlSurface {
        fn constructed(&self) {
            self.parent_constructed();

            let gl_area = self.obj();
            gl_area.set_auto_render(false);
            gl_area.set_has_depth_buffer(false);
            gl_area.set_has_stencil_buffer(false);
            // Request OpenGL 4.3 (required by ghostty renderer)
            gl_area.set_required_version(4, 3);
            gl_area.set_focusable(true);
            gl_area.set_can_focus(true);

            // Set up IME context
            let im_context = gtk4::IMMulticontext::new();
            *self.im_context.borrow_mut() = Some(im_context);
        }

        fn dispose(&self) {
            let surface = self.surface.get();
            if !surface.is_null() {
                #[cfg(feature = "link-ghostty")]
                unsafe {
                    ghostty_surface_free(surface);
                }
                self.surface.set(ptr::null_mut());
            }
        }
    }

    impl WidgetImpl for GhosttyGlSurface {
        fn realize(&self) {
            self.parent_realize();
            let widget = self.obj();
            widget.make_current();
            if widget.error().is_some() {
                tracing::error!("Failed to make GL context current");
                return;
            }
            tracing::debug!("GhosttyGlSurface realized with GL context");
        }

        fn unrealize(&self) {
            self.parent_unrealize();
        }
    }

    impl GLAreaImpl for GhosttyGlSurface {
        fn render(&self, _context: &gdk4::GLContext) -> glib::Propagation {
            let surface = self.surface.get();
            if !surface.is_null() {
                #[cfg(feature = "link-ghostty")]
                unsafe {
                    ghostty_surface_draw(surface);
                }
            }
            glib::Propagation::Stop
        }

        fn resize(&self, width: i32, height: i32) {
            let surface = self.surface.get();
            if !surface.is_null() && width > 0 && height > 0 {
                #[cfg(feature = "link-ghostty")]
                unsafe {
                    ghostty_surface_set_size(surface, width as u32, height as u32);
                }
            }
        }
    }
}

glib::wrapper! {
    /// A GtkGLArea that renders a ghostty terminal surface.
    pub struct GhosttyGlSurface(ObjectSubclass<imp::GhosttyGlSurface>)
        @extends gtk4::GLArea, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl GhosttyGlSurface {
    /// Create a new terminal surface widget.
    pub fn new() -> Self {
        glib::Object::builder().build()
    }

    /// Initialize the ghostty surface with the given app.
    ///
    /// This creates the underlying `ghostty_surface_t` and connects all
    /// input event controllers.
    ///
    /// # Safety
    /// The `app` must be a valid ghostty_app_t that outlives this surface.
    pub fn initialize(
        &self,
        app: ghostty_app_t,
        working_directory: Option<&str>,
        command: Option<&str>,
    ) {
        let imp = self.imp();
        imp.app.set(app);

        self.setup_event_controllers();

        // Create the surface after the widget is realized
        let widget = self.clone();
        let wd = working_directory.map(|s| s.to_string());
        let cmd = command.map(|s| s.to_string());

        self.connect_realize(move |_| {
            widget.create_surface(app, wd.as_deref(), cmd.as_deref());
        });
    }

    fn create_surface(
        &self,
        app: ghostty_app_t,
        working_directory: Option<&str>,
        command: Option<&str>,
    ) {
        if app.is_null() {
            tracing::warn!("Cannot create surface: app is null (stub mode)");
            return;
        }

        #[cfg(feature = "link-ghostty")]
        {
            let mut config = unsafe { ghostty_surface_config_new() };

            // Set platform to Linux with our GtkGLArea
            config.platform_tag = ghostty_platform_e::GHOSTTY_PLATFORM_LINUX;
            config.platform = ghostty_platform_u {
                linux: ghostty_platform_linux_s {
                    gl_area: self.as_ptr() as *mut c_void,
                },
            };

            // Set scale factor
            config.scale_factor = self.scale_factor() as f64;

            // Set working directory
            let wd_cstr;
            if let Some(wd) = working_directory {
                wd_cstr = std::ffi::CString::new(wd).ok();
                config.working_directory =
                    wd_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr());
            }

            // Set command
            let cmd_cstr;
            if let Some(cmd) = command {
                cmd_cstr = std::ffi::CString::new(cmd).ok();
                config.command = cmd_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr());
            }

            config.context = ghostty_surface_context_e::GHOSTTY_SURFACE_CONTEXT_SPLIT;
            config.userdata = self.as_ptr() as *mut c_void;

            let surface = unsafe { ghostty_surface_new(app, &config) };
            if surface.is_null() {
                tracing::error!("ghostty_surface_new returned null");
                return;
            }

            self.imp().surface.set(surface);
            tracing::debug!("ghostty surface created successfully");
        }
    }

    fn setup_event_controllers(&self) {
        // Keyboard events
        let key_controller = gtk4::EventControllerKey::new();
        {
            let surface_widget = self.clone();
            key_controller.connect_key_pressed(move |controller, keyval, keycode, state| {
                surface_widget.on_key_event(
                    controller,
                    keyval.into_glib(),
                    keycode,
                    state,
                    ghostty_input_action_e::GHOSTTY_ACTION_PRESS,
                )
            });
        }
        {
            let surface_widget = self.clone();
            key_controller.connect_key_released(move |controller, keyval, keycode, state| {
                surface_widget.on_key_event(
                    controller,
                    keyval.into_glib(),
                    keycode,
                    state,
                    ghostty_input_action_e::GHOSTTY_ACTION_RELEASE,
                );
            });
        }
        self.add_controller(key_controller);

        // Mouse click events
        let click = gtk4::GestureClick::new();
        click.set_button(0); // All buttons
        {
            let surface_widget = self.clone();
            click.connect_pressed(move |gesture, _n_press, x, y| {
                let button = gesture.current_button();
                surface_widget.on_mouse_button(
                    button,
                    x,
                    y,
                    ghostty_input_mouse_state_e::GHOSTTY_MOUSE_PRESS,
                );
            });
        }
        {
            let surface_widget = self.clone();
            click.connect_released(move |gesture, _n_press, x, y| {
                let button = gesture.current_button();
                surface_widget.on_mouse_button(
                    button,
                    x,
                    y,
                    ghostty_input_mouse_state_e::GHOSTTY_MOUSE_RELEASE,
                );
            });
        }
        self.add_controller(click);

        // Mouse motion events
        let motion = gtk4::EventControllerMotion::new();
        {
            let surface_widget = self.clone();
            motion.connect_motion(move |_controller, x, y| {
                surface_widget.on_mouse_motion(x, y);
            });
        }
        self.add_controller(motion);

        // Scroll events
        let scroll = gtk4::EventControllerScroll::new(
            gtk4::EventControllerScrollFlags::BOTH_AXES
                | gtk4::EventControllerScrollFlags::DISCRETE,
        );
        {
            let surface_widget = self.clone();
            scroll.connect_scroll(move |_controller, dx, dy| {
                surface_widget.on_scroll(dx, dy);
                glib::Propagation::Stop
            });
        }
        self.add_controller(scroll);

        // Focus events
        let focus = gtk4::EventControllerFocus::new();
        {
            let surface_widget = self.clone();
            focus.connect_enter(move |_| {
                surface_widget.on_focus_change(true);
            });
        }
        {
            let surface_widget = self.clone();
            focus.connect_leave(move |_| {
                surface_widget.on_focus_change(false);
            });
        }
        self.add_controller(focus);
    }

    fn on_key_event(
        &self,
        _controller: &gtk4::EventControllerKey,
        keyval: u32,
        keycode: u32,
        state: gdk4::ModifierType,
        action: ghostty_input_action_e,
    ) -> glib::Propagation {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return glib::Propagation::Proceed;
        }

        let mods = keys::gdk_mods_to_ghostty(state);
        let ghostty_key = keys::gdk_keyval_to_ghostty(keyval)
            .unwrap_or(ghostty_input_key_e::GHOSTTY_KEY_UNIDENTIFIED);

        let key_event = ghostty_input_key_s {
            action,
            mods,
            consumed_mods: 0,
            keycode,
            text: ptr::null(),
            unshifted_codepoint: 0,
            composing: false,
        };

        #[cfg(feature = "link-ghostty")]
        {
            let handled = unsafe { ghostty_surface_key(surface, key_event) };
            if handled {
                return glib::Propagation::Stop;
            }
        }
        let _ = key_event;

        glib::Propagation::Proceed
    }

    fn on_mouse_button(
        &self,
        button: u32,
        _x: f64,
        _y: f64,
        state: ghostty_input_mouse_state_e,
    ) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        let ghostty_button = keys::gdk_button_to_ghostty(button);

        #[cfg(feature = "link-ghostty")]
        unsafe {
            ghostty_surface_mouse_button(surface, state, ghostty_button, 0);
        }
        let _ = (state, ghostty_button);
    }

    fn on_mouse_motion(&self, x: f64, y: f64) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        unsafe {
            ghostty_surface_mouse_pos(surface, x, y, 0);
        }
        let _ = (x, y);
    }

    fn on_scroll(&self, dx: f64, dy: f64) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        unsafe {
            ghostty_surface_mouse_scroll(surface, dx, dy, 0);
        }
        let _ = (dx, dy);
    }

    fn on_focus_change(&self, focused: bool) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        unsafe {
            ghostty_surface_set_focus(surface, focused);
        }
        let _ = focused;
    }

    /// Get the raw ghostty surface pointer.
    pub fn raw_surface(&self) -> ghostty_surface_t {
        self.imp().surface.get()
    }

    /// Request the surface to refresh its rendering.
    pub fn refresh(&self) {
        let surface = self.imp().surface.get();
        if !surface.is_null() {
            #[cfg(feature = "link-ghostty")]
            unsafe {
                ghostty_surface_refresh(surface);
            }
        }
        self.queue_render();
    }

    /// Send text input to the terminal (e.g., from IME commit).
    pub fn send_text(&self, text: &str) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        {
            let Ok(cstr) = std::ffi::CString::new(text) else {
                // Text contains NUL bytes — split on NUL and send each segment
                for segment in text.split('\0') {
                    if segment.is_empty() {
                        continue;
                    }
                    if let Ok(c) = std::ffi::CString::new(segment) {
                        unsafe {
                            ghostty_surface_text(surface, c.as_ptr(), segment.len());
                        }
                    }
                }
                return;
            };
            unsafe {
                ghostty_surface_text(surface, cstr.as_ptr(), text.len());
            }
        }
        let _ = text;
    }

    /// Set the current title (called from action callback).
    pub fn set_title(&self, title: &str) {
        *self.imp().title.borrow_mut() = title.to_string();
    }

    /// Get the current title.
    pub fn title(&self) -> String {
        self.imp().title.borrow().clone()
    }

    /// Request the surface to close.
    pub fn request_close(&self) {
        let surface = self.imp().surface.get();
        if !surface.is_null() {
            #[cfg(feature = "link-ghostty")]
            unsafe {
                ghostty_surface_request_close(surface);
            }
        }
    }

    /// Check if the process has exited.
    pub fn process_exited(&self) -> bool {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return true;
        }
        #[cfg(feature = "link-ghostty")]
        {
            unsafe { ghostty_surface_process_exited(surface) }
        }
        #[cfg(not(feature = "link-ghostty"))]
        false
    }

    /// Get the surface size info.
    pub fn surface_size(&self) -> Option<ghostty_surface_size_s> {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return None;
        }
        #[cfg(feature = "link-ghostty")]
        {
            Some(unsafe { ghostty_surface_size(surface) })
        }
        #[cfg(not(feature = "link-ghostty"))]
        None
    }
}

impl Default for GhosttyGlSurface {
    fn default() -> Self {
        Self::new()
    }
}
