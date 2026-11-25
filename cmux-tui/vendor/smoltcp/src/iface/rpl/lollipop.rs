//! Implementation of sequence counters defined in [RFC 6550 § 7.2]. Values from 128 and greater
//! are used as a linear sequence to indicate a restart and bootstrap the counter. Values less than
//! or equal to 127 are used as a circular sequence number space of size 128. When operating in the
//! circular region, if sequence numbers are detected to be too far apart, then they are not
//! comparable.
//!
//! [RFC 6550 § 7.2]: https://datatracker.ietf.org/doc/html/rfc6550#section-7.2

#[derive(Debug, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct SequenceCounter(u8);

impl Default for SequenceCounter {
    fn default() -> Self {
        // RFC6550 7.2 recommends 240 (256 - SEQUENCE_WINDOW) as the initialization value of the
        // counter.
        Self(240)
    }
}

impl SequenceCounter {
    /// Create a new sequence counter.
    ///
    /// Use `Self::default()` when a new sequence counter needs to be created with a value that is
    /// recommended in RFC6550 7.2, being 240.
    pub fn new(value: u8) -> Self {
        Self(value)
    }

    /// Return the value of the sequence counter.
    pub fn value(&self) -> u8 {
        self.0
    }

    /// Increment the sequence counter.
    ///
    /// When the sequence counter is greater than or equal to 128, the maximum value is 255.
    /// When the sequence counter is less than 128, the maximum value is 127.
    ///
    /// When an increment of the sequence counter would cause the counter to increment beyond its
    /// maximum value, the counter MUST wrap back to zero.
    pub fn increment(&mut self) {
        let max = if self.0 >= 128 { 255 } else { 127 };

        self.0 = match self.0.checked_add(1) {
            Some(val) if val <= max => val,
            _ => 0,
        };
    }
}

impl PartialEq for SequenceCounter {
    fn eq(&self, other: &Self) -> bool {
        let a = self.value() as usize;
        let b = other.value() as usize;

        if ((128..=255).contains(&a) && (0..=127).contains(&b))
            || ((128..=255).contains(&b) && (0..=127).contains(&a))
        {
            false
        } else {
            let result = if a > b { a - b } else { b - a };

            if result <= super::consts::SEQUENCE_WINDOW as usize {
                // RFC1982
                a == b
            } else {
                // This case is actually not comparable.
                false
            }
        }
    }
}

impl PartialOrd for SequenceCounter {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        use super::consts::SEQUENCE_WINDOW;
        use core::cmp::Ordering;

        let a = self.value() as usize;
        let b = other.value() as usize;

        if (128..256).contains(&a) && (0..128).contains(&b) {
            if 256 + b - a <= SEQUENCE_WINDOW as usize {
                Some(Ordering::Less)
            } else {
                Some(Ordering::Greater)
            }
        } else if (128..256).contains(&b) && (0..128).contains(&a) {
            if 256 + a - b <= SEQUENCE_WINDOW as usize {
                Some(Ordering::Greater)
            } else {
                Some(Ordering::Less)
            }
        } else if ((0..128).contains(&a) && (0..128).contains(&b))
            || ((128..256).contains(&a) && (128..256).contains(&b))
        {
            let result = if a > b { a - b } else { b - a };

            if result <= SEQUENCE_WINDOW as usize {
                // RFC1982
                a.partial_cmp(&b)
            } else {
                // This case is not comparable.
                None
            }
        } else {
            unreachable!();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_counter_increment() {
        let mut seq = SequenceCounter::new(253);
        seq.increment();
        assert_eq!(seq.value(), 254);
        seq.increment();
        assert_eq!(seq.value(), 255);
        seq.increment();
        assert_eq!(seq.value(), 0);

        let mut seq = SequenceCounter::new(126);
        seq.increment();
        assert_eq!(seq.value(), 127);
        seq.increment();
        assert_eq!(seq.value(), 0);
    }

    #[test]
    fn sequence_counter_comparison() {
        use core::cmp::Ordering;

        assert!(SequenceCounter::new(240) != SequenceCounter::new(1));
        assert!(SequenceCounter::new(1) != SequenceCounter::new(240));
        assert!(SequenceCounter::new(1) != SequenceCounter::new(240));
        assert!(SequenceCounter::new(240) == SequenceCounter::new(240));
        assert!(SequenceCounter::new(240 - 17) != SequenceCounter::new(240));

        assert_eq!(
            SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(5)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            SequenceCounter::new(250).partial_cmp(&SequenceCounter::new(5)),
            Some(Ordering::Less)
        );
        assert_eq!(
            SequenceCounter::new(5).partial_cmp(&SequenceCounter::new(250)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            SequenceCounter::new(127).partial_cmp(&SequenceCounter::new(129)),
            Some(Ordering::Less)
        );
        assert_eq!(
            SequenceCounter::new(120).partial_cmp(&SequenceCounter::new(121)),
            Some(Ordering::Less)
        );
        assert_eq!(
            SequenceCounter::new(121).partial_cmp(&SequenceCounter::new(120)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(241)),
            Some(Ordering::Less)
        );
        assert_eq!(
            SequenceCounter::new(241).partial_cmp(&SequenceCounter::new(240)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            SequenceCounter::new(120).partial_cmp(&SequenceCounter::new(120)),
            Some(Ordering::Equal)
        );
        assert_eq!(
            SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(240)),
            Some(Ordering::Equal)
        );
        assert_eq!(
            SequenceCounter::new(130).partial_cmp(&SequenceCounter::new(241)),
            None
        );
    }
}
