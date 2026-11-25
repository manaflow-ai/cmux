//! Text search and omnibar ranking over one profile's bookmarks
//! (plans/cmux-next/bookmarks.md section 5), and the URL rules they use:
//! what counts as the same page and how a URL reads in a list.
//!
//! [`search`] is the manager page's and `cmux bookmark list --search`'s
//! filter: every term in the title or the URL, folders by title, tree
//! order. [`rank`] is the omnibar's and the palette's: every term must
//! start a word of the title, start the host or appear in the URL, and the
//! best-named bookmark of a page wins.

use std::collections::HashMap;

use unicode_normalization::UnicodeNormalization as _;

use cmux_bookmarks_core::{Bookmark, Tree};

/// Bonus over an equal history match: a bookmarked page ranks like a
/// typed one (scores stay below the typed row's 1000).
pub const BOOKMARK_BONUS: f64 = 150.0;
/// Highest score a bookmark gets.
pub const MAX_SCORE: f64 = 999.0;

/// Case, diacritic and width folded text: NFKD, combining marks dropped,
/// lowercased.
pub fn fold(text: &str) -> String {
    text.nfkd()
        .filter(|character| !unicode_normalization::char::is_combining_mark(*character))
        .flat_map(char::to_lowercase)
        .collect()
}

/// Most terms a query uses; the rest are ignored (each term is matched
/// against every node).
pub const MAX_TERMS: usize = 32;

/// The folded terms of `text`, split at white space, at most
/// [`MAX_TERMS`].
pub fn tokens(text: &str) -> Vec<String> {
    fold(text).split_whitespace().take(MAX_TERMS).map(str::to_string).collect()
}

/// Nodes whose title or URL holds every term of `text`, in tree order
/// (folders match by title). No terms, no results.
pub fn search(tree: &Tree, text: &str) -> Vec<Bookmark> {
    let terms = tokens(text);
    if terms.is_empty() {
        return Vec::new();
    }
    tree.listing()
        .into_iter()
        .filter(|node| {
            let mut haystack = fold(&node.title);
            if let Some(url) = &node.url {
                haystack.push(' ');
                haystack.push_str(&fold(url));
            }
            terms.iter().all(|term| haystack.contains(term.as_str()))
        })
        .collect()
}

/// One ranked bookmark.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Ranked {
    pub bookmark: Bookmark,
    pub score: f64,
}

/// The score of URL bookmark `node` for `text`, or `None` when a term
/// matches nothing (or `node` is a folder).
pub fn score(node: &Bookmark, text: &str, now_ms: u64) -> Option<f64> {
    score_terms(node, &tokens(text), now_ms)
}

/// [`score`] with `text` already split into [`tokens`].
fn score_terms(node: &Bookmark, terms: &[String], now_ms: u64) -> Option<f64> {
    let url = node.url.as_deref()?;
    if terms.is_empty() {
        return None;
    }
    let title = fold(&node.title);
    let words = title.split(|c: char| !c.is_alphanumeric()).filter(|word| !word.is_empty());
    let words = words.collect::<Vec<_>>();
    let url_text = fold(&display_text(url));
    let host = stripped_host(url);
    let mut matched = 0.0;
    let mut covered = 0usize;
    for (index, term) in terms.iter().enumerate() {
        if index == 0 && !host.is_empty() && host.starts_with(term.as_str()) {
            matched += 600.0;
        } else if let Some(word) = words.iter().find(|word| word.starts_with(term.as_str())) {
            matched += 450.0;
            covered += term.chars().count().min(word.chars().count());
        } else if url_text.contains(term.as_str()) {
            matched += 300.0;
        } else {
            return None;
        }
    }
    matched /= terms.len() as f64;
    let title_length = title.chars().count();
    let coverage = if title_length == 0 { 0.0 } else { covered as f64 / title_length as f64 };
    let recency = node.last_used_ms.map_or(0.0, |used| {
        let days = now_ms.saturating_sub(used) as f64 / 86_400_000.0;
        100.0 * (-days / 14.0).exp()
    });
    let brevity = (40.0 - url_text.chars().count() as f64 / 4.0).max(0.0);
    Some((matched + 100.0 * coverage + recency + brevity + BOOKMARK_BONUS).min(MAX_SCORE))
}

/// The best `limit` URL bookmarks for `text`, highest first, one per page
/// ([`url_key`]): the best-scored bookmark of a URL wins, then the title.
pub fn rank<'a>(
    bookmarks: impl IntoIterator<Item = &'a Bookmark>,
    text: &str,
    now_ms: u64,
    limit: usize,
) -> Vec<Ranked> {
    let terms = tokens(text);
    let mut best = HashMap::<String, Ranked>::new();
    for node in bookmarks {
        let (Some(url), Some(score)) = (node.url.as_deref(), score_terms(node, &terms, now_ms))
        else {
            continue;
        };
        let key = url_key(url);
        if best.get(&key).is_some_and(|existing| existing.score >= score) {
            continue;
        }
        best.insert(key, Ranked { bookmark: node.clone(), score });
    }
    let mut ranked = best.into_values().collect::<Vec<_>>();
    ranked.sort_by(|a, b| {
        b.score.total_cmp(&a.score).then_with(|| a.bookmark.title.cmp(&b.bookmark.title))
    });
    ranked.truncate(limit);
    ranked
}

// MARK: URLs

/// The parts of an absolute URL this module reads: the scheme, the
/// authority (empty without `//`) and the rest.
fn split_url(url: &str) -> Option<(&str, Option<&str>, &str)> {
    let (scheme, rest) = url.split_once(':')?;
    let Some(after) = rest.strip_prefix("//") else { return Some((scheme, None, rest)) };
    let end = after.find(['/', '?', '#']).unwrap_or(after.len());
    let (authority, tail) = after.split_at(end);
    Some((scheme, Some(authority), tail))
}

/// The host of an authority (`user@host:port`), without user or port.
fn host_of(authority: &str) -> &str {
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    if host.starts_with('[') {
        return host.find(']').and_then(|end| host.get(..=end)).unwrap_or(host);
    }
    host.split_once(':').map_or(host, |(host, _)| host)
}

/// The same-page key: scheme and host lowercased, an empty path is `/`;
/// queries and fragments count.
pub fn url_key(url: &str) -> String {
    let Some((scheme, authority, tail)) = split_url(url) else { return url.to_string() };
    let scheme = scheme.to_ascii_lowercase();
    let Some(authority) = authority else { return format!("{scheme}:{tail}") };
    let host = host_of(authority);
    // Only the host component is lowercased; user info and port keep their case.
    let (userinfo, host_port) = match authority.rsplit_once('@') {
        Some((userinfo, host_port)) => (Some(userinfo), host_port),
        None => (None, authority),
    };
    let port = host_port.get(host.len()..).unwrap_or_default();
    let lowered = match userinfo {
        Some(userinfo) => format!("{userinfo}@{}{port}", host.to_lowercase()),
        None => format!("{}{port}", host.to_lowercase()),
    };
    let tail = if tail.is_empty() || tail.starts_with(['?', '#']) && !host.is_empty() {
        format!("/{tail}")
    } else {
        tail.to_string()
    };
    format!("{scheme}://{lowered}{tail}")
}

/// The origin (`scheme://host[:port]`), the favicon cache key; `None`
/// without a host.
pub fn favicon_key(url: &str) -> Option<String> {
    let (scheme, authority, _) = split_url(url)?;
    let authority = authority?;
    let host = host_of(authority).to_lowercase();
    if host.is_empty() {
        return None;
    }
    let after_user = authority.rsplit_once('@').map_or(authority, |(_, rest)| rest);
    let port = after_user
        .strip_prefix(host_of(authority))
        .and_then(|rest| rest.strip_prefix(':'))
        .filter(|port| !port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()));
    let scheme = scheme.to_ascii_lowercase();
    Some(match port {
        Some(port) => format!("{scheme}://{host}:{port}"),
        None => format!("{scheme}://{host}"),
    })
}

/// `github.com/foo` for `https://github.com/foo`: http(s) and `www.`
/// dropped, and a lone trailing `/`; other schemes stay whole.
pub fn display_text(url: &str) -> String {
    for prefix in ["https://", "http://"] {
        if url.len() >= prefix.len() && url.is_char_boundary(prefix.len()) {
            let (head, rest) = url.split_at(prefix.len());
            if head.eq_ignore_ascii_case(prefix) {
                let rest = match rest.get(..4) {
                    Some(www) if www.eq_ignore_ascii_case("www.") => rest.get(4..).unwrap_or(""),
                    _ => rest,
                };
                let trimmed = rest.strip_suffix('/').filter(|head| !head.contains('/'));
                return trimmed.unwrap_or(rest).to_string();
            }
        }
    }
    url.to_string()
}

/// The host, lowercased, without `www.`.
fn stripped_host(url: &str) -> String {
    let host = split_url(url).and_then(|(_, authority, _)| authority).map(host_of);
    let host = host.unwrap_or("").to_lowercase();
    host.strip_prefix("www.").map_or(host.clone(), str::to_string)
}

/// The URL a person typed in an edit field, else `None`. Text without a
/// scheme gets `https://` (`example.com`); `localhost:3000` gets `http://`.
pub fn parse_typed(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.contains(char::is_whitespace) {
        return None;
    }
    if let Some((scheme, rest)) = trimmed.split_once(':') {
        let is_port = rest.starts_with(|c: char| c.is_ascii_digit()) && !rest.starts_with("//");
        if is_port {
            return Some(format!("http://{trimmed}"));
        }
        let scheme_ok = !scheme.is_empty()
            && scheme.chars().all(|c| c.is_alphanumeric() || matches!(c, '+' | '-' | '.'));
        if scheme_ok && cmux_bookmarks_core::validate_url(trimmed).is_ok() {
            return Some(trimmed.to_string());
        }
    }
    if !(trimmed.contains('.') || trimmed.starts_with("localhost")) {
        return None;
    }
    let url = format!("https://{trimmed}");
    cmux_bookmarks_core::validate_url(&url).ok().map(|()| url)
}
