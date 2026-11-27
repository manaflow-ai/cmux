use super::*;
use serde_json::Value;

const SCHEMA: &str = include_str!("../../../../schemas/deeplinks/agent-link.json");

fn fields(link: &AgentLink) -> Value {
    let mut v = serde_json::json!({"harness": link.harness, "session": link.session});
    for (k, f) in [
        ("host", &link.host),
        ("name", &link.name),
        ("message", &link.message),
        ("machine", &link.machine),
    ] {
        if let Some(f) = f {
            v[k] = Value::String(f.clone());
        }
    }
    v
}

/// Every vector of the shared schema: the web form and the native form read the same fields,
/// and a link the page and the app refuse is refused here.
#[test]
fn the_schema_vectors_read_the_same_here() {
    assert!(WEB.is_some() && NATIVE.is_some(), "a link pattern does not compile");
    let schema: Value = serde_json::from_str(SCHEMA).unwrap();
    for v in schema["vectors"].as_array().unwrap() {
        let name = v["name"].as_str().unwrap();
        let mut forms = Vec::new();
        if let Some(web) = v["web"].as_str() {
            forms.push(format!("https://cmux.com{WEB_PATH}?{web}"));
        }
        if let Some(link) = v["link"].as_str() {
            forms.push(link.to_owned());
        }
        for form in forms {
            let got = find(&form).unwrap_or_else(|| panic!("{name}: no link in {form}"));
            match (&v["fields"], got) {
                (Value::Null, Err(_)) => {}
                (Value::Null, Ok(link)) => panic!("{name}: {form} read as {link:?}"),
                (want, Ok(link)) => assert_eq!(&fields(&link), want, "{name}: {form}"),
                (_, Err(e)) => panic!("{name}: {form} refused: {e}"),
            }
        }
    }
}

#[test]
fn a_pr_footer_line_carries_its_link() {
    let line = "Agent session: [my-vm](https://cmux.com/deeplink/agent?harness=claude&session=01a16c8c-54ec-71b2-a0fa-125d1404dd72&host=my-vm)";
    let link = find(line).unwrap().unwrap();
    assert_eq!(link.harness, "claude");
    assert_eq!(link.session, "01a16c8c-54ec-71b2-a0fa-125d1404dd72");
    assert_eq!(link.host.as_deref(), Some("my-vm"));
    // A localized page and an HTML-escaped query read the same.
    let html = "https://cmux.com/en/deeplink/agent?harness=codex&amp;session=s%3A1&amp;host=hb";
    let link = find(html).unwrap().unwrap();
    assert_eq!((link.harness.as_str(), link.session.as_str()), ("codex", "s:1"));
    assert_eq!(link.host.as_deref(), Some("hb"));
}

#[test]
fn a_written_link_reads_back_and_leaves_out_what_the_schema_refuses() {
    let link = AgentLink {
        harness: "claude".into(),
        session: "s:1".into(),
        host: Some("my-vm".into()),
        name: Some("two words".into()),
        ..Default::default()
    };
    let url = link.web_url().unwrap();
    assert_eq!(url, "https://cmux.com/deeplink/agent?harness=claude&session=s:1&host=my-vm");
    assert_eq!(find(&url).unwrap().unwrap(), AgentLink { name: None, ..link });
    assert!(AgentLink { harness: "Claude".into(), ..Default::default() }.web_url().is_none());
}

#[test]
fn text_without_a_link_is_not_one() {
    assert!(find("https://cmux.com/deeplink/agent").unwrap().is_err());
    for not in [
        "builder/review",
        "01a16c8c-54ec-71b2-a0fa-125d1404dd72",
        "builder/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/deeplink/agentx?harness=claude&session=s1",
        "https://evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com.evil.com/deeplink/agent?harness=claude&session=s1",
        "https://cmux.com/x/y/deeplink/agent?harness=claude&session=s1",
        "http://cmux.com/deeplink/agent?harness=claude&session=s1",
        "notcmux://agent/claude/s1",
        "see https://evil.com/?u=cmux://agent/claude/s1",
    ] {
        assert!(find(not).is_none(), "{not}");
    }
    // In markdown, angle brackets or quotes it still reads.
    for text in [
        "<cmux://agent/claude/s1>",
        "(https://cmux.com/zh-CN/deeplink/agent?harness=claude&session=s1)",
        "\"https://www.cmux.com/deeplink/agent/?harness=claude&session=s1\"",
    ] {
        assert_eq!(find(text).unwrap().unwrap().session, "s1", "{text}");
    }
}
