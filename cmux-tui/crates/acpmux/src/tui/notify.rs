//! Terminal notifications from the TUI: OSC 9 for Ghostty, iTerm2 and
//! WezTerm, OSC 99 for kitty, wrapped for tmux. Fired on two transitions
//! only: a permission request, and a turn that ended on a session not on
//! screen. `ACPMUX_NO_NOTIFY=1` turns them off.

use std::io::Write;

pub fn send(title: &str, body: &str) {
    if std::env::var_os("ACPMUX_NO_NOTIFY").is_some() {
        return;
    }
    let clean = |s: &str| s.chars().filter(|c| !c.is_control()).collect::<String>();
    let (title, body) = (clean(title), clean(body));
    let kitty = std::env::var("KITTY_WINDOW_ID").is_ok()
        || std::env::var("TERM").map(|t| t.contains("kitty")).unwrap_or(false);
    let seq = if kitty {
        format!("\x1b]99;i=1:d=0;{title}\x1b\\\x1b]99;i=1:p=body;{body}\x1b\\")
    } else {
        format!("\x1b]9;{title}: {body}\x1b\\")
    };
    let seq = if std::env::var("TMUX").is_ok() {
        format!("\x1bPtmux;{}\x1b\\", seq.replace('\x1b', "\x1b\x1b"))
    } else {
        seq
    };
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}
