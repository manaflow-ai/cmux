// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! Every catalog action, one module per group, in catalog order (menu ranks tie-break on it).

mod account;
mod agent;
mod agent_chat_copy;
mod agent_chat_identifier;
mod agent_chat_menu;
mod agent_chat_rail;
mod agent_chat_view;
mod agent_configuration;
mod agent_harness;
mod agent_share;
mod agent_side_question;
mod agent_transcript;
mod app_store;
pub mod args;
mod auto_archive;
mod automations;
mod backdrop;
mod bookmark;
mod browser;
mod browser_chrome;
mod browser_hit;
mod browser_profile;
mod browser_toolbar;
mod certificate_warning;
mod chief_screen_share;
mod chrome_style;
mod cloud;
mod cloud_port;
mod cloud_session;
mod cmux_remote;
mod density;
mod divider;
mod extension;
mod file_page;
mod files_pane;
mod git;
mod hang_reports;
mod help_link;
mod hibernation;
mod history;
mod home;
mod home_message;
mod import;
mod joined_machine;
mod layout;
mod link;
mod list;
mod machine_icon;
mod markdown_page;
mod music;
mod new_placement;
mod notification;
mod notification_sound;
mod now_playing_card;
mod page_info;
mod palette_history;
mod palette_key;
mod pane;
mod pane_background;
mod phone;
mod profile;
mod profile_menu;
mod remote;
mod resource;
mod screen;
mod screen_group;
mod server;
mod settings;
mod share;
mod sidebar;
mod sidebar_priority;
mod sidebar_section;
mod stash;
mod tab;
mod tab_group;
mod tab_icon;
mod tasks;
mod terminal;
mod theme;
mod vertical_tabs;
mod viewer;
mod voice_room;
mod window;
mod workspace;
mod workspace_bulk_archive;
mod workspace_group;
mod workspace_verb;

use crate::model::Action;

/// The groups in catalog order.
pub static GROUPS: &[&[Action]] = &[
    window::ACTIONS,
    workspace::ACTIONS,
    workspace_verb::ACTIONS,
    workspace_group::ACTIONS,
    profile::ACTIONS,
    theme::ACTIONS,
    pane::ACTIONS,
    new_placement::ACTIONS,
    tab::ACTIONS,
    vertical_tabs::ACTIONS,
    agent_chat_rail::ACTIONS,
    cmux_remote::ACTIONS,
    tab_icon::ACTIONS,
    resource::ACTIONS,
    home::ACTIONS,
    home_message::ACTIONS,
    tab_group::ACTIONS,
    screen::ACTIONS,
    screen_group::ACTIONS,
    terminal::ACTIONS,
    browser::ACTIONS,
    browser_toolbar::ACTIONS,
    browser_chrome::ACTIONS,
    browser_hit::ACTIONS,
    viewer::ACTIONS,
    file_page::ACTIONS,
    page_info::ACTIONS,
    certificate_warning::ACTIONS,
    extension::ACTIONS,
    browser_profile::ACTIONS,
    profile_menu::ACTIONS,
    sidebar::ACTIONS,
    notification::ACTIONS,
    notification_sound::ACTIONS,
    agent::ACTIONS,
    agent_chat_menu::ACTIONS,
    agent_configuration::ACTIONS,
    agent_transcript::ACTIONS,
    agent_chat_identifier::ACTIONS,
    agent_share::ACTIONS,
    agent_chat_copy::ACTIONS,
    agent_chat_view::ACTIONS,
    agent_side_question::ACTIONS,
    agent_harness::ACTIONS,
    git::ACTIONS,
    cloud::ACTIONS,
    cloud_port::ACTIONS,
    account::ACTIONS,
    remote::ACTIONS,
    cloud_session::ACTIONS,
    machine_icon::ACTIONS,
    settings::ACTIONS,
    help_link::ACTIONS,
    density::ACTIONS,
    chrome_style::ACTIONS,
    backdrop::ACTIONS,
    pane_background::ACTIONS,
    divider::ACTIONS,
    hibernation::ACTIONS,
    auto_archive::ACTIONS,
    workspace_bulk_archive::ACTIONS,
    layout::ACTIONS,
    history::ACTIONS,
    stash::ACTIONS,
    music::ACTIONS,
    voice_room::ACTIONS,
    chief_screen_share::ACTIONS,
    now_playing_card::ACTIONS,
    bookmark::ACTIONS,
    sidebar_section::ACTIONS,
    sidebar_priority::ACTIONS,
    joined_machine::ACTIONS,
    app_store::ACTIONS,
    automations::ACTIONS,
    tasks::ACTIONS,
    phone::ACTIONS,
    files_pane::ACTIONS,
    link::ACTIONS,
    share::ACTIONS,
    server::ACTIONS,
    markdown_page::ACTIONS,
    list::ACTIONS,
    palette_key::ACTIONS,
    import::ACTIONS,
    hang_reports::ACTIONS,
    palette_history::ACTIONS,
];
