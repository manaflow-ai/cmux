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
    let import = import_plan::html("default", CHROME_EXPORT, "Imported", "Bookmarks Bar").unwrap();
    let import = import.unwrap_or_default();
    assert_eq!(import.parent, "bar");
    assert!(!import.replace);
    assert_eq!(titles(&import.nodes), ["Imported"]);
    let children = import.nodes[0].children.clone().unwrap_or_default();
    assert_eq!(titles(&children), ["Bookmarks Bar", "Other"]);
    assert!(
        import_plan::html("default", "<html>nothing</html>", "Imported", "Bar").unwrap().is_none()
    );
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
    let plan =
        import_plan::source("default", "Imported from Chrome", "chrome:Default", &items).unwrap();
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
    let plan = import_plan::source("default", "T", "k", &items).unwrap();
    assert_eq!(
        titles(plan.import.nodes[0].children.as_deref().unwrap_or_default()),
        ["Bar", "Other"]
    );
}

/// A link the store would refuse is skipped, so one bad entry never refuses the whole file
/// (review F3: `http://[bad` has a scheme but does not parse).
#[test]
fn a_link_the_store_would_refuse_is_skipped() {
    let html =
        "<DL><DT><A HREF=\"http://[bad\">Bad</A><DT><A HREF=\"https://ok.test/\">Good</A></DL>";
    let document = netscape::read(html);
    assert_eq!(titles(&document.other), ["Good"]);
    let import = import_plan::html("default", html, "Imported", "Bar")
        .unwrap()
        .expect("the good link imports");
    assert_eq!(titles(import.nodes[0].children.as_deref().unwrap_or_default()), ["Good"]);
}

/// A browser item with an unusable URL is counted as skipped; the rest import.
#[test]
fn a_source_item_the_store_would_refuse_is_skipped() {
    let items = [item("Bad", "http://[bad", &["Bar"]), item("Good", "https://ok.test", &["Bar"])];
    let plan = import_plan::source("default", "T", "k", &items).unwrap();
    assert_eq!((plan.added, plan.duplicates, plan.skipped), (1, 0, 1));
    assert_eq!(titles(plan.import.nodes[0].children.as_deref().unwrap_or_default()), ["Good"]);
}

/// Review F1 (third review): a 10,000-deep file is read without recursing past the depth limit
/// and its import is refused as too deep; nothing below the limit is kept.
#[test]
fn a_ten_thousand_deep_file_is_refused_as_too_deep() {
    let depth = 10_000;
    let mut html = String::from("<DL>");
    for level in 0..depth {
        html.push_str(&format!("<DT><H3>F{level}</H3><DL>"));
    }
    html.push_str("<DT><A HREF=\"https://deep.test/\">Deep</A>");
    html.push_str(&"</DL>".repeat(depth + 1));
    let document = netscape::read(&html);
    assert!(document.too_deep);
    assert_eq!(document.count(), cmux_bookmarks_core::MAX_BOOKMARK_DEPTH);
    let refusal = import_plan::html("default", &html, "Imported", "Bar").unwrap_err();
    assert_eq!(refusal.reason(), cmux_bookmarks_core::Reason::TooDeep);
}

/// A browser source whose folder path passes the depth limit is refused as too deep, before any
/// folder is built (a 10,000-level path).
#[test]
fn a_source_path_past_the_depth_limit_is_refused() {
    let path = (0..10_000).map(|level| format!("F{level}")).collect::<Vec<_>>();
    let items = [SourceItem {
        title: "Deep".into(),
        url: "https://deep.test/".into(),
        folder_path: path,
        created_ms: None,
    }];
    let refusal = import_plan::source("default", "T", "k", &items).unwrap_err();
    assert_eq!(refusal.reason(), cmux_bookmarks_core::Reason::TooDeep);
}

/// Review F2 (third review): a skipped row never decides the layout: the valid rows share the
/// bar folder, so it is dropped even when a bad row elsewhere comes first.
#[test]
fn a_skipped_row_does_not_keep_the_shared_folder() {
    let items = [
        item("Bad", "http://[bad", &["Other"]),
        item("A", "https://a.test", &["Bar"]),
        item("B", "https://b.test", &["Bar", "Work"]),
    ];
    let plan = import_plan::source("default", "T", "k", &items).unwrap();
    assert_eq!(plan.skipped, 1);
    assert_eq!(titles(plan.import.nodes[0].children.as_deref().unwrap_or_default()), ["A", "Work"]);
}

/// Review 4 F1: rows, but none usable, are refused, so the source's folder is not replaced.
#[test]
fn a_source_with_no_usable_row_is_refused() {
    let items = [item("Bad", "http://[bad", &["Bar"]), item("Worse", "nope", &["Bar"])];
    let refusal = import_plan::source("default", "T", "k", &items).unwrap_err();
    assert!(refusal.message().contains("no usable bookmarks"), "{refusal}");
}

/// Review 4 F2: the bookmark counts toward the depth: under mixed first folders, a 63-folder path
/// is 65 levels with the source's folder and the bookmark, and is refused here.
#[test]
fn a_sixty_three_folder_path_counts_the_bookmark() {
    let deep = (0..63).map(|level| format!("F{level}")).collect::<Vec<_>>();
    let deep = deep.iter().map(String::as_str).collect::<Vec<_>>();
    let items =
        [item("Deep", "https://deep.test/", &deep), item("Top", "https://top.test/", &["Other"])];
    let refusal = import_plan::source("default", "T", "k", &items).unwrap_err();
    assert_eq!(refusal.reason(), cmux_bookmarks_core::Reason::TooDeep);
    // 62 folders is 64 levels: allowed.
    let items = [
        item("Deep", "https://deep.test/", &deep[..62]),
        item("Top", "https://top.test/", &["Other"]),
    ];
    assert!(import_plan::source("default", "T", "k", &items).is_ok());
}
