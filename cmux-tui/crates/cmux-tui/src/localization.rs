use std::sync::OnceLock;

use crate::config::Action;

mod agent_wrapper;
mod agents_doctor;
mod app_control;
mod attach;
mod auth_token;
mod automation;
mod billing;
mod browser;
mod cli_connection;
mod coderouter;
mod config;
mod foreign_viewport;
mod graphics;
mod host_share;
mod layout;
mod local_server;
mod machine_agent;
mod menu;
mod pairing;
mod remote;
mod remote_client;
mod runtime;
mod sandbox_run;
mod server_mount;
mod session;
mod session_reset;
mod shortcuts;
mod sidebar;
mod skew;
mod startup;
mod terminal;
mod terminal_input;
pub(crate) mod terminal_respawn;
mod update_notice;

pub(crate) use agent_wrapper::AgentWrapperMessages;
pub(crate) use agents_doctor::AgentsDoctorMessages;
pub(crate) use app_control::{AppControlMessages, VersionLabels};
pub(crate) use attach::AttachMessages;
pub(crate) use auth_token::AuthTokenMessages;
pub(crate) use automation::AutomationMessages;
pub(crate) use billing::BillingMessages;
pub(crate) use browser::BrowserMessages;
pub(crate) use cli_connection::CliConnectionMessages;
pub(crate) use coderouter::CodeRouterMessages;
pub(crate) use config::ConfigMessages;
pub(crate) use foreign_viewport::ForeignViewportMessages;
pub(crate) use graphics::GraphicsMessages;
pub(crate) use layout::LayoutMessages;
pub(crate) use local_server::LocalServerMessages;
pub(crate) use machine_agent::MachineAgentMessages;
pub(crate) use menu::MenuMessages;
pub(crate) use pairing::PairingMessages;
pub(crate) use remote::RemoteMessages;
pub(crate) use remote_client::RemoteClientMessages;
pub(crate) use runtime::RuntimeMessages;
pub(crate) use sandbox_run::SandboxRunMessages;
pub(crate) use server_mount::server_mount;
pub(crate) use session::SessionMessages;
pub(crate) use session_reset::SessionResetMessages;
pub(crate) use shortcuts::ShortcutMessages;
pub(crate) use sidebar::SidebarMessages;
pub(crate) use skew::SkewMessages;
pub(crate) use startup::StartupMessages;
pub(crate) use terminal::TerminalMessages;
pub(crate) use terminal_input::TerminalInputMessages;
pub(crate) use update_notice::UpdateNoticeMessages;

const FOREIGN_VIEWPORT_HINT_CAPACITY: usize = 64;

/// The English update notice strings, for tests that check both languages.
#[cfg(test)]
pub(crate) fn update_notice_english() -> &'static UpdateNoticeMessages {
    &update_notice::ENGLISH
}

#[cfg(test)]
pub(crate) fn update_notice_japanese() -> &'static UpdateNoticeMessages {
    &update_notice::JAPANESE
}

/// `cmux attach --help`, naming the program the way it was run.
pub(crate) fn attach_help() -> String {
    catalog().attach.help.replace("{program}", &crate::cli::BIN.to_string())
}

/// Format a dollar amount with two decimals and thousands separators.
/// Non-finite or negative inputs render as zero so a bad upstream number
/// can never produce a misleading readout.
pub(crate) fn format_usd(amount: f64) -> String {
    let amount = if amount.is_finite() && amount > 0.0 { amount } else { 0.0 };
    let cents = (amount * 100.0).round() as u64;
    let whole = cents / 100;
    let fraction = cents % 100;
    let digits = whole.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    format!("${grouped}.{fraction:02}")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForeignViewportHint {
    bytes: [u8; FOREIGN_VIEWPORT_HINT_CAPACITY],
    len: usize,
}

impl ForeignViewportHint {
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.bytes[..self.len])
            .expect("foreign viewport hint is assembled from UTF-8 strings and ASCII digits")
    }
}

const fn decimal_width(mut value: u16) -> usize {
    let mut width = 1;
    while value >= 10 {
        value /= 10;
        width += 1;
    }
    width
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Catalog {
    japanese: bool,
    pub startup: StartupMessages,
    pub local_server: LocalServerMessages,
    pub skew: SkewMessages,
    pub terminal_input: TerminalInputMessages,
    pub pairing: PairingMessages,
    pub foreign_viewport: ForeignViewportMessages,
    pub graphics: GraphicsMessages,
    pub terminal: TerminalMessages,
    pub session: SessionMessages,
    pub session_reset: SessionResetMessages,
    pub machine_agent: MachineAgentMessages,
    pub menu: MenuMessages,
    pub shortcuts: ShortcutMessages,
    pub browser: BrowserMessages,
    pub layout: LayoutMessages,
    pub runtime: RuntimeMessages,
    pub remote_client: RemoteClientMessages,
    pub remote: RemoteMessages,
    pub config: ConfigMessages,
    pub attach: AttachMessages,
    pub cli_connection: CliConnectionMessages,
    pub sidebar: SidebarMessages,
    pub agent_wrapper: AgentWrapperMessages,
    pub agents_doctor: AgentsDoctorMessages,
    pub host_share: host_share::Messages,
    pub app_control: AppControlMessages,
    pub coderouter: CodeRouterMessages,
    pub automation: AutomationMessages,
    pub billing: BillingMessages,
    pub auth_token: AuthTokenMessages,
    pub sandbox_run: SandboxRunMessages,
    pub update_notice: UpdateNoticeMessages,
}

impl Catalog {
    /// Whether this is the Japanese catalog, for help text built in code.
    pub fn is_japanese(&self) -> bool {
        self.japanese
    }

    pub fn action_label(&self, action: Action) -> &'static str {
        let definition = action.definition();
        if self.japanese { definition.label_ja } else { definition.label_en }
    }
}

static ENGLISH: Catalog = Catalog {
    japanese: false,
    coderouter: coderouter::ENGLISH,
    automation: automation::ENGLISH,
    billing: billing::ENGLISH,
    auth_token: auth_token::ENGLISH,
    sandbox_run: sandbox_run::ENGLISH,
    update_notice: update_notice::ENGLISH,
    app_control: app_control::ENGLISH,
    agent_wrapper: agent_wrapper::ENGLISH,
    agents_doctor: agents_doctor::ENGLISH,
    host_share: host_share::ENGLISH,
    startup: startup::ENGLISH,
    terminal_input: terminal_input::ENGLISH,
    local_server: local_server::ENGLISH,
    skew: skew::ENGLISH,
    pairing: pairing::ENGLISH,
    foreign_viewport: foreign_viewport::ENGLISH,
    graphics: graphics::ENGLISH,
    terminal: terminal::ENGLISH,
    session: session::ENGLISH,
    session_reset: session_reset::ENGLISH,
    machine_agent: machine_agent::ENGLISH,
    menu: menu::ENGLISH,
    shortcuts: shortcuts::ENGLISH,
    browser: browser::ENGLISH,
    layout: layout::ENGLISH,
    runtime: runtime::ENGLISH,
    remote_client: remote_client::ENGLISH,
    remote: remote::ENGLISH,
    config: config::ENGLISH,
    attach: attach::ENGLISH,
    cli_connection: cli_connection::ENGLISH,
    sidebar: sidebar::ENGLISH,
};

static JAPANESE: Catalog = Catalog {
    japanese: true,
    coderouter: coderouter::JAPANESE,
    automation: automation::JAPANESE,
    billing: billing::JAPANESE,
    auth_token: auth_token::JAPANESE,
    sandbox_run: sandbox_run::JAPANESE,
    update_notice: update_notice::JAPANESE,
    app_control: app_control::JAPANESE,
    agent_wrapper: agent_wrapper::JAPANESE,
    agents_doctor: agents_doctor::JAPANESE,
    host_share: host_share::JAPANESE,
    startup: startup::JAPANESE,
    terminal_input: terminal_input::JAPANESE,
    local_server: local_server::JAPANESE,
    skew: skew::JAPANESE,
    pairing: pairing::JAPANESE,
    foreign_viewport: foreign_viewport::JAPANESE,
    graphics: graphics::JAPANESE,
    terminal: terminal::JAPANESE,
    session: session::JAPANESE,
    session_reset: session_reset::JAPANESE,
    machine_agent: machine_agent::JAPANESE,
    menu: menu::JAPANESE,
    shortcuts: shortcuts::JAPANESE,
    browser: browser::JAPANESE,
    layout: layout::JAPANESE,
    runtime: runtime::JAPANESE,
    remote_client: remote_client::JAPANESE,
    remote: remote::JAPANESE,
    config: config::JAPANESE,
    attach: attach::JAPANESE,
    cli_connection: cli_connection::JAPANESE,
    sidebar: sidebar::JAPANESE,
};

pub(crate) fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<&'static Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| catalog_for_locale(&system_locale()))
}

pub(crate) fn catalog_for_locale(locale: &str) -> &'static Catalog {
    if locale.to_ascii_lowercase().starts_with("ja") { &JAPANESE } else { &ENGLISH }
}

fn system_locale() -> String {
    std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LC_MESSAGES"))
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
