use crate::ghostty::GhosttyCapture;

#[derive(Debug, Clone, serde::Serialize)]
pub struct TerminalCapture {
    pub title: String,
    pub pwd: String,
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub history: String,
    pub visible: String,
}

pub fn capture_terminal(raw: GhosttyCapture, title: String, pwd: String) -> TerminalCapture {
    TerminalCapture {
        title,
        pwd,
        cols: raw.cols,
        rows: raw.rows,
        cursor_x: raw.cursor_x,
        cursor_y: raw.cursor_y,
        history: raw.history,
        visible: raw.visible,
    }
}
