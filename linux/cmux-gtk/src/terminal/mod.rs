//! GTK terminal surface integration backed by VTE.

use cmux_core::terminal::{TerminalCommand, TerminalSession};
use gtk::prelude::*;
use vte4::{prelude::*, PtyFlags};

pub fn terminal(session: &TerminalSession) -> gtk::Widget {
    let terminal = vte4::Terminal::new();
    terminal.set_hexpand(true);
    terminal.set_vexpand(true);
    terminal.set_scrollback_lines(10_000);
    terminal.set_scroll_on_output(false);
    terminal.set_scroll_on_keystroke(true);

    spawn_shell(&terminal, &session.command);

    terminal.upcast()
}

fn spawn_shell(terminal: &vte4::Terminal, command: &TerminalCommand) {
    let mut argv = Vec::with_capacity(command.args.len() + 1);
    argv.push(command.program.as_str());
    argv.extend(command.args.iter().map(String::as_str));

    let working_directory = command
        .working_directory
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());

    terminal.spawn_async(
        PtyFlags::DEFAULT,
        working_directory.as_deref(),
        &argv,
        &[],
        glib::SpawnFlags::DEFAULT,
        || {},
        -1,
        None::<&gio::Cancellable>,
        |result| {
            if let Err(error) = result {
                eprintln!("failed to spawn terminal shell: {error}");
            }
        },
    );
}
