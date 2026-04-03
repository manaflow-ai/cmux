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
use std::os::raw::c_char;
use std::os::raw::c_void;
use std::ptr;
use std::rc::Rc;

pub use uuid::Uuid;

use crate::callbacks::ClipboardContent;
use crate::keys;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum ImeKeyEventState {
    #[default]
    Idle,
    NotComposing,
    Composing,
}

fn cstring_input(text: &str, context: &'static str) -> Option<std::ffi::CString> {
    match std::ffi::CString::new(text) {
        Ok(cstr) => Some(cstr),
        Err(_) => {
            tracing::warn!("Ignoring {} containing interior NUL", context);
            None
        }
    }
}

// Minimal GL bindings for viewport setup.
// GtkGLArea does NOT set glViewport before emitting the render signal,
// but ghostty's renderer reads GL_VIEWPORT to determine the surface size.
#[cfg(feature = "link-ghostty")]
mod gl_raw {
    pub type GLint = i32;
    pub type GLsizei = i32;

    #[link(name = "GL")]
    extern "C" {
        pub fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei);
    }
}

// -----------------------------------------------------------------------
// GObject subclass for the GL surface widget
// -----------------------------------------------------------------------

/// Shared GL context across all GhosttyGlSurface instances.
///
/// When the UI layout is rebuilt (e.g., on split), GtkGLArea widgets are
/// unrealized and re-realized. Each realization normally creates a NEW GL
/// context, but OpenGL FBOs and VAOs are per-context objects. Ghostty's
/// renderer creates FBOs/VAOs during surface init, so they become invalid
/// in the new context and the surface can't render.
///
/// By sharing a single GL context across all surfaces, we ensure that all
/// GL objects remain valid even after unrealize/re-realize cycles.
/// GtkGLArea's unrealize drops its reference to the context, but our
/// global reference keeps the context alive.
thread_local! {
    static SHARED_GL_CONTEXT: RefCell<Option<gdk4::GLContext>> = const { RefCell::new(None) };
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GhosttyGlSurface {
        pub(super) surface: Cell<ghostty_surface_t>,
        pub(super) app: Cell<ghostty_app_t>,
        pub(super) panel_id: Cell<Option<super::Uuid>>,
        pub(super) callback_userdata: RefCell<Option<Box<crate::callbacks::SurfaceUserdata>>>,
        pub(super) pending_text: RefCell<Vec<String>>,
        pub(super) title: RefCell<String>,
        pub(super) im_context: RefCell<Option<gtk4::IMMulticontext>>,
        pub(super) im_composing: Cell<bool>,
        pub(super) in_keyevent: Cell<ImeKeyEventState>,
        pub(super) im_commit_text: RefCell<Vec<u8>>,
        pub(super) close_handler: RefCell<Option<Rc<dyn Fn(bool)>>>,
        pub(super) focused: Cell<bool>,
        pub(super) focus_idle_queued: Cell<bool>,
        pub(super) focus_restore_armed: Cell<bool>,
        pub(super) focus_disarm_source: RefCell<Option<glib::SourceId>>,
        pub(super) resize_focus_restore_source: RefCell<Option<glib::SourceId>>,
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
            // Match Ghostty's GTK surface behavior so resizes and renderer-driven
            // invalidations can produce fresh frames without our own manual loop.
            gl_area.set_auto_render(true);
            gl_area.set_has_depth_buffer(false);
            gl_area.set_has_stencil_buffer(false);
            // Request OpenGL 4.3 (required by ghostty renderer)
            gl_area.set_required_version(4, 3);
            gl_area.set_focusable(true);
            gl_area.set_can_focus(true);

            // Set up IME context
            let im_context = gtk4::IMMulticontext::new();
            *self.im_context.borrow_mut() = Some(im_context);
            gl_area.setup_ime();
        }

        fn dispose(&self) {
            if let Some(source) = self.focus_disarm_source.borrow_mut().take() {
                source.remove();
            }
            if let Some(source) = self.resize_focus_restore_source.borrow_mut().take() {
                source.remove();
            }
            if let Some(im_context) = self.im_context.borrow().as_ref() {
                im_context.set_client_widget(Option::<&gtk4::Widget>::None);
            }

            let surface = self.surface.get();
            if !surface.is_null() {
                #[cfg(feature = "link-ghostty")]
                unsafe {
                    ghostty_surface_free(surface);
                }
                self.surface.set(ptr::null_mut());
            }
            self.callback_userdata.borrow_mut().take();
            self.close_handler.borrow_mut().take();
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
        }

        fn unrealize(&self) {
            self.parent_unrealize();
        }
    }

    impl GLAreaImpl for GhosttyGlSurface {
        fn create_context(&self) -> Option<gdk4::GLContext> {
            use gdk4::prelude::GLContextExt;
            use gtk4::prelude::NativeExt;

            // Return the shared context if it exists and is still valid.
            let existing = super::SHARED_GL_CONTEXT.with(|cell| cell.borrow().clone());
            if let Some(ctx) = existing {
                return Some(ctx);
            }

            // First surface — create the shared context.
            let widget = self.obj();
            let native = widget.native()?;
            let surface = native.surface()?;
            match surface.create_gl_context() {
                Ok(ctx) => {
                    // Force desktop OpenGL (not GLES) and require 4.3 core profile
                    ctx.set_use_es(0); // 0 = desktop GL, not GLES
                    ctx.set_required_version(4, 3);

                    // Store for reuse by all future surfaces.
                    super::SHARED_GL_CONTEXT.with(|cell| {
                        *cell.borrow_mut() = Some(ctx.clone());
                    });

                    Some(ctx)
                }
                Err(e) => {
                    tracing::error!("Failed to create GL context: {}", e);
                    None
                }
            }
        }

        fn render(&self, _context: &gdk4::GLContext) -> glib::Propagation {
            let surface = self.surface.get();
            if !surface.is_null() {
                #[cfg(feature = "link-ghostty")]
                unsafe {
                    let widget = self.obj();
                    let scale = widget.scale_factor();
                    let w = widget.width() * scale;
                    let h = widget.height() * scale;

                    // Ensure ghostty's internal surface size matches the
                    // actual widget dimensions. The initial GtkGLArea resize
                    // signal fires before the ghostty surface exists, so we
                    // must always sync the size here.
                    ghostty_surface_set_content_scale(surface, scale as f64, scale as f64);
                    ghostty_surface_set_size(surface, w as u32, h as u32);

                    // GtkGLArea does NOT set glViewport before the render signal.
                    // Ghostty's renderer reads GL_VIEWPORT via surfaceSize() to
                    // determine the render area. We must set it here.
                    gl_raw::glViewport(0, 0, w, h);

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
                    let scale = self.obj().scale_factor();
                    let width_px = width.saturating_mul(scale) as u32;
                    let height_px = height.saturating_mul(scale) as u32;
                    let scale = scale as f64;
                    ghostty_surface_set_content_scale(surface, scale, scale);
                    ghostty_surface_set_size(surface, width_px, height_px);
                }

                self.obj().schedule_resize_focus_restore();
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

        self.connect_realize(move |w| {
            widget.create_surface(app, wd.as_deref(), cmd.as_deref());
            // Grab focus so keyboard events go to this terminal
            w.grab_focus();
        });
    }

    fn create_surface(
        &self,
        app: ghostty_app_t,
        _working_directory: Option<&str>,
        _command: Option<&str>,
    ) {
        if app.is_null() {
            tracing::warn!("Cannot create surface: app is null (stub mode)");
            return;
        }

        if !self.imp().surface.get().is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        {
            let mut config = unsafe { ghostty_surface_config_new() };
            let callback_userdata = Box::new(crate::callbacks::SurfaceUserdata::new(self));

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
            if let Some(wd) = _working_directory {
                wd_cstr = std::ffi::CString::new(wd).ok();
                config.working_directory = wd_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr());
            }

            // Set command
            let cmd_cstr;
            if let Some(cmd) = _command {
                cmd_cstr = std::ffi::CString::new(cmd).ok();
                config.command = cmd_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr());
            }

            config.context = ghostty_surface_context_e::GHOSTTY_SURFACE_CONTEXT_SPLIT;
            config.userdata =
                (&*callback_userdata as *const crate::callbacks::SurfaceUserdata) as *mut c_void;

            let surface = unsafe { ghostty_surface_new(app, &config) };
            if surface.is_null() {
                tracing::error!("ghostty_surface_new returned null");
                return;
            }

            tracing::info!(
                ?surface,
                scale_factor = config.scale_factor,
                "ghostty surface created successfully"
            );

            *self.imp().callback_userdata.borrow_mut() = Some(callback_userdata);
            self.imp().surface.set(surface);

            self.flush_pending_text();
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
                // Grab focus on click so key events go to this widget
                surface_widget.grab_focus();
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
        controller: &gtk4::EventControllerKey,
        keyval: u32,
        keycode: u32,
        state: gdk4::ModifierType,
        action: ghostty_input_action_e,
    ) -> glib::Propagation {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return glib::Propagation::Proceed;
        }

        let was_composing = self.imp().im_composing.get();
        if action == ghostty_input_action_e::GHOSTTY_ACTION_PRESS {
            if let Some(im_context) = self.imp().im_context.borrow().as_ref() {
                if let Some(event) = controller.current_event() {
                    self.update_ime_cursor_location();
                    self.imp().in_keyevent.set(if was_composing {
                        ImeKeyEventState::Composing
                    } else {
                        ImeKeyEventState::NotComposing
                    });
                    let ime_handled = im_context.filter_keypress(&event);
                    self.imp().in_keyevent.set(ImeKeyEventState::Idle);

                    if ime_handled {
                        let is_composing = self.imp().im_composing.get();
                        let has_committed_text =
                            !self.imp().im_commit_text.borrow().is_empty();
                        if is_composing || was_composing {
                            return glib::Propagation::Stop;
                        }
                        // IME claimed "handled" but we weren't composing.
                        // If it committed text, fall through so ghostty
                        // associates it with this key event (normal typing).
                        // If it committed nothing, the IME just observed the
                        // key (e.g. kime checking for hangul toggle) — fall
                        // through so ghostty still processes the key.
                    }
                }
            }
        }

        let mods = keys::gdk_mods_to_ghostty(state);

        // Convert keyval to a GDK Key for unicode conversion
        let key: gdk4::Key = unsafe { glib::translate::from_glib(keyval) };

        let committed_text = {
            let mut text = self.imp().im_commit_text.borrow_mut();
            std::mem::take(&mut *text)
        };

        let mut text_buf = [0u8; 8];
        let text_cstr;
        let committed_text_cstr;
        let text_ptr = if !committed_text.is_empty() {
            match std::ffi::CString::new(committed_text) {
                Ok(cstr) => {
                    committed_text_cstr = cstr;
                    committed_text_cstr.as_ptr()
                }
                Err(_) => {
                    tracing::warn!("Ignoring IME commit containing interior NUL");
                    ptr::null()
                }
            }
        } else if action == ghostty_input_action_e::GHOSTTY_ACTION_PRESS {
            if let Some(ch) = key.to_unicode() {
                if ch >= '\x20' {
                    let len = ch.encode_utf8(&mut text_buf).len();
                    text_buf[len] = 0;
                    text_cstr = &text_buf[..=len];
                    text_cstr.as_ptr() as *const c_char
                } else {
                    ptr::null()
                }
            } else {
                ptr::null()
            }
        } else {
            ptr::null()
        };

        // Consumed modifiers: modifiers that were used by the keymap to
        // produce the keyval (e.g. Shift is consumed when turning `;` into `:`).
        // Without this, ghostty sees Shift+`:` instead of just `:`.
        let consumed_mods = controller
            .current_event()
            .and_then(|ev| ev.downcast_ref::<gdk4::KeyEvent>().map(|ke| {
                keys::gdk_mods_to_ghostty(ke.consumed_modifiers())
            }))
            .unwrap_or(0);

        // Unshifted codepoint: the unicode value of the key without Shift.
        // Translate the hardware keycode with no modifiers but preserving the
        // keyboard group (layout) from the current event.
        let unshifted_codepoint = {
            let display = self.display();
            let group = controller
                .current_event()
                .and_then(|ev| ev.downcast_ref::<gdk4::KeyEvent>().map(|ke| ke.layout() as i32))
                .unwrap_or(0);
            if let Some((unshifted_key, _, _, _)) =
                display.translate_key(keycode, gdk4::ModifierType::empty(), group)
            {
                unshifted_key.to_unicode().map(|c| c as u32).unwrap_or(0)
            } else {
                key.to_lower().to_unicode().map(|c| c as u32).unwrap_or(0)
            }
        };

        let key_event = ghostty_input_key_s {
            action,
            mods,
            consumed_mods,
            keycode,
            text: text_ptr,
            unshifted_codepoint,
            composing: self.imp().im_composing.get(),
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

    fn on_mouse_button(&self, button: u32, _x: f64, _y: f64, state: ghostty_input_mouse_state_e) {
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
            // Ghostty expects positive deltas for up/right and negative for
            // down/left. GTK delivers the inverse "natural scrolling" sign.
            ghostty_surface_mouse_scroll(surface, -dx, -dy, 0);
        }
        let _ = (dx, dy);
    }

    fn on_focus_change(&self, focused: bool) {
        self.imp().focused.set(focused);
        let surface = self.imp().surface.get();
        if let Some(im_context) = self.imp().im_context.borrow().as_ref() {
            if focused {
                im_context.focus_in();
                self.update_ime_cursor_location();
            } else {
                self.imp().im_composing.set(false);
                self.imp().im_commit_text.borrow_mut().clear();
                im_context.focus_out();
                im_context.reset();
                self.update_preedit("");
            }
        }

        if focused {
            self.cancel_focus_disarm();
            self.imp().focus_restore_armed.set(true);
        } else {
            self.schedule_focus_disarm();
        }

        if surface.is_null() || self.imp().focus_idle_queued.replace(true) {
            return;
        }

        let surface_widget = self.clone();
        glib::idle_add_local_once(move || {
            let imp = surface_widget.imp();
            imp.focus_idle_queued.set(false);

            let surface = imp.surface.get();
            if surface.is_null() {
                return;
            }

            #[cfg(feature = "link-ghostty")]
            unsafe {
                ghostty_surface_set_focus(surface, imp.focused.get());
            }
        });
    }

    fn schedule_focus_disarm(&self) {
        self.cancel_focus_disarm();

        let surface_widget = self.clone();
        let source =
            glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
                surface_widget.imp().focus_disarm_source.borrow_mut().take();
                if !surface_widget.imp().focused.get() {
                    surface_widget.imp().focus_restore_armed.set(false);
                }
            });
        *self.imp().focus_disarm_source.borrow_mut() = Some(source);
    }

    fn cancel_focus_disarm(&self) {
        if let Some(source) = self.imp().focus_disarm_source.borrow_mut().take() {
            source.remove();
        }
    }

    fn schedule_resize_focus_restore(&self) {
        if !self.imp().focus_restore_armed.get() {
            return;
        }

        self.cancel_focus_disarm();

        if let Some(source) = self.imp().resize_focus_restore_source.borrow_mut().take() {
            source.remove();
        }

        let surface_widget = self.clone();
        let source =
            glib::timeout_add_local_once(std::time::Duration::from_millis(150), move || {
                surface_widget
                    .imp()
                    .resize_focus_restore_source
                    .borrow_mut()
                    .take();

                if !surface_widget.imp().focused.get() {
                    let _ = surface_widget.grab_focus();
                }
            });
        *self.imp().resize_focus_restore_source.borrow_mut() = Some(source);
    }

    /// Set the panel ID for this surface (for reverse lookup in callbacks).
    pub fn set_panel_id(&self, id: Uuid) {
        self.imp().panel_id.set(Some(id));
    }

    /// Get the panel ID associated with this surface.
    pub fn panel_id(&self) -> Option<Uuid> {
        self.imp().panel_id.get()
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

    fn write_text(&self, surface: ghostty_surface_t, text: &str) -> bool {
        #[cfg(feature = "link-ghostty")]
        {
            let Some(cstr) = cstring_input(text, "terminal text input") else {
                return false;
            };
            unsafe {
                ghostty_surface_text(surface, cstr.as_ptr(), text.len());
            }
        }
        let _ = (surface, text);
        true
    }

    fn flush_pending_text(&self) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        let pending = std::mem::take(&mut *self.imp().pending_text.borrow_mut());
        for text in pending {
            let _ = self.write_text(surface, &text);
        }
    }

    /// Send text input to the terminal (e.g., from IME commit).
    pub fn send_text(&self, text: &str) -> bool {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            self.imp().pending_text.borrow_mut().push(text.to_string());
            return true;
        }

        self.write_text(surface, text)
    }

    pub fn read_clipboard_request(&self, clipboard: ghostty_clipboard_e, context: *mut c_void) {
        let clipboard = self.clipboard_for_kind(clipboard);
        let surface = self.clone();
        let context = SendPtr(context);
        clipboard.read_text_async(None::<&gtk4::gio::Cancellable>, move |result| {
            let text = match result {
                Ok(Some(text)) => text.to_string(),
                Ok(None) => String::new(),
                Err(err) => {
                    tracing::warn!("Failed to read clipboard text: {}", err);
                    String::new()
                }
            };

            surface.complete_clipboard_request(&text, context.0, false);
        });
    }

    pub fn confirm_clipboard_read(
        &self,
        content: &str,
        context: *mut c_void,
        request: ghostty_clipboard_request_e,
    ) {
        tracing::warn!(
            ?request,
            "Auto-confirming Ghostty clipboard request in embedded host"
        );
        self.complete_clipboard_request(content, context, true);
    }

    pub fn write_clipboard(
        &self,
        clipboard: ghostty_clipboard_e,
        content: &[ClipboardContent],
        _confirm: bool,
    ) {
        let clipboard = self.clipboard_for_kind(clipboard);
        if let Some(text) = content
            .iter()
            .find_map(
                |entry| match (entry.mime.as_deref(), entry.data.as_deref()) {
                    (Some("text/plain"), Some(text)) => Some(text),
                    _ => None,
                },
            )
            .or_else(|| content.iter().find_map(|entry| entry.data.as_deref()))
        {
            clipboard.set_text(text);
        }
    }

    pub fn set_close_handler<F>(&self, handler: F)
    where
        F: Fn(bool) + 'static,
    {
        *self.imp().close_handler.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn close_requested(&self, process_alive: bool) {
        tracing::debug!(process_alive, "ghostty requested surface close");
        let handler = self.imp().close_handler.borrow().clone();
        if let Some(handler) = handler {
            handler(process_alive);
        }
    }

    fn setup_ime(&self) {
        let Some(im_context) = self.imp().im_context.borrow().as_ref().cloned() else {
            return;
        };

        im_context.set_client_widget(Some(self));
        im_context.set_use_preedit(true);

        let surface_widget = self.clone();
        im_context.connect_preedit_start(move |_context| {
            surface_widget.im_preedit_start();
        });

        let surface_widget = self.clone();
        im_context.connect_commit(move |_context, text| {
            surface_widget.im_commit(text);
        });

        let surface_widget = self.clone();
        im_context.connect_preedit_changed(move |context| {
            surface_widget.im_preedit_changed(context);
        });

        let surface_widget = self.clone();
        im_context.connect_preedit_end(move |_context| {
            surface_widget.im_preedit_end();
        });
    }

    fn im_preedit_start(&self) {
        self.imp().im_composing.set(true);
        self.imp().im_commit_text.borrow_mut().clear();
    }

    fn im_preedit_changed(&self, context: &gtk4::IMMulticontext) {
        self.imp().im_composing.set(true);
        let (text, _attrs, _cursor_pos) = context.preedit_string();
        self.update_preedit(text.as_str());
        self.update_ime_cursor_location();
    }

    fn im_preedit_end(&self) {
        self.imp().im_composing.set(false);
        self.update_preedit("");
    }

    fn im_commit(&self, text: &str) {
        match self.imp().in_keyevent.get() {
            ImeKeyEventState::NotComposing => {
                let mut committed = self.imp().im_commit_text.borrow_mut();
                committed.clear();
                committed.extend_from_slice(text.as_bytes());
            }
            ImeKeyEventState::Composing | ImeKeyEventState::Idle => {
                self.imp().im_composing.set(false);
                self.update_preedit("");
                self.send_text_as_key(text);
            }
        }
    }

    fn send_text_as_key(&self, text: &str) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(not(feature = "link-ghostty"))]
        let _ = text;

        let Some(cstr) = cstring_input(text, "IME commit") else {
            return;
        };

        #[cfg(feature = "link-ghostty")]
        unsafe {
            let event = ghostty_input_key_s {
                action: ghostty_input_action_e::GHOSTTY_ACTION_PRESS,
                mods: 0,
                consumed_mods: 0,
                keycode: 0,
                text: cstr.as_ptr(),
                unshifted_codepoint: 0,
                composing: false,
            };
            let _ = ghostty_surface_key(surface, event);
        }

        #[cfg(not(feature = "link-ghostty"))]
        let _ = cstr;
    }

    fn update_preedit(&self, text: &str) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        {
            let Some(cstr) = cstring_input(text, "IME preedit") else {
                return;
            };

            unsafe {
                ghostty_surface_preedit(surface, cstr.as_ptr(), text.len());
            }
        }
        let _ = text;
    }

    fn update_ime_cursor_location(&self) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        unsafe {
            let Some(im_context) = self.imp().im_context.borrow().as_ref().cloned() else {
                return;
            };

            let mut x = 0.0;
            let mut y = 0.0;
            let mut w = 0.0;
            let mut h = 0.0;
            ghostty_surface_ime_point(surface, &mut x, &mut y, &mut w, &mut h);
            let rect = gdk4::Rectangle::new(
                x.round() as i32,
                y.round() as i32,
                w.max(1.0).round() as i32,
                h.max(1.0).round() as i32,
            );
            im_context.set_cursor_location(&rect);
        }
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

    fn clipboard_for_kind(&self, clipboard: ghostty_clipboard_e) -> gdk4::Clipboard {
        match clipboard {
            ghostty_clipboard_e::GHOSTTY_CLIPBOARD_SELECTION => self.primary_clipboard(),
            _ => self.clipboard(),
        }
    }

    fn complete_clipboard_request(&self, text: &str, context: *mut c_void, confirmed: bool) {
        let surface = self.imp().surface.get();
        if surface.is_null() {
            return;
        }

        #[cfg(feature = "link-ghostty")]
        {
            let Some(cstr) = cstring_input(text, "clipboard request") else {
                return;
            };

            unsafe {
                ghostty_surface_complete_clipboard_request(
                    surface,
                    cstr.as_ptr(),
                    context,
                    confirmed,
                );
            }
        }
        #[cfg(not(feature = "link-ghostty"))]
        let _ = (text, context, confirmed);
    }
}

#[derive(Clone, Copy)]
struct SendPtr(*mut c_void);

unsafe impl Send for SendPtr {}

#[cfg(test)]
mod tests {
    use super::cstring_input;

    #[test]
    fn cstring_input_accepts_valid_text() {
        assert!(cstring_input("hello", "test").is_some());
    }

    #[test]
    fn cstring_input_rejects_interior_nul() {
        assert!(cstring_input("hel\0lo", "test").is_none());
    }
}

impl Default for GhosttyGlSurface {
    fn default() -> Self {
        Self::new()
    }
}
