mod app;
mod model;
mod notifications;
mod session;
mod socket;
mod ui;

use tracing_subscriber::EnvFilter;

fn main() {
    prefer_desktop_opengl();

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

fn prefer_desktop_opengl() {
    const FLAG: &str = "gl-prefer-gl";
    match std::env::var("GDK_DEBUG") {
        Ok(existing) if existing.split(',').any(|flag| flag.trim() == FLAG) => {}
        Ok(existing) if existing.trim().is_empty() => std::env::set_var("GDK_DEBUG", FLAG),
        Ok(existing) => std::env::set_var("GDK_DEBUG", format!("{existing},{FLAG}")),
        Err(_) => std::env::set_var("GDK_DEBUG", FLAG),
    }
}
