//! Version order: Sparkle's `SUStandardVersionComparator` (how Sparkle orders
//! `sparkle:version` against `CFBundleVersion`), Foundation's numeric string
//! order (kept rollback builds), and the macOS version an appcast item needs.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use unicode_general_category::{GeneralCategory, get_general_category};

/// The character classes of `SUStandardVersionComparator` (Sparkle 2.10.0).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CharType {
    Number,
    String,
    Period,
    Punctuation,
    Whitespace,
    Dash,
}

impl CharType {
    fn of(c: char) -> Self {
        if c == '.' {
            return Self::Period;
        }
        if c == '-' {
            return Self::Dash;
        }
        // NSString reads UTF-16 units: a character outside the BMP is two
        // surrogates, and no NSCharacterSet holds a surrogate.
        if u32::from(c) > 0xFFFF {
            return Self::String;
        }
        if get_general_category(c) == GeneralCategory::DecimalNumber {
            return Self::Number;
        }
        if is_whitespace_or_newline(c) {
            return Self::Whitespace;
        }
        if is_punctuation(c) {
            return Self::Punctuation;
        }
        Self::String
    }

    /// The type of a split part: the type of its first character.
    fn of_part(part: &str) -> Self {
        part.chars().next().map_or(Self::String, Self::of)
    }

    fn is_separator(self) -> bool {
        matches!(self, Self::Period | Self::Punctuation | Self::Whitespace)
    }

    /// Separators of any kind count as one class; the rest only match themselves.
    fn same_class(self, other: Self) -> bool {
        if self.is_separator() { other.is_separator() } else { self == other }
    }
}

/// `NSCharacterSet.whitespaceAndNewlineCharacterSet`: Unicode Z*, U+0009 to
/// U+000D and U+0085.
pub(crate) fn is_whitespace_or_newline(c: char) -> bool {
    matches!(c, '\u{9}'..='\u{D}' | '\u{85}')
        || matches!(
            get_general_category(c),
            GeneralCategory::SpaceSeparator
                | GeneralCategory::LineSeparator
                | GeneralCategory::ParagraphSeparator
        )
}

/// `NSCharacterSet.whitespaceCharacterSet`: Unicode Zs and U+0009 (no newlines).
pub(crate) fn is_whitespace(c: char) -> bool {
    c == '\u{9}' || get_general_category(c) == GeneralCategory::SpaceSeparator
}

/// `NSCharacterSet.punctuationCharacterSet`: Unicode P*. `+`, `$`, `<`, `=`,
/// `>`, `^`, `` ` ``, `|` and `~` are symbols, not punctuation.
fn is_punctuation(c: char) -> bool {
    matches!(
        get_general_category(c),
        GeneralCategory::ConnectorPunctuation
            | GeneralCategory::DashPunctuation
            | GeneralCategory::OpenPunctuation
            | GeneralCategory::ClosePunctuation
            | GeneralCategory::InitialPunctuation
            | GeneralCategory::FinalPunctuation
            | GeneralCategory::OtherPunctuation
    )
}

/// `splitVersionString:`. A dash after the first character ends the version
/// ("1.5.5-335d3e2" reads as "1.5.5"); separators are one part each.
fn split(version: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut chars = version.chars();
    let Some(first) = chars.next() else { return parts };
    let mut current = String::from(first);
    let mut old = CharType::of(first);
    for c in chars {
        let new = CharType::of(c);
        if new == CharType::Dash {
            break;
        }
        if old != new || old.is_separator() {
            parts.push(std::mem::take(&mut current));
        }
        current.push(c);
        old = new;
    }
    parts.push(current);
    parts
}

/// How many parts at the start are numbers or periods.
fn number_and_period_prefix(parts: &[String]) -> usize {
    parts
        .iter()
        .take_while(|part| matches!(CharType::of_part(part), CharType::Number | CharType::Period))
        .count()
}

/// `balanceVersionPartsA:partsB:`: pads the shorter number-and-period prefix
/// with `0` and `.` parts, so "1.0" equals "1.0.0".
fn balance(a: &mut Vec<String>, b: &mut Vec<String>) {
    let count_a = number_and_period_prefix(a);
    let count_b = number_and_period_prefix(b);
    match count_a.cmp(&count_b) {
        Ordering::Greater => pad(b, count_b, a, count_a),
        Ordering::Less => pad(a, count_a, b, count_b),
        Ordering::Equal => {}
    }
}

fn pad(to: &mut Vec<String>, to_count: usize, from: &[String], from_count: usize) {
    let padding =
        from.iter().skip(to_count).take(from_count.saturating_sub(to_count)).map(|part| {
            if CharType::of_part(part) == CharType::Period {
                ".".to_owned()
            } else {
                "0".to_owned()
            }
        });
    let mut balanced: Vec<String> = to.iter().take(to_count).cloned().collect();
    balanced.extend(padding);
    balanced.extend(to.iter().skip(to_count).cloned());
    *to = balanced;
}

/// `-[NSString longLongValue]` of a run of digits: the leading ASCII digits,
/// saturating at `LLONG_MAX`.
fn long_long_value(part: &str) -> i64 {
    let mut value: i64 = 0;
    for c in part.chars() {
        let Some(digit) = c.to_digit(10).filter(|_| c.is_ascii_digit()) else { break };
        value = value.saturating_mul(10).saturating_add(i64::from(digit));
    }
    value
}

/// `-[NSString compare:]` for the ASCII parts versions hold: UTF-16 unit order.
fn compare_strings(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Sparkle's `compareVersion:toVersion:`: `Less` when `a` is older than `b`.
pub fn compare_sparkle(a: &str, b: &str) -> Ordering {
    let mut parts_a = split(a);
    let mut parts_b = split(b);
    balance(&mut parts_a, &mut parts_b);
    for (part_a, part_b) in parts_a.iter().zip(parts_b.iter()) {
        let type_a = CharType::of_part(part_a);
        let type_b = CharType::of_part(part_b);
        if type_a.same_class(type_b) {
            let order = match type_a {
                CharType::Number => long_long_value(part_a).cmp(&long_long_value(part_b)),
                CharType::String => compare_strings(part_a, part_b),
                _ => Ordering::Equal,
            };
            if order != Ordering::Equal {
                return order;
            }
        } else if type_a != CharType::String && type_b == CharType::String {
            return Ordering::Greater;
        } else if type_a == CharType::String && type_b != CharType::String {
            return Ordering::Less;
        } else if type_a == CharType::Number {
            // One is a number and the other a separator: the separator is invalid.
            return Ordering::Greater;
        } else {
            return Ordering::Less;
        }
    }
    let shared = parts_a.len().min(parts_b.len());
    let (longer, longer_is_a) = match parts_a.len().cmp(&parts_b.len()) {
        Ordering::Equal => return Ordering::Equal,
        Ordering::Greater => (&parts_a, true),
        Ordering::Less => (&parts_b, false),
    };
    let missing = longer.get(shared).map_or(CharType::String, |part| CharType::of_part(part));
    // A string tail ("1.0b" against "1.0") makes the shorter version newer;
    // a number or separator tail makes the longer one newer.
    let longer_wins = missing != CharType::String;
    if longer_wins == longer_is_a { Ordering::Greater } else { Ordering::Less }
}

/// `AppcastSelector.isOlder`: Sparkle orders `a` before `b`.
pub fn is_older(a: &str, than: &str) -> bool {
    compare_sparkle(a, than) == Ordering::Less
}

/// `String.compare(_:options: .numeric)`: runs of ASCII digits compare by
/// value, everything else by UTF-16 unit.
pub fn compare_numeric(a: &str, b: &str) -> Ordering {
    let a: Vec<u16> = a.encode_utf16().collect();
    let b: Vec<u16> = b.encode_utf16().collect();
    let (mut i, mut j) = (0usize, 0usize);
    while let (Some(&ca), Some(&cb)) = (a.get(i), b.get(j)) {
        if is_ascii_digit_unit(ca) && is_ascii_digit_unit(cb) {
            let run_a = digit_run(&a, i);
            let run_b = digit_run(&b, j);
            let order = compare_digit_runs(&run_a, &run_b);
            if order != Ordering::Equal {
                return order;
            }
            i = i.saturating_add(run_a.len());
            j = j.saturating_add(run_b.len());
            continue;
        }
        if ca != cb {
            return ca.cmp(&cb);
        }
        i = i.saturating_add(1);
        j = j.saturating_add(1);
    }
    let rest_a = a.len().saturating_sub(i);
    let rest_b = b.len().saturating_sub(j);
    rest_a.cmp(&rest_b)
}

fn is_ascii_digit_unit(unit: u16) -> bool {
    (u16::from(b'0')..=u16::from(b'9')).contains(&unit)
}

fn digit_run(units: &[u16], start: usize) -> Vec<u16> {
    units.iter().skip(start).take_while(|unit| is_ascii_digit_unit(**unit)).copied().collect()
}

/// Numeric order of two digit runs of any length (no overflow).
fn compare_digit_runs(a: &[u16], b: &[u16]) -> Ordering {
    let significant = |run: &[u16]| -> Vec<u16> {
        run.iter().skip_while(|unit| **unit == u16::from(b'0')).copied().collect()
    };
    let a = significant(a);
    let b = significant(b);
    a.len().cmp(&b.len()).then_with(|| a.cmp(&b))
}

/// `KeptVersionStore.isNewer`: numeric build order (CFBundleVersion is monotonic).
pub fn is_newer_build(a: &str, than: &str) -> bool {
    compare_numeric(a, than) == Ordering::Greater
}

/// Indices of `builds`, newest first by numeric build order (a stable sort,
/// so equal builds keep their order).
pub fn newest_first(builds: &[String]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..builds.len()).collect();
    order.sort_by(|left, right| {
        let (Some(a), Some(b)) = (builds.get(*left), builds.get(*right)) else {
            return Ordering::Equal;
        };
        compare_numeric(b, a)
    });
    order
}

/// A macOS version such as `26.0` or `15.6.1`, compared numerically. Missing
/// components count as zero, so `26` equals `26.0.0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct SystemVersion {
    pub major: i64,
    #[serde(default)]
    pub minor: i64,
    #[serde(default)]
    pub patch: i64,
}

impl SystemVersion {
    pub fn new(major: i64, minor: i64, patch: i64) -> Self {
        Self { major, minor, patch }
    }

    /// Parses `"26"`, `"26.0"` or `"15.6.1"` (surrounding whitespace is
    /// ignored); nil for anything else. Each part is what Swift's `Int(_:)`
    /// reads (an optional sign, then ASCII digits) and must not be negative.
    pub fn parse(text: &str) -> Option<Self> {
        let parts: Vec<&str> = text.trim_matches(is_whitespace_or_newline).split('.').collect();
        if !(1..=3).contains(&parts.len()) {
            return None;
        }
        let mut numbers = Vec::with_capacity(3);
        for part in parts {
            numbers.push(swift_int(part).filter(|value| *value >= 0)?);
        }
        let mut numbers = numbers.into_iter();
        Some(Self {
            major: numbers.next().unwrap_or(0),
            minor: numbers.next().unwrap_or(0),
            patch: numbers.next().unwrap_or(0),
        })
    }

    /// `26.0`, or `15.6.1` when the patch is set.
    pub fn description(&self) -> String {
        if self.patch == 0 {
            format!("{}.{}", self.major, self.minor)
        } else {
            format!("{}.{}.{}", self.major, self.minor, self.patch)
        }
    }
}

/// Swift's `Int(String)`: an optional `+` or `-`, then one or more ASCII
/// digits, within `Int.min...Int.max`.
fn swift_int(text: &str) -> Option<i64> {
    let (negative, digits) = match text.chars().next() {
        Some('+') => (false, text.get(1..)?),
        Some('-') => (true, text.get(1..)?),
        _ => (false, text),
    };
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let mut value: i64 = 0;
    for c in digits.chars() {
        let digit = i64::from(c.to_digit(10)?);
        value = if negative {
            value.checked_mul(10)?.checked_sub(digit)?
        } else {
            value.checked_mul(10)?.checked_add(digit)?
        };
    }
    Some(value)
}
