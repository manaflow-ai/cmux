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

#[cfg(test)]
mod tests {
    use super::window_title_osc;

    #[test]
    fn window_title_osc_uses_osc_0_and_2_and_strips_controls() {
        assert_eq!(window_title_osc("hello").as_slice(), b"\x1b]0;hello\x07\x1b]2;hello\x07");
        assert_eq!(window_title_osc("a\x1bb\x07c").as_slice(), b"\x1b]0;a b c\x07\x1b]2;a b c\x07");
    }
}
