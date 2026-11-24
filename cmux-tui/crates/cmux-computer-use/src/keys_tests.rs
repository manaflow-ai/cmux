#[test]
fn a_trailing_double_plus_is_the_plus_key() {
    let c = KeyCombo::parse("cmd++").unwrap();
    assert_eq!((c.modifiers.clone(), c.key), (vec![Modifier::Meta], Key::Char('+')));
    let c = KeyCombo::parse("ctrl+shift++").unwrap();
    assert_eq!(c.key, Key::Char('+'));
    assert_eq!(c.modifiers.len(), 2);
    assert!(KeyCombo::parse("nope++").is_err());
}

use super::*;

#[test]
fn parses_combos() {
    let c = KeyCombo::parse("cmd+shift+t").unwrap();
    assert_eq!(c.modifiers, vec![Modifier::Shift, Modifier::Meta]);
    assert_eq!(c.key, Key::Char('t'));
    assert_eq!(KeyCombo::parse("Return").unwrap().key, Key::Return);
    assert_eq!(KeyCombo::parse("ctrl+F5").unwrap().key, Key::F(5));
    assert_eq!(KeyCombo::parse("+").unwrap().key, Key::Char('+'));
    assert_eq!(KeyCombo::parse("cmd+plus").unwrap().key, Key::Char('+'));
    assert!(KeyCombo::parse("hyper+x").is_err());
    assert!(KeyCombo::parse("cmd+notakey").is_err());
}
