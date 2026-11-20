/*! Time structures.

The `time` module contains structures used to represent both
absolute and relative time.

 - [Instant] is used to represent absolute time.
 - [Duration] is used to represent relative time.

[Instant]: struct.Instant.html
[Duration]: struct.Duration.html
*/

use core::{fmt, ops};

/// A representation of an absolute time value.
///
/// The `Instant` type is a wrapper around a `i64` value that
/// represents a number of microseconds, monotonically increasing
/// since an arbitrary moment in time, such as system startup.
///
/// * A value of `0` is inherently arbitrary.
/// * A value less than `0` indicates a time before the starting
///   point.
#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Instant {
    micros: i64,
}

impl Instant {
    pub const ZERO: Instant = Instant::from_micros_const(0);

    /// Create a new `Instant` from a number of microseconds.
    pub fn from_micros<T: Into<i64>>(micros: T) -> Instant {
        Instant {
            micros: micros.into(),
        }
    }

    pub const fn from_micros_const(micros: i64) -> Instant {
        Instant { micros }
    }

    /// Create a new `Instant` from a number of milliseconds.
    pub fn from_millis<T: Into<i64>>(millis: T) -> Instant {
        Instant {
            micros: millis.into() * 1000,
        }
    }

    /// Create a new `Instant` from a number of milliseconds.
    pub const fn from_millis_const(millis: i64) -> Instant {
        Instant {
            micros: millis * 1000,
        }
    }

    /// Create a new `Instant` from a number of seconds.
    pub fn from_secs<T: Into<i64>>(secs: T) -> Instant {
        Instant {
            micros: secs.into() * 1000000,
        }
    }

    /// Create a new `Instant` from the current [std::time::SystemTime].
    ///
    /// See [std::time::SystemTime::now]
    ///
    /// [std::time::SystemTime]: https://doc.rust-lang.org/std/time/struct.SystemTime.html
    /// [std::time::SystemTime::now]: https://doc.rust-lang.org/std/time/struct.SystemTime.html#method.now
    #[cfg(feature = "std")]
    pub fn now() -> Instant {
        Self::from(::std::time::SystemTime::now())
    }

    /// The fractional number of milliseconds that have passed
    /// since the beginning of time.
    pub const fn millis(&self) -> i64 {
        self.micros % 1000000 / 1000
    }

    /// The fractional number of microseconds that have passed
    /// since the beginning of time.
    pub const fn micros(&self) -> i64 {
        self.micros % 1000000
    }

    /// The number of whole seconds that have passed since the
    /// beginning of time.
    pub const fn secs(&self) -> i64 {
        self.micros / 1000000
    }

    /// The total number of milliseconds that have passed since
    /// the beginning of time.
    pub const fn total_millis(&self) -> i64 {
        self.micros / 1000
    }
    /// The total number of milliseconds that have passed since
    /// the beginning of time.
    pub const fn total_micros(&self) -> i64 {
        self.micros
    }
}

#[cfg(feature = "std")]
impl From<::std::time::Instant> for Instant {
    fn from(other: ::std::time::Instant) -> Instant {
        static REFERENTIAL: ::std::sync::LazyLock<::std::time::Instant> =
            ::std::sync::LazyLock::new(::std::time::Instant::now);

        let n = other.saturating_duration_since(*REFERENTIAL);
        Self::from_micros(n.as_secs() as i64 * 1000000 + n.subsec_micros() as i64)
    }
}

#[cfg(feature = "std")]
impl From<::std::time::SystemTime> for Instant {
    fn from(other: ::std::time::SystemTime) -> Instant {
        let n = other
            .duration_since(::std::time::UNIX_EPOCH)
            .expect("start time must not be before the unix epoch");
        Self::from_micros(n.as_secs() as i64 * 1000000 + n.subsec_micros() as i64)
    }
}

#[cfg(feature = "std")]
impl From<Instant> for ::std::time::SystemTime {
    fn from(val: Instant) -> Self {
        ::std::time::UNIX_EPOCH + ::std::time::Duration::from_micros(val.micros as u64)
    }
}

impl fmt::Display for Instant {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}.{:0>3}s", self.secs(), self.millis())
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Instant {
    fn format(&self, f: defmt::Formatter) {
        defmt::write!(f, "{}.{:03}s", self.secs(), self.millis());
    }
}

impl ops::Add<Duration> for Instant {
    type Output = Instant;

    fn add(self, rhs: Duration) -> Instant {
        Instant::from_micros(self.micros + rhs.total_micros() as i64)
    }
}

impl ops::AddAssign<Duration> for Instant {
    fn add_assign(&mut self, rhs: Duration) {
        self.micros += rhs.total_micros() as i64;
    }
}

impl ops::Sub<Duration> for Instant {
    type Output = Instant;

    fn sub(self, rhs: Duration) -> Instant {
        Instant::from_micros(self.micros - rhs.total_micros() as i64)
    }
}

impl ops::SubAssign<Duration> for Instant {
    fn sub_assign(&mut self, rhs: Duration) {
        self.micros -= rhs.total_micros() as i64;
    }
}

impl ops::Sub<Instant> for Instant {
    type Output = Duration;

    fn sub(self, rhs: Instant) -> Duration {
        Duration::from_micros((self.micros - rhs.micros).unsigned_abs())
    }
}

/// A relative amount of time.
#[derive(Debug, Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Duration {
    micros: u64,
}

impl Duration {
    pub const ZERO: Duration = Duration::from_micros(0);
    /// The longest possible duration we can encode.
    pub const MAX: Duration = Duration::from_micros(u64::MAX);
    /// Create a new `Duration` from a number of microseconds.
    pub const fn from_micros(micros: u64) -> Duration {
        Duration { micros }
    }

    /// Create a new `Duration` from a number of milliseconds.
    pub const fn from_millis(millis: u64) -> Duration {
        Duration {
            micros: millis * 1000,
        }
    }

    /// Create a new `Duration` from a number of seconds.
    pub const fn from_secs(secs: u64) -> Duration {
        Duration {
            micros: secs * 1000000,
        }
    }

    /// The fractional number of milliseconds in this `Duration`.
    pub const fn millis(&self) -> u64 {
        self.micros / 1000 % 1000
    }

    /// The fractional number of milliseconds in this `Duration`.
    pub const fn micros(&self) -> u64 {
        self.micros % 1000000
    }

    /// The number of whole seconds in this `Duration`.
    pub const fn secs(&self) -> u64 {
        self.micros / 1000000
    }

    /// The total number of milliseconds in this `Duration`.
    pub const fn total_millis(&self) -> u64 {
        self.micros / 1000
    }

    /// The total number of microseconds in this `Duration`.
    pub const fn total_micros(&self) -> u64 {
        self.micros
    }
}

impl fmt::Display for Duration {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}.{:03}s", self.secs(), self.millis())
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Duration {
    fn format(&self, f: defmt::Formatter) {
        defmt::write!(f, "{}.{:03}s", self.secs(), self.millis());
    }
}

impl ops::Add<Duration> for Duration {
    type Output = Duration;

    fn add(self, rhs: Duration) -> Duration {
        Duration::from_micros(self.micros + rhs.total_micros())
    }
}

impl ops::AddAssign<Duration> for Duration {
    fn add_assign(&mut self, rhs: Duration) {
        self.micros += rhs.total_micros();
    }
}

impl ops::Sub<Duration> for Duration {
    type Output = Duration;

    fn sub(self, rhs: Duration) -> Duration {
        Duration::from_micros(
            self.micros
                .checked_sub(rhs.total_micros())
                .expect("overflow when subtracting durations"),
        )
    }
}

impl ops::SubAssign<Duration> for Duration {
    fn sub_assign(&mut self, rhs: Duration) {
        self.micros = self
            .micros
            .checked_sub(rhs.total_micros())
            .expect("overflow when subtracting durations");
    }
}

impl ops::Mul<u32> for Duration {
    type Output = Duration;

    fn mul(self, rhs: u32) -> Duration {
        Duration::from_micros(self.micros * rhs as u64)
    }
}

impl ops::MulAssign<u32> for Duration {
    fn mul_assign(&mut self, rhs: u32) {
        self.micros *= rhs as u64;
    }
}

impl ops::Div<u32> for Duration {
    type Output = Duration;

    fn div(self, rhs: u32) -> Duration {
        Duration::from_micros(self.micros / rhs as u64)
    }
}

impl ops::DivAssign<u32> for Duration {
    fn div_assign(&mut self, rhs: u32) {
        self.micros /= rhs as u64;
    }
}

impl ops::Shl<u32> for Duration {
    type Output = Duration;

    fn shl(self, rhs: u32) -> Duration {
        Duration::from_micros(self.micros << rhs)
    }
}

impl ops::ShlAssign<u32> for Duration {
    fn shl_assign(&mut self, rhs: u32) {
        self.micros <<= rhs;
    }
}

impl ops::Shr<u32> for Duration {
    type Output = Duration;

    fn shr(self, rhs: u32) -> Duration {
        Duration::from_micros(self.micros >> rhs)
    }
}

impl ops::ShrAssign<u32> for Duration {
    fn shr_assign(&mut self, rhs: u32) {
        self.micros >>= rhs;
    }
}

impl From<::core::time::Duration> for Duration {
    fn from(other: ::core::time::Duration) -> Duration {
        Duration::from_micros(other.as_secs() * 1000000 + other.subsec_micros() as u64)
    }
}

impl From<Duration> for ::core::time::Duration {
    fn from(val: Duration) -> Self {
        ::core::time::Duration::from_micros(val.total_micros())
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_instant_ops() {
        // std::ops::Add
        assert_eq!(
            Instant::from_millis(4) + Duration::from_millis(6),
            Instant::from_millis(10)
        );
        // std::ops::Sub
        assert_eq!(
            Instant::from_millis(7) - Duration::from_millis(5),
            Instant::from_millis(2)
        );
    }

    #[test]
    fn test_instant_getters() {
        let instant = Instant::from_millis(5674);
        assert_eq!(instant.secs(), 5);
        assert_eq!(instant.millis(), 674);
        assert_eq!(instant.total_millis(), 5674);
    }

    #[test]
    fn test_instant_display() {
        assert_eq!(format!("{}", Instant::from_millis(74)), "0.074s");
        assert_eq!(format!("{}", Instant::from_millis(5674)), "5.674s");
        assert_eq!(format!("{}", Instant::from_millis(5000)), "5.000s");
    }

    #[test]
    #[cfg(feature = "std")]
    fn test_instant_conversions() {
        let mut epoc: ::std::time::SystemTime = Instant::from_millis(0).into();
        assert_eq!(
            Instant::from(::std::time::UNIX_EPOCH),
            Instant::from_millis(0)
        );
        assert_eq!(epoc, ::std::time::UNIX_EPOCH);
        epoc = Instant::from_millis(2085955200i64 * 1000).into();
        assert_eq!(
            epoc,
            ::std::time::UNIX_EPOCH + ::std::time::Duration::from_secs(2085955200)
        );
    }

    #[test]
    #[cfg(feature = "std")]
    fn test_instant_conversions_from_std_instant() {
        let std_now = ::std::time::Instant::now();

        let before = Instant::from(std_now);
        ::std::thread::sleep(::std::time::Duration::from_millis(5));
        let after = Instant::from(std_now);

        assert_eq!(
            before, after,
            "converting the same std Instant twice should yield the same result"
        );
    }

    #[test]
    fn test_duration_ops() {
        // std::ops::Add
        assert_eq!(
            Duration::from_millis(40) + Duration::from_millis(2),
            Duration::from_millis(42)
        );
        // std::ops::Sub
        assert_eq!(
            Duration::from_millis(555) - Duration::from_millis(42),
            Duration::from_millis(513)
        );
        // std::ops::Mul
        assert_eq!(Duration::from_millis(13) * 22, Duration::from_millis(286));
        // std::ops::Div
        assert_eq!(Duration::from_millis(53) / 4, Duration::from_micros(13250));
    }

    #[test]
    fn test_duration_assign_ops() {
        let mut duration = Duration::from_millis(4735);
        duration += Duration::from_millis(1733);
        assert_eq!(duration, Duration::from_millis(6468));
        duration -= Duration::from_millis(1234);
        assert_eq!(duration, Duration::from_millis(5234));
        duration *= 4;
        assert_eq!(duration, Duration::from_millis(20936));
        duration /= 5;
        assert_eq!(duration, Duration::from_micros(4187200));
    }

    #[test]
    #[should_panic(expected = "overflow when subtracting durations")]
    fn test_sub_from_zero_overflow() {
        let _ = Duration::from_millis(0) - Duration::from_millis(1);
    }

    #[test]
    #[should_panic(expected = "attempt to divide by zero")]
    fn test_div_by_zero() {
        let _ = Duration::from_millis(4) / 0;
    }

    #[test]
    fn test_duration_getters() {
        let instant = Duration::from_millis(4934);
        assert_eq!(instant.secs(), 4);
        assert_eq!(instant.millis(), 934);
        assert_eq!(instant.total_millis(), 4934);
    }

    #[test]
    fn test_duration_conversions() {
        let mut std_duration = ::core::time::Duration::from_millis(4934);
        let duration: Duration = std_duration.into();
        assert_eq!(duration, Duration::from_millis(4934));
        assert_eq!(Duration::from(std_duration), Duration::from_millis(4934));

        std_duration = duration.into();
        assert_eq!(std_duration, ::core::time::Duration::from_millis(4934));
    }
}
