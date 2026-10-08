//! `LocalId` follows the interface schema: `^[a-z][a-zA-Z0-9-]{0,63}$`
//! (cmux.terminal.backend/1 `options.kinds.items.pattern`).

use ssh_terminal::iface::LocalId;

fn ok(value: &str) -> bool {
    LocalId::new(value).is_ok()
}

#[test]
fn sixty_four_characters_are_accepted_and_sixty_five_are_refused() {
    let longest = format!("a{}", "b".repeat(63));
    assert_eq!(longest.len(), 64);
    assert!(ok(&longest), "64 characters match the schema");
    let too_long = format!("a{}", "b".repeat(64));
    assert!(!ok(&too_long), "65 characters do not match the schema");
}

#[test]
fn the_first_character_is_a_lowercase_ascii_letter() {
    assert!(ok("a"));
    assert!(ok("z9"));
    for bad in ["", "A", "Ab", "9a", "-a", "_a", "\u{e9}a"] {
        assert!(!ok(bad), "{bad:?} must be refused");
    }
}

#[test]
fn later_characters_are_ascii_letters_digits_and_hyphens() {
    for good in ["aB", "cloud-VM-2", "sshTerminal", "a-0-Z"] {
        assert!(ok(good), "{good:?} matches the schema");
    }
    for bad in ["a_b", "a.b", "a b", "a/b", "a\u{e9}", "a\u{212a}"] {
        assert!(!ok(bad), "{bad:?} must be refused");
    }
}
