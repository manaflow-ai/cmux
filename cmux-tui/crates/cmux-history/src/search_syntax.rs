//! The search operators every history search understands, as Obsidian's and
//! GitHub's do: a search field narrows by kind and by time without leaving the
//! keyboard. One parser, so the History page, the palette's history page,
//! `cmux history list|search` and `history-search` read a query the same way.
//!
//! - `is:KIND` or `kind:KIND`: only that kind (repeat for several). Each
//!   surface names its kinds; a name it does not know stays a plain word.
//! - `after:WHEN` or `since:WHEN`: at or after WHEN.
//! - `before:WHEN`: before WHEN.
//! - `-word`, `-"some words"`: leave out what contains it.
//! - `"some words"`: that text, spaces included.
//!
//! WHEN is an age (`30m`, `2h`, `7d`, `4w`), `today`, `yesterday` or a local
//! date `YYYY-MM-DD`. A value that does not parse leaves the token a plain
//! word, so a search for `before:lunch` still finds that text.

use crate::fold::fold;

const MINUTE_MS: i64 = 60_000;
const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

/// A parsed search: what must and must not appear, the kinds and the time
/// window it names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchFilter<K> {
    /// As typed; every one must appear. A quoted phrase keeps its spaces.
    /// Each store folds them as its own text is folded.
    pub words: Vec<String>,
    /// As typed; none may appear.
    pub excluded: Vec<String>,
    /// Empty: every kind.
    pub kinds: Vec<K>,
    /// Inclusive, Unix milliseconds.
    pub after_ms: Option<i64>,
    /// Exclusive, Unix milliseconds.
    pub before_ms: Option<i64>,
}

impl<K: PartialEq> SearchFilter<K> {
    /// Every one of `words`, in every kind and at any time.
    pub fn words(words: Vec<String>) -> Self {
        Self { words, excluded: Vec::new(), kinds: Vec::new(), after_ms: None, before_ms: None }
    }

    /// Parses `text`. `kind` names the surface's kinds (`None`: not a kind
    /// there). Ages count back from `now_ms`; `today`, `yesterday` and dates
    /// count from `local_day_start_ms`, the local start of today.
    pub fn parse(
        text: &str,
        now_ms: i64,
        local_day_start_ms: i64,
        kind: impl Fn(&str) -> Option<K>,
    ) -> Self {
        let mut filter = Self::words(Vec::new());
        for token in split(text) {
            let (negated, body) = match token.text.strip_prefix('-') {
                Some(rest) if !rest.is_empty() => (true, rest),
                _ => (false, token.text.as_str()),
            };
            if !token.quoted && !negated && filter.operator(body, now_ms, local_day_start_ms, &kind)
            {
                continue;
            }
            let word = if token.quoted { token.text.as_str() } else { body };
            if word.trim().is_empty() {
                continue;
            }
            if negated && !token.quoted {
                filter.excluded.push(word.to_owned());
            } else {
                filter.words.push(word.to_owned());
            }
        }
        filter
    }

    /// Applies `key:value` when it is an operator; false leaves it a word.
    fn operator(
        &mut self,
        token: &str,
        now_ms: i64,
        local_day_start_ms: i64,
        kind: &impl Fn(&str) -> Option<K>,
    ) -> bool {
        let Some((key, value)) = token.split_once(':') else {
            return false;
        };
        let value = value.to_ascii_lowercase();
        match key.to_ascii_lowercase().as_str() {
            "is" | "kind" => match kind(&value) {
                Some(found) => {
                    if !self.kinds.contains(&found) {
                        self.kinds.push(found);
                    }
                    true
                }
                None => false,
            },
            "after" | "since" => match when(&value, now_ms, local_day_start_ms) {
                Some(at) => {
                    self.after_ms = Some(self.after_ms.map_or(at, |old| old.max(at)));
                    true
                }
                None => false,
            },
            "before" => match when(&value, now_ms, local_day_start_ms) {
                Some(at) => {
                    self.before_ms = Some(self.before_ms.map_or(at, |old| old.min(at)));
                    true
                }
                None => false,
            },
            _ => false,
        }
    }

    /// True when the filter names no kind or names `kind`.
    pub fn wants(&self, kind: &K) -> bool {
        self.kinds.is_empty() || self.kinds.contains(kind)
    }

    /// True when `at_ms` is inside the time window.
    pub fn covers(&self, at_ms: i64) -> bool {
        self.after_ms.is_none_or(|after| at_ms >= after)
            && self.before_ms.is_none_or(|before| at_ms < before)
    }

    /// True when `haystack` has every word and no excluded one, both sides
    /// folded ([`fold`]).
    pub fn matches(&self, haystack: &str) -> bool {
        if self.words.is_empty() && self.excluded.is_empty() {
            return true;
        }
        let folded = fold(haystack);
        self.words.iter().all(|word| folded.contains(fold(word).as_str()))
            && !self.excluded.iter().any(|word| folded.contains(fold(word).as_str()))
    }
}

struct Token {
    text: String,
    quoted: bool,
}

/// Whitespace-separated tokens; `"..."` (or `-"..."`) is one token with its
/// spaces. An unclosed quote runs to the end.
fn split(text: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(&ch) = chars.peek() {
        if ch.is_whitespace() {
            chars.next();
            continue;
        }
        let mut word = String::new();
        let mut quoted = false;
        while let Some(&ch) = chars.peek() {
            if ch.is_whitespace() {
                break;
            }
            chars.next();
            if ch == '"' && (word.is_empty() || word == "-") {
                quoted = true;
                let negated = word == "-";
                word.clear();
                for inner in chars.by_ref() {
                    if inner == '"' {
                        break;
                    }
                    word.push(inner);
                }
                if negated {
                    // A quoted exclusion: fold it here and mark it unquoted
                    // so `parse` files it with the excluded words.
                    tokens.push(Token { text: format!("-{word}"), quoted: false });
                    word.clear();
                    quoted = false;
                }
                break;
            }
            word.push(ch);
        }
        if !word.is_empty() {
            tokens.push(Token { text: word, quoted });
        }
    }
    tokens
}

/// The time WHEN names, or `None` when it is not a time.
fn when(value: &str, now_ms: i64, local_day_start_ms: i64) -> Option<i64> {
    match value {
        "today" => return Some(local_day_start_ms),
        "yesterday" => return Some(local_day_start_ms - DAY_MS),
        _ => {}
    }
    if let Some(at) = date(value, local_day_start_ms) {
        return Some(at);
    }
    let unit_at = value.find(|ch: char| !ch.is_ascii_digit())?;
    let (count, unit) = value.split_at(unit_at);
    let count: i64 = count.parse().ok()?;
    let unit_ms = match unit {
        "m" | "min" => MINUTE_MS,
        "h" => HOUR_MS,
        "d" => DAY_MS,
        "w" => 7 * DAY_MS,
        _ => return None,
    };
    Some(now_ms.saturating_sub(count.saturating_mul(unit_ms)))
}

/// Local midnight of `YYYY-MM-DD`. The zone offset is read off
/// `local_day_start_ms`: for zones from UTC-10 to UTC+13, local midnight of
/// day D falls in [D - 13 h, D + 10 h], so D is the UTC date 13 hours later.
/// UTC+14 (Line Islands) reads a day early and UTC-11 and UTC-12 a day
/// late; a date across a daylight-saving change can be an hour off.
fn date(value: &str, local_day_start_ms: i64) -> Option<i64> {
    let mut parts = value.splitn(3, '-');
    let (year, month, day) = (parts.next()?, parts.next()?, parts.next()?);
    if year.len() != 4 || month.len() != 2 || day.len() != 2 {
        return None;
    }
    let (year, month, day): (i64, u32, u32) =
        (year.parse().ok()?, month.parse().ok()?, day.parse().ok()?);
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    let utc_today = (local_day_start_ms + 13 * HOUR_MS).div_euclid(DAY_MS) * DAY_MS;
    let offset = utc_today - local_day_start_ms;
    Some(days_from_civil(year, month, day) * DAY_MS - offset)
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month = i64::from(month);
    let day_of_year =
        (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
#[path = "search_syntax_tests.rs"]
mod tests;
