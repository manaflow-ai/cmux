/// Search rank for one action. Exact stable-ID/title matches win, followed by
/// title prefix, word prefix, and ordered subsequence. Every query token must
/// match. Larger values rank first.
pub(crate) fn search_score(query: &str, title: &str, id: &str, focus_rank: u16) -> Option<u32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Some(focus_rank as u32);
    }
    let title = title.to_lowercase();
    let id = id.to_lowercase();
    if query == title || query == id {
        return Some(50_000 + focus_rank as u32);
    }
    let mut score = focus_rank as u32;
    for token in query.split_whitespace() {
        let token_score = if title.starts_with(token) || id.starts_with(token) {
            8_000
        } else if title.split(|ch: char| !ch.is_alphanumeric()).any(|word| word.starts_with(token))
            || id.split(['.', '-', '_']).any(|word| word.starts_with(token))
        {
            5_000
        } else if title.contains(token) || id.contains(token) {
            3_000
        } else if is_subsequence(token, &title) || is_subsequence(token, &id) {
            1_000
        } else {
            return None;
        };
        score += token_score;
    }
    Some(score)
}

fn is_subsequence(needle: &str, haystack: &str) -> bool {
    let mut needle = needle.chars();
    let Some(mut next) = needle.next() else { return true };
    for character in haystack.chars() {
        if character == next {
            let Some(character) = needle.next() else { return true };
            next = character;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::search_score;

    #[test]
    fn exact_prefix_word_and_subsequence_matches_have_stable_precedence() {
        let exact = search_score("new tab", "New tab", "cmux.new-tab", 0).unwrap();
        let prefix = search_score("new", "New tab", "cmux.new-tab", 0).unwrap();
        let word = search_score("tab", "New tab", "cmux.new-tab", 0).unwrap();
        let subsequence = search_score("ntb", "New tab", "cmux.new-tab", 0).unwrap();
        assert!(exact > prefix && prefix > word && word > subsequence);
        assert_eq!(search_score("browser", "New tab", "cmux.new-tab", 0), None);
    }
}
