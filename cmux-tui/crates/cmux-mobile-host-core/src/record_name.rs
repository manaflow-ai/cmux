//! `MobileHostPairedDevices.acpmuxRecordName`: the acpmux pairing name of a phone's own credential.

/// `phone-` and the phone's id lowercased, keeping only ASCII letters, digits and `-`, at most 74 of them.
///
/// Swift filters by `Character` (grapheme), so an ASCII letter carrying a combining mark (`e\u{301}`)
/// is not ASCII there and is dropped; this does the same for the marks a grapheme joins.
pub fn acpmux_record_name(id: &str) -> String {
    let lowered: Vec<char> = id.to_lowercase().chars().collect();
    let mut name = String::from("phone-");
    let mut kept = 0;
    for (index, ch) in lowered.iter().enumerate() {
        if kept == 74 {
            break;
        }
        let joined = lowered.get(index + 1).is_some_and(|next| extends_grapheme(*next));
        if (ch.is_ascii_alphanumeric() || *ch == '-') && !joined {
            name.push(*ch);
            kept += 1;
        }
    }
    name
}

/// A character that joins the one before it into one grapheme (combining marks, joiners, selectors).
fn extends_grapheme(ch: char) -> bool {
    matches!(ch as u32,
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x200C..=0x200D | 0x20D0..=0x20FF
        | 0xFE00..=0xFE0F | 0xFE20..=0xFE2F | 0xE0100..=0xE01EF)
}
