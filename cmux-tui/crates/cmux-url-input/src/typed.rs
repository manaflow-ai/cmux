//! RED STUB (replaced by the port in the next commit): the typed policy's API
//! with the daemon rule behind it, to show the ported Swift corpus fails on
//! `normalize_url`, the rule BrowserURLResolver was said to copy.

use crate::normalize_url;

pub const CMUX_APP_PAGE_HOSTS: [&str; 1] = ["stashed"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TypedInput<'a> {
    pub home: &'a str,
    pub allows_chromium_schemes: bool,
}

pub fn contains_pairing_link(_text: &str) -> bool {
    false
}

pub fn is_loopback_host(_host: &str) -> bool {
    false
}

pub fn is_non_unique_host(_host: &str) -> bool {
    false
}

pub fn split_host_and_port(_authority: &str) -> (String, bool) {
    (String::new(), false)
}

impl TypedInput<'_> {
    /// The daemon rule, a web search read as "search".
    pub fn resolve(&self, input: &str) -> Option<String> {
        if input.trim().is_empty() {
            return None;
        }
        let url = normalize_url(input);
        (!url.starts_with("https://www.google.com/search?q=")).then_some(url)
    }
}
