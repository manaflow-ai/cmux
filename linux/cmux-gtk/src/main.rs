mod notifications;
mod terminal;

use adw::prelude::*;
use cmux_core::{
    terminal::{TerminalCommand, TerminalSession},
    APP_ID,
};
use gtk::glib;

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &adw::Application) {
    let header = adw::HeaderBar::new();

    let sidebar = gtk::ListBox::new();
    sidebar.append(&gtk::Label::new(Some("Workspace 1")));
    sidebar.append(&gtk::Label::new(Some("Workspace 2")));
    sidebar.add_css_class("navigation-sidebar");

    let session = TerminalSession::new("workspace-1", "Workspace 1", TerminalCommand::user_shell());
    let placeholder = terminal::placeholder(&session);

    let split = gtk::Paned::builder()
        .orientation(gtk::Orientation::Horizontal)
        .start_child(&sidebar)
        .end_child(&placeholder)
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

    window.present();
}
