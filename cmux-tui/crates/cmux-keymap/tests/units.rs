//! Stroke parsing, the physical key table and the C ABI.

use cmux_keymap::ffi::{
    CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT, CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS, CMUX_KEYMAP_MOD_CMD,
    CMUX_KEYMAP_MOD_CTRL, CMUX_KEYMAP_MOD_SHIFT, CMUX_KEYMAP_NO_KEY_CODE, CMUX_KEYMAP_PASS,
    CMUX_KEYMAP_PENDING, CMUX_KEYMAP_STYLE_EMACS, CMUX_KEYMAP_STYLE_VIM, cmux_keymap_feed,
    cmux_keymap_free, cmux_keymap_new, cmux_keymap_reset, cmux_keymap_stroke_matches,
};
use cmux_keymap::{
    KEY_STYLES_JSON, ListCommand, Mods, Stroke, code_for_mac_key_code, mac_key_code_for_code,
    qwerty_char,
};
use std::ffi::CString;
use std::ptr;

fn stroke(mods: Mods, key: &str) -> Option<Stroke> {
    Some(Stroke { mods, key: key.to_owned() })
}

#[test]
fn strokes_parse_in_keybindings_syntax() {
    let cmd = Mods { cmd: true, ..Mods::NONE };
    let cmd_shift = Mods { cmd: true, shift: true, ..Mods::NONE };
    assert_eq!(Stroke::parse("cmd+shift+]"), stroke(cmd_shift, "]"));
    assert_eq!(Stroke::parse("shift+cmd+]"), stroke(cmd_shift, "]"));
    assert_eq!(Stroke::parse("cmd+Z"), stroke(cmd, "z"));
    assert_eq!(Stroke::parse("j"), stroke(Mods::NONE, "j"));
    assert_eq!(Stroke::parse("/"), stroke(Mods::NONE, "/"));
    assert_eq!(Stroke::parse("+"), stroke(Mods::NONE, "+"));
    assert_eq!(Stroke::parse("cmd++"), stroke(cmd, "+"));
    assert_eq!(Stroke::parse("cmd+="), stroke(cmd, "="));
    assert_eq!(Stroke::parse("escape"), stroke(Mods::NONE, "escape"));
    assert_eq!(Stroke::parse("Esc"), stroke(Mods::NONE, "escape"));
    assert_eq!(
        Stroke::parse("ctrl+PageDown"),
        stroke(Mods { ctrl: true, ..Mods::NONE }, "pagedown")
    );
    assert_eq!(
        Stroke::parse("control+option+command+shift+k"),
        stroke(Mods { cmd: true, ctrl: true, alt: true, shift: true }, "k")
    );
    for bad in ["", "cmd+", "hyper+k", "cmd+kk", "cmd++k", "ctrl++"] {
        if bad == "ctrl++" {
            // `ctrl++` is ctrl and the + key.
            assert_eq!(Stroke::parse(bad), stroke(Mods { ctrl: true, ..Mods::NONE }, "+"));
            continue;
        }
        assert_eq!(Stroke::parse(bad), None, "{bad:?} is not a stroke");
    }
}

#[test]
fn mods_bits_round_trip() {
    for bits in 0..16 {
        assert_eq!(Mods::from_bits(bits).bits(), bits);
    }
    assert_eq!(Mods::from_bits(0xF0), Mods::NONE);
    assert_eq!(Mods::CMD, CMUX_KEYMAP_MOD_CMD);
    assert_eq!(Mods::CTRL, CMUX_KEYMAP_MOD_CTRL);
    assert_eq!(Mods::SHIFT, CMUX_KEYMAP_MOD_SHIFT);
}

#[test]
fn mac_key_codes_name_their_physical_keys() {
    assert_eq!(code_for_mac_key_code(0), Some("KeyA"));
    assert_eq!(code_for_mac_key_code(6), Some("KeyZ"));
    assert_eq!(code_for_mac_key_code(33), Some("BracketLeft"));
    assert_eq!(code_for_mac_key_code(44), Some("Slash"));
    assert_eq!(code_for_mac_key_code(50), Some("Backquote"));
    assert_eq!(code_for_mac_key_code(53), Some("Escape"));
    assert_eq!(code_for_mac_key_code(125), Some("ArrowDown"));
    assert_eq!(code_for_mac_key_code(36), Some("Enter"));
    assert_eq!(code_for_mac_key_code(CMUX_KEYMAP_NO_KEY_CODE), None);
    assert_eq!(qwerty_char("KeyZ"), Some("z"));
    assert_eq!(qwerty_char("Digit1"), Some("1"));
    assert_eq!(qwerty_char("Semicolon"), Some(";"));
    assert_eq!(qwerty_char("Escape"), None);
    // Every key of the table maps both ways, with no code or kVK code twice.
    let table: serde_json::Value = serde_json::from_str(KEY_STYLES_JSON).expect("parses");
    let keys = table["keys"].as_array().expect("keys");
    let mut macs = std::collections::BTreeSet::new();
    for key in keys {
        let code = key["code"].as_str().expect("code");
        let mac = u16::try_from(key["mac"].as_u64().expect("mac")).expect("a u16");
        assert!(macs.insert(mac), "kVK {mac} is listed twice");
        assert_eq!(code_for_mac_key_code(mac), Some(code), "kVK {mac}");
        assert_eq!(mac_key_code_for_code(code), Some(mac), "{code}");
        assert_eq!(qwerty_char(code), key["qwerty"].as_str(), "{code}");
    }
}

#[test]
fn list_commands_follow_the_tables_order() {
    let table: serde_json::Value = serde_json::from_str(KEY_STYLES_JSON).expect("parses");
    let ids: Vec<&str> =
        table["commands"].as_array().expect("commands").iter().filter_map(|c| c.as_str()).collect();
    let ours: Vec<&str> = ListCommand::ALL.iter().map(|c| c.id()).collect();
    assert_eq!(ids, ours);
    for (index, command) in ListCommand::ALL.into_iter().enumerate() {
        assert_eq!(command.index(), index);
        assert_eq!(ListCommand::from_id(command.id()), Some(command));
    }
}

fn c(text: &str) -> CString {
    CString::new(text).expect("no NUL")
}

#[test]
fn the_c_abi_feeds_a_list_by_mac_key_code() {
    // Dvorak, vim, followLayout: US C (kVK 8) types j, US U (kVK 32) types g.
    let keymap = cmux_keymap_new(CMUX_KEYMAP_STYLE_VIM, CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT);
    assert!(!keymap.is_null());
    let (j, upper_j, g, upper_g) = (c("j"), c("J"), c("g"), c("G"));
    unsafe {
        assert_eq!(cmux_keymap_feed(keymap, 8, j.as_ptr(), upper_j.as_ptr(), 0, false), 0);
        assert_eq!(
            cmux_keymap_feed(keymap, 32, g.as_ptr(), upper_g.as_ptr(), 0, false),
            CMUX_KEYMAP_PENDING
        );
        assert_eq!(cmux_keymap_feed(keymap, 32, g.as_ptr(), upper_g.as_ptr(), 0, false), 2);
        assert_eq!(
            cmux_keymap_feed(keymap, 32, g.as_ptr(), upper_g.as_ptr(), 0, false),
            CMUX_KEYMAP_PENDING
        );
        cmux_keymap_reset(keymap);
        // After the reset the next g starts over.
        assert_eq!(
            cmux_keymap_feed(keymap, 32, g.as_ptr(), upper_g.as_ptr(), 0, false),
            CMUX_KEYMAP_PENDING
        );
        cmux_keymap_reset(keymap);
        assert_eq!(
            cmux_keymap_feed(
                keymap,
                32,
                g.as_ptr(),
                upper_g.as_ptr(),
                CMUX_KEYMAP_MOD_SHIFT,
                false
            ),
            3
        );
        // Escape by its kVK code leaves a text field; a null key string is no character.
        assert_eq!(cmux_keymap_feed(keymap, 53, ptr::null(), ptr::null(), 0, true), 9);
        assert_eq!(
            cmux_keymap_feed(keymap, 125, ptr::null(), ptr::null(), 0, false),
            CMUX_KEYMAP_PASS
        );
        assert_eq!(
            cmux_keymap_feed(keymap, 8, j.as_ptr(), upper_j.as_ptr(), 0, true),
            CMUX_KEYMAP_PASS
        );
        cmux_keymap_free(keymap);
        cmux_keymap_free(ptr::null_mut());
        cmux_keymap_reset(ptr::null_mut());
        assert_eq!(
            cmux_keymap_feed(ptr::null_mut(), 8, j.as_ptr(), ptr::null(), 0, false),
            CMUX_KEYMAP_PASS
        );
    }
    // AZERTY, emacs, qwertyPositions: US A (kVK 0, types q) is ctrl+a.
    let keymap = cmux_keymap_new(CMUX_KEYMAP_STYLE_EMACS, CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS);
    let (q, upper_q) = (c("q"), c("Q"));
    unsafe {
        assert_eq!(
            cmux_keymap_feed(keymap, 0, q.as_ptr(), upper_q.as_ptr(), CMUX_KEYMAP_MOD_CTRL, false),
            2
        );
        cmux_keymap_free(keymap);
    }
}

#[test]
fn the_c_abi_matches_shortcuts_in_both_layouts() {
    let cmd = CMUX_KEYMAP_MOD_CMD;
    // Dvorak: the key at US Z (kVK 6) types ;.
    let (binding, semi, colon) = (c("cmd+z"), c(";"), c(":"));
    unsafe {
        assert!(!cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT,
            binding.as_ptr(),
            6,
            semi.as_ptr(),
            colon.as_ptr(),
            cmd
        ));
        assert!(cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS,
            binding.as_ptr(),
            6,
            semi.as_ptr(),
            colon.as_ptr(),
            cmd
        ));
        // AZERTY: Cmd-Shift on US Period (kVK 47) types / with Shift.
        let (slash, colon_key, slash_shifted) = (c("cmd+/"), c(":"), c("/"));
        assert!(cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT,
            slash.as_ptr(),
            47,
            colon_key.as_ptr(),
            slash_shifted.as_ptr(),
            cmd | CMUX_KEYMAP_MOD_SHIFT
        ));
        // No physical key: matched by the character in both modes.
        let (k, upper_k, binding_k) = (c("k"), c("K"), c("cmd+k"));
        assert!(cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_QWERTY_POSITIONS,
            binding_k.as_ptr(),
            CMUX_KEYMAP_NO_KEY_CODE,
            k.as_ptr(),
            upper_k.as_ptr(),
            cmd
        ));
        assert!(!cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT,
            ptr::null(),
            6,
            semi.as_ptr(),
            colon.as_ptr(),
            cmd
        ));
        let bad = c("hyper+z");
        assert!(!cmux_keymap_stroke_matches(
            CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT,
            bad.as_ptr(),
            6,
            semi.as_ptr(),
            colon.as_ptr(),
            cmd
        ));
    }
}

fn strokes(list: &[(&str, Mods)]) -> Vec<Stroke> {
    list.iter().map(|(key, mods)| Stroke { mods: *mods, key: (*key).to_owned() }).collect()
}

#[test]
fn candidates_list_what_a_key_may_mean_in_order() {
    use cmux_keymap::{KeyEvent, ShortcutLayout, candidates};
    let cmd = Mods { cmd: true, ..Mods::NONE };
    let cmd_shift = Mods { cmd: true, shift: true, ..Mods::NONE };
    let follow = ShortcutLayout::FollowLayout;
    let positions = ShortcutLayout::QwertyPositions;
    // AZERTY Cmd-Shift on US Period: the : it types, then the / it types with Shift (no Shift).
    let azerty_period =
        KeyEvent { code: Some("Period"), key: ":", shifted_key: Some("/"), mods: cmd_shift };
    assert_eq!(candidates(follow, &azerty_period), strokes(&[(":", cmd_shift), ("/", cmd)]));
    assert_eq!(candidates(positions, &azerty_period), strokes(&[(".", cmd_shift)]));
    // AZERTY's & key is also 1; its Shift digit is not offered without Shift held.
    let azerty_one = KeyEvent { code: Some("Digit1"), key: "&", shifted_key: Some("1"), mods: cmd };
    assert_eq!(candidates(follow, &azerty_one), strokes(&[("&", cmd), ("1", cmd)]));
    // QWERTZ ü counts as [, and its capital never drops Shift.
    let qwertz_u =
        KeyEvent { code: Some("BracketLeft"), key: "ü", shifted_key: Some("Ü"), mods: cmd_shift };
    assert_eq!(candidates(follow, &qwertz_u), strokes(&[("[", cmd_shift)]));
    // A letter's capital never drops Shift; a dead key with no code means nothing.
    let shift_z =
        KeyEvent { code: Some("KeyZ"), key: "z", shifted_key: Some("Z"), mods: cmd_shift };
    assert_eq!(candidates(follow, &shift_z), strokes(&[("z", cmd_shift)]));
    let dead = KeyEvent { code: None, key: "Dead", shifted_key: None, mods: cmd };
    assert!(candidates(follow, &dead).is_empty());
    // Named keys by name or by code; the digit row's digit is not repeated.
    let escape = KeyEvent { code: None, key: "escape", shifted_key: None, mods: Mods::NONE };
    assert_eq!(candidates(positions, &escape), strokes(&[("escape", Mods::NONE)]));
    let down = KeyEvent { code: Some("ArrowDown"), key: "", shifted_key: None, mods: Mods::NONE };
    assert_eq!(candidates(follow, &down), strokes(&[("down", Mods::NONE)]));
    let one = KeyEvent { code: Some("Digit1"), key: "1", shifted_key: Some("!"), mods: cmd };
    assert_eq!(candidates(follow, &one), strokes(&[("1", cmd)]));
}

#[test]
fn the_c_abi_writes_candidates_without_allocating() {
    use cmux_keymap::ffi::{CMUX_KEYMAP_CANDIDATES_MAX, CmuxKeymapStroke, cmux_keymap_candidates};
    let empty = CmuxKeymapStroke { key: [0; 16], mods: 0 };
    let mut out = [empty; CMUX_KEYMAP_CANDIDATES_MAX];
    let (colon, slash) = (c(":"), c("/"));
    let cmd_shift = CMUX_KEYMAP_MOD_CMD | CMUX_KEYMAP_MOD_SHIFT;
    // AZERTY Cmd-Shift on US Period (kVK 47).
    let n = unsafe {
        cmux_keymap_candidates(
            CMUX_KEYMAP_LAYOUT_FOLLOW_LAYOUT,
            47,
            colon.as_ptr(),
            slash.as_ptr(),
            cmd_shift,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(n, 2);
    assert_eq!(&out[0].key[..2], b":\0");
    assert_eq!(out[0].mods, cmd_shift);
    assert_eq!(&out[1].key[..2], b"/\0");
    assert_eq!(out[1].mods, CMUX_KEYMAP_MOD_CMD);
    assert_eq!(out[2], empty);
    // A short buffer gets the first ones; the count says how many there are.
    let mut one = [empty; 1];
    let n = unsafe {
        cmux_keymap_candidates(
            0,
            47,
            colon.as_ptr(),
            slash.as_ptr(),
            cmd_shift,
            one.as_mut_ptr(),
            1,
        )
    };
    assert_eq!(n, 2);
    assert_eq!(&one[0].key[..2], b":\0");
    let n = unsafe {
        cmux_keymap_candidates(0, 47, colon.as_ptr(), slash.as_ptr(), cmd_shift, ptr::null_mut(), 0)
    };
    assert_eq!(n, 2);
    // A named key by its kVK code: Page Down (kVK 121).
    let n = unsafe {
        cmux_keymap_candidates(1, 121, ptr::null(), ptr::null(), 0, out.as_mut_ptr(), out.len())
    };
    assert_eq!(n, 1);
    assert_eq!(&out[0].key[..9], b"pagedown\0");
}
