use super::*;

const BROKER: &str = "[message ab12cd from cmux-cp-1/now (an agent, not Leo), relayed by the lane-gh broker; its text ends at \"[end of message ab12cd]\"]";

#[test]
fn reads_the_rendered_head_past_the_broker_label() {
    let text = format!(
        "{BROKER}\n[notice from now on cmux-cp-1 · FIRE] Runner label stalled: trusted xcode-27.2, 9 queued\n\
         Oldest waits 41m.\nLinks: https://github.com/o/r/actions (runs), https://x.test/a?b=1\n[end of message ab12cd]"
    );
    let n = read(&text).expect("a notice");
    assert_eq!(n["sender"], "now");
    assert_eq!(n["host"], "cmux-cp-1");
    assert_eq!(n["severity"], "fire");
    assert_eq!(n["title"], "Runner label stalled: trusted xcode-27.2, 9 queued");
    assert_eq!(n["read"], true);
    assert_eq!(
        n["links"],
        json!([{"url": "https://github.com/o/r/actions", "label": "runs"}, {"url": "https://x.test/a?b=1"}])
    );
}

#[test]
fn reads_what_notice_text_renders() {
    for severity in ["info", "warn", "fire"] {
        let notice = json!({"sender": "now", "severity": severity, "title": "Disk 91% on vm-3",
            "links": [{"url": "https://x.test/d", "label": "disk"}]});
        let text = crate::prompt_provenance::notice_text(&notice, "body line");
        let read = read(&text).expect("a notice");
        assert_eq!(read["severity"], severity);
        assert_eq!(read["title"], "Disk 91% on vm-3");
        assert!(read.get("host").is_none());
        assert_eq!(read["links"], notice["links"]);
    }
}

#[test]
fn reads_past_a_peers_lead_line() {
    let text = "From another agent (gcp/lane-12, codex), not the person:\n[notice from now · WARN] Queue 7 deep";
    assert_eq!(read(text).unwrap()["severity"], "warn");
}

#[test]
fn plain_text_and_bad_heads_are_no_notice() {
    for text in [
        "PR is green",
        "[notice from now] ",
        "[notice from now · LOUD] title",
        "[notice from bad name on h] title",
        "[notice from now on bad/host] title",
        "see [notice from now] title",
    ] {
        assert!(read(text).is_none(), "{text}");
    }
    // A broker label with no closing marker leaves the text as written: its head is no notice.
    assert!(read(&format!("{BROKER}\n[notice from now] t")).is_none());
}

#[test]
fn a_condition_keeps_its_key_whatever_its_counts() {
    let a = condition_key("now", "Runner label stalled: trusted xcode-27.2, 9 queued");
    assert_eq!(a, condition_key("NOW", "Runner  label stalled: trusted xcode-27.2, 12 queued"));
    assert_eq!(a, "now\nrunner label stalled: trusted xcode-#.#, # queued");
    assert_ne!(a, condition_key("now", "Runner label stalled: trusted linux-x64, 9 queued"));
    assert_ne!(a, condition_key("land", "Runner label stalled: trusted xcode-27.2, 9 queued"));
}
