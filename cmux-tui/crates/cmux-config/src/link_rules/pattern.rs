//! URL rules (`browser.urlsToAlwaysOpenExternally`, a `terminal.linkOpener`
//! rule's URL pattern), matched as classic cmux matched them: plain text is a
//! case-insensitive substring, `*`/`?` are wildcards, `re:` is a bounded
//! regex. Ported from Swift `BrowserExternalURLPatternMatcher` (itself classic
//! `CmuxSettings` `BrowserExternalURLPolicy`), with its exact bounds and its
//! exact accept and refuse rules for a regex ([`regex_accepts`]).

use regex::{Regex, RegexBuilder};

/// The longest target a matcher considers, in UTF-8 bytes.
const MAXIMUM_TARGET_LENGTH: usize = 16_384;
/// Each rule gets its own bounded slice, so a costly rule cannot keep a later
/// one from being considered.
const MAXIMUM_MATCH_OPERATIONS_PER_PATTERN: i64 = 32_768;
/// The most rules one matcher keeps.
const MAXIMUM_PATTERN_COUNT: usize = 256;
/// The most values one matcher inspects.
const MAXIMUM_INPUT_VALUE_COUNT: usize = 512;
/// The longest rule accepted for matching, in UTF-8 bytes.
const MAXIMUM_PATTERN_LENGTH: usize = 4096;
/// The total rule text one matcher keeps, in characters.
const MAXIMUM_TOTAL_PATTERN_LENGTH: usize = 65_536;
/// The longest regex text accepted, in UTF-8 bytes.
const MAXIMUM_EXPRESSION_LENGTH: usize = 8_192;
/// Two quantifiers and one alternation cover normal URL rules (`https?`,
/// `.*`, `\d+`).
const MAXIMUM_QUANTIFIER_COUNT: usize = 2;
const MAXIMUM_ALTERNATION_COUNT: usize = 1;
/// At most one variable-width quantifier; the `.*`/`.+` subset is turned into
/// a bounded glob before this gate.
const MAXIMUM_VARIABLE_QUANTIFIER_COUNT: usize = 1;
/// The largest `{n}` / `{n,m}` bound.
const MAXIMUM_REPEAT: u64 = 16_384;

/// The normalized, compiled rules of one list.
#[derive(Debug, Clone)]
pub struct Matcher {
    patterns: Vec<String>,
    compiled: Vec<Compiled>,
}

impl Matcher {
    /// Builds a matcher from rules, one per value or line; blank lines,
    /// `#` comments and repeats are dropped and the bounds applied.
    pub fn new<S: AsRef<str>>(values: &[S]) -> Self {
        let patterns = normalized_patterns(values);
        let compiled = patterns.iter().map(|pattern| compile(pattern)).collect();
        Self { patterns, compiled }
    }

    /// The normalized rules.
    pub fn patterns(&self) -> &[String] {
        &self.patterns
    }

    /// Whether a rule matches `target` (a URL's absolute string).
    pub fn matches(&self, target: &str) -> bool {
        if target.len() > MAXIMUM_TARGET_LENGTH {
            return false;
        }
        let needs_normalized = self.compiled.iter().any(|c| matches!(c, Compiled::Wildcard(_)));
        let normalized = if needs_normalized { target.to_lowercase() } else { String::new() };
        let characters: Vec<char> = normalized.chars().collect();
        let lowered_target = target.to_lowercase();
        self.compiled.iter().any(|pattern| {
            let mut budget = MAXIMUM_MATCH_OPERATIONS_PER_PATTERN;
            pattern.matches(target, &lowered_target, &characters, &normalized, &mut budget)
        })
    }
}

/// Whether one rule list matches `target`.
pub fn matches<S: AsRef<str>>(patterns: &[S], target: &str) -> bool {
    Matcher::new(patterns).matches(target)
}

#[derive(Debug, Clone)]
enum Compiled {
    /// A case-insensitive substring (lowercased).
    Literal(String),
    /// A regex-shaped rule that is not `re:`: the substring, else the regex.
    LiteralFallback(String, Option<Regex>),
    Regex(Option<Regex>),
    Wildcard(Wildcard),
    Unmatchable,
}

impl Compiled {
    fn matches(
        &self,
        target: &str,
        lowered_target: &str,
        characters: &[char],
        normalized: &str,
        budget: &mut i64,
    ) -> bool {
        match self {
            Self::Wildcard(wildcard) => wildcard.matches(characters, normalized, budget),
            Self::Literal(literal) => lowered_target.contains(literal.as_str()),
            Self::LiteralFallback(literal, regex) => {
                lowered_target.contains(literal.as_str())
                    || regex.as_ref().is_some_and(|regex| regex.is_match(target))
            }
            Self::Regex(regex) => regex.as_ref().is_some_and(|regex| regex.is_match(target)),
            Self::Unmatchable => false,
        }
    }
}

fn compile(pattern: &str) -> Compiled {
    if pattern.len() > MAXIMUM_PATTERN_LENGTH {
        return Compiled::Unmatchable;
    }
    if pattern.get(..3).is_some_and(|prefix| prefix.eq_ignore_ascii_case("re:")) {
        let expression = pattern[3..].trim();
        if let Some(wildcard) = linear_wildcard(expression) {
            return Compiled::Wildcard(wildcard);
        }
        return Compiled::Regex(make_regex(expression));
    }
    if (pattern.contains('*') || pattern.contains('?')) && !is_legacy_regex_wildcard(pattern) {
        return match Wildcard::new(pattern) {
            Some(wildcard) => Compiled::Wildcard(wildcard),
            None => Compiled::Unmatchable,
        };
    }
    if is_regex_shaped(pattern) {
        if let Some(wildcard) = linear_wildcard(pattern) {
            return Compiled::Wildcard(wildcard);
        }
        return Compiled::LiteralFallback(pattern.to_lowercase(), make_regex(pattern));
    }
    Compiled::Literal(pattern.to_lowercase())
}

fn make_regex(expression: &str) -> Option<Regex> {
    if !regex_accepts(expression) {
        return None;
    }
    RegexBuilder::new(expression).case_insensitive(true).build().ok()
}

fn is_regex_shaped(pattern: &str) -> bool {
    pattern.chars().any(|c| "\\^$+()[]{}|".contains(c))
        || pattern.contains(".*")
        || pattern.contains(".+")
}

/// A rule with `*` or `?` that is really classic's regex (`.*`, `.+`): it then
/// takes the regex path, not the glob.
fn is_legacy_regex_wildcard(pattern: &str) -> bool {
    let mut has_legacy_quantifier = false;
    let mut escaping = false;
    let mut previous_was_dot = false;
    for character in pattern.chars() {
        if escaping {
            escaping = false;
            previous_was_dot = false;
            continue;
        }
        if character == '\\' {
            escaping = true;
            previous_was_dot = false;
            continue;
        }
        if character == '?' {
            return false;
        }
        if character == '*' || character == '+' {
            if previous_was_dot {
                has_legacy_quantifier = true;
            } else if character == '*' {
                // A standalone star is a glob wildcard, even when a later
                // literal period forms the text `.*`.
                return false;
            }
        }
        previous_was_dot = character == '.';
    }
    has_legacy_quantifier
}

/// The small `.*`/`.+` regex subset as a bounded glob, so repeated wildcard
/// quantifiers stay linear; anything else stays on the regex path.
fn linear_wildcard(expression: &str) -> Option<Wildcard> {
    let mut wildcard = String::new();
    let mut has_quantifier = false;
    let characters: Vec<char> = expression.chars().collect();
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        let next = characters.get(index + 1).copied();
        if character == '.' {
            match next {
                Some('*') => {
                    wildcard.push('*');
                    has_quantifier = true;
                    index += 2;
                    continue;
                }
                Some('+') => {
                    // At least one character.
                    wildcard.push_str("?*");
                    has_quantifier = true;
                    index += 2;
                    continue;
                }
                _ => {}
            }
            wildcard.push('?');
            index += 1;
            continue;
        }
        if character == '\\' {
            let escaped = next?;
            // Letter and number escapes are classes, boundaries,
            // backreferences or code points: left to the regex.
            if escaped.is_alphabetic() || escaped.is_numeric() {
                return None;
            }
            push_wildcard_literal(escaped, &mut wildcard);
            index += 2;
            continue;
        }
        if "^$()[]{}|+?*".contains(character) {
            return None;
        }
        push_wildcard_literal(character, &mut wildcard);
        index += 1;
    }
    if !has_quantifier {
        return None;
    }
    Wildcard::new(&wildcard)
}

fn push_wildcard_literal(character: char, wildcard: &mut String) {
    if matches!(character, '\\' | '*' | '?') {
        wildcard.push('\\');
    }
    wildcard.push(character);
}

fn normalized_patterns<S: AsRef<str>>(values: &[S]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    let mut total = 0usize;
    for value in values.iter().take(MAXIMUM_INPUT_VALUE_COUNT) {
        if total >= MAXIMUM_TOTAL_PATTERN_LENGTH {
            return result;
        }
        let bounded: String = value.as_ref().chars().take(MAXIMUM_TOTAL_PATTERN_LENGTH).collect();
        for token in bounded.split(is_newline) {
            let normalized = token.trim();
            if normalized.is_empty() || normalized.starts_with('#') {
                continue;
            }
            if !seen.insert(normalized.to_owned()) {
                continue;
            }
            let length = normalized.chars().count();
            if result.len() >= MAXIMUM_PATTERN_COUNT
                || total + length > MAXIMUM_TOTAL_PATTERN_LENGTH
            {
                return result;
            }
            result.push(normalized.to_owned());
            total += length;
        }
    }
    result
}

/// Foundation's `CharacterSet.newlines`.
pub(crate) fn is_newline(c: char) -> bool {
    matches!(c, '\u{A}'..='\u{D}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Token {
    Star,
    One,
    Literal(char),
}

/// A `*`/`?` glob matched in linear time with no backtracking blowup. Every
/// glob has an implicit `*` at both ends (classic's substring behaviour).
#[derive(Debug, Clone)]
struct Wildcard {
    literal_anchor: Option<String>,
    tokens: Vec<Token>,
}

impl Wildcard {
    fn new(pattern: &str) -> Option<Self> {
        if pattern.len() > MAXIMUM_PATTERN_LENGTH {
            return None;
        }
        let mut tokens = vec![Token::Star];
        let mut escaping = false;
        let mut current = String::new();
        let mut longest = String::new();
        fn end_literal(current: &mut String, longest: &mut String) {
            if current.chars().count() > longest.chars().count() {
                *longest = std::mem::take(current);
            }
            current.clear();
        }
        fn push_literal(tokens: &mut Vec<Token>, current: &mut String, character: char) {
            for lowered in character.to_lowercase() {
                tokens.push(Token::Literal(lowered));
                current.push(lowered);
            }
        }
        for character in pattern.chars() {
            if escaping {
                push_literal(&mut tokens, &mut current, character);
                escaping = false;
                continue;
            }
            match character {
                '\\' => escaping = true,
                '*' => {
                    // Consecutive stars are one star.
                    if tokens.last() != Some(&Token::Star) {
                        tokens.push(Token::Star);
                    }
                    end_literal(&mut current, &mut longest);
                }
                '?' => {
                    tokens.push(Token::One);
                    end_literal(&mut current, &mut longest);
                }
                _ => push_literal(&mut tokens, &mut current, character),
            }
        }
        if escaping {
            tokens.push(Token::Literal('\\'));
            current.push('\\');
        }
        end_literal(&mut current, &mut longest);
        if tokens.last() != Some(&Token::Star) {
            tokens.push(Token::Star);
        }
        let literal_anchor = (longest.chars().count() >= 2).then_some(longest);
        Some(Self { literal_anchor, tokens })
    }

    fn matches(&self, characters: &[char], normalized: &str, budget: &mut i64) -> bool {
        if let Some(anchor) = &self.literal_anchor
            && !normalized.contains(anchor.as_str())
        {
            return false;
        }
        let tokens = &self.tokens;
        let mut token = 0;
        let mut character = 0;
        let mut last_star: Option<usize> = None;
        let mut star_match = 0;
        while character < characters.len() {
            *budget -= 1;
            if *budget < 0 {
                return false;
            }
            if token < tokens.len() {
                let matched = match tokens[token] {
                    Token::Star => false,
                    Token::One => true,
                    Token::Literal(literal) => literal == characters[character],
                };
                if matched {
                    token += 1;
                    character += 1;
                    continue;
                }
                if tokens[token] == Token::Star {
                    last_star = Some(token);
                    token += 1;
                    star_match = character;
                    continue;
                }
            }
            if let Some(star) = last_star
                && star_match < characters.len()
            {
                token = star + 1;
                star_match += 1;
                character = star_match;
                continue;
            }
            return false;
        }
        while token < tokens.len() && tokens[token] == Token::Star {
            token += 1;
        }
        token == tokens.len()
    }
}

/// Whether `expression` has the bounded shape a synchronous URL decision
/// accepts (Swift `BrowserExternalURLRegexSafety.accepts`): no
/// backreferences, subroutine calls or `(?` forms, at most two quantifiers,
/// one of them variable-width, one alternation, no quantified group that
/// already holds a quantifier or alternation.
pub fn regex_accepts(expression: &str) -> bool {
    if expression.is_empty() || expression.len() > MAXIMUM_EXPRESSION_LENGTH {
        return false;
    }
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Atom {
        None,
        Ordinary,
        Group,
        Quantified,
    }
    let characters: Vec<char> = expression.chars().collect();
    let mut group_has_quantifier: Vec<bool> = Vec::new();
    let mut group_has_alternation: Vec<bool> = Vec::new();
    let mut previous = Atom::None;
    let mut previous_group_complex = false;
    let mut escaping = false;
    let mut in_class = false;
    let mut quantifiers = 0;
    let mut variable_quantifiers = 0;
    let mut alternations = 0;
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        let next = index + 1;
        if escaping {
            if character.is_numeric() || matches!(character, 'k' | 'K' | 'g' | 'G') {
                return false;
            }
            escaping = false;
            previous = Atom::Ordinary;
            previous_group_complex = false;
            index = next;
            continue;
        }
        if character == '\\' {
            escaping = true;
            index = next;
            continue;
        }
        if in_class {
            if character == ']' {
                in_class = false;
                previous = Atom::Ordinary;
                previous_group_complex = false;
            }
            index = next;
            continue;
        }
        match character {
            '[' => {
                in_class = true;
                previous = Atom::Ordinary;
                previous_group_complex = false;
            }
            '(' => {
                if characters.get(next) == Some(&'?') {
                    return false;
                }
                group_has_quantifier.push(false);
                group_has_alternation.push(false);
                previous = Atom::None;
                previous_group_complex = false;
            }
            ')' => {
                let (Some(has_quantifier), Some(has_alternation)) =
                    (group_has_quantifier.pop(), group_has_alternation.pop())
                else {
                    return false;
                };
                if let Some(last) = group_has_quantifier.last_mut() {
                    *last |= has_quantifier;
                }
                if let Some(last) = group_has_alternation.last_mut() {
                    *last |= has_alternation;
                }
                previous = Atom::Group;
                previous_group_complex = has_quantifier || has_alternation;
            }
            '|' => {
                alternations += 1;
                if alternations > MAXIMUM_ALTERNATION_COUNT {
                    return false;
                }
                if let Some(last) = group_has_alternation.last_mut() {
                    *last = true;
                }
                previous = Atom::None;
                previous_group_complex = false;
            }
            '*' | '+' | '?' | '{' => {
                let mut end = next;
                let mut variable = character != '?';
                if character == '{' {
                    let Some((parsed_end, is_variable)) = quantifier_end(&characters, index) else {
                        return false;
                    };
                    end = parsed_end;
                    variable = is_variable;
                }
                if previous != Atom::Ordinary && previous != Atom::Group {
                    return false;
                }
                // A quantified group that already holds a quantifier or
                // alternation: the catastrophic-backtracking shape.
                if previous == Atom::Group && previous_group_complex {
                    return false;
                }
                quantifiers += 1;
                if quantifiers > MAXIMUM_QUANTIFIER_COUNT {
                    return false;
                }
                if variable {
                    variable_quantifiers += 1;
                    if variable_quantifiers > MAXIMUM_VARIABLE_QUANTIFIER_COUNT {
                        return false;
                    }
                }
                if let Some(last) = group_has_quantifier.last_mut() {
                    *last = true;
                }
                previous = Atom::Quantified;
                previous_group_complex = false;
                index = end;
                continue;
            }
            '^' | '$' => {
                previous = Atom::None;
                previous_group_complex = false;
            }
            _ => {
                previous = Atom::Ordinary;
                previous_group_complex = false;
            }
        }
        index = next;
    }
    !escaping && !in_class && group_has_quantifier.is_empty()
}

/// The end of a `{n}`, `{n,}` or `{n,m}` quantifier starting at `start`, and
/// whether it is variable-width; `None` when it is not one.
fn quantifier_end(characters: &[char], start: usize) -> Option<(usize, bool)> {
    let close = characters[start + 1..].iter().position(|&c| c == '}')? + start + 1;
    let body: String = characters[start + 1..close].iter().collect();
    let parts: Vec<&str> = body.split(',').collect();
    if parts.len() != 1 && parts.len() != 2 {
        return None;
    }
    let number = |text: &str| -> Option<u64> {
        if text.is_empty() || !text.chars().all(char::is_numeric) {
            return None;
        }
        // Swift's `Int(_:)` reads ASCII digits only.
        text.parse::<u64>().ok().filter(|n| *n <= MAXIMUM_REPEAT)
    };
    let lower = number(parts[0])?;
    let upper = match parts.get(1).copied() {
        None => Some(lower),
        Some("") => None,
        Some(text) => Some(number(text).filter(|upper| *upper >= lower)?),
    };
    Some((close + 1, upper != Some(lower)))
}
