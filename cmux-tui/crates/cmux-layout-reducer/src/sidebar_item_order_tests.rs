use super::*;

fn ws(id: &str) -> Item {
    Item::Workspace(id.into())
}
fn top(id: &str) -> Item {
    Item::TopItem(id.into())
}
fn key(kind: &str, id: &str) -> RowKey {
    RowKey { kind: kind.into(), id: id.into() }
}
fn strings(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

/// The default sidebar: Home and the App Store drawn as the document's top block, then three workspaces.
fn home_block_order() -> Order {
    Order {
        top_items: vec![],
        rows: vec![top("itm_home"), top("itm_store"), ws("1"), ws("2"), ws("3")],
        stops: BTreeMap::new(),
    }
}

fn workspaces_only() -> Settings {
    Settings {
        numbering: Scope::WorkspacesOnly,
        stepping: Scope::WorkspacesOnly,
        ..Settings::default()
    }
}

#[test]
fn command_one_is_the_first_workspace_under_the_top_block() {
    let order = home_block_order();
    assert_eq!(order.pick(1, workspaces_only()), Some(ws("1")));
    assert_eq!(order.pick(3, workspaces_only()), Some(ws("3")));
    assert_eq!(order.number(&top("itm_home"), workspaces_only()), None);
    assert_eq!(order.number(&ws("1"), workspaces_only()), Some(1));
}

#[test]
fn stepping_workspaces_only_skips_the_top_block() {
    let order = home_block_order();
    assert_eq!(order.step(Some(&ws("1")), -1, workspaces_only(), None), Some(ws("3")));
    assert_eq!(order.step(None, 1, workspaces_only(), None), Some(ws("1")));
}

#[test]
fn every_item_still_counts_the_top_block() {
    assert_eq!(home_block_order().pick(1, Settings::default()), Some(top("itm_home")));
}

#[test]
fn command_nine_is_the_last_or_the_ninth() {
    let rows: Vec<Item> = (1..=12).map(|n| ws(&n.to_string())).collect();
    let order = Order { rows, ..Order::default() };
    assert_eq!(order.pick(9, Settings::default()), Some(ws("12")));
    let ninth = Settings { cmd9: NinthKey::Ninth, ..Settings::default() };
    assert_eq!(order.pick(9, ninth), Some(ws("9")));
    assert_eq!(order.number(&ws("12"), Settings::default()), Some(9));
    assert_eq!(order.number(&ws("9"), Settings::default()), None);
    assert_eq!(order.number(&ws("9"), ninth), Some(9));
    assert_eq!(order.pick(0, Settings::default()), None);
    let short = Order { rows: vec![ws("a")], ..Order::default() };
    assert_eq!(short.pick(4, Settings::default()), Some(ws("a")));
    assert_eq!(short.pick(4, ninth), None);
    assert_eq!(Order::default().pick(1, Settings::default()), None);
}

#[test]
fn a_walk_wraps_or_stops_at_the_ends() {
    let order = home_block_order();
    assert_eq!(order.step(Some(&ws("3")), 1, Settings::default(), None), Some(top("itm_home")));
    let no_wrap = Settings { stepping_wraps: false, ..Settings::default() };
    assert_eq!(order.step(Some(&ws("3")), 1, no_wrap, None), None);
    assert_eq!(order.step(Some(&ws("2")), 0, Settings::default(), None), None);
}

#[test]
fn a_workspace_drawn_between_stops_walks_from_its_place() {
    let mut order = Order { rows: vec![ws("a"), ws("a"), ws("b"), ws("x")], ..Order::default() };
    order.rows[1] = Item::Group("g".into());
    // x is an opened fold's row listed at the end but drawn after a.
    assert_eq!(
        order.step(Some(&ws("x")), 1, Settings::default(), Some(1)),
        Some(Item::Group("g".into()))
    );
    assert_eq!(order.step(Some(&ws("x")), -1, Settings::default(), Some(1)), Some(ws("a")));
}

#[test]
fn a_collapsed_group_stands_for_its_members() {
    let mut order = home_block_order();
    order.rows.push(Item::Group("g".into()));
    order.stops.insert("m".into(), Item::Group("g".into()));
    assert_eq!(order.stop(Some(&ws("m"))), Some(Item::Group("g".into())));
    assert_eq!(order.stop(Some(&ws("nobody"))), None);
    assert!(order.reveals_top(Some(&ws("1"))));
    assert!(!order.reveals_top(Some(&ws("2"))));
    assert!(!order.reveals_top(None));
}

#[test]
fn rows_become_stops_by_kind() {
    let mut source = Source {
        rows: vec![
            key("header", "h"),
            key("block", "top"),
            key("workspace", "1"),
            key("workspace", "hidden"),
            key("item", "link"),
            key("group", "open"),
            key("group", "shut"),
            key("group", "empty"),
            key("block", "folded"),
        ],
        selectable: ["1", "m1", "m2"].iter().map(|s| (*s).to_owned()).collect(),
        collapsed_blocks: ["folded".to_owned()].into_iter().collect(),
        top: strings(&["home", "store", "loose"]),
        listed: ["top".to_owned(), "folded".to_owned()].into_iter().collect(),
        ..Source::default()
    };
    source.in_block.insert("top".into(), strings(&["home", "store"]));
    source.in_block.insert("folded".into(), strings(&["deep"]));
    source.groups.insert("open".into(), Group { collapsed: false, members: strings(&["m1"]) });
    source
        .groups
        .insert("shut".into(), Group { collapsed: true, members: strings(&["m1", "gone", "m2"]) });
    source.groups.insert("empty".into(), Group { collapsed: true, members: strings(&["gone"]) });
    let order = make(&source);
    assert_eq!(
        order.rows,
        vec![top("home"), top("store"), ws("1"), top("link"), Item::Group("shut".into())]
    );
    assert_eq!(order.stops.len(), 2);
    assert_eq!(order.top_items, vec![top("loose")]);
}

#[test]
fn the_drawn_place_follows_the_last_stop_before_it() {
    let rows = vec![ws("a"), ws("b"), ws("c")];
    assert_eq!(drawn_place(&rows, &[ws("a"), ws("x"), ws("b")], "x"), Some(1));
    assert_eq!(drawn_place(&rows, &[ws("x"), ws("a")], "x"), Some(0));
    assert_eq!(drawn_place(&rows, &[ws("q"), ws("c"), ws("x")], "x"), Some(3));
    assert_eq!(drawn_place(&rows, &[ws("a")], "x"), None);
}
