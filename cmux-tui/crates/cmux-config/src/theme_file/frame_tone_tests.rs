use super::*;

#[test]
fn white_takes_the_frame_rung() {
    assert_eq!(share(Rgb::hex(0xFFFFFF), Rgb::hex(0x000000)), FRAME_RUNG);
}

#[test]
fn every_share_is_one_step_and_no_more() {
    for &(name, base, ink) in &FIXTURE_THEMES {
        let (base, ink) = (Rgb::hex(base), Rgb::hex(ink));
        let s = share(base, ink);
        assert!((FRAME_RUNG..=SELECTED_RUNG).contains(&s), "{name}: {s}");
        let made = step(base, ink, s);
        if s > FRAME_RUNG && s < SELECTED_RUNG {
            assert!((made - STEP).abs() < 1e-4, "{name}: step {made}");
        } else if s == FRAME_RUNG {
            assert!(made >= STEP, "{name}: step {made}");
        }
    }
}

#[test]
fn a_mid_gray_ground_takes_more_than_the_rung() {
    let s = share(Rgb::hex(0x6E6E6E), Rgb::hex(0xF0F0F0));
    assert!(s > FRAME_RUNG && s < SELECTED_RUNG, "{s}");
}

#[test]
fn a_state_washes_to_its_rung_over_the_frame() {
    let under = 0.05;
    let w = wash_over(0.08, under);
    assert!((1.0 - (1.0 - under) * (1.0 - w) - 0.08).abs() < 1e-12);
    assert_eq!(wash_over(0.04, under), 0.0);
}

/// Writes the fixture `FrameToneTests` reads to `CMUX_FRAME_TONE_FIXTURE`;
/// without it, only checks the fixture serializes.
#[test]
fn writes_the_swift_fixture() {
    let fresh = format!("{}\n", serde_json::to_string_pretty(&fixture()).unwrap());
    if let Some(path) = std::env::var_os("CMUX_FRAME_TONE_FIXTURE") {
        std::fs::write(&path, &fresh).unwrap();
    }
    assert!(fresh.contains("\"cases\""));
}
