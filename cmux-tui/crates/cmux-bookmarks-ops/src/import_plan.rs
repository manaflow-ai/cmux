//! Where imports land (bookmarks.md section 3 and the onboarding
//! contract): a browser import is one folder per source at the end of the
//! Bookmarks Bar, replaced in place on a re-import; an HTML file is one
//! "Imported" folder there.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::netscape::{self, Document, folder, link};
use cmux_bookmarks_core::{
    BOOKMARKS_BAR, BookmarkError, BookmarkImport, BookmarkImportNode, MAX_BOOKMARK_DEPTH, Reason,
    validate_url,
};

/// A flat imported bookmark, with its folder path from the source's root
/// (the shape the app's browser import reads from every browser).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceItem {
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub folder_path: Vec<String>,
    #[serde(default)]
    pub created_ms: Option<u64>,
}

/// One browser source's import and what it holds.
#[derive(Debug, Clone)]
pub struct SourcePlan {
    pub import: BookmarkImport,
    /// Bookmarks the import creates.
    pub added: usize,
    /// Bookmarks left out: the same URL is already in the same folder
    /// (decision BOOKMARKS-IMPORT-EVERY-BROWSER I4); in another folder it stays.
    pub duplicates: usize,
    /// Items left out because the store would refuse their URL (no
    /// scheme, unparsable, too long): one bad item never refuses the rest.
    pub skipped: usize,
}

/// The replace-or-create import of one browser source into `profile`: one
/// folder titled `title` that carries `source_key`. Items keep their order;
/// folders appear in order of first use. When every item shares the same
/// first folder (the source's bar), that level is dropped.
pub fn source(
    profile: &str,
    title: &str,
    source_key: &str,
    items: &[SourceItem],
) -> Result<SourcePlan, BookmarkError> {
    // Rows the store would refuse go first, so they never change the layout of the rest.
    let usable = items.iter().filter(|item| validate_url(&item.url).is_ok()).collect::<Vec<_>>();
    let skipped = items.len() - usable.len();
    // Rows, but none usable: refused, so the source's folder is not replaced by an empty one.
    if !items.is_empty() && usable.is_empty() {
        return Err(BookmarkError::invalid("no usable bookmarks: every row's URL is refused"));
    }
    let shared = usable.first().and_then(|item| item.folder_path.first());
    let strip = shared.is_some() && usable.iter().all(|item| item.folder_path.first() == shared);
    // The source's folder, the path's folders (less the dropped first level) and the bookmark.
    let levels = |item: &&SourceItem| 1 + item.folder_path.len() - usize::from(strip) + 1;
    if usable.iter().any(|item| levels(item) > MAX_BOOKMARK_DEPTH) {
        return Err(too_deep());
    }
    let mut root = Builder::default();
    let mut added = 0;
    for item in usable {
        let path =
            if strip { item.folder_path.get(1..).unwrap_or_default() } else { &item.folder_path };
        if root.add(link(&item.title, &item.url, item.created_ms), path) {
            added += 1;
        }
    }
    let import = BookmarkImport {
        browser_profile_id: profile.to_string(),
        parent: BOOKMARKS_BAR.to_string(),
        index: None,
        source_key: Some(source_key.to_string()),
        replace: true,
        nodes: vec![folder(title, None, root.nodes())],
    };
    Ok(SourcePlan { import, added, duplicates: items.len() - added - skipped, skipped })
}

fn too_deep() -> BookmarkError {
    BookmarkError::invalid(format!("bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"))
        .because(Reason::TooDeep)
}

/// An HTML file into a new folder named `title` at the end of the bar (the
/// file's toolbar folder becomes a subfolder named `bar_title`).
pub fn file(profile: &str, document: Document, title: &str, bar_title: &str) -> BookmarkImport {
    BookmarkImport {
        browser_profile_id: profile.to_string(),
        parent: BOOKMARKS_BAR.to_string(),
        index: None,
        source_key: None,
        replace: false,
        nodes: vec![folder(title, None, document.nodes(bar_title))],
    }
}

/// [`file`] from the file's text; `None` when it holds no bookmark.
/// Refused as too deep when the file nests past [`MAX_BOOKMARK_DEPTH`].
pub fn html(
    profile: &str,
    html: &str,
    title: &str,
    bar_title: &str,
) -> Result<Option<BookmarkImport>, BookmarkError> {
    let document = netscape::read(html);
    if document.too_deep {
        return Err(too_deep());
    }
    Ok((document.count() > 0).then(|| file(profile, document, title, bar_title)))
}

/// A folder tree under construction, in first-use order.
#[derive(Default)]
struct Builder {
    entries: Vec<Entry>,
    urls: HashSet<String>,
}

enum Entry {
    Leaf(BookmarkImportNode),
    Folder(String, Builder),
}

impl Builder {
    /// False when the folder already holds this URL (the node is skipped).
    fn add(&mut self, node: BookmarkImportNode, path: &[String]) -> bool {
        let Some((name, rest)) = path.split_first() else {
            if let Some(url) = &node.url
                && !self.urls.insert(url.clone())
            {
                return false;
            }
            self.entries.push(Entry::Leaf(node));
            return true;
        };
        for entry in &mut self.entries {
            if let Entry::Folder(title, child) = entry
                && title == name
            {
                return child.add(node, rest);
            }
        }
        let mut child = Builder::default();
        let added = child.add(node, rest);
        self.entries.push(Entry::Folder(name.clone(), child));
        added
    }

    fn nodes(self) -> Vec<BookmarkImportNode> {
        self.entries
            .into_iter()
            .map(|entry| match entry {
                Entry::Leaf(node) => node,
                Entry::Folder(title, child) => folder(&title, None, child.nodes()),
            })
            .collect()
    }
}
