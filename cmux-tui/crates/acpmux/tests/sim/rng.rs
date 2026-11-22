//! The simulation's one source of randomness: SplitMix64, seeded by the run's seed. Every choice
//! the simulation makes (the plan, the agent's timing, the faults) is drawn from a stream split
//! off this one, so a seed is the whole run.

#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number in `lo..=hi`.
    pub fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next_u64() % (hi - lo + 1)
    }

    /// True `percent` times in 100.
    pub fn chance(&mut self, percent: u64) -> bool {
        self.next_u64() % 100 < percent
    }

    /// An independent stream for one part of the run (`salt` names the part).
    pub fn split(&mut self, salt: u64) -> Rng {
        Rng::new(self.next_u64() ^ salt.wrapping_mul(0xD6E8_FEB8_6659_FD93))
    }
}
