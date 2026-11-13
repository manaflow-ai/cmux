//! What the readers return, shaped as the Swift `Codable` types the app decodes them into
//! (`ImportedBookmark`, `ImportedHistoryEntry`, `ImportedTab`, `ImportedExtension`,
//! `ImportedSearchEngine`): a `nil` is a missing key, a date is seconds since 2001-01-01.

use serde_json::{Map, Value, json};

/// A bookmark with its folder path from the source's root ("Bookmarks Bar", "Work").
#[derive(Clone, Debug, PartialEq)]
pub struct Bookmark {
    pub title: String,
    /// The source's text; an importable scheme (`url::importable`).
    pub url: String,
    pub folder_path: Vec<String>,
    /// Seconds since 2001-01-01 UTC.
    pub date_added: Option<f64>,
}

/// One history page, already aggregated per URL by the source.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryEntry {
    pub url: String,
    pub title: Option<String>,
    pub visit_count: i64,
    /// Seconds since 2001-01-01 UTC.
    pub last_visit: f64,
}

/// An open tab from the source's last session, in window then tab order.
#[derive(Clone, Debug, PartialEq)]
pub struct Tab {
    pub url: String,
    pub title: Option<String>,
    pub window: usize,
    pub pinned: bool,
}

/// A Chrome extension installed in a source profile.
#[derive(Clone, Debug, PartialEq)]
pub struct Extension {
    /// The 32-letter extension id (a-p).
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub enabled: bool,
    pub from_web_store: bool,
}

/// A source profile's default search engine (`{searchTerms}` marks the typed text).
#[derive(Clone, Debug, PartialEq)]
pub struct SearchEngine {
    pub name: String,
    pub keyword: Option<String>,
    pub search: String,
    pub suggest: Option<String>,
}

/// Why a reader gave up (the Swift readers' thrown errors).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadError {
    /// The file could not be read (`Data(contentsOf:)`).
    Read(String),
    /// Not JSON or not a property list (`JSONSerialization`, `PropertyListSerialization`).
    Syntax(String),
    /// Parsed, but not the shape the reader takes (`Failure.notBookmarks`, `notSidebar`).
    Shape(&'static str),
    /// The private copy could not be made (`SQLiteSnapshot.Failure.copy`).
    Copy(String),
    /// SQLite would not open the copy (`Failure.open`).
    Open(String),
    /// A statement failed (`Failure.query`).
    Query(String),
}

impl ReadError {
    pub fn kind(&self) -> &'static str {
        match self {
            ReadError::Read(_) => "read",
            ReadError::Syntax(_) => "syntax",
            ReadError::Shape(what) => what,
            ReadError::Copy(_) => "copy",
            ReadError::Open(_) => "open",
            ReadError::Query(_) => "query",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            ReadError::Read(m)
            | ReadError::Syntax(m)
            | ReadError::Copy(m)
            | ReadError::Open(m)
            | ReadError::Query(m) => m,
            ReadError::Shape(what) => what,
        }
    }

    pub fn to_json(&self) -> Value {
        json!({ "kind": self.kind(), "message": self.message() })
    }
}

fn put(map: &mut Map<String, Value>, key: &str, value: Option<Value>) {
    if let Some(value) = value {
        map.insert(key.to_owned(), value);
    }
}

impl Bookmark {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("title".into(), json!(self.title));
        map.insert("url".into(), json!(self.url));
        map.insert("folderPath".into(), json!(self.folder_path));
        put(&mut map, "dateAdded", self.date_added.map(|d| json!(d)));
        Value::Object(map)
    }
}

impl HistoryEntry {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("url".into(), json!(self.url));
        put(&mut map, "title", self.title.as_ref().map(|t| json!(t)));
        map.insert("visitCount".into(), json!(self.visit_count));
        map.insert("lastVisit".into(), json!(self.last_visit));
        Value::Object(map)
    }
}

impl Tab {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("url".into(), json!(self.url));
        put(&mut map, "title", self.title.as_ref().map(|t| json!(t)));
        map.insert("window".into(), json!(self.window));
        map.insert("pinned".into(), json!(self.pinned));
        Value::Object(map)
    }
}

impl Extension {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), json!(self.id));
        map.insert("name".into(), json!(self.name));
        put(&mut map, "version", self.version.as_ref().map(|v| json!(v)));
        map.insert("enabled".into(), json!(self.enabled));
        map.insert("fromWebStore".into(), json!(self.from_web_store));
        Value::Object(map)
    }

    /// Chrome extension ids are 32 letters from a to p (`ImportedExtension.isValidID`).
    pub fn is_valid_id(id: &str) -> bool {
        id.chars().count() == 32 && id.chars().all(|c| ('a'..='p').contains(&c))
    }
}

impl SearchEngine {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("name".into(), json!(self.name));
        put(&mut map, "keyword", self.keyword.as_ref().map(|k| json!(k)));
        map.insert("search".into(), json!(self.search));
        put(&mut map, "suggest", self.suggest.as_ref().map(|s| json!(s)));
        Value::Object(map)
    }

    /// Decodes the shape [`SearchEngine::to_json`] writes (the app passes one back for
    /// [`crate::search::setting`]).
    pub fn from_json(value: &Value) -> Option<SearchEngine> {
        let object = value.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(SearchEngine {
            name: text("name")?,
            keyword: text("keyword"),
            search: text("search")?,
            suggest: text("suggest"),
        })
    }
}

/// Every item's JSON, in order.
pub fn list<T>(items: &[T], to_json: impl Fn(&T) -> Value) -> Value {
    Value::Array(items.iter().map(to_json).collect())
}
