use super::*;

#[test]
fn reads_plain_quoted_and_block_values() {
    let plain = "---\nname: wrangler\ndescription: Deploy Workers.\n---\nbody\n";
    assert_eq!(name_and_description(plain), Some(("wrangler".into(), "Deploy Workers.".into())));
    let quoted = "---\nname: \"goal\"\ndescription: 'Make a goal: done-when'\n---\n";
    assert_eq!(
        name_and_description(quoted),
        Some(("goal".into(), "Make a goal: done-when".into()))
    );
    let folded = "---\nname: aws-auth\ndescription: >-\n  Adds user authentication\n  with Cognito.\n---\n# AWS\n";
    assert_eq!(
        name_and_description(folded),
        Some(("aws-auth".into(), "Adds user authentication with Cognito.".into()))
    );
    let literal = "---\r\nname: x\r\ndescription: |\r\n  one\r\n  two\r\n---\r\n";
    assert_eq!(parse(literal).unwrap().description.as_deref(), Some("one\ntwo"));
}

#[test]
fn missing_fields_and_flags() {
    let only = "---\ndescription: top cmd\ndisable-model-invocation: true\n---\nDo it\n";
    let front = parse(only).unwrap();
    assert_eq!(front.name, None);
    assert_eq!(front.description.as_deref(), Some("top cmd"));
    assert!(front.disable_model_invocation);
    assert_eq!(name_and_description(only), None);
    assert_eq!(parse("no frontmatter"), None);
    assert_eq!(parse("---\n- a list\n---\n"), None);
    assert_eq!(parse("---\n---\n"), Some(Frontmatter::default()));
    // A `---` that starts a longer word does not end the block.
    let dashes = "---\nname: a\ndescription: |\n  x\n  ---word\n---\n";
    assert_eq!(parse(dashes).unwrap().description.as_deref(), Some("x\n---word"));
}
