//! A Finder-like order (`localizedStandardCompare`): case-insensitive, with
//! digit runs compared as numbers ("iPhone 9" before "iPhone 17").
use std::cmp::Ordering;

enum Chunk<'a> {
    Digits(&'a str),
    Text(String),
}

fn chunks(text: &str) -> Vec<Chunk<'_>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut digits: Option<bool> = None;
    for (index, ch) in text.char_indices() {
        let is_digit = ch.is_ascii_digit();
        if let Some(previous) = digits
            && previous != is_digit
        {
            out.push(chunk(text.get(start..index).unwrap_or(""), previous));
            start = index;
        }
        digits = Some(is_digit);
    }
    if let Some(previous) = digits {
        out.push(chunk(text.get(start..).unwrap_or(""), previous));
    }
    out
}

fn chunk(text: &str, digits: bool) -> Chunk<'_> {
    if digits { Chunk::Digits(text) } else { Chunk::Text(text.to_lowercase()) }
}

fn compare_digits(lhs: &str, rhs: &str) -> Ordering {
    let lhs_trim = lhs.trim_start_matches('0');
    let rhs_trim = rhs.trim_start_matches('0');
    lhs_trim.len().cmp(&rhs_trim.len()).then_with(|| lhs_trim.cmp(rhs_trim))
}

/// `lhs` against `rhs` in the Finder's order; exact text breaks a tie.
pub(crate) fn compare(lhs: &str, rhs: &str) -> Ordering {
    let (left, right) = (chunks(lhs), chunks(rhs));
    for (l, r) in left.iter().zip(right.iter()) {
        let order = match (l, r) {
            (Chunk::Digits(a), Chunk::Digits(b)) => compare_digits(a, b),
            (Chunk::Text(a), Chunk::Text(b)) => a.cmp(b),
            (Chunk::Digits(_), Chunk::Text(_)) => Ordering::Less,
            (Chunk::Text(_), Chunk::Digits(_)) => Ordering::Greater,
        };
        if order != Ordering::Equal {
            return order;
        }
    }
    left.len().cmp(&right.len()).then_with(|| lhs.cmp(rhs))
}

#[cfg(test)]
mod tests {
    use super::compare;
    use std::cmp::Ordering;

    #[test]
    fn numbers_compare_by_value_and_case_is_ignored() {
        assert_eq!(compare("iPhone 9", "iPhone 17"), Ordering::Less);
        assert_eq!(compare("ipad", "iPhone"), Ordering::Less);
        assert_eq!(compare("iPhone 17e", "iPhone 17"), Ordering::Greater);
        assert_eq!(compare("a", "a"), Ordering::Equal);
    }
}
