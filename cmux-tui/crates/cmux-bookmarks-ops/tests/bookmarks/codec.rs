//! The Netscape file reader and writer, and the import plans (ported from
//! the app's Swift codec, which they replace).

use cmux_bookmarks_core::{Bookmark, BookmarkImportNode, Tree};
use cmux_bookmarks_ops::import_plan::{self, SourceItem};
use cmux_bookmarks_ops::netscape::{self, decode};

fn node(id: u32, parent: &str, kind: &str, title: &str, url: Option<&str>) -> Bookmark {
    Bookmark {
        id: format!("bm_{id:032x}"),
        browser_profile_id: "default".into(),
        parent: parent.into(),
        kind: kind.into(),
        index: 0,
        title: title.into(),
        url: url.map(str::to_string),
        favicon_key: None,
        source_key: None,
        created_ms: 1_700_000_000_000,
        last_used_ms: None,
        icon: None,
    }
}

fn titles(nodes: &[BookmarkImportNode]) -> Vec<String> {
    nodes.iter().map(|node| node.title.clone()).collect()
}

const CHROME_EXPORT: &str = r#"<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file. -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1600000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://example.com/" ADD_DATE="1600000001">Example &amp; Co</A>
        <DT><H3>Work</H3>
        <DL><p>
            <DT><A href='https://github.com'>GitHub</A>
        </DL><p>
    </DL><p>
    <DT><A HREF="https://other.example">Other</A>
    <DT><A HREF="no-scheme">Skipped</A>
</DL><p>
"#;

#[test]
fn reads_the_toolbar_folder_and_the_rest() {
    let document = netscape::read(CHROME_EXPORT);
    let bar = document.bar.clone().unwrap_or_default();
    assert_eq!(titles(&bar), ["Example & Co", "Work"]);
    assert_eq!(bar[0].url.as_deref(), Some("https://example.com/"));
    assert_eq!(bar[0].created_ms, Some(1_600_000_001_000));
    assert_eq!(titles(bar[1].children.as_deref().unwrap_or_default()), ["GitHub"]);
    assert_eq!(titles(&document.other), ["Other"]);
    assert_eq!(document.count(), 4);
}

#[test]
fn reads_sloppy_files() {
    // Lowercase tags, no </DT>, an unclosed list, microsecond dates.
    let html =
        "<dl><dt><h3 add_date=\"1600000000000000\">A</h3><dl><dt><a href=\"https://a.test\">x</a>";
    let document = netscape::read(html);
    assert!(document.bar.is_none());
    assert_eq!(titles(&document.other), ["A"]);
    assert_eq!(document.other[0].created_ms, Some(1_600_000_000_000));
    assert_eq!(titles(document.other[0].children.as_deref().unwrap_or_default()), ["x"]);
}

#[test]
fn an_anonymous_list_keeps_its_items_in_the_parent() {
    let html = "<DL><DT><A HREF=\"https://a.test\">a</A><DL><DT><A HREF=\"https://b.test\">b</A></DL></DL>";
    assert_eq!(titles(&netscape::read(html).other), ["a", "b"]);
}

#[test]
fn decodes_character_references() {
    assert_eq!(decode(" a &lt;b&gt; &#65;&#x42; &amp &quot;q&quot; "), "a <b> AB &amp \"q\"");
}

#[test]
fn writes_what_it_reads() {
    let mut bar_folder = node(2, "bar", "folder", "Work <1>", None);
    bar_folder.index = 1;
    let inner = node(3, &bar_folder.id, "url", "Docs \"x\"", Some("https://docs.test/?a=1&b=2"));
    let first = node(1, "bar", "url", "Example", Some("https://example.com"));
    let other = node(4, "other", "url", "Elsewhere", Some("https://else.test"));
    let tree = Tree::from_listing("default", [first, bar_folder, inner, other]);
    let html = netscape::write(&tree, "Bookmarks Bar");
    assert!(html.contains("PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks Bar</H3>"));
    assert!(html.contains("HREF=\"https://docs.test/?a=1&amp;b=2\" ADD_DATE=\"1700000000\""));
    let document = netscape::read(&html);
    let bar = document.bar.clone().unwrap_or_default();
    assert_eq!(titles(&bar), ["Example", "Work <1>"]);
    let children = bar[1].children.clone().unwrap_or_default();
    assert_eq!(children[0].url.as_deref(), Some("https://docs.test/?a=1&b=2"));
    assert_eq!(children[0].title, "Docs \"x\"");
    assert_eq!(titles(&document.other), ["Elsewhere"]);
}

#[test]
fn a_file_imports_into_one_folder_at_the_end_of_the_bar() {
    let import = import_plan::html("default", CHROME_EXPORT, "Imported", "Bookmarks Bar");
    let import = import.unwrap_or_default();
    assert_eq!(import.parent, "bar");
    assert!(!import.replace);
    assert_eq!(titles(&import.nodes), ["Imported"]);
    let children = import.nodes[0].children.clone().unwrap_or_default();
    assert_eq!(titles(&children), ["Bookmarks Bar", "Other"]);
    assert!(import_plan::html("default", "<html>nothing</html>", "Imported", "Bar").is_none());
}

fn item(title: &str, url: &str, path: &[&str]) -> SourceItem {
    SourceItem {
        title: title.into(),
        url: url.into(),
        folder_path: path.iter().map(|part| part.to_string()).collect(),
        created_ms: None,
    }
}

#[test]
fn a_source_import_drops_the_shared_first_folder_and_skips_duplicates() {
    let items = [
        item("A", "https://a.test", &["Bar"]),
        item("B", "https://b.test", &["Bar", "Work"]),
        item("A again", "https://a.test", &["Bar"]),
        item("B elsewhere", "https://b.test", &["Bar"]),
    ];
    let plan = import_plan::source("default", "Imported from Chrome", "chrome:Default", &items);
    assert_eq!(plan.added, 3);
    assert_eq!(plan.duplicates, 1);
    assert!(plan.import.replace);
    assert_eq!(plan.import.source_key.as_deref(), Some("chrome:Default"));
    let root = &plan.import.nodes[0];
    assert_eq!(root.title, "Imported from Chrome");
    let children = root.children.clone().unwrap_or_default();
    assert_eq!(titles(&children), ["A", "Work", "B elsewhere"]);
}

#[test]
fn a_source_import_keeps_different_first_folders() {
    let items = [item("A", "https://a.test", &["Bar"]), item("B", "https://b.test", &["Other"])];
    let plan = import_plan::source("default", "T", "k", &items);
    assert_eq!(
        titles(plan.import.nodes[0].children.as_deref().unwrap_or_default()),
        ["Bar", "Other"]
    );
}
