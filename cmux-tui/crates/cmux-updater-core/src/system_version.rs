//! A macOS version such as `26.0` or `15.6.1`, compared numerically. Appcast items carry
//! `sparkle:minimumSystemVersion` in this form. Missing components count as zero, so `26`
//! equals `26.0.0`.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct SystemVersion {
    pub major: i64,
    #[serde(default)]
    pub minor: i64,
    #[serde(default)]
    pub patch: i64,
}

impl SystemVersion {
    pub fn new(major: i64, minor: i64, patch: i64) -> SystemVersion {
        SystemVersion { major, minor, patch }
    }

    /// Parses `"26"`, `"26.0"` or `"15.6.1"` (surrounding whitespace allowed); nil for anything
    /// else: an empty or non-ASCII part, a negative number, more than three parts. A part reads
    /// as Swift's `Int(_:)` does, so `+5` is 5.
    pub fn parse(text: &str) -> Option<SystemVersion> {
        let parts: Vec<&str> = text.trim().split('.').collect();
        if !(1..=3).contains(&parts.len()) {
            return None;
        }
        let mut numbers = [0i64; 3];
        for (slot, part) in numbers.iter_mut().zip(&parts) {
            if part.is_empty() || !part.is_ascii() {
                return None;
            }
            let value: i64 = part.parse().ok()?;
            if value < 0 {
                return None;
            }
            *slot = value;
        }
        Some(SystemVersion::new(numbers[0], numbers[1], numbers[2]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_one_to_three_parts() {
        assert_eq!(SystemVersion::parse("26"), Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(SystemVersion::parse(" 26.0 \n"), Some(SystemVersion::new(26, 0, 0)));
        assert_eq!(SystemVersion::parse("15.6.1"), Some(SystemVersion::new(15, 6, 1)));
        assert_eq!(SystemVersion::parse("+5"), Some(SystemVersion::new(5, 0, 0)));
        assert_eq!(SystemVersion::parse("-0"), Some(SystemVersion::new(0, 0, 0)));
    }

    #[test]
    fn refuses_the_rest() {
        for text in ["", "26.", ".1", "1.2.3.4", "a", "1.-1", "１", "26 .0", "99999999999999999999"]
        {
            assert_eq!(SystemVersion::parse(text), None, "{text:?}");
        }
    }

    #[test]
    fn orders_numerically() {
        assert!(SystemVersion::new(15, 6, 1) < SystemVersion::new(26, 0, 0));
        assert!(SystemVersion::new(15, 10, 0) > SystemVersion::new(15, 9, 9));
        assert_eq!(SystemVersion::parse("26"), SystemVersion::parse("26.0.0"));
    }
}
