use super::*;

fn request(name: &str, fingerprint: Option<&str>) -> consent::Request {
    consent::Request {
        id: "s1".into(),
        viewer_id: "v1".into(),
        viewer_name: name.into(),
        viewer_key_fingerprint: fingerprint.map(str::to_owned),
        scope: "view".into(),
        received_ms: 0,
    }
}

#[test]
fn hub_text_is_printed_without_control_characters() {
    assert_eq!(printable("Ann's Mac"), "Ann's Mac");
    assert_eq!(printable("\u{1b}[2J\u{1b}[31mEvil\u{1b}[0m"), "Evil");
    assert_eq!(printable("a\u{1b}]0;title\u{7}b"), "ab");
    assert_eq!(printable("x\ny\rz\t\u{0}\u{7f}\u{9b}1m"), "xyz1m");
    assert_eq!(printable("\u{202e}cod.exe\u{202c}\u{2066}\u{200f}"), "cod.exe");
    let hostile = "\u{1b}[2J\u{202e}Mallory\nlinux-host: approved";
    for line in [request_line(&request(hostile, None)), ask_line(&request(hostile, None))] {
        assert!(
            !line.chars().any(|c| c.is_control() || cmux_hub_host::text::is_bidi_control(c)),
            "{line:?}"
        );
        assert!(line.contains("Mallorylinux-host: approved"), "{line:?}");
    }
}

#[test]
fn fingerprints_are_cut_on_a_character_boundary() {
    // 15 ASCII bytes then a 3-byte character across the 16-byte mark.
    let fp = "0123456789abcde\u{20ac}\u{20ac}tail";
    let line = request_line(&request("Ann", Some(fp)));
    assert!(line.contains("(key 0123456789abcde\u{20ac})"), "{line}");
    let line = request_line(&request("Ann", Some("\u{1b}[31m\u{e9}")));
    assert!(line.contains("(key \u{e9})"), "{line}");
    assert!(request_line(&request("Ann", None)).contains("(key -)"));
}

#[test]
fn the_ask_line_names_this_hosts_commands() {
    let line = ask_line(&request("Ann", None));
    assert!(line.starts_with(&format!("{TAG}: Ann asks to view")), "{line}");
    assert!(line.contains(&format!("{COMMAND} approve s1")), "{line}");
    assert!(line.contains(&format!("{COMMAND} deny s1")), "{line}");
}
