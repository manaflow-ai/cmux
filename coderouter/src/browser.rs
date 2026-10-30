//! Opening a page in the person's browser (an OAuth or device-code sign-in, the pricing page).
//!
//! The `webbrowser` crate asks LaunchServices directly on macOS and never reads `BROWSER`, so in
//! a cmux terminal or agent (where `BROWSER` names cmux's `cmux-open-url`) a sign-in page went to
//! the default browser instead of a cmux browser tab. This runs `BROWSER` first, as Python's
//! `webbrowser`, gh and `xdg-open` do, and falls back to the system browser when it is unset or
//! cannot start.

use std::process::{Command, Stdio};

/// Opens `url`: the first `BROWSER` command (with `%s` replaced by the URL, else the URL appended
/// as the last argument; never through a shell), else the system browser.
pub(crate) fn open(url: &str) {
    if let Some((program, args)) = browser_command(std::env::var("BROWSER").ok().as_deref(), url) {
        let spawned = Command::new(&program)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        if let Ok(mut child) = spawned {
            // A GUI browser may run for as long as the page is open: reap it off this thread.
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            return;
        }
    }
    let _ = webbrowser::open(url);
}

/// The program and arguments that open `url` for `BROWSER` value `browser` (a `:`-separated list
/// of commands; the first non-empty one is used), or `None` when it names none.
fn browser_command(browser: Option<&str>, url: &str) -> Option<(String, Vec<String>)> {
    let first = browser?
        .split(':')
        .map(str::trim)
        .find(|command| !command.is_empty())?;
    let mut words = first.split_whitespace().map(str::to_owned);
    let program = words.next()?;
    let mut args: Vec<String> = words.collect();
    if args.iter().any(|arg| arg.contains("%s")) {
        for arg in &mut args {
            *arg = arg.replace("%s", url);
        }
    } else {
        args.push(url.to_owned());
    }
    Some((program, args))
}

#[cfg(test)]
mod tests {
    use super::browser_command;

    const URL: &str = "https://console.opencode.ai/auth/device?code=ABCD-1234";

    #[test]
    fn cmux_open_url_gets_the_url() {
        assert_eq!(
            browser_command(Some("cmux-open-url"), URL),
            Some(("cmux-open-url".to_owned(), vec![URL.to_owned()]))
        );
    }

    #[test]
    fn placeholder_args_and_lists_follow_the_posix_convention() {
        assert_eq!(
            browser_command(Some("firefox -P work %s:open"), URL),
            Some((
                "firefox".to_owned(),
                vec!["-P".to_owned(), "work".to_owned(), URL.to_owned()]
            ))
        );
        assert_eq!(
            browser_command(Some(" : open"), URL),
            Some(("open".to_owned(), vec![URL.to_owned()]))
        );
    }

    #[test]
    fn unset_or_blank_uses_the_system_browser() {
        assert_eq!(browser_command(None, URL), None);
        assert_eq!(browser_command(Some(""), URL), None);
        assert_eq!(browser_command(Some(" :: "), URL), None);
    }
}
