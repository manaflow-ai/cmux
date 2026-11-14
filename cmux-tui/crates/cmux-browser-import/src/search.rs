//! Search engine rules shared by the Chromium, Firefox and Safari readers
//! (`ImportedSearchEngine` and `ChromiumSearchEngineReader.engine`/`clean` in
//! `ChromiumSearchEngineReader.swift`, `WellKnownSearchEngines.swift`).

use crate::model::SearchEngine;
use crate::url;

const SEARCH_TERMS: &str = "{searchTerms}";
const PLACEHOLDER: &str = "CMUXSEARCHTERMS";

/// The search addresses of the engines Firefox and Safari ship, which their settings name
/// without a template: the first entry whose key is in the name.
pub const WELL_KNOWN: [(&str, &str, &str); 8] = [
    ("google", "Google", "https://www.google.com/search?q={searchTerms}"),
    ("bing", "Bing", "https://www.bing.com/search?q={searchTerms}"),
    ("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q={searchTerms}"),
    ("ddg", "DuckDuckGo", "https://duckduckgo.com/?q={searchTerms}"),
    ("ecosia", "Ecosia", "https://www.ecosia.org/search?q={searchTerms}"),
    ("yahoo", "Yahoo", "https://search.yahoo.com/search?p={searchTerms}"),
    ("baidu", "Baidu", "https://www.baidu.com/s?wd={searchTerms}"),
    ("qwant", "Qwant", "https://www.qwant.com/?q={searchTerms}"),
];

/// The well-known engine one of `names` names ("google@search.mozilla.orgdefault",
/// "com.google.www").
pub fn well_known(names: &[Option<&str>]) -> Option<SearchEngine> {
    let lowered: Vec<String> =
        names.iter().flatten().map(|name| name.to_lowercase()).filter(|n| !n.is_empty()).collect();
    let (_, name, search) =
        WELL_KNOWN.iter().find(|(key, _, _)| lowered.iter().any(|name| name.contains(key)))?;
    Some(SearchEngine {
        name: (*name).to_owned(),
        keyword: None,
        search: (*search).to_owned(),
        suggest: None,
    })
}

/// A template's host, lowercased, without `www.`.
pub fn host(template: &str) -> Option<String> {
    let host = url::host(&template.replace(SEARCH_TERMS, "x").replace("%s", "x"))?;
    Some(host.strip_prefix("www.").map_or_else(|| host.clone(), str::to_owned))
}

/// What `browser.searchEngine` becomes (`ImportedSearchEngine.setting(builtIn:)`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Setting {
    pub engine: String,
    pub search: Option<String>,
    pub suggest: Option<String>,
}

/// The built-in engine whose search address has this engine's host (`built_in`: engine id and
/// its search template), else `custom` with this engine's addresses.
pub fn setting<'a>(
    engine: &SearchEngine,
    built_in: impl IntoIterator<Item = (&'a str, &'a str)>,
) -> Setting {
    if let Some(own) = host(&engine.search)
        && let Some((id, _)) =
            built_in.into_iter().find(|(_, template)| host(template).as_deref() == Some(&own))
    {
        return Setting { engine: id.to_owned(), search: None, suggest: None };
    }
    Setting {
        engine: "custom".to_owned(),
        search: Some(engine.search.clone()),
        suggest: engine.suggest.clone(),
    }
}

/// An engine from a source's fields, or `None` unless its search address is https and takes
/// the typed text. A suggest address that does not is dropped.
pub fn engine(
    name: Option<&str>,
    keyword: Option<&str>,
    search: Option<&str>,
    suggest: Option<&str>,
) -> Option<SearchEngine> {
    let usable = |template: &str| {
        template.contains(SEARCH_TERMS) && template.to_lowercase().starts_with("https://")
    };
    let search = clean(search?);
    if !usable(&search) {
        return None;
    }
    let suggest = suggest.map(clean).filter(|s| usable(s));
    let title = name
        .filter(|n| !n.is_empty())
        .map(str::to_owned)
        .or_else(|| host(&search))
        .unwrap_or_else(|| search.clone());
    Some(SearchEngine {
        name: title,
        keyword: keyword.filter(|k| !k.is_empty()).map(str::to_owned),
        search,
        suggest,
    })
}

/// Drops Chromium's own `{google:...}` parameters and any query item another placeholder
/// fills (`{inputEncoding}`), which no other browser fills in, and any item they leave empty
/// (`&t=`). A query left with no item goes, `?` included.
///
/// Kept items keep their text; Foundation's `URLComponents.queryItems` setter re-encodes them,
/// which differs only for an escape it would write another way (`%2B` stays `%2B` here).
pub fn clean(template: &str) -> String {
    let text = drop_google_parameters(template);
    let marked = text.replace(SEARCH_TERMS, PLACEHOLDER);
    let (before_fragment, fragment) = match marked.split_once('#') {
        Some((head, tail)) => (head, Some(tail)),
        None => (marked.as_str(), None),
    };
    let Some((base, query)) = before_fragment.split_once('?') else { return text };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|item| match item.split_once('=') {
            None => !item.is_empty(),
            Some((_, value)) => {
                let value = url::percent_decode(value);
                !value.is_empty() && !value.contains('{')
            }
        })
        .collect();
    let mut out = base.to_owned();
    if !kept.is_empty() {
        out.push('?');
        out.push_str(&kept.join("&"));
    }
    if let Some(fragment) = fragment {
        out.push('#');
        out.push_str(fragment);
    }
    out.replace(PLACEHOLDER, SEARCH_TERMS)
}

/// Removes every `{google:<letters>}` (the regex `\{google:[A-Za-z]+\}`).
fn drop_google_parameters(template: &str) -> String {
    const OPEN: &str = "{google:";
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find(OPEN) {
        let (head, tail) = rest.split_at_checked(start).unwrap_or((rest, ""));
        let after = tail.get(OPEN.len()..).unwrap_or_default();
        let letters = after.bytes().take_while(u8::is_ascii_alphabetic).count();
        if letters > 0 && after.as_bytes().get(letters) == Some(&b'}') {
            out.push_str(head);
            rest = after.get(letters.saturating_add(1)..).unwrap_or_default();
        } else {
            // Not a parameter: keep its `{` and look again after it.
            out.push_str(head);
            out.push('{');
            rest = tail.get(1..).unwrap_or_default();
        }
    }
    out.push_str(rest);
    out
}
