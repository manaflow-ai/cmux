//! The terminal window title: OSC 0 and 2, with control characters replaced.

pub fn window_title_osc(title: &str) -> Vec<u8> {
    let title = sanitize_window_title(title);
    format!("\x1b]0;{title}\x07\x1b]2;{title}\x07").into_bytes()
}

pub(super) fn sanitize_window_title(title: &str) -> String {
    title
        .chars()
        .map(|ch| match ch {
            '\u{00}'..='\u{1f}' | '\u{7f}' => ' ',
            _ => ch,
        })
        .collect()
}
