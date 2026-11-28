use super::*;

fn sgr(text: &str) -> Vec<Vec<u16>> {
    text.split(';').map(|g| g.split(':').map(|v| v.parse().unwrap_or(0)).collect()).collect()
}

#[test]
fn sgr_round_trips() {
    for text in ["1;31", "38;5;200;48;2;1;2;3", "4:3;58:2::9:8:7", "7;9;53;97;104", "2;3;5;8"] {
        let mut style = Style::default();
        style.apply_sgr(&sgr(text));
        let mut out = Vec::new();
        style.write_sgr(&mut out);
        let written = String::from_utf8(out).unwrap();
        let inner = &written[2..written.len() - 1];
        let mut again = Style::default();
        again.apply_sgr(&sgr(inner));
        assert_eq!(style, again, "{text} -> {written}");
    }
}

#[test]
fn reset_keeps_the_link() {
    let mut style = Style { link: 3, flags: BOLD, ..Style::default() };
    style.apply_sgr(&sgr("0"));
    assert_eq!(style.link, 3);
    assert_eq!(style.flags, 0);
}
