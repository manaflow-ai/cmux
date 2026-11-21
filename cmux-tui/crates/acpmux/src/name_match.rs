//! The one rule for a session or machine name someone typed (Leo, 2026-11-05, on `td2-a` failing
//! for the session `td2-A`: "stuff like that should work better yes"). A key names a name at the
//! first of four steps it reaches: exactly; in any case; as the start of the name, in any case;
//! ignoring case and the separators `-`, `_` and space. A caller takes the first step with any
//! match, and only its one match: several at that step are refused with each of them, never
//! guessed. `hub/key_route.rs` applies it to `NAME` and `HOST/NAME` keys on every session
//! command, and to `--host`; leo-workspace's `tools/name_match.py` is the same rule for the
//! fleet tools (`reach`, `sessions new --machine`, `leo-forward --to`, `wt`).

/// How a key names a name, in the order the steps are tried.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Step {
    Exact,
    Case,
    Prefix,
    Separators,
}

/// The first step at which `key` names `name`, or None when it names it at none.
pub fn step(name: &str, key: &str) -> Option<Step> {
    if key.is_empty() {
        None
    } else if name == key {
        Some(Step::Exact)
    } else if name.eq_ignore_ascii_case(key) {
        Some(Step::Case)
    } else if name.len() > key.len()
        && name
            .as_bytes()
            .get(..key.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(key.as_bytes()))
    {
        Some(Step::Prefix)
    } else if folded(key).next().is_some() && folded(name).eq(folded(key)) {
        Some(Step::Separators)
    } else {
        None
    }
}

/// The step at which `key` names a sub-session `name` (`PARENT/SHORT`) by its last segments:
/// `td2-a` and `td2_a` name `coord/td2-A`. Never by a prefix of them (a short key would reach
/// any child), and never a name with no more segments than `key`.
pub fn short_step(name: &str, key: &str) -> Option<Step> {
    let segments = key.split('/').count();
    let cut =
        name.char_indices().filter(|(_, c)| *c == '/').map(|(i, _)| i).rev().nth(segments - 1)?;
    step(name.get(cut + 1..)?, key).filter(|at| *at != Step::Prefix)
}

/// `text` in lowercase without `-`, `_` or spaces: `td2-A`, `td2_a` and `TD2 a` all read `td2a`.
/// An iterator, so a lookup over every session allocates nothing.
fn folded(text: &str) -> impl Iterator<Item = char> + '_ {
    text.chars().filter(|c| !matches!(c, '-' | '_' | ' ')).map(|c| c.to_ascii_lowercase())
}

/// The names of `items` that `key` names at its first step with any match: `Ok(Some)` for one,
/// `Ok(None)` for none, `Err` with every match of that step when there are several.
pub fn pick<T>(
    items: impl IntoIterator<Item = T>,
    key: &str,
    name_of: impl Fn(&T) -> &str,
) -> Result<Option<T>, Vec<T>> {
    let mut best: Option<(Step, Vec<T>)> = None;
    for item in items {
        let Some(at) = step(name_of(&item), key) else { continue };
        match &mut best {
            Some((step, found)) if *step == at => found.push(item),
            Some((step, _)) if *step < at => {}
            _ => best = Some((at, vec![item])),
        }
    }
    match best {
        None => Ok(None),
        Some((_, mut found)) if found.len() == 1 => Ok(found.pop()),
        Some((_, found)) => Err(found),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names<'a>(key: &str, all: &[&'a str]) -> Result<Option<&'a str>, Vec<&'a str>> {
        pick(all.iter().copied(), key, |n| n)
    }

    #[test]
    fn a_key_in_another_case_names_the_one_session_with_that_name() {
        assert_eq!(names("td2-a", &["td2-A", "td2-B"]), Ok(Some("td2-A")));
    }

    #[test]
    fn a_prefix_several_names_share_is_refused_with_every_one() {
        let all = ["td2-A", "td2-B", "td2-C", "td2-D", "other"];
        assert_eq!(names("td2", &all), Err(vec!["td2-A", "td2-B", "td2-C", "td2-D"]));
        assert_eq!(names("TD2-c", &all), Ok(Some("td2-C")));
        assert_eq!(names("oth", &all), Ok(Some("other")));
    }

    #[test]
    fn an_exact_name_wins_over_one_in_another_case() {
        assert_eq!(names("td2-a", &["td2-A", "td2-a"]), Ok(Some("td2-a")));
        // Two that differ only in case tie for a third spelling.
        assert_eq!(names("TD2-a", &["td2-A", "td2-a"]), Err(vec!["td2-A", "td2-a"]));
        // A whole name in another case wins over a longer name it starts.
        assert_eq!(names("review", &["Review", "review-2"]), Ok(Some("Review")));
    }

    #[test]
    fn a_short_name_is_read_by_the_same_steps_but_never_as_a_prefix() {
        assert_eq!(short_step("coord/td2-A", "td2-a"), Some(Step::Case));
        assert_eq!(short_step("coord/td2-A", "td2_a"), Some(Step::Separators));
        assert_eq!(short_step("a/coord/td2-A", "COORD/td2-a"), Some(Step::Case));
        assert_eq!(short_step("coord/td2-A", "td2"), None);
        assert_eq!(short_step("td2-A", "td2-a"), None);
    }

    #[test]
    fn separators_and_case_are_ignored_last() {
        assert_eq!(names("td2_a", &["td2-A", "td2-B"]), Ok(Some("td2-A")));
        assert_eq!(names("td2 a", &["td2-A"]), Ok(Some("td2-A")));
        assert_eq!(names("td2a", &["td2-A"]), Ok(Some("td2-A")));
        assert_eq!(names("ab", &["a-b", "a_b"]), Err(vec!["a-b", "a_b"]));
        assert_eq!(names("-", &["a-b"]), Ok(None));
        assert_eq!(names("", &["a"]), Ok(None));
    }
}
