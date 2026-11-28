use super::*;

// On Windows many env var tests will fail so we need to conditionally check for ANSI support.
// This allows other terminals on Windows to still assert env var support.
macro_rules! skip_windows_ansi_supported {
    () => {
        #[cfg(windows)]
        {
            if crate::ansi_support::supports_ansi() {
                return;
            }
        }
    };
}

#[cfg_attr(windows, test)]
#[cfg(windows)]
fn windows_always_truecolor() {
    // This should always be true on supported Windows 10+,
    // but downlevel Windows clients and other terminals may fail `cargo test` otherwise.
    if crate::ansi_support::supports_ansi() {
        assert_eq!(u16::MAX, available_color_count());
    };
}

#[test]
fn colorterm_overrides_term() {
    skip_windows_ansi_supported!();
    temp_env::with_vars(
        [("COLORTERM", Some("truecolor")), ("TERM", Some("xterm-256color"))],
        || {
            assert_eq!(u16::MAX, available_color_count());
        },
    );
}

#[test]
fn term_24bits() {
    skip_windows_ansi_supported!();
    temp_env::with_vars([("COLORTERM", None), ("TERM", Some("xterm-24bits"))], || {
        assert_eq!(u16::MAX, available_color_count());
    });
}

#[test]
fn term_256color() {
    skip_windows_ansi_supported!();
    temp_env::with_vars([("COLORTERM", None), ("TERM", Some("xterm-256color"))], || {
        assert_eq!(256u16, available_color_count());
    });
}

#[test]
fn default_color_count() {
    skip_windows_ansi_supported!();
    temp_env::with_vars([("COLORTERM", None::<&str>), ("TERM", None)], || {
        assert_eq!(8, available_color_count());
    });
}

#[test]
fn unsupported_term_colorterm_values() {
    skip_windows_ansi_supported!();
    temp_env::with_vars([("COLORTERM", Some("gibberish")), ("TERM", Some("gibberish"))], || {
        assert_eq!(8u16, available_color_count());
    });
}
