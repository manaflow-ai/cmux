use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn library_words_parse() {
    assert_eq!(parse(&[]).unwrap(), Request::List);
    assert_eq!(parse(&words("ls")).unwrap(), Request::List);
    assert_eq!(parse(&words("on roomy")).unwrap(), Request::On { name: "roomy".into() });
    assert_eq!(parse(&words("off roomy")).unwrap(), Request::Off { name: "roomy".into() });
    assert_eq!(
        parse(&words("order roomy 2")).unwrap(),
        Request::Order { name: "roomy".into(), position: Position::At(2) }
    );
    assert_eq!(
        parse(&words("order roomy top")).unwrap(),
        Request::Order { name: "roomy".into(), position: Position::Top }
    );
    assert_eq!(
        parse(&words("export set.json --link --on --name mine")).unwrap(),
        Request::Export {
            file: Some("set.json".into()),
            link: true,
            only_on: true,
            name: Some("mine".into())
        }
    );
    assert_eq!(
        parse(&words("import - --on")).unwrap(),
        Request::Import { source: "-".into(), on: true }
    );
    for bad in ["on", "on -x", "order roomy 0", "order roomy", "import", "frob", "export a b"] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn a_link_carries_the_collection_and_a_damaged_one_is_refused() {
    let text = "{\"cmuxCollection\":1,\"entries\":[]}\n";
    let link = to_link(text).unwrap();
    assert!(link.starts_with(LINK_PREFIX));
    assert_eq!(from_link(link.strip_prefix(LINK_PREFIX).unwrap()).unwrap(), text);
    assert!(from_link("not base64 at all!").is_err());
    assert!(from_link("AAAA").is_err());
}
