//! The servers cmux knows by name (`registry.json`, probed live; see its
//! `probed` line). A registry hit is the only way a card shows "Verified".

use serde::Deserialize;

/// How a server signs in.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AuthKind {
    /// No sign-in.
    None,
    /// OAuth 2.1 authorization code with PKCE, client from DCR or metadata.
    Oauth,
    /// OAuth 2.0 device code (RFC 8628) with the entry's public `client_id`.
    Device,
    /// A key the person types into the card's private field.
    Key,
}

/// One known server.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    pub title: String,
    /// The registrable domain the card shows as "By".
    pub publisher: String,
    pub url: String,
    pub auth: AuthKind,
    /// The least scopes asked by default; empty means what the server's
    /// metadata names as its default.
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default)]
    pub client_id: Option<String>,
    /// The header a key goes in (`auth: key`).
    #[serde(default)]
    pub key_header: Option<String>,
    /// The server also works without a key.
    #[serde(default)]
    pub key_optional: bool,
    #[serde(default)]
    pub docs: Option<String>,
}

#[derive(Deserialize)]
struct File {
    servers: Vec<Entry>,
}

/// The known servers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Registry {
    pub entries: Vec<Entry>,
}

/// Lower case, with spaces, `-`, `_` and `.` dropped: "Hugging Face",
/// "hugging-face" and "huggingface" are one key.
fn key(s: &str) -> String {
    s.trim()
        .chars()
        .filter(|c| !matches!(c, ' ' | '-' | '_' | '.'))
        .flat_map(char::to_lowercase)
        .collect()
}

impl Registry {
    /// The registry shipped in this build.
    pub fn builtin() -> Self {
        Self::parse(include_str!("registry.json")).unwrap_or_default()
    }

    /// Parses a registry file.
    pub fn parse(text: &str) -> Result<Self, String> {
        let file: File = serde_json::from_str(text).map_err(|e| e.to_string())?;
        Ok(Self { entries: file.servers })
    }

    /// The entry a name or alias names (case, spaces and punctuation
    /// ignored), or the entry whose URL is exactly `text`.
    pub fn find(&self, text: &str) -> Option<&Entry> {
        let k = key(text);
        if k.is_empty() {
            return None;
        }
        self.entries.iter().find(|e| {
            normalize(&e.url).is_some_and(|u| Some(u) == normalize(text))
                || key(&e.name) == k
                || key(&e.title) == k
                || e.aliases.iter().any(|a| key(a) == k)
        })
    }

    /// The entry whose URL is exactly this one (the only "Verified" match
    /// for a URL input).
    pub fn by_url(&self, url: &str) -> Option<&Entry> {
        let want = normalize(url)?;
        self.entries.iter().find(|e| normalize(&e.url).as_deref() == Some(want.as_str()))
    }

    /// Up to three names close to `text`, for an unknown input.
    pub fn near(&self, text: &str) -> Vec<String> {
        let k = key(text);
        let mut scored: Vec<(usize, &str)> = self
            .entries
            .iter()
            .map(|e| (distance(&k, &key(&e.name)), e.name.as_str()))
            .filter(|(d, name)| *d <= 2.max(name.len() / 3))
            .collect();
        scored.sort();
        scored.into_iter().take(3).map(|(_, n)| n.to_owned()).collect()
    }
}

/// A URL as the parser writes it (`https://a.com` and `https://a.com/` are one).
fn normalize(url: &str) -> Option<String> {
    url::Url::parse(url.trim()).ok().map(|u| u.to_string())
}

/// Levenshtein distance.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut prev = row.first().copied().unwrap_or(0);
        if let Some(first) = row.first_mut() {
            *first = i + 1;
        }
        for (j, cb) in b.iter().enumerate() {
            let above = row.get(j + 1).copied().unwrap_or(usize::MAX);
            let left = row.get(j).copied().unwrap_or(usize::MAX);
            let next = (prev + usize::from(ca != *cb))
                .min(above.saturating_add(1))
                .min(left.saturating_add(1));
            prev = above;
            if let Some(cell) = row.get_mut(j + 1) {
                *cell = next;
            }
        }
    }
    row.last().copied().unwrap_or(0)
}
