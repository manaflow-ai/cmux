use crate::style::{Color, Colored};

fn check_format_color(colored: Colored, expected: &str) {
    Colored::set_ansi_color_disabled(true);
    assert_eq!(colored.to_string(), "");
    Colored::set_ansi_color_disabled(false);
    assert_eq!(colored.to_string(), expected);
}

#[test]
fn test_format_fg_color() {
    let colored = Colored::ForegroundColor(Color::Red);
    check_format_color(colored, "38;5;9");
}

#[test]
fn test_format_bg_color() {
    let colored = Colored::BackgroundColor(Color::Red);
    check_format_color(colored, "48;5;9");
}

#[test]
fn test_format_reset_fg_color() {
    let colored = Colored::ForegroundColor(Color::Reset);
    check_format_color(colored, "39");
}

#[test]
fn test_format_reset_bg_color() {
    let colored = Colored::BackgroundColor(Color::Reset);
    check_format_color(colored, "49");
}

#[test]
fn test_format_fg_rgb_color() {
    let colored = Colored::BackgroundColor(Color::Rgb { r: 1, g: 2, b: 3 });
    check_format_color(colored, "48;2;1;2;3");
}

#[test]
fn test_format_fg_ansi_color() {
    let colored = Colored::ForegroundColor(Color::AnsiValue(255));
    check_format_color(colored, "38;5;255");
}

#[test]
fn test_parse_ansi_fg() {
    test_parse_ansi(Colored::ForegroundColor)
}

#[test]
fn test_parse_ansi_bg() {
    test_parse_ansi(Colored::ForegroundColor)
}

/// Used for test_parse_ansi_fg and test_parse_ansi_bg
fn test_parse_ansi(bg_or_fg: impl Fn(Color) -> Colored) {
    /// Formats a re-parses `color` to check the result.
    macro_rules! test {
        ($color:expr) => {
            let colored = bg_or_fg($color);
            assert_eq!(Colored::parse_ansi(&format!("{}", colored)), Some(colored));
        };
    }

    use Color::*;

    test!(Reset);
    test!(Black);
    test!(DarkGrey);
    test!(Red);
    test!(DarkRed);
    test!(Green);
    test!(DarkGreen);
    test!(Yellow);
    test!(DarkYellow);
    test!(Blue);
    test!(DarkBlue);
    test!(Magenta);
    test!(DarkMagenta);
    test!(Cyan);
    test!(DarkCyan);
    test!(White);
    test!(Grey);

    // n in 0..=15 will give us the color values above back.
    for n in 16..=255 {
        test!(AnsiValue(n));
    }

    for r in 0..=255 {
        for g in [0, 2, 18, 19, 60, 100, 200, 250, 254, 255].iter().copied() {
            for b in [0, 12, 16, 99, 100, 161, 200, 255].iter().copied() {
                test!(Rgb { r, g, b });
            }
        }
    }
}

#[test]
fn test_parse_invalid_ansi_color() {
    /// Checks that trying to parse `s` yields None.
    fn test(s: &str) {
        assert_eq!(Colored::parse_ansi(s), None);
    }
    test("");
    test(";");
    test(";;");
    test(";;");
    test("0");
    test("1");
    test("12");
    test("100");
    test("100048949345");
    test("39;");
    test("49;");
    test("39;2");
    test("49;2");
    test("38");
    test("38;");
    test("38;0");
    test("38;5");
    test("38;5;0;");
    test("38;5;0;2");
    test("38;5;80;");
    test("38;5;80;2");
    test("38;5;257");
    test("38;2");
    test("38;2;");
    test("38;2;0");
    test("38;2;0;2");
    test("38;2;0;2;257");
    test("38;2;0;2;25;");
    test("38;2;0;2;25;3");
    test("48");
    test("48;");
    test("48;0");
    test("48;5");
    test("48;5;0;");
    test("48;5;0;2");
    test("48;5;80;");
    test("48;5;80;2");
    test("48;5;257");
    test("48;2");
    test("48;2;");
    test("48;2;0");
    test("48;2;0;2");
    test("48;2;0;2;257");
    test("48;2;0;2;25;");
    test("48;2;0;2;25;3");
}

#[test]
fn test_no_color() {
    std::env::set_var("NO_COLOR", "1");
    assert!(Colored::ansi_color_disabled());
    std::env::set_var("NO_COLOR", "XXX");
    assert!(Colored::ansi_color_disabled());
    std::env::set_var("NO_COLOR", "");
    assert!(!Colored::ansi_color_disabled());
    std::env::remove_var("NO_COLOR");
    assert!(!Colored::ansi_color_disabled());
}
