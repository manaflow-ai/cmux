//! Date-pinned API versions on top of numbered revisions.
//!
//! A client pins the API it was written against by a date, `YYYY-MM-DD`
//! (`2026-11-24`). Each revision in the compat file carries the date it
//! shipped (`base_date` for `base`, `date` for every later one). A pin
//! resolves to the newest revision dated on or before it, so a client keeps
//! the shape it was written against, and the existing rules translate every
//! message to and from that revision. The server answers with the dated
//! version it served ([`Schema::served_version`]).
//!
//! - A pin before `base_date` is refused: that shape is no longer served.
//! - A pin after the newest date gets the newest revision; the answer names
//!   the older date, so the client knows what it got.
//! - A client that pins nothing keeps the protocol's existing default.
//!
//! The promise (`cmux-tui/spec/api-versioning.md`): no breaking change ships
//! without a new dated version, and every dated version stays served for at
//! least 12 months after the version that replaced it.

use crate::CompatError;
use crate::schema::Schema;

/// A validated `YYYY-MM-DD` date. Ordering is calendar order because the
/// fields are fixed width.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ApiDate {
    year: u16,
    month: u8,
    day: u8,
}

impl ApiDate {
    /// Parses `YYYY-MM-DD` (four digit year, two digit month and day, a
    /// day that exists in that month).
    pub fn parse(text: &str) -> Result<Self, CompatError> {
        let bad = || CompatError::BadVersion(text.to_owned());
        let bytes = text.as_bytes();
        if bytes.len() != 10 || bytes.get(4) != Some(&b'-') || bytes.get(7) != Some(&b'-') {
            return Err(bad());
        }
        let number = |range: std::ops::Range<usize>| -> Result<u16, CompatError> {
            let digits = text.get(range).ok_or_else(bad)?;
            if !digits.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad());
            }
            digits.parse().map_err(|_| bad())
        };
        let year = number(0..4)?;
        let month = u8::try_from(number(5..7)?).map_err(|_| bad())?;
        let day = u8::try_from(number(8..10)?).map_err(|_| bad())?;
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
        let days = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if leap => 29,
            2 => 28,
            _ => return Err(bad()),
        };
        if day == 0 || day > days {
            return Err(bad());
        }
        Ok(Self { year, month, day })
    }
}

impl std::fmt::Display for ApiDate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

/// What a pin resolved to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    /// The revision that serves the pin.
    pub revision: u32,
    /// That revision's dated name: the version the server answers with.
    pub served: String,
}

impl Schema {
    /// The dated name of `revision`, when the schema is dated.
    pub fn served_version(&self, revision: u32) -> Option<&str> {
        if revision == self.base {
            return self.base_date.as_deref();
        }
        self.revisions.iter().find(|r| r.rev == revision).and_then(|r| r.date.as_deref())
    }

    /// The newest dated version (`None` before the schema is dated).
    pub fn current_version(&self) -> Option<&str> {
        self.served_version(self.current())
    }

    /// The oldest dated version still served.
    pub fn oldest_version(&self) -> Option<&str> {
        self.base_date.as_deref()
    }

    /// Resolves a client's pin to the newest revision dated on or before it.
    pub fn resolve_version(&self, pin: &str) -> Result<Resolved, CompatError> {
        let wanted = ApiDate::parse(pin)?;
        let Some(base_date) = self.base_date.as_deref() else {
            return Err(CompatError::InvalidSchema(format!(
                "protocol {} has no dated versions",
                self.protocol
            )));
        };
        let unsupported = || CompatError::UnsupportedVersion {
            version: pin.to_owned(),
            oldest: base_date.to_owned(),
            newest: self.current_version().unwrap_or(base_date).to_owned(),
        };
        if wanted < ApiDate::parse(base_date)? {
            return Err(unsupported());
        }
        let mut resolved = Resolved { revision: self.base, served: base_date.to_owned() };
        for revision in &self.revisions {
            let Some(date) = revision.date.as_deref() else { break };
            if ApiDate::parse(date)? > wanted {
                break;
            }
            resolved = Resolved { revision: revision.rev, served: date.to_owned() };
        }
        Ok(resolved)
    }
}

/// Once `base_date` is set, every revision carries a valid date later than
/// the one before; without it, no revision is dated.
pub(crate) fn validate_dates(schema: &Schema) -> Result<(), CompatError> {
    let Some(base_date) = schema.base_date.as_deref() else {
        return match schema.revisions.iter().find(|r| r.date.is_some()) {
            Some(r) => Err(CompatError::InvalidSchema(format!(
                "revision {} has a date but the schema has no base_date",
                r.rev
            ))),
            None => Ok(()),
        };
    };
    let mut previous = ApiDate::parse(base_date)?;
    for revision in &schema.revisions {
        let Some(date) = revision.date.as_deref() else {
            return Err(CompatError::InvalidSchema(format!(
                "revision {} has no date; a dated schema dates every revision",
                revision.rev
            )));
        };
        let date = ApiDate::parse(date)?;
        if date <= previous {
            return Err(CompatError::InvalidSchema(format!(
                "revision {} is dated {date}, not after {previous}",
                revision.rev
            )));
        }
        previous = date;
    }
    Ok(())
}

#[cfg(test)]
#[path = "version_tests.rs"]
mod tests;
