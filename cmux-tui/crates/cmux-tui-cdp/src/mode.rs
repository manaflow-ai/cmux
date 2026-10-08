/// Whether a browser surface asks for a headful or headless browser (a
/// surface option; cmux-tui-core re-exports it).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BrowserMode {
    #[default]
    Headful,
    Headless,
}
