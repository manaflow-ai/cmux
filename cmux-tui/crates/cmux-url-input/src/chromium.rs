//! RED STUB (replaced by the port in the next commit): no Rust rule for
//! Chromium internal pages existed.

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChromiumPageRoute {
    CmuxPage(&'static str),
    BrowserSettings,
    PasswordsPage,
    Chromium(String),
}

impl ChromiumPageRoute {
    pub fn is_cmux_owned(&self) -> bool {
        !matches!(self, Self::Chromium(_))
    }
}

pub fn chromium_internal_url(_text: &str) -> Option<String> {
    None
}

pub fn chromium_page_route(_url: &str) -> Option<ChromiumPageRoute> {
    None
}
