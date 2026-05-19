mod notifications;
mod terminal;

use adw::prelude::*;
use cmux_core::{
    storage::{SavedSession, SavedState, StateStore},
    terminal::{TerminalCommand, TerminalSession},
    APP_ID,
};
use gtk::glib;
use std::{cell::RefCell, rc::Rc};

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &adw::Application) {
    let header = adw::HeaderBar::new();
    let add_button = gtk::Button::builder()
        .icon_name("list-add-symbolic")
        .tooltip_text("New shell")
        .build();
    header.pack_start(&add_button);

    let sidebar = gtk::ListBox::new();
    sidebar.add_css_class("navigation-sidebar");
    sidebar.set_selection_mode(gtk::SelectionMode::Single);

    let terminal_stack = gtk::Stack::builder()
        .hexpand(true)
        .vexpand(true)
        .transition_type(gtk::StackTransitionType::Crossfade)
        .build();

    let store = StateStore::xdg().ok();
    let initial_sessions = load_sessions(store.as_ref());
    let sessions = Rc::new(RefCell::new(Vec::<TerminalSession>::new()));

    for session in initial_sessions {
        append_session(&sidebar, &terminal_stack, &sessions, session);
    }
    sidebar.select_row(sidebar.row_at_index(0).as_ref());

    {
        let terminal_stack = terminal_stack.clone();
        let sessions = Rc::clone(&sessions);
        sidebar.connect_row_selected(move |_, row| {
            let Some(row) = row else {
                return;
            };
            let index = usize::try_from(row.index()).expect("GTK row indexes are non-negative");
            if let Some(session) = sessions.borrow().get(index) {
                terminal_stack.set_visible_child_name(&session.id);
            }
        });
    }

    {
        let sidebar = sidebar.clone();
        let terminal_stack = terminal_stack.clone();
        let sessions = Rc::clone(&sessions);
        add_button.connect_clicked(move |_| {
            let next = sessions.borrow().len() + 1;
            let session = TerminalSession::new(
                format!("workspace-{next}"),
                format!("Workspace {next}"),
                TerminalCommand::user_shell(),
            );
            append_session(&sidebar, &terminal_stack, &sessions, session);
            let last_index =
                i32::try_from(sessions.borrow().len() - 1).expect("session count fits i32");
            sidebar.select_row(sidebar.row_at_index(last_index).as_ref());
        });
    }

    let split = gtk::Paned::builder()
        .orientation(gtk::Orientation::Horizontal)
        .start_child(&sidebar)
        .end_child(&terminal_stack)
        .resize_start_child(false)
        .shrink_start_child(false)
        .build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&split));

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("cmux")
        .default_width(1200)
        .default_height(800)
        .content(&toolbar)
        .build();

    if let Some(store) = store {
        let sessions = Rc::clone(&sessions);
        window.connect_close_request(move |_| {
            let state = SavedState {
                sessions: sessions.borrow().iter().map(SavedSession::from).collect(),
            };
            if let Err(error) = store.save(&state) {
                eprintln!("failed to save cmux state: {error}");
            }
            glib::Propagation::Proceed
        });
    }

    window.present();
}

fn load_sessions(store: Option<&StateStore>) -> Vec<TerminalSession> {
    let sessions: Vec<TerminalSession> = store
        .and_then(|store| match store.load() {
            Ok(state) => Some(
                state
                    .sessions
                    .into_iter()
                    .map(saved_session_to_terminal)
                    .collect(),
            ),
            Err(error) => {
                eprintln!("failed to load cmux state: {error}");
                None
            }
        })
        .unwrap_or_default();

    if sessions.is_empty() {
        vec![TerminalSession::new(
            "workspace-1",
            "Workspace 1",
            TerminalCommand::user_shell(),
        )]
    } else {
        sessions
    }
}

fn append_session(
    sidebar: &gtk::ListBox,
    terminal_stack: &gtk::Stack,
    sessions: &Rc<RefCell<Vec<TerminalSession>>>,
    session: TerminalSession,
) {
    let row = gtk::ListBoxRow::new();
    row.set_child(Some(&gtk::Label::new(Some(&session.title))));
    sidebar.append(&row);

    let terminal = terminal::terminal(&session);
    terminal_stack.add_named(&terminal, Some(&session.id));
    sessions.borrow_mut().push(session);
}

fn saved_session_to_terminal(session: SavedSession) -> TerminalSession {
    TerminalSession::new(
        session.id,
        session.title,
        TerminalCommand {
            program: session.program,
            args: session.args,
            working_directory: session.working_directory,
        },
    )
}
