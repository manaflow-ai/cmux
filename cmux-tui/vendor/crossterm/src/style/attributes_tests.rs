use super::{Attribute, Attributes};

#[test]
fn test_attributes() {
    let mut attributes: Attributes = Attribute::Bold.into();
    assert!(attributes.has(Attribute::Bold));
    attributes.set(Attribute::Italic);
    assert!(attributes.has(Attribute::Italic));
    attributes.unset(Attribute::Italic);
    assert!(!attributes.has(Attribute::Italic));
    attributes.toggle(Attribute::Bold);
    assert!(attributes.is_empty());
}

#[test]
fn test_attributes_const() {
    const ATTRIBUTES: Attributes =
        Attributes::none().with(Attribute::Bold).with(Attribute::Italic).without(Attribute::Bold);
    assert!(!ATTRIBUTES.has(Attribute::Bold));
    assert!(ATTRIBUTES.has(Attribute::Italic));
}
