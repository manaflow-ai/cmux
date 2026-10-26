//! Token matching, match tiers, typo correction and match quality.

use crate::Entry;
use crate::text::{
    CharClass, FoldedText, Query, char_class, has_prefix, is_lu, js_trim, title_is_query,
};

pub(crate) const TITLE_WEIGHT: i64 = 100;
const KEYWORD_WEIGHT: i64 = 80;
const SUBTITLE_WEIGHT: i64 = 65;
const ACCESSORY_WEIGHT: i64 = 50;

/// Match classes, best first (plans/cmux-next/palette-ranking.md section 5). A row's class
/// decides its order before any quality, usage or bias.
pub(crate) mod match_tier {
    /// The query is one of the row's handles (`a612`, or its digits `612`).
    pub const HANDLE: i64 = 13;
    /// The whole title is the query.
    pub const WHOLE_TITLE: i64 = 12;
    /// A scope row whose keyword is the whole query.
    pub const SCOPE_KEYWORD: i64 = 11;
    /// The title starts with the query, in whole words.
    pub const TITLE_PREFIX: i64 = 10;
    /// Every token is a whole title word.
    pub const WHOLE_WORDS: i64 = 9;
    /// The title starts with the query, the last word cut.
    pub const TITLE_PARTIAL_PREFIX: i64 = 8;
    /// Every token starts a title word.
    pub const TITLE_WORDS: i64 = 7;
    /// The query is the start of the title's word initials.
    pub const ACRONYM: i64 = 6;
    /// Every token is a title substring, or starts a keyword word.
    pub const SUBSTRING: i64 = 4;
    /// Every token is one edit from a title word, or matches strictly.
    pub const TYPO: i64 = 3;
    /// Every token matches in order from a title word start, or is a keyword, subtitle or
    /// accessory substring.
    pub const FUZZY: i64 = 2;
}

/// Points per tier: above the largest quality, usage and bias sum.
pub(crate) const TIER_SCALE: i64 = 1_000;
pub(crate) const MAXIMUM_QUALITY: i64 = 880;
/// A demoted row (a setting) drops this many tier units.
pub(crate) const DEMOTION: i64 = 3;

pub(crate) struct Field {
    pub text: FoldedText,
    pub weight: i64,
}

pub(crate) fn fields_for(entry: &Entry) -> Vec<Field> {
    let mut fields = vec![Field { text: FoldedText::new(&entry.title), weight: TITLE_WEIGHT }];
    if !entry.keywords.is_empty() {
        fields.push(Field {
            text: FoldedText::new(&entry.keywords.join(" ")),
            weight: KEYWORD_WEIGHT,
        });
    }
    if let Some(subtitle) = entry.subtitle.as_deref().filter(|text| !text.is_empty()) {
        fields.push(Field { text: FoldedText::new(subtitle), weight: SUBTITLE_WEIGHT });
    }
    if let Some(accessory) = entry.accessory.as_deref().filter(|text| !text.is_empty()) {
        fields.push(Field { text: FoldedText::new(accessory), weight: ACCESSORY_WEIGHT });
    }
    fields
}

struct TokenMatch {
    score: i64,
    start: usize,
    end: usize,
}

fn substring_start(
    needle: &[char],
    folded: &[char],
    bonuses: &[i64],
    require_boundary: bool,
) -> Option<usize> {
    if needle.is_empty() || needle.len() > folded.len() {
        return None;
    }
    (0..=folded.len() - needle.len()).find(|&start| {
        (!require_boundary || bonuses[start] >= 7) && folded[start..start + needle.len()] == *needle
    })
}

fn window_score(token: &[char], folded: &[char], bonuses: &[i64], start: usize, end: usize) -> i64 {
    let mut score = 0;
    let mut token_index = 0;
    let mut previous_match: i64 = -2;
    let mut run_bonus = 0;
    let mut index = start;
    while index <= end && token_index < token.len() {
        if folded[index] == token[token_index] {
            let mut bonus = bonuses[index];
            if index as i64 == previous_match + 1 {
                bonus = bonus.max(run_bonus);
                score += 5;
            } else {
                run_bonus = bonus;
            }
            if token_index == 0 {
                bonus *= 2;
            }
            score += 16 + bonus;
            previous_match = index as i64;
            token_index += 1;
        } else {
            score -= if index as i64 == previous_match + 1 { 3 } else { 1 };
        }
        index += 1;
    }
    score - start.min(12) as i64
}

fn forward_window_end(token: &[char], folded: &[char], start: usize) -> Option<usize> {
    let mut token_index = 0;
    for (index, &scalar) in folded.iter().enumerate().skip(start) {
        if scalar == token[token_index] {
            token_index += 1;
            if token_index == token.len() {
                return Some(index);
            }
        }
    }
    None
}

fn token_score(token: &[char], text: &FoldedText) -> Option<TokenMatch> {
    if token.is_empty() {
        return Some(TokenMatch { score: 0, start: 0, end: 0 });
    }
    if token.len() > text.folded.len() {
        return None;
    }
    if let Some(start) = substring_start(token, &text.folded, &text.bonus, true) {
        let end = start + token.len() - 1;
        return Some(TokenMatch {
            score: window_score(token, &text.folded, &text.bonus, start, end),
            start,
            end,
        });
    }
    let end = forward_window_end(token, &text.folded, 0)?;
    let mut token_index = token.len() - 1;
    let mut start = end;
    for index in (0..=end).rev() {
        if text.folded[index] == token[token_index] {
            if token_index == 0 {
                start = index;
                break;
            }
            token_index -= 1;
        }
    }
    let mut end = end;
    let mut best = window_score(token, &text.folded, &text.bonus, start, end);
    if text.bonus[start] < 9 {
        let first = token[0];
        if let Some(index) = (0..text.folded.len())
            .find(|&index| text.folded[index] == first && text.bonus[index] >= 7 && index != start)
            && let Some(alternate_end) = forward_window_end(token, &text.folded, index)
        {
            let alternate = window_score(token, &text.folded, &text.bonus, index, alternate_end);
            if alternate > best {
                best = alternate;
                start = index;
                end = alternate_end;
            }
        }
    }
    Some(TokenMatch { score: best, start, end })
}

fn phrase_bonus(query: &Query, text: &FoldedText) -> i64 {
    if query.phrase.is_empty() || query.phrase.len() > text.folded.len() {
        return 0;
    }
    if has_prefix(&text.folded, &query.phrase) {
        return if query.phrase.len() == text.folded.len() { 220 } else { 90 };
    }
    if query.joined.len() >= 2 && has_prefix(&text.initials, &query.joined) {
        return 70;
    }
    if query.phrase.len() >= 2
        && substring_start(&query.phrase, &text.folded, &text.bonus, true).is_some()
    {
        return 30;
    }
    0
}

/// How well one token matches one field: 3 starts a word, 2 contiguous, 1 in order from a word
/// start, 0 none.
fn token_level(token: &[char], token_mask: u64, text: &FoldedText) -> u8 {
    if token.is_empty() {
        return 3;
    }
    if text.mask & token_mask != token_mask {
        return 0;
    }
    if substring_start(token, &text.folded, &text.bonus, true).is_some() {
        return 3;
    }
    if substring_start(token, &text.folded, &text.bonus, false).is_some() {
        return 2;
    }
    let from_word_start = (0..text.folded.len()).any(|index| {
        text.folded[index] == token[0]
            && text.bonus[index] >= 7
            && forward_window_end(token, &text.folded, index).is_some()
    });
    u8::from(from_word_start)
}

/// The tier one token reaches through its best field; -1 when no field matches.
fn token_tier(token: &[char], token_mask: u64, fields: &[Field]) -> i64 {
    let mut best = -1;
    for field in fields {
        let level = token_level(token, token_mask, &field.text);
        if level == 0 {
            continue;
        }
        let reached = if field.weight == TITLE_WEIGHT {
            if level >= 2 { match_tier::SUBSTRING } else { match_tier::FUZZY }
        } else if field.weight == KEYWORD_WEIGHT {
            match level {
                3 => match_tier::SUBSTRING,
                2 => match_tier::FUZZY,
                _ => -1,
            }
        } else if level >= 2 {
            match_tier::FUZZY
        } else {
            -1
        };
        best = best.max(reached);
    }
    best
}

/// At most one insert, delete, substitute or adjacent swap turns `a` into `b`.
fn within_one_edit(a: &[char], b: &[char]) -> bool {
    if a.len().abs_diff(b.len()) > 1 {
        return false;
    }
    let mut i = 0;
    while i < a.len() && i < b.len() && a[i] == b[i] {
        i += 1;
    }
    if i == a.len() && i == b.len() {
        return true;
    }
    let rest_equal = |x: usize, y: usize| {
        if a.len() as i64 - x as i64 != b.len() as i64 - y as i64 {
            return false;
        }
        a.get(x..).unwrap_or_default() == b.get(y..).unwrap_or_default()
    };
    if a.len() == b.len() {
        if rest_equal(i + 1, i + 1) {
            return true;
        }
        return i + 1 < a.len() && a[i] == b[i + 1] && a[i + 1] == b[i] && rest_equal(i + 2, i + 2);
    }
    if a.len() > b.len() { rest_equal(i + 1, i) } else { rest_equal(i, i + 1) }
}

/// One adjacent swap and nothing else.
fn is_transposition(a: &[char], b: &[char]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let diff: Vec<usize> = (0..a.len()).filter(|&i| a[i] != b[i]).collect();
    diff.len() == 2
        && diff[1] == diff[0] + 1
        && a[diff[0]] == b[diff[1]]
        && a[diff[1]] == b[diff[0]]
}

/// The query with each mistyped token replaced by the title word it is one edit from.
fn typo_correction(query: &Query, title: &FoldedText) -> Option<Query> {
    let words = title.words();
    let mut typos = 0;
    let mut corrected: Vec<String> = Vec::with_capacity(query.tokens.len());
    for (token_index, token) in query.tokens.iter().enumerate() {
        if token_level(token, query.token_masks[token_index], title) >= 2 {
            corrected.push(token.iter().collect());
            continue;
        }
        if token.len() < 3 {
            return None;
        }
        let close = words.iter().find(|word| {
            if word.len() + 1 < token.len() {
                return false;
            }
            let head = |n: usize| &word[..n.min(word.len())];
            if token.len() == 3 {
                return is_transposition(token, head(3));
            }
            within_one_edit(token, word)
                || within_one_edit(token, head(token.len()))
                || within_one_edit(token, head(token.len() + 1))
        })?;
        corrected.push(close.iter().collect());
        typos += 1;
    }
    (typos > 0).then(|| Query::new(&corrected.join(" ")))
}

fn is_whole_word(token: &[char], text: &FoldedText) -> bool {
    text.words().iter().any(|word| word.as_slice() == token)
}

fn starts_with_whole_words(query: &Query, text: &FoldedText) -> bool {
    if !has_prefix(&text.folded, &query.phrase) {
        return false;
    }
    match text.original.get(query.phrase.len()) {
        None => true,
        Some(&next) => {
            char_class(next) == CharClass::Delimiter || text.bonus[query.phrase.len()] >= 7
        }
    }
}

/// A one-word query that names the action id: the whole id, or a start of it written like an id.
fn action_id_tier(id: Option<&[char]>, query: &Query) -> Option<i64> {
    let id = id?;
    if query.tokens.len() != 1 || query.joined.len() < 4 || !has_prefix(id, &query.joined) {
        return None;
    }
    if id.len() == query.joined.len() {
        return Some(match_tier::TITLE_PREFIX);
    }
    let raw = js_trim(&query.raw);
    (raw.contains('.') || raw.chars().any(is_lu)).then_some(match_tier::SUBSTRING)
}

/// A tier and the query its quality is measured with (a typo row: the corrected one).
pub(crate) struct TierMatch<'q> {
    pub tier: i64,
    pub query: QueryRef<'q>,
}

/// The original query or an owned corrected one.
pub(crate) enum QueryRef<'q> {
    Original(&'q Query),
    Corrected(Query),
}

impl QueryRef<'_> {
    pub(crate) fn get(&self) -> &Query {
        match self {
            QueryRef::Original(query) => query,
            QueryRef::Corrected(query) => query,
        }
    }
}

fn text_tier<'q>(
    entry: &Entry,
    query: &'q Query,
    fields: &[Field],
    allows_typo: bool,
) -> Option<TierMatch<'q>> {
    let title = &fields[0].text;
    let tiered = |tier: i64| Some(TierMatch { tier, query: QueryRef::Original(query) });
    let title_has_letters = title.mask & query.mask == query.mask;
    if title_has_letters && title_is_query(&entry.title, &query.raw) {
        return tiered(match_tier::WHOLE_TITLE);
    }
    if entry.enters_scope == Some(true)
        && entry.keywords.iter().any(|keyword| title_is_query(keyword, &query.raw))
    {
        return tiered(match_tier::SCOPE_KEYWORD);
    }
    if title_has_letters {
        if starts_with_whole_words(query, title) {
            return tiered(match_tier::TITLE_PREFIX);
        }
        if query.tokens.iter().all(|token| is_whole_word(token, title)) {
            return tiered(match_tier::WHOLE_WORDS);
        }
        if has_prefix(&title.folded, &query.phrase) {
            return tiered(match_tier::TITLE_PARTIAL_PREFIX);
        }
        if query
            .tokens
            .iter()
            .zip(&query.token_masks)
            .all(|(token, &mask)| token_level(token, mask, title) == 3)
        {
            return tiered(match_tier::TITLE_WORDS);
        }
    }
    if query.tokens.len() == 1
        && query.joined.len() >= 2
        && has_prefix(&title.initials, &query.joined)
    {
        return tiered(match_tier::ACRONYM);
    }
    let mut reached_tier = match_tier::SUBSTRING;
    for (token, &mask) in query.tokens.iter().zip(&query.token_masks) {
        let reached = token_tier(token, mask, fields);
        if reached < 0 {
            reached_tier = -1;
            break;
        }
        reached_tier = reached_tier.min(reached);
    }
    if allows_typo
        && reached_tier < match_tier::TYPO
        && let Some(corrected) = typo_correction(query, title)
    {
        return Some(TierMatch { tier: match_tier::TYPO, query: QueryRef::Corrected(corrected) });
    }
    if reached_tier < 0 { None } else { tiered(reached_tier) }
}

/// The row's tier: its text, or its action id when that is better; a demoted row 3 units lower.
pub(crate) fn entry_tier<'q>(
    entry: &Entry,
    id: Option<&[char]>,
    query: &'q Query,
    fields: &[Field],
    allows_typo: bool,
) -> Option<TierMatch<'q>> {
    let mut found = text_tier(entry, query, fields, allows_typo);
    if let Some(by_id) = action_id_tier(id, query)
        && found.as_ref().is_none_or(|current| by_id > current.tier)
    {
        found = Some(TierMatch { tier: by_id, query: QueryRef::Original(query) });
    }
    if entry.demoted == Some(true)
        && let Some(current) = found.as_mut()
    {
        current.tier -= DEMOTION;
    }
    found
}

pub(crate) fn highlights_for(query: &Query, title: &FoldedText) -> Vec<usize> {
    if let Some(phrase_start) = substring_start(&query.phrase, &title.folded, &title.bonus, false) {
        return (phrase_start..phrase_start + query.phrase.len())
            .filter(|&index| title.folded[index] != ' ')
            .collect();
    }
    let mut positions = std::collections::BTreeSet::new();
    for token in &query.tokens {
        let Some(found) = token_score(token, title) else { continue };
        let mut matched = 0;
        let mut index = found.start;
        while index <= found.end && matched < token.len() {
            if title.folded[index] == token[matched] {
                positions.insert(index);
                matched += 1;
            }
            index += 1;
        }
    }
    positions.into_iter().collect()
}

/// The match quality inside a tier.
pub(crate) fn match_quality(query: &Query, fields: &[Field]) -> i64 {
    let mut total = 0;
    for (token, &token_mask) in query.tokens.iter().zip(&query.token_masks) {
        let mut best = 0;
        for field in fields {
            if field.text.mask & token_mask != token_mask {
                continue;
            }
            if let Some(found) = token_score(token, &field.text) {
                best = best.max(found.score * field.weight / 100);
            }
        }
        total += best;
    }
    let mut bonus = 0;
    for field in fields {
        if field.text.mask & query.mask == query.mask {
            bonus = bonus.max(phrase_bonus(query, &field.text) * field.weight / 100);
        }
    }
    let title = &fields[0].text;
    let initials_bonus = if query.joined.len() >= 2
        && title.initials.len() == query.joined.len()
        && has_prefix(&title.initials, &query.joined)
    {
        40
    } else {
        0
    };
    let quality = total + bonus + initials_bonus - (title.folded.len() / 6) as i64;
    quality.clamp(0, MAXIMUM_QUALITY)
}
