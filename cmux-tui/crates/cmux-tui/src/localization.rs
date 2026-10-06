use std::sync::OnceLock;

use crate::config::Action;

mod agent_wrapper;
mod app_control;
mod attach;
mod browser;
mod coderouter;
mod config;
mod foreign_viewport;
mod graphics;
mod layout;
mod local_server;
mod machine_agent;
mod menu;
mod pairing;
mod remote;
mod remote_client;
mod runtime;
mod session;
mod session_reset;
mod shortcuts;
mod sidebar;
mod startup;
mod terminal;
mod terminal_input;

pub(crate) use agent_wrapper::AgentWrapperMessages;
pub(crate) use app_control::AppControlMessages;
pub(crate) use attach::AttachMessages;
pub(crate) use browser::BrowserMessages;
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
pub(crate) use session::SessionMessages;
pub(crate) use session_reset::SessionResetMessages;
pub(crate) use shortcuts::ShortcutMessages;
pub(crate) use sidebar::SidebarMessages;
pub(crate) use startup::StartupMessages;
pub(crate) use terminal::TerminalMessages;
pub(crate) use terminal_input::TerminalInputMessages;

const FOREIGN_VIEWPORT_HINT_CAPACITY: usize = 64;

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
    pub sidebar: SidebarMessages,
    pub agent_wrapper: AgentWrapperMessages,
    pub app_control: AppControlMessages,
    pub coderouter: CodeRouterMessages,
}

impl Catalog {
    pub fn action_label(&self, action: Action) -> &'static str {
        let definition = action.definition();
        if self.japanese { definition.label_ja } else { definition.label_en }
    }
}

static ENGLISH: Catalog = Catalog {
    japanese: false,
    coderouter: coderouter::ENGLISH,
    app_control: app_control::ENGLISH,
    agent_wrapper: agent_wrapper::ENGLISH,
    startup: startup::ENGLISH,
    terminal_input: terminal_input::ENGLISH,
    local_server: local_server::ENGLISH,
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
    sidebar: sidebar::ENGLISH,
};

static JAPANESE: Catalog = Catalog {
    japanese: true,
    coderouter: coderouter::JAPANESE,
    app_control: app_control::JAPANESE,
    agent_wrapper: agent_wrapper::JAPANESE,
    startup: startup::JAPANESE,
    terminal_input: terminal_input::JAPANESE,
    local_server: local_server::JAPANESE,
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
