//! Sparkle's order of version strings (`SUStandardVersionComparator`, Sparkle 2.10.0,
//! Sparkle/SUStandardVersionComparator.m), so the app compares `CFBundleVersion`s the way the
//! Sparkle that installs them does.
//!
//! A version splits into parts of one kind: a run of digits, a run of other letters, or one
//! separator (`.`, whitespace, punctuation). A `-` ends the version (`1.2-beta` is `1.2`). The
//! leading numbers and periods of the shorter side are padded with `.` and `0`, so `1.0` equals
//! `1.0.0`. Parts then compare pairwise: numbers by value, letters by text, separators equal
//! each other; a number or separator beats letters, and a number beats a separator. When one
//! side runs out, a remaining letters part makes it older (`1.0b` < `1.0`), anything else newer.
//!
//! Characters are UTF-16 units, as `NSString` reads them. Digits are ASCII `0`-`9`, and
//! punctuation is the ASCII part of Unicode's punctuation categories (`P*`: `$+<=>^|~` and
//! backquote are symbols, so letters): build numbers are ASCII.

use std::cmp::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Number,
    Letters,
    Period,
    Punctuation,
    Whitespace,
    Dash,
}

impl Kind {
    fn of(unit: u16) -> Kind {
        match unit {
            0x2E => Kind::Period,
            0x2D => Kind::Dash,
            0x30..=0x39 => Kind::Number,
            _ => match char::from_u32(u32::from(unit)) {
                Some(c) if c.is_whitespace() => Kind::Whitespace,
                Some(c) if is_ascii_unicode_punctuation(c) => Kind::Punctuation,
                _ => Kind::Letters,
            },
        }
    }

    fn is_separator(self) -> bool {
        matches!(self, Kind::Period | Kind::Punctuation | Kind::Whitespace)
    }

    /// Sparkle's "equal character type class": separators all match each other.
    fn same_class(self, other: Kind) -> bool {
        if self.is_separator() { other.is_separator() } else { self == other }
    }
}

/// ASCII characters in Unicode's punctuation categories (`NSCharacterSet.punctuationCharacterSet`).
fn is_ascii_unicode_punctuation(c: char) -> bool {
    matches!(
        c,
        '!' | '"'
            | '#'
            | '%'
            | '&'
            | '\''
            | '('
            | ')'
            | '*'
            | ','
            | '-'
            | '.'
            | '/'
            | ':'
            | ';'
            | '?'
            | '@'
            | '['
            | '\\'
            | ']'
            | '_'
            | '{'
            | '}'
    )
}

/// One part: its UTF-16 units and its kind (the kind of its first unit, as Sparkle reads it).
#[derive(Debug, Clone)]
struct Part {
    units: Vec<u16>,
    kind: Kind,
}

impl Part {
    fn new(units: Vec<u16>) -> Part {
        let kind = units.first().map_or(Kind::Letters, |unit| Kind::of(*unit));
        Part { units, kind }
    }

    /// `-[NSString longLongValue]`: leading whitespace, an optional sign, then digits;
    /// saturates like it does.
    fn value(&self) -> i64 {
        let mut value: i64 = 0;
        for unit in &self.units {
            match unit {
                0x30..=0x39 => {
                    value = value.saturating_mul(10).saturating_add(i64::from(unit - 0x30))
                }
                _ => break,
            }
        }
        value
    }
}

fn split(version: &str) -> Vec<Part> {
    let units: Vec<u16> = version.encode_utf16().collect();
    let Some((&first, rest)) = units.split_first() else { return Vec::new() };
    let mut parts = Vec::new();
    let mut current = vec![first];
    let mut old = Kind::of(first);
    for &unit in rest {
        let new = Kind::of(unit);
        if new == Kind::Dash {
            break;
        }
        if old != new || old.is_separator() {
            parts.push(Part::new(std::mem::replace(&mut current, vec![unit])));
        } else {
            current.push(unit);
        }
        old = new;
    }
    parts.push(Part::new(current));
    parts
}

fn leading_numbers_and_periods(parts: &[Part]) -> usize {
    parts.iter().take_while(|part| matches!(part.kind, Kind::Number | Kind::Period)).count()
}

/// Pads `to`'s leading numbers and periods to `from`'s count with `0` and `.`.
fn pad(to: &mut Vec<Part>, to_count: usize, from: &[Part], from_count: usize) {
    let fillers = from.iter().enumerate().take(from_count).skip(to_count);
    for (index, part) in fillers {
        let filler: &str = if part.kind == Kind::Period { "." } else { "0" };
        to.insert(index, Part::new(filler.encode_utf16().collect()));
    }
}

/// How `a` orders against `b`, as `-[SUStandardVersionComparator compareVersion:toVersion:]`.
pub fn compare(a: &str, b: &str) -> Ordering {
    let mut parts_a = split(a);
    let mut parts_b = split(b);
    let count_a = leading_numbers_and_periods(&parts_a);
    let count_b = leading_numbers_and_periods(&parts_b);
    if count_a > count_b {
        pad(&mut parts_b, count_b, &parts_a, count_a);
    } else if count_b > count_a {
        pad(&mut parts_a, count_a, &parts_b, count_b);
    }

    for (part_a, part_b) in parts_a.iter().zip(&parts_b) {
        let (kind_a, kind_b) = (part_a.kind, part_b.kind);
        if kind_a.same_class(kind_b) {
            match kind_a {
                Kind::Number => match part_a.value().cmp(&part_b.value()) {
                    Ordering::Equal => {}
                    order => return order,
                },
                Kind::Letters => match part_a.units.cmp(&part_b.units) {
                    Ordering::Equal => {}
                    order => return order,
                },
                _ => {}
            }
        } else if kind_a != Kind::Letters && kind_b == Kind::Letters {
            return Ordering::Greater;
        } else if kind_a == Kind::Letters && kind_b != Kind::Letters {
            return Ordering::Less;
        } else if kind_a == Kind::Number {
            return Ordering::Greater;
        } else {
            return Ordering::Less;
        }
    }

    let shared = parts_a.len().min(parts_b.len());
    let (missing, shorter, larger) = if parts_a.len() > parts_b.len() {
        (parts_a.get(shared), Ordering::Less, Ordering::Greater)
    } else {
        (parts_b.get(shared), Ordering::Greater, Ordering::Less)
    };
    match missing {
        None => Ordering::Equal,
        Some(part) if part.kind == Kind::Letters => shorter,
        Some(_) => larger,
    }
}

/// Whether `a` is older than `b` (the app's `AppcastSelector.isOlder`).
pub fn is_older(a: &str, b: &str) -> bool {
    compare(a, b) == Ordering::Less
}

#[cfg(test)]
mod tests {
    use super::*;
    use Ordering::{Equal, Greater, Less};

    #[track_caller]
    fn check(a: &str, b: &str, order: Ordering) {
        assert_eq!(compare(a, b), order, "{a} vs {b}");
        assert_eq!(compare(b, a), order.reverse(), "{b} vs {a}");
    }

    // Cases worked through Sparkle 2.10.0's comparator by hand.
    #[test]
    fn numbers() {
        check("1.0", "1.1", Less);
        check("1.0", "1.0", Equal);
        check("2.0", "1.1", Greater);
        check("0.1", "0.0.1", Greater);
        check(".1", "0.0.1", Less);
        check("0.1", ".1", Greater);
        check("10", "9", Greater);
        check("10.0", "9.0", Greater);
        check("1.0", "1.0.0", Equal);
        check("1.0.0", "1.0.1", Less);
        check("1.0.1", "1.0", Greater);
        check("1", "1.0", Equal);
        check("1", "1.1", Less);
    }

    #[test]
    fn prereleases() {
        check("1.5.5", "1.5.6a1", Less);
        check("1.1.0b1", "1.1.0b2", Less);
        check("1.1.1b2", "1.1.2b1", Less);
        check("1.1.1b2", "1.1.2a1", Less);
        check("1.0a1", "1.0b1", Less);
        check("1.0b1", "1.0", Less);
        check("0.9", "1.0a1", Less);
        check("1.0b", "1.0b2", Less);
        check("1.0b10", "1.0b11", Less);
        check("1.0b9", "1.0b10", Less);
        check("1.0rc", "1.0", Less);
        check("1.0b", "1.0", Less);
        check("1.0pre1", "1.0", Less);
    }

    #[test]
    fn separators_match_each_other() {
        check("1 0", "1_0", Equal);
        check("1,0", "1:0", Equal);
        // A period counts toward the leading numbers and periods; other separators do not, so
        // `1 0` is padded to `1.0 0` and is the newer.
        check("1.0", "1 0", Less);
    }

    #[test]
    fn a_dash_ends_the_version() {
        check("1.2-beta", "1.2", Equal);
        check("1.2.3-4", "1.2.3", Equal);
        check("1.2-9", "1.3", Less);
    }

    #[test]
    fn letters_and_symbols() {
        check("1.0", "1.0a", Greater);
        check("1.0+1", "1.0", Less);
        check("a", "b", Less);
        check("", "", Equal);
        check("", "1", Less);
        check("1.", "1", Equal);
    }

    #[test]
    fn nightly_build_numbers() {
        check("20261125.1203", "20261125.1204", Less);
        check("4321", "4320", Greater);
        check("9223372036854775808", "9223372036854775807", Equal);
    }
}
