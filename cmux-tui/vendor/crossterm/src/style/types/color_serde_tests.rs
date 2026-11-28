use super::Color;
use serde_json;

#[test]
fn test_deserial_known_color_conversion() {
    assert_eq!(serde_json::from_str::<Color>("\"Reset\"").unwrap(), Color::Reset);
    assert_eq!(serde_json::from_str::<Color>("\"reset\"").unwrap(), Color::Reset);
    assert_eq!(serde_json::from_str::<Color>("\"Red\"").unwrap(), Color::Red);
    assert_eq!(serde_json::from_str::<Color>("\"red\"").unwrap(), Color::Red);
    assert_eq!(serde_json::from_str::<Color>("\"dark_red\"").unwrap(), Color::DarkRed);
    assert_eq!(serde_json::from_str::<Color>("\"grey\"").unwrap(), Color::Grey);
    assert_eq!(serde_json::from_str::<Color>("\"dark_grey\"").unwrap(), Color::DarkGrey);
    assert_eq!(serde_json::from_str::<Color>("\"green\"").unwrap(), Color::Green);
    assert_eq!(serde_json::from_str::<Color>("\"dark_green\"").unwrap(), Color::DarkGreen);
    assert_eq!(serde_json::from_str::<Color>("\"yellow\"").unwrap(), Color::Yellow);
    assert_eq!(serde_json::from_str::<Color>("\"dark_yellow\"").unwrap(), Color::DarkYellow);
    assert_eq!(serde_json::from_str::<Color>("\"blue\"").unwrap(), Color::Blue);
    assert_eq!(serde_json::from_str::<Color>("\"dark_blue\"").unwrap(), Color::DarkBlue);
    assert_eq!(serde_json::from_str::<Color>("\"magenta\"").unwrap(), Color::Magenta);
    assert_eq!(serde_json::from_str::<Color>("\"dark_magenta\"").unwrap(), Color::DarkMagenta);
    assert_eq!(serde_json::from_str::<Color>("\"cyan\"").unwrap(), Color::Cyan);
    assert_eq!(serde_json::from_str::<Color>("\"dark_cyan\"").unwrap(), Color::DarkCyan);
    assert_eq!(serde_json::from_str::<Color>("\"white\"").unwrap(), Color::White);
    assert_eq!(serde_json::from_str::<Color>("\"black\"").unwrap(), Color::Black);
}

#[test]
fn test_deserial_unknown_color_conversion() {
    assert!(serde_json::from_str::<Color>("\"unknown\"").is_err());
}

#[test]
fn test_deserial_ansi_value() {
    assert_eq!(serde_json::from_str::<Color>("\"ansi_(255)\"").unwrap(), Color::AnsiValue(255));
}

#[test]
fn test_deserial_unvalid_ansi_value() {
    assert!(serde_json::from_str::<Color>("\"ansi_(256)\"").is_err());
    assert!(serde_json::from_str::<Color>("\"ansi_(-1)\"").is_err());
}

#[test]
fn test_deserial_rgb() {
    assert_eq!(
        serde_json::from_str::<Color>("\"rgb_(255,255,255)\"").unwrap(),
        Color::from((255, 255, 255))
    );
}

#[test]
fn test_deserial_unvalid_rgb() {
    assert!(serde_json::from_str::<Color>("\"rgb_(255,255,255,255)\"").is_err());
    assert!(serde_json::from_str::<Color>("\"rgb_(256,255,255)\"").is_err());
}

#[test]
fn test_deserial_rgb_hex() {
    assert_eq!(serde_json::from_str::<Color>("\"#ffffff\"").unwrap(), Color::from((255, 255, 255)));
    assert_eq!(serde_json::from_str::<Color>("\"#FFFFFF\"").unwrap(), Color::from((255, 255, 255)));
}

#[test]
fn test_deserial_unvalid_rgb_hex() {
    assert!(serde_json::from_str::<Color>("\"#FFFFFFFF\"").is_err());
    assert!(serde_json::from_str::<Color>("\"#FFGFFF\"").is_err());
    // Ferris is 4 bytes so this will be considered the correct length.
    assert!(serde_json::from_str::<Color>("\"#ff🦀\"").is_err());
}
