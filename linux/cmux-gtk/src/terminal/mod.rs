//! GTK terminal surface integration.
//!
//! The first Linux milestone uses this placeholder so the GTK shell can land
//! independently from the VTE-backed PTY implementation. The next PR should
//! replace this with a `vte4::Terminal` widget that spawns `TerminalCommand`.

use cmux_core::terminal::TerminalSession;
use gtk::prelude::*;

pub fn placeholder(session: &TerminalSession) -> gtk::Widget {
    let label = gtk::Label::new(Some(&format!(
        "Terminal placeholder for {}\\n{}",
        session.title, session.command.program
    )));
    label.set_hexpand(true);
    label.set_vexpand(true);
    label.upcast()
}
