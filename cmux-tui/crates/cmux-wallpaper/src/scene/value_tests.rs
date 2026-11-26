use super::*;
use serde_json::json;

#[test]
fn a_plain_value_is_a_constant() {
    let t = Track::number(&json!(0.5), "/x", 10.0, 0.0, 1.0).unwrap();
    assert!(!t.is_animated());
    assert_eq!(t.at(0.0), 0.5);
    assert_eq!(t.at(9.0), 0.5);
}

#[test]
fn keys_interpolate_hold_and_clamp() {
    let t = Track::number(&json!({"keys": [[2, 0], [4, 1], [6, 0, "hold"]]}), "/x", 10.0, 0.0, 1.0)
        .unwrap();
    assert!(t.is_animated());
    assert_eq!(t.at(0.0), 0.0);
    assert_eq!(t.at(3.0), 0.5);
    assert_eq!(t.at(5.9), 1.0);
    assert_eq!(t.at(6.0), 0.0);
    assert_eq!(t.at(9.0), 0.0);
}

#[test]
fn keys_out_of_order_or_range_are_refused() {
    let e = Track::number(&json!({"keys": [[4, 0], [2, 1]]}), "/x", 10.0, 0.0, 1.0).unwrap_err();
    assert_eq!(e.pointer, "/x/keys/1/0");
    let e = Track::number(&json!({"keys": [[11, 0]]}), "/x", 10.0, 0.0, 1.0).unwrap_err();
    assert_eq!(e.kind, ManifestErrorKind::OutOfRange);
    let e = Track::number(&json!({"keys": [[1, 2]]}), "/x", 10.0, 0.0, 1.0).unwrap_err();
    assert_eq!(e.pointer, "/x/keys/0/1");
    let e = Track::number(&json!({"keys": [[1, 0]], "loop": 2}), "/x", 10.0, 0.0, 1.0).unwrap_err();
    assert_eq!(e.kind, ManifestErrorKind::UnknownKey);
}

#[test]
fn eases_start_at_0_and_end_at_1() {
    for e in [
        Ease::Linear,
        Ease::In,
        Ease::Out,
        Ease::InOut,
        Ease::Sine,
        Ease::Bezier([0.4, 0.0, 0.2, 1.0]),
    ] {
        assert!(e.apply(0.0).abs() < 1e-4, "{e:?}");
        assert!((e.apply(1.0) - 1.0).abs() < 1e-4, "{e:?}");
    }
    assert!(Ease::In.apply(0.5) < 0.5 && Ease::Out.apply(0.5) > 0.5);
    // CSS ease (0.25, 0.1, 0.25, 1) at x = 0.5 is about 0.8024.
    assert!((Ease::Bezier([0.25, 0.1, 0.25, 1.0]).apply(0.5) - 0.8024).abs() < 2e-3);
}

#[test]
fn colors_take_hex_theme_tokens_and_mixes() {
    let theme = Theme { ink: [0.0; 3], paper: [1.0; 3], accent: [1.0, 0.0, 0.0] };
    let c = |s: &str| ColorSpec::parse(&json!(s), "/c").unwrap().resolve(&theme);
    assert_eq!(c("#FFFFFF"), [1.0, 1.0, 1.0, 1.0]);
    assert!((c("#00000080")[3] - 0.502).abs() < 1e-3);
    assert_eq!(c("accent"), [1.0, 0.0, 0.0, 1.0]);
    assert_eq!(c("accent 50% paper"), [1.0, 0.5, 0.5, 1.0]);
    for bad in ["#FFF", "blue", "accent 150% paper", "accent paper"] {
        assert!(ColorSpec::parse(&json!(bad), "/c").is_err(), "{bad}");
    }
}

#[test]
fn color_keys_follow_the_theme() {
    let t = Track::color(&json!({"keys": [[0, "ink"], [2, "paper"]]}), "/c", 4.0).unwrap();
    let dark = Theme { ink: [1.0; 3], paper: [0.0; 3], accent: [0.0; 3] };
    assert_eq!(t.at(1.0, &dark), [0.5, 0.5, 0.5, 1.0]);
    assert_eq!(t.at(2.0, &dark), [0.0, 0.0, 0.0, 1.0]);
}
