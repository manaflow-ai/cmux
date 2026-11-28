use super::super::{Attribute, Color, ContentStyle, Stylize};

#[test]
fn set_fg_bg_add_attr() {
    let style = ContentStyle::new().with(Color::Blue).on(Color::Red).attribute(Attribute::Bold);

    assert_eq!(style.foreground_color, Some(Color::Blue));
    assert_eq!(style.background_color, Some(Color::Red));
    assert!(style.attributes.has(Attribute::Bold));

    let mut styled_content = style.apply("test");

    styled_content =
        styled_content.with(Color::Green).on(Color::Magenta).attribute(Attribute::NoItalic);

    let style = styled_content.style();

    assert_eq!(style.foreground_color, Some(Color::Green));
    assert_eq!(style.background_color, Some(Color::Magenta));
    assert!(style.attributes.has(Attribute::Bold));
    assert!(style.attributes.has(Attribute::NoItalic));
}
