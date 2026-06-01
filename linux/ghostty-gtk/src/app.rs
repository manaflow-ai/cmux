//! Safe wrapper around ghostty_app_t lifecycle.

use ghostty_sys::*;
use std::ptr;

use crate::callbacks::RuntimeCallbacks;

/// Manages the lifecycle of a ghostty application instance.
///
/// The GhosttyApp owns the `ghostty_app_t` and `ghostty_config_t` and ensures
/// they are properly freed on drop.
pub struct GhosttyApp {
    app: ghostty_app_t,
    config: ghostty_config_t,
    /// Prevent Send — ghostty_app_t is not thread-safe
    _not_send: std::marker::PhantomData<*mut ()>,
}

impl GhosttyApp {
    /// Initialize the ghostty runtime. Must be called once before any other API.
    ///
    /// # Safety
    /// This calls into the C FFI. Should only be called once per process.
    #[cfg(feature = "link-ghostty")]
    pub fn init() -> Result<(), String> {
        configure_bundled_resources_dir();
        let ret = unsafe { ghostty_init(0, ptr::null_mut()) };
        if ret != GHOSTTY_SUCCESS {
            return Err(format!("ghostty_init failed with code {}", ret));
        }
        Ok(())
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn init() -> Result<(), String> {
        tracing::warn!("ghostty not linked — running in stub mode");
        Ok(())
    }

    /// Create a new GhosttyApp with the given runtime callbacks.
    ///
    /// # Safety
    /// The `callbacks` must remain valid for the lifetime of this app.
    #[cfg(feature = "link-ghostty")]
    pub fn new(callbacks: &RuntimeCallbacks) -> Result<Self, String> {
        let config = unsafe { ghostty_config_new() };
        if config.is_null() {
            return Err("ghostty_config_new returned null".into());
        }

        unsafe {
            ghostty_config_load_default_files(config);
            ghostty_config_load_recursive_files(config);
            ghostty_config_finalize(config);
        }

        // Check for config diagnostics
        let diag_count = unsafe { ghostty_config_diagnostics_count(config) };
        for i in 0..diag_count {
            let diag = unsafe { ghostty_config_get_diagnostic(config, i) };
            if diag.message.is_null() {
                tracing::warn!("ghostty config diagnostic: (null message)");
                continue;
            }
            let msg = unsafe { std::ffi::CStr::from_ptr(diag.message) };
            tracing::warn!("ghostty config diagnostic: {:?}", msg);
        }

        let runtime_config = callbacks.as_raw();
        let app = unsafe { ghostty_app_new(&runtime_config, config) };
        if app.is_null() {
            unsafe { ghostty_config_free(config) };
            return Err("ghostty_app_new returned null".into());
        }

        Ok(Self {
            app,
            config,
            _not_send: std::marker::PhantomData,
        })
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn new(_callbacks: &RuntimeCallbacks) -> Result<Self, String> {
        Ok(Self {
            app: ptr::null_mut(),
            config: ptr::null_mut(),
            _not_send: std::marker::PhantomData,
        })
    }

    /// Process pending events. Should be called from `glib::idle_add` wakeup.
    #[cfg(feature = "link-ghostty")]
    pub fn tick(&self) {
        unsafe { ghostty_app_tick(self.app) };
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn tick(&self) {}

    /// Get the raw app pointer for FFI calls.
    pub fn raw(&self) -> ghostty_app_t {
        self.app
    }

    /// Notify ghostty that the app focus state changed.
    #[cfg(feature = "link-ghostty")]
    pub fn set_focus(&self, focused: bool) {
        unsafe { ghostty_app_set_focus(self.app, focused) };
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn set_focus(&self, _focused: bool) {}

    /// Set the system color scheme (light/dark).
    #[cfg(feature = "link-ghostty")]
    pub fn set_color_scheme(&self, scheme: ghostty_color_scheme_e) {
        unsafe { ghostty_app_set_color_scheme(self.app, scheme) };
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn set_color_scheme(&self, _scheme: ghostty_color_scheme_e) {}

    /// Check if any surfaces need confirmation before quitting.
    #[cfg(feature = "link-ghostty")]
    pub fn needs_confirm_quit(&self) -> bool {
        unsafe { ghostty_app_needs_confirm_quit(self.app) }
    }

    #[cfg(not(feature = "link-ghostty"))]
    pub fn needs_confirm_quit(&self) -> bool {
        false
    }

    /// Get the config handle for creating surfaces with inherited config.
    pub fn config(&self) -> ghostty_config_t {
        self.config
    }
}

#[cfg(feature = "link-ghostty")]
fn configure_bundled_resources_dir() {
    const KEY: &str = "GHOSTTY_RESOURCES_DIR";

    if std::env::var_os(KEY).is_some() {
        return;
    }

    let Some(dir) = ghostty_sys::bundled_resources_dir() else {
        return;
    };

    if std::path::Path::new(dir).exists() {
        std::env::set_var(KEY, dir);
        tracing::info!(
            resources_dir = dir,
            "Configured bundled Ghostty resources dir"
        );
    }
}

impl Drop for GhosttyApp {
    fn drop(&mut self) {
        #[cfg(feature = "link-ghostty")]
        unsafe {
            if !self.app.is_null() {
                ghostty_app_free(self.app);
            }
            if !self.config.is_null() {
                ghostty_config_free(self.config);
            }
        }
    }
}
