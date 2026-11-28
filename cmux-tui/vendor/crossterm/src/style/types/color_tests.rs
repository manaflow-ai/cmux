use super::Color;

#[test]
fn test_known_color_conversion() {
    assert_eq!("reset".parse(), Ok(Color::Reset));
    assert_eq!("grey".parse(), Ok(Color::Grey));
    assert_eq!("dark_grey".parse(), Ok(Color::DarkGrey));
    assert_eq!("red".parse(), Ok(Color::Red));
    assert_eq!("dark_red".parse(), Ok(Color::DarkRed));
    assert_eq!("green".parse(), Ok(Color::Green));
    assert_eq!("dark_green".parse(), Ok(Color::DarkGreen));
    assert_eq!("yellow".parse(), Ok(Color::Yellow));
    assert_eq!("dark_yellow".parse(), Ok(Color::DarkYellow));
    assert_eq!("blue".parse(), Ok(Color::Blue));
    assert_eq!("dark_blue".parse(), Ok(Color::DarkBlue));
    assert_eq!("magenta".parse(), Ok(Color::Magenta));
    assert_eq!("dark_magenta".parse(), Ok(Color::DarkMagenta));
    assert_eq!("cyan".parse(), Ok(Color::Cyan));
    assert_eq!("dark_cyan".parse(), Ok(Color::DarkCyan));
    assert_eq!("white".parse(), Ok(Color::White));
    assert_eq!("black".parse(), Ok(Color::Black));
}

#[test]
fn test_unknown_color_conversion_yields_white() {
    assert_eq!("foo".parse(), Ok(Color::White));
}

#[test]
fn test_know_rgb_color_conversion() {
    assert_eq!(Color::from((0, 0, 0)), Color::Rgb { r: 0, g: 0, b: 0 });
    assert_eq!(Color::from((255, 255, 255)), Color::Rgb { r: 255, g: 255, b: 255 });
}
