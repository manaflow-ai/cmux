//! `difflib.get_close_matches` and `shlex.join`, as the Python layer uses them, so both languages
//! pick the same close word and print the same command.

/// The Ratcliff/Obershelp matching characters of `a` and `b` (difflib's `SequenceMatcher`, no junk).
fn matching(a: &[char], b: &[char]) -> usize {
    if a.is_empty() || b.is_empty() {
        return 0;
    }
    // The longest common block: earliest in `a`, then earliest in `b` (difflib's tie-break).
    let (mut best_i, mut best_j, mut best_k) = (0, 0, 0);
    let mut prev = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![0usize; b.len() + 1];
        for (j, cb) in b.iter().enumerate() {
            if ca == cb {
                let k = prev.get(j).copied().unwrap_or(0) + 1;
                if let Some(slot) = cur.get_mut(j + 1) {
                    *slot = k;
                }
                if k > best_k {
                    (best_i, best_j, best_k) = (i + 1 - k, j + 1 - k, k);
                }
            }
        }
        prev = cur;
    }
    if best_k == 0 {
        return 0;
    }
    best_k
        + matching(a.get(..best_i).unwrap_or_default(), b.get(..best_j).unwrap_or_default())
        + matching(
            a.get(best_i + best_k..).unwrap_or_default(),
            b.get(best_j + best_k..).unwrap_or_default(),
        )
}

/// difflib's `ratio()`: 2 * matches / total length.
pub fn ratio(a: &str, b: &str) -> f64 {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let total = a.len() + b.len();
    if total == 0 {
        return 1.0;
    }
    #[allow(clippy::cast_precision_loss, reason = "word lengths")]
    {
        2.0 * matching(&a, &b) as f64 / total as f64
    }
}

/// `difflib.get_close_matches(word, known, n, cutoff)`: the best first, ties by the larger string.
pub fn close_matches<S: AsRef<str>>(word: &str, known: &[S], n: usize, cutoff: f64) -> Vec<String> {
    let mut scored: Vec<(f64, String)> = known
        .iter()
        .map(|k| (ratio(k.as_ref(), word), k.as_ref().to_owned()))
        .filter(|(score, _)| *score >= cutoff)
        .collect();
    scored.sort_by(|x, y| y.0.total_cmp(&x.0).then_with(|| y.1.cmp(&x.1)));
    scored.into_iter().take(n).map(|(_, k)| k).collect()
}

/// `shlex.join`: each word quoted for a POSIX shell only when it needs it.
pub fn shell_join<S: AsRef<str>>(words: &[S]) -> String {
    words.iter().map(|w| quote(w.as_ref())).collect::<Vec<_>>().join(" ")
}

fn quote(word: &str) -> String {
    let plain = |c: char| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c);
    if !word.is_empty() && word.chars().all(plain) {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
#[path = "close_tests.rs"]
mod tests;
