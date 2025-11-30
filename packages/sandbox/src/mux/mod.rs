pub mod character;
pub mod commands;
pub mod events;
pub mod grid;
pub mod layout;
pub mod palette;
pub mod runner;
pub mod sidebar;
pub mod state;
pub mod terminal;
pub mod ui;

pub use runner::run_mux_tui;
