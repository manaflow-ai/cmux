use super::*;
use super::super::icon::{validate_presentation_icon, validate_presentation_icon_asset};

const SVG_NS: &str = r#"xmlns="http://www.w3.org/2000/svg""#;

fn clean(input: &str) -> String {
    sanitize_svg_icon(input.as_bytes()).expect("sanitizes")
}

fn refused(input: &[u8]) -> String {
    format!("{:#}", sanitize_svg_icon(input).expect_err("refused"))
}

fn assert_absent(output: &str, needles: &[&str]) {
    let lower = output.to_ascii_lowercase();
    for needle in needles {
        assert!(!lower.contains(needle), "{needle:?} survived in {output}");
    }
}

#[test]
fn keeps_a_plain_icon_in_canonical_form() {
    let input = r##"<?xml version="1.0" encoding="UTF-8"?>
<!-- drawn by hand -->
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 24 24" version="1.1">
  <path d="M0 0h24v24H0z" fill="#ff0000"/>
  <circle cx="12" cy="12" r="4" stroke="rgb(0, 0, 0)" stroke-width="2"/>
</svg>"##;
    assert_eq!(
        clean(input),
        format!(
            r##"<svg {SVG_NS} viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#ff0000"></path><circle cx="12" cy="12" r="4" stroke="rgb(0, 0, 0)" stroke-width="2"></circle></svg>"##
        )
    );
}

#[test]
fn sanitized_output_is_a_fixed_point() {
    let input = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff"/></linearGradient></defs>
<g transform="translate(1 2) scale(0.5)" fill="url(#g)"><rect width="4" height="4" rx="1"/></g>
<text x="1" y="7" font-size="3">a &lt; b &amp; &#x41;&#66; &quot;q&quot; <![CDATA[<c>]]></text>
<script>alert(1)</script></svg>"##;
    let once = clean(input);
    assert_eq!(clean(&once), once);
    assert!(once.contains("<text x=\"1\" y=\"7\" font-size=\"3\">a &lt; b &amp; AB &quot;q&quot; &lt;c&gt;</text>"), "{once}");
    assert!(once.contains(r##"fill="url(#g)""##), "{once}");
}

#[test]
fn removes_script_elements_and_their_content() {
    let output = clean(&format!(
        r#"<svg {SVG_NS}><script>alert(document.cookie)</script><SCRIPT>alert(2)</SCRIPT><html:script xmlns:html="http://www.w3.org/1999/xhtml">alert(3)</html:script><script><![CDATA[alert(4)]]></script><rect width="1" height="1"/></svg>"#
    ));
    assert_absent(&output, &["script", "alert"]);
    assert!(output.contains("<rect width=\"1\" height=\"1\"></rect>"), "{output}");
}

#[test]
fn removes_foreign_object_subtrees() {
    let output = clean(&format!(
        r#"<svg {SVG_NS}><foreignObject width="10" height="10"><div xmlns="http://www.w3.org/1999/xhtml"><iframe src="https://evil.example/"></iframe><img src="x" onerror="alert(1)"/></div><text>inner</text></foreignObject></svg>"#
    ));
    assert_eq!(output, format!("<svg {SVG_NS}></svg>"));
}

#[test]
fn removes_external_and_internal_references() {
    let output = clean(
        r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
<image href="https://evil.example/x.png" width="1" height="1"/>
<image xlink:href="data:image/svg+xml;base64,PHN2Zz4=" width="1" height="1"/>
<a href="javascript:alert(1)"><rect width="1" height="1"/></a>
<use href="https://evil.example/sprite.svg#icon"/>
<use xlink:href="#local"/>
<linearGradient id="g" href="https://evil.example/g.svg#g" xlink:href="#h"/>
<feImage href="https://evil.example/"/><filter><feImage xlink:href="https://evil.example/"/></filter>
<pattern id="p" href="https://evil.example/"/>
</svg>"##,
    );
    assert_absent(&output, &["href", "https", "evil", "javascript", "data:", "<a", "<use", "image", "filter", "pattern"]);
    assert!(output.contains(r#"<linearGradient id="g"></linearGradient>"#), "{output}");
}

#[test]
fn removes_event_handler_attributes() {
    let output = clean(&format!(
        r#"<svg {SVG_NS} onload="alert(1)" ONLOAD="alert(2)"><rect width="1" onclick="alert(3)" onmouseover="alert(4)" onbegin="alert(5)"/><g onfocusin="alert(6)"/></svg>"#
    ));
    assert_absent(&output, &["alert", "onload", "onclick", "onmouseover", "onbegin", "onfocusin"]);
    assert_eq!(output, format!(r#"<svg {SVG_NS}><rect width="1"></rect><g></g></svg>"#));
}

#[test]
fn removes_animation_that_could_rewrite_attributes() {
    let output = clean(&format!(
        r#"<svg {SVG_NS}><rect width="1"><set attributeName="href" to="javascript:alert(1)"/><animate attributeName="fill" values="red;url(https://evil.example/)"/></rect><animateTransform/><animateMotion/></svg>"#
    ));
    assert_absent(&output, &["set", "animate", "javascript", "evil"]);
}

#[test]
fn css_url_only_names_a_fragment_in_the_same_icon() {
    let output = clean(&format!(
        r##"<svg {SVG_NS}>
<rect id="a" fill="url(https://evil.example/x.svg#p)" stroke="url( #ok )" width="1"/>
<rect id="b" fill="URL(//evil.example/p)" clip-path="url(#clip)" mask="url('#m')"/>
<rect id="c" fill="u\rl(https://evil.example/)" stroke="\75 rl(https://evil.example/)"/>
<rect id="d" style="fill:url(https://evil.example/)" fill="image(https://evil.example/)"/>
<rect id="e" fill="red;background:url(x)" stroke="expression(alert(1))"/>
<rect id="f" fill="#00f" stroke="currentColor" stroke-width="url(#w) url(https://evil.example/)"/>
<style>@import url(https://evil.example/a.css); rect {{ fill: url(https://evil.example/) }}</style>
</svg>"##
    ));
    assert_absent(&output, &["evil", "style", "image(", "expression", "\\", "'"]);
    assert!(output.contains(r##"<rect id="a" stroke="url( #ok )" width="1"></rect>"##), "{output}");
    assert!(output.contains(r##"<rect id="b" clip-path="url(#clip)"></rect>"##), "{output}");
    assert!(output.contains(r##"<rect id="f" fill="#00f" stroke="currentColor"></rect>"##), "{output}");
}

#[test]
fn refuses_entity_expansion_and_any_doctype() {
    let laughs = r#"<?xml version="1.0"?>
<!DOCTYPE lolz [
 <!ENTITY lol "lol">
 <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
 <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
 <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
]>
<svg xmlns="http://www.w3.org/2000/svg"><text>&lol3;</text></svg>"#;
    assert!(refused(laughs.as_bytes()).contains("DOCTYPE"));
    let external = r#"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg xmlns="http://www.w3.org/2000/svg"/>"#;
    assert!(refused(external.as_bytes()).contains("DOCTYPE"));
    let xxe = r#"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg"><text>&x;</text></svg>"#;
    assert!(refused(xxe.as_bytes()).contains("DOCTYPE"));
    let undeclared = format!(r#"<svg {SVG_NS}><text>&lol;</text></svg>"#);
    assert!(refused(undeclared.as_bytes()).contains("entity"));
    let in_attribute = format!(r#"<svg {SVG_NS}><rect width="&lol;"/></svg>"#);
    assert!(sanitize_svg_icon(in_attribute.as_bytes()).is_err());
}

#[test]
fn refuses_oversized_input() {
    let mut big = format!(r#"<svg {SVG_NS}><path d=""#);
    big.push_str(&"M0 0".repeat(MAX_SVG_ICON_BYTES / 4));
    big.push_str(r#""/></svg>"#);
    assert!(big.len() > MAX_SVG_ICON_BYTES);
    assert!(refused(big.as_bytes()).contains("64 KiB"));

    // Already canonical, so the output is the same 64 KiB.
    let mut fits = format!(r#"<svg {SVG_NS}><path d=""#);
    let padding = MAX_SVG_ICON_BYTES - fits.len() - r#""></path></svg>"#.len();
    fits.push_str(&"0".repeat(padding));
    fits.push_str(r#""></path></svg>"#);
    assert_eq!(fits.len(), MAX_SVG_ICON_BYTES);
    assert_eq!(clean(&fits), fits);
}

#[test]
fn refuses_output_that_grows_past_the_limit() {
    // `"` in text becomes `&quot;` (six bytes for one).
    let mut text = format!(r#"<svg {SVG_NS}><text>"#);
    let filler = MAX_SVG_ICON_BYTES - text.len() - "</text></svg>".len();
    text.push_str(&"\"".repeat(filler));
    text.push_str("</text></svg>");
    assert_eq!(text.len(), MAX_SVG_ICON_BYTES);
    assert!(refused(text.as_bytes()).contains("64 KiB"));
}

#[test]
fn refuses_deep_nesting_without_recursing() {
    let deep = |levels: usize| {
        format!(r#"<svg {SVG_NS}>{}{}</svg>"#, "<g>".repeat(levels), "</g>".repeat(levels))
    };
    assert!(sanitize_svg_icon(deep(MAX_SVG_ICON_DEPTH - 1).as_bytes()).is_ok());
    assert!(refused(deep(MAX_SVG_ICON_DEPTH).as_bytes()).contains("nest"));
    assert!(refused(deep(9_000).as_bytes()).contains("nest"));
    // Dropped subtrees count too.
    let hidden = format!(
        r#"<svg {SVG_NS}><script>{}{}</script></svg>"#,
        "<x>".repeat(MAX_SVG_ICON_DEPTH),
        "</x>".repeat(MAX_SVG_ICON_DEPTH)
    );
    assert!(refused(hidden.as_bytes()).contains("nest"));
}

#[test]
fn refuses_too_many_elements() {
    let many = format!(r#"<svg {SVG_NS}>{}</svg>"#, "<g/>".repeat(MAX_SVG_ICON_ELEMENTS));
    assert!(refused(many.as_bytes()).contains("elements"));
}

#[test]
fn refuses_documents_that_are_not_one_svg_element() {
    for bad in [
        "".as_bytes(),
        b"   ",
        b"<html><svg/></html>",
        b"<SVG xmlns=\"http://www.w3.org/2000/svg\"/>",
        b"<svg:svg xmlns:svg=\"http://www.w3.org/2000/svg\"/>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"><g></svg>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"><g>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"/><svg xmlns=\"http://www.w3.org/2000/svg\"/>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>trailing",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" width=\"2\"/>",
        b"<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><svg/>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"><text>\xff</text></svg>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"><text>a\x01b</text></svg>",
        b"<svg xmlns=\"http://www.w3.org/2000/svg\"><text>&#1;</text></svg>",
    ] {
        assert!(sanitize_svg_icon(bad).is_err(), "accepted {:?}", String::from_utf8_lossy(bad));
    }
}

#[test]
fn drops_namespace_tricks_and_processing_instructions() {
    let output = clean(
        r#"<?xml-stylesheet href="https://evil.example/a.css"?><svg xmlns="http://www.w3.org/2000/svg"><g xmlns="http://www.w3.org/1999/xhtml" xml:base="https://evil.example/"><rect width="1"/></g><svg:rect xmlns:svg="http://www.w3.org/2000/svg" width="2"/></svg>"#,
    );
    assert_eq!(output, format!(r#"<svg {SVG_NS}><g><rect width="1"></rect></g></svg>"#));
}

#[test]
fn icon_wire_names_the_sanitized_bytes() {
    let sanitized = clean(&format!(r#"<svg {SVG_NS}><rect width="1"/></svg>"#));
    let wire = svg_icon_wire(&sanitized);
    assert!(wire.starts_with("svg:sha256-") && wire.len() == 11 + 64, "{wire}");
    validate_presentation_icon_asset(&wire, sanitized.as_bytes()).expect("owner accepts");
    // The owner sanitizes again: a client's raw copy, even with a matching
    // digest, is refused unless it is already the sanitized form.
    let raw = format!(r#"<svg {SVG_NS}><script>alert(1)</script><rect width="1"/></svg>"#);
    assert!(validate_presentation_icon_asset(&svg_icon_wire(&raw), raw.as_bytes()).is_err());
    let other = clean(&format!(r#"<svg {SVG_NS}><rect width="2"/></svg>"#));
    assert!(validate_presentation_icon_asset(&wire, other.as_bytes()).is_err());
    for bad in ["svg:sha256-xyz", "image:sha256-00", &wire.to_ascii_uppercase(), &wire[4..]] {
        assert!(validate_presentation_icon_asset(bad, sanitized.as_bytes()).is_err(), "{bad}");
    }
    // Until the asset store exists, a bare reference is refused.
    assert!(validate_presentation_icon(&wire).is_err());
    validate_presentation_icon("star.fill").expect("symbol still valid");
}
