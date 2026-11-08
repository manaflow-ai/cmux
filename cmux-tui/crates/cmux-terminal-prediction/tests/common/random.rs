//! Deterministic generator, so a failing seed replays exactly.
//!
//! SplitMix64, as the Swift suite's `SimulationRandom`, with the Swift
//! standard library's range sampling on top (Lemire's nearly divisionless
//! method, `Int.random(in:using:)`, `Bool.random(using:)`,
//! `randomElement(using:)`), so a seed draws the same values here and there.

#[derive(Clone, Debug)]
pub struct SimulationRandom {
    state: u64,
}

impl SimulationRandom {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// `next(upperBound:)`: uniform in `0..upper_bound`.
    pub fn next_below(&mut self, upper_bound: u64) -> u64 {
        assert!(upper_bound != 0, "upperBound cannot be zero.");
        let mut product = u128::from(self.next_u64()) * u128::from(upper_bound);
        if (product as u64) < upper_bound {
            let threshold = upper_bound.wrapping_neg() % upper_bound;
            while (product as u64) < threshold {
                product = u128::from(self.next_u64()) * u128::from(upper_bound);
            }
        }
        (product >> 64) as u64
    }

    /// `Int.random(in: low...high, using:)`.
    pub fn int_in(&mut self, low: i64, high: i64) -> i64 {
        let delta = high.wrapping_sub(low) as u64;
        if delta == u64::MAX {
            return self.next_u64() as i64;
        }
        low.wrapping_add(self.next_below(delta + 1) as i64)
    }

    /// `Int.random(in: low..<high, using:)`.
    pub fn int_below(&mut self, low: i64, high: i64) -> i64 {
        low.wrapping_add(self.next_below(high.wrapping_sub(low) as u64) as i64)
    }

    /// `Bool.random(using:)`.
    pub fn bool(&mut self) -> bool {
        (self.next_u64() >> 17) & 1 == 0
    }

    /// `randomElement(using:)` of a non-empty slice.
    pub fn element<T: Copy>(&mut self, items: &[T]) -> T {
        let len = i64::try_from(items.len()).expect("slice length");
        items[usize::try_from(self.int_below(0, len)).expect("index")]
    }
}
