//! The order of kept builds and channel tracks: `NSString.compare(_:options: .numeric)`, which
//! the app's `KeptVersionStore.isNewer` used. Runs of ASCII digits compare by value (`1204` after
//! `999`); everything else compares unit by unit. This is not Sparkle's order ([`crate::version`]):
//! the updater's offer uses Sparkle's, the kept list and the channel tracks this one.

use std::cmp::Ordering;

fn digits_value(digits: &[u16]) -> (usize, &[u16]) {
    let start = digits.iter().position(|unit| *unit != 0x30).unwrap_or(digits.len());
    let significant = digits.get(start..).unwrap_or_default();
    (significant.len(), significant)
}

/// How `a` orders against `b` with the numeric option.
pub fn compare(a: &str, b: &str) -> Ordering {
    let a: Vec<u16> = a.encode_utf16().collect();
    let b: Vec<u16> = b.encode_utf16().collect();
    let is_digit = |unit: &u16| (0x30..=0x39).contains(unit);
    let (mut i, mut j) = (0usize, 0usize);
    loop {
        match (a.get(i), b.get(j)) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if is_digit(x) && is_digit(y) => {
                let run_a =
                    a.get(i..).unwrap_or_default().iter().take_while(|unit| is_digit(unit)).count();
                let run_b =
                    b.get(j..).unwrap_or_default().iter().take_while(|unit| is_digit(unit)).count();
                let (len_a, sig_a) =
                    digits_value(a.get(i..i.saturating_add(run_a)).unwrap_or_default());
                let (len_b, sig_b) =
                    digits_value(b.get(j..j.saturating_add(run_b)).unwrap_or_default());
                match len_a.cmp(&len_b).then_with(|| sig_a.cmp(sig_b)) {
                    Ordering::Equal => {}
                    order => return order,
                }
                i = i.saturating_add(run_a);
                j = j.saturating_add(run_b);
            }
            (Some(x), Some(y)) => match x.cmp(y) {
                Ordering::Equal => {
                    i = i.saturating_add(1);
                    j = j.saturating_add(1);
                }
                order => return order,
            },
        }
    }
}

/// Whether `a` is newer than `b` (`KeptVersionStore.isNewer`).
pub fn is_newer(a: &str, b: &str) -> bool {
    compare(a, b) == Ordering::Greater
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digit_runs_compare_by_value() {
        assert!(is_newer("1204", "999"));
        assert!(is_newer("1.10", "1.9"));
        assert!(!is_newer("1203", "1203"));
        assert_eq!(compare("a2", "a10"), Ordering::Less);
        assert_eq!(compare("20261125.1", "20261124.9"), Ordering::Greater);
    }

    #[test]
    fn other_units_compare_in_order() {
        assert_eq!(compare("abc", "abd"), Ordering::Less);
        assert_eq!(compare("", "1"), Ordering::Less);
        assert_eq!(compare("1a", "1"), Ordering::Greater);
    }
}
