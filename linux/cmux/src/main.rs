mod app;
mod model;
mod notifications;
#[allow(dead_code)] // Phase 5: session persistence
mod session;
mod socket;
mod ui;

use tracing_subscriber::EnvFilter;

fn main() {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    tracing::info!("cmux starting");

    // Initialize ghostty runtime
    if let Err(e) = ghostty_gtk::app::GhosttyApp::init() {
        tracing::error!("Failed to initialize ghostty: {}", e);
        std::process::exit(1);
    }

    // Run the GTK application
    let exit_code = app::run();
    std::process::exit(exit_code);
}
