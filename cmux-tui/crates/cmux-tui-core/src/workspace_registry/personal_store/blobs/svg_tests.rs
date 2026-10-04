//! The SVG sanitizer: refusals, the allowlist on known attack shapes, and a
//! property test over generated documents.

use proptest::prelude::*;
use quick_xml::Reader;

use super::*;

const OPEN: &str = r#"<svg xmlns="http://www.w3.org/2000/svg">"#;
const XLINK_OPEN: &str =
    r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">"#;

fn clean(input: &str) -> String {
    sanitize_svg(input.as_bytes()).unwrap_or_else(|error| panic!("{input}: {error}"))
}

fn refused(input: &[u8]) -> String {
    sanitize_svg(input).expect_err("the document must be refused").to_string()
}

fn wrap(body: &str) -> String {
    format!("{OPEN}{body}</svg>")
}

#[test]
fn scripts_event_attributes_and_styles_are_dropped() {
    assert_eq!(
        clean(&wrap("<script>alert(1)</script><rect width=\"1\"/>")),
        wrap("<rect width=\"1\"/>")
    );
    assert_eq!(
        clean(
            r#"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)" width="2"><g onclick="x()"/></svg>"#
        ),
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="2"><g/></svg>"#
    );
    assert_eq!(
        clean(&wrap(
            r#"<style>@import url(https://evil.example/x.css);</style><path style="fill:red" d="M0 0"/>"#
        )),
        wrap(r#"<path d="M0 0"/>"#)
    );
    // Names are case-sensitive: an upper-case SCRIPT is not an SVG element.
    assert_eq!(
        clean(&wrap("<SCRIPT>alert(1)</SCRIPT>")),
        r#"<svg xmlns="http://www.w3.org/2000/svg"/>"#
    );
}

#[test]
fn foreign_content_images_links_animation_and_text_are_dropped_with_their_subtrees() {
    let body = r#"<foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><script>x()</script></div></foreignObject><image href="https://evil.example/a.png"/><a href="https://evil.example"><rect width="3"/></a><animate attributeName="href" to="javascript:x()"/><set attributeName="fill" to="red"/><animateTransform/><animateMotion/><text>hi<tspan>there</tspan></text><circle r="1"/>"#;
    assert_eq!(clean(&wrap(body)), wrap(r#"<circle r="1"/>"#));
}

#[test]
fn references_must_stay_inside_the_document() {
    let body = r##"<defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs><use href="https://evil.example/s.svg#a"/><use href="#g"/><use xlink:href="#g"/><use xlink:href="data:image/svg+xml,x"/><rect fill="url(http://evil.example/#g)"/><rect fill="url(#g)" clip-path="url( '#g' )"/><rect fill="url(data:x)"/><rect fill="URL(//evil.example/a)"/><rect fill="image-set(//evil.example/a.png 1x)"/><rect fill="\75rl(//evil.example/a)"/><a href="javascript:alert(1)"/><rect id="javascript:x" transform="rotate(45) translate(1 2)"/><rect fill="java&#x73;cript:x()"/>"##;
    let input = format!("{XLINK_OPEN}{body}</svg>");
    assert_eq!(
        clean(&input),
        format!(
            "{XLINK_OPEN}{}</svg>",
            r##"<defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs><use/><use href="#g"/><use xlink:href="#g"/><use/><rect/><rect fill="url(#g)" clip-path="url( &apos;#g&apos; )"/><rect/><rect/><rect/><rect/><rect transform="rotate(45) translate(1 2)"/><rect/>"##
        )
    );
    // Without a kept xlink:href the output declares no xlink namespace.
    assert_eq!(clean(&format!("{XLINK_OPEN}<use xlink:href=\"http://x\"/></svg>")), wrap("<use/>"));
}

#[test]
fn a_use_never_copies_another_use() {
    let body = r##"<defs><g id="a"><path d="M0 0"/></g><g id="b"><use href="#a"/><use href="#a"/></g></defs><use href="#b"/><use href="#a"/><g id="c"><use href="#c"/></g>"##;
    let expected = r##"<defs><g id="a"><path d="M0 0"/></g><g id="b"><use href="#a"/><use href="#a"/></g></defs><use href="#a"/><g id="c"/>"##;
    assert_eq!(clean(&wrap(body)), wrap(expected));
    // A use of the root (which holds a use) is a cycle.
    let root = r##"<svg xmlns="http://www.w3.org/2000/svg" id="r"><use href="#r"/></svg>"##;
    assert_eq!(clean(root), r##"<svg xmlns="http://www.w3.org/2000/svg" id="r"/>"##);
}

#[test]
fn reference_chains_that_multiply_or_cycle_are_refused() {
    // Each level is a mask that draws ten paths, and each path is masked by
    // the next level: 10^levels draws without a single nested use.
    let mut body = String::from("<defs>");
    for level in 0..6 {
        body.push_str(&format!("<mask id=\"m{level}\">"));
        for _ in 0..10 {
            body.push_str(&format!("<path d=\"M0 0\" mask=\"url(#m{})\"/>", level + 1));
        }
        body.push_str("</mask>");
    }
    body.push_str("<mask id=\"m6\"><path d=\"M0 0\"/></mask></defs><rect mask=\"url(#m0)\"/>");
    assert!(refused(wrap(&body).as_bytes()).contains("more than"));
    // The same through uses of masked paths (each use names a path without a use).
    let mut body = String::from("<defs>");
    for level in 0..6 {
        body.push_str(&format!("<path id=\"p{level}\" d=\"M0 0\" mask=\"url(#n{level})\"/><mask id=\"n{level}\">"));
        for _ in 0..10 {
            body.push_str(&format!("<use href=\"#p{}\"/>", level + 1));
        }
        body.push_str("</mask>");
    }
    body.push_str("<path id=\"p6\" d=\"M0 0\"/></defs><use href=\"#p0\"/>");
    assert!(refused(wrap(&body).as_bytes()).contains("more than"));
    for cycle in [
        r##"<mask id="a"><path mask="url(#a)"/></mask><rect mask="url(#a)"/>"##,
        r##"<clipPath id="a"><rect clip-path="url(#b)"/></clipPath><clipPath id="b"><rect clip-path="url(#a)"/></clipPath><rect clip-path="url(#a)"/>"##,
        r##"<linearGradient id="a" href="#b"/><linearGradient id="b" href="#a"/><rect fill="url(#a)"/>"##,
    ] {
        assert!(refused(wrap(cycle).as_bytes()).contains("cycle"), "{cycle}");
    }
    // A small shared definition used several times is fine.
    let ok = r##"<defs><linearGradient id="g"><stop offset="0"/></linearGradient></defs><rect fill="url(#g)"/><circle fill="url(#g)"/>"##;
    assert_eq!(clean(&wrap(ok)), wrap(ok));
}

#[test]
fn output_never_repeats_an_attribute_or_carries_a_non_xml_character() {
    let doubled = r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink" xmlns:y="http://www.w3.org/1999/xlink"><use x:href="#a" y:href="#b"/></svg>"##;
    assert_eq!(
        clean(doubled),
        format!("{XLINK_OPEN}<use xlink:href=\"#a\"/></svg>")
    );
    let odd = "<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"a&#xFFFF;b\"><title>x&#xFFFE;y\u{FFFF}z</title></svg>";
    assert_eq!(
        clean(odd),
        r#"<svg xmlns="http://www.w3.org/2000/svg" id="a b"><title>xyz</title></svg>"#
    );
}

#[test]
fn doctype_entities_processing_instructions_and_cdata_never_reach_the_output() {
    let billion_laughs = r#"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;"><!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">]><svg xmlns="http://www.w3.org/2000/svg"><title>&lol3;</title></svg>"#;
    assert!(refused(billion_laughs.as_bytes()).contains("undeclared entity"));
    let in_attribute = r#"<!DOCTYPE svg [<!ENTITY x "javascript:alert(1)">]><svg xmlns="http://www.w3.org/2000/svg"><use href="&x;"/></svg>"#;
    assert!(refused(in_attribute.as_bytes()).contains("undeclared entity"));
    let external = r#"<!DOCTYPE svg [<!ENTITY ext SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg"><title>&ext;</title></svg>"#;
    assert!(refused(external.as_bytes()).contains("undeclared entity"));
    // A plain DOCTYPE (as editors write it), PIs, comments and CDATA are dropped.
    let editor = r#"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><?xml-stylesheet href="https://evil.example/a.css"?><!-- made by hand --><svg xmlns="http://www.w3.org/2000/svg"><![CDATA[<script>x()</script>]]><title>A &amp; B &#60;3</title></svg>"#;
    assert_eq!(clean(editor), wrap("<title>A &amp; B &lt;3</title>"));
}

#[test]
fn documents_that_are_not_well_formed_svg_are_refused() {
    for input in [
        "",
        "plain text",
        "<html><body/></html>",
        "<svg/>",
        r#"<svg xmlns="http://www.w3.org/1999/xhtml"/>"#,
        r#"<x:svg xmlns:x="urn:not-svg"/>"#,
        r#"<svg xmlns="http://www.w3.org/2000/svg"><g></svg>"#,
        r#"<svg xmlns="http://www.w3.org/2000/svg"><g>"#,
        r#"<svg xmlns="http://www.w3.org/2000/svg"/><svg xmlns="http://www.w3.org/2000/svg"/>"#,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="1" width="2"/>"#,
        r#"<svg xmlns="http://www.w3.org/2000/svg"><title>&nbsp;</title></svg>"#,
    ] {
        refused(input.as_bytes());
    }
    refused(b"<svg xmlns=\"http://www.w3.org/2000/svg\">\xff</svg>");
    let deep = format!("{OPEN}{}{}</svg>", "<g>".repeat(MAX_DEPTH), "</g>".repeat(MAX_DEPTH));
    assert!(refused(deep.as_bytes()).contains("deeper"));
    let mut large = OPEN.as_bytes().to_vec();
    large.resize(MAX_SVG_BYTES + 1 - 6, b' ');
    large.extend_from_slice(b"</svg>");
    assert!(refused(&large).contains("exceeds"));
    // A prefixed SVG root is accepted and written unprefixed.
    assert_eq!(
        clean(r#"<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:g/></s:svg>"#),
        wrap("<g/>")
    );
}

/// Assert the structural properties every sanitized document has.
fn assert_clean(output: &str) {
    let mut reader = Reader::from_str(output);
    loop {
        match reader.read_event().expect("the output re-parses") {
            Event::Start(start) | Event::Empty(start) => {
                let name = std::str::from_utf8(start.name().as_ref()).unwrap().to_string();
                assert!(ELEMENTS.contains(&name.as_str()), "element {name} in {output}");
                for attribute in start.attributes() {
                    let attribute = attribute.expect("attributes re-parse");
                    let key = std::str::from_utf8(attribute.key.as_ref()).unwrap().to_string();
                    let value =
                        attribute.normalized_value(XmlVersion::Implicit1_0).unwrap().to_string();
                    if key == "xmlns" || key == "xmlns:xlink" {
                        assert!(value == SVG_NAMESPACE || value == XLINK_NAMESPACE);
                        continue;
                    }
                    assert!(
                        ATTRIBUTES.contains(&key.as_str()) || key == "xlink:href",
                        "attribute {key} in {output}"
                    );
                    assert!(safe_value(&value), "value {value} in {output}");
                    if key.ends_with("href") {
                        assert!(value.starts_with('#'), "href {value} in {output}");
                    }
                }
            }
            Event::GeneralRef(reference) => {
                let name = reference.decode().unwrap().to_string();
                assert!(
                    reference.is_char_ref() || resolve_predefined_entity(&name).is_some(),
                    "entity {name} in {output}"
                );
            }
            Event::End(_) | Event::Text(_) => {}
            Event::Eof => break,
            other => panic!("unexpected {other:?} in {output}"),
        }
    }
    let lower = output.to_ascii_lowercase();
    for banned in ["<script", "<style", "<foreignobject", "<image", "<!doctype", "<![cdata", "<?"] {
        assert!(!lower.contains(banned), "{banned} in {output}");
    }
}

fn fragment() -> impl Strategy<Value = String> {
    let element = prop::sample::select(vec![
        "g",
        "path",
        "rect",
        "use",
        "title",
        "desc",
        "defs",
        "linearGradient",
        "stop",
        "mask",
        "script",
        "style",
        "foreignObject",
        "image",
        "a",
        "animate",
        "set",
        "text",
        "tspan",
        "SCRIPT",
        "x:script",
        "svg",
    ]);
    let attribute = prop::sample::select(vec![
        "d",
        "fill",
        "href",
        "xlink:href",
        "id",
        "transform",
        "style",
        "onload",
        "onclick",
        "clip-path",
        "mask",
        "xmlns",
        "xmlns:xlink",
        "xml:space",
        "x:href",
        "width",
    ]);
    let value = prop::sample::select(vec![
        "a",
        "#a",
        "url(#a)",
        "url( \"#a\" )",
        "url(http://evil/x#a)",
        "javascript:alert(1)",
        "data:text/html,x",
        "M0 0L1 1",
        "rotate(3)",
        "image-set(//evil/x 1x)",
        "\\75rl(//e)",
        "red",
        "http://www.w3.org/2000/svg",
        "http://www.w3.org/1999/xlink",
        "java&#x73;cript:x",
        "&amp;&lt;&gt;&quot;",
        "&#10;a&#13;b&#9;",
        "expression(alert(1))",
        "",
    ]);
    let text = prop::sample::select(vec![
        "hello",
        "&amp;",
        "&#60;script&#62;",
        "<![CDATA[<script>x()</script>]]>",
        "<!-- c -->",
        "<?pi x?>",
        "a\r\nb",
        "&#13;",
        "  ",
        "javascript:alert(1)",
    ]);
    let leaf = prop_oneof![
        text.prop_map(str::to_string),
        (element.clone(), prop::collection::vec((attribute.clone(), value.clone()), 0..3))
            .prop_map(|(name, attributes)| format!("<{name}{}/>", render(&attributes))),
    ];
    leaf.prop_recursive(4, 48, 6, move |inner| {
        (
            element.clone(),
            prop::collection::vec((attribute.clone(), value.clone()), 0..3),
            prop::collection::vec(inner, 0..6),
        )
            .prop_map(|(name, attributes, children)| {
                format!("<{name}{}>{}</{name}>", render(&attributes), children.concat())
            })
    })
}

/// Attributes with unique names (a duplicate refuses the whole document).
fn render(attributes: &[(&str, &str)]) -> String {
    let mut seen = Vec::new();
    let mut output = String::new();
    for (name, value) in attributes {
        if seen.contains(name) {
            continue;
        }
        seen.push(*name);
        output.push_str(&format!(" {name}=\"{value}\""));
    }
    output
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn generated_documents_sanitize_to_clean_idempotent_svg(
        children in prop::collection::vec(fragment(), 0..6),
        doctype in any::<bool>(),
    ) {
        let prefix = if doctype { r#"<!DOCTYPE svg [<!ENTITY e "x">]>"# } else { "" };
        let input = format!(
            r#"{prefix}<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:x="urn:x">{}</svg>"#,
            children.concat()
        );
        if let Ok(output) = sanitize_svg(input.as_bytes()) {
            assert_clean(&output);
            prop_assert_eq!(sanitize_svg(output.as_bytes()).unwrap(), output);
        }
    }

    #[test]
    fn arbitrary_bytes_never_produce_unclean_output(input in prop::collection::vec(any::<u8>(), 0..512)) {
        if let Ok(output) = sanitize_svg(&input) {
            assert_clean(&output);
            prop_assert_eq!(sanitize_svg(output.as_bytes()).unwrap(), output);
        }
    }
}
