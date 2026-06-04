mod app;
mod model;
mod notifications;
mod session;
mod socket;
mod ui;

use tracing_subscriber::EnvFilter;

fn main() {
    configure_gdk_environment();

    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    tracing::info!("cmux starting");

    // Run the GTK application
    let exit_code = app::run();
    std::process::exit(exit_code);
}

fn configure_gdk_environment() {
    // Match vanilla Ghostty's GDK environment setup.
    // Ghostty's renderer requires desktop OpenGL (not GLES) and doesn't use Vulkan.
    // GTK's fractional scaling for GL can cause blurry/oversized text.
    //
    // GTK >=4.16 splits GDK_DEBUG into GDK_DEBUG + GDK_DISABLE.
    // GTK 4.14-4.15 uses GDK_DEBUG for everything.
    // Setting both is safe — unknown flags are silently ignored.

    // GDK_DEBUG: disable GLES fallback, Vulkan, and fractional GL scaling.
    // gl-no-fractional prevents GTK from using fractional scaling on GL surfaces,
    // which can cause blurry or oversized text. Removed upstream in GTK 4.17.5
    // but safe to set on all versions (ignored if unknown).
    append_env_flags("GDK_DEBUG", &["gl-disable-gles", "vulkan-disable", "gl-no-fractional"]);

    // GDK_DISABLE: hard-disable GLES API, Vulkan, and color management (GTK >=4.16).
    // GTK's color management implementation can distort terminal colors;
    // vanilla Ghostty disables it on GTK <4.18. Safe to set on all versions.
    append_env_flags("GDK_DISABLE", &["gles-api", "vulkan", "color-mgmt"]);
}

fn append_env_flags(var: &str, flags: &[&str]) {
    let existing = std::env::var(var).unwrap_or_default();
    let existing_set: std::collections::HashSet<&str> =
        existing.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();

    let mut combined: Vec<&str> = existing.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
    for flag in flags {
        if !existing_set.contains(flag) {
            combined.push(flag);
        }
    }

    if !combined.is_empty() {
        std::env::set_var(var, combined.join(","));
    }
}
