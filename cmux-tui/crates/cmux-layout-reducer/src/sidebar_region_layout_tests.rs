//! Ports of the app's region layout tests (PinnedSectionHasNoHeaderTests,
//! PinnedRowsLookLikeRowsTests, SidebarIconColumnTests' band header case)
//! and a replay of the Swift transliteration's vectors.

use super::*;
use crate::sidebar_layout::{Arrangement, ItemRef, Region};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-region-layout/vectors.json");
const LOOKS: [LookVariant; 5] = [
    LookVariant::Quiet,
    LookVariant::Card,
    LookVariant::Tray,
    LookVariant::Lines,
    LookVariant::LinesIcons,
];

/// The app's standard band metrics at a 28 pt row, with the rows' trailing trim.
fn standard() -> Metrics {
    Metrics {
        row_height: 28.0,
        header_height: 24.0,
        inset: 8.0,
        section_gap: 8.0,
        padding: 8.0,
        card_padding: 4.0,
        tile_min_width: 42.0,
        tile_height: 36.0,
        tile_gap: 8.0,
        icon_button_width: Some(36.0),
        line_width: 1.0,
        favorite_height: Some(64.0),
        glyph_column: Some(14.0),
        top_padding: None,
        bottom_padding: None,
        leading_separator: false,
        trailing_trim: 4.5,
        row_gap: 4.0,
    }
}

fn workspace(id: &str) -> Item {
    Item::new(id, ItemRef::new(WORKSPACE_KIND, &format!("local:{id}")), true)
}

fn section(id: &str, title: Option<&str>, items: Vec<Item>) -> Section {
    let mut section = Section::new(id, Region::Top, Look::BuiltIn, Content::Items);
    section.title = title.map(str::to_owned);
    section.shows_title = title.is_some();
    section.items = items;
    section
}

fn band(sections: Vec<Section>, width: f64, look: LookVariant, metrics: Metrics) -> Band {
    Band {
        sections,
        width,
        look,
        collapsed: Vec::new(),
        metrics,
        label_widths: HashMap::new(),
        app_heights: HashMap::new(),
        icon_widths: HashMap::new(),
    }
}

fn pinned(items: Vec<Item>) -> Section {
    section(PINNED_SECTION, Some("Pinned"), items).with_untitled()
}

trait Untitled {
    fn with_untitled(self) -> Self;
}

impl Untitled for Section {
    fn with_untitled(mut self) -> Self {
        self.shows_title = false;
        self
    }
}

#[test]
fn pinned_draws_no_header_in_any_look() {
    let pinned = pinned(vec![workspace("itm_pin")]);
    assert_eq!(header_title(&pinned), None);
    for look in LOOKS {
        assert_eq!(header(&pinned, look), None, "{look:?} draws a header for Pinned");
        let layout = make(&band(vec![pinned.clone()], 240.0, look, standard()));
        assert!(!layout.rows.iter().any(|r| matches!(r.kind, RowKind::Header { .. })), "{look:?}");
    }
}

#[test]
fn a_pinned_section_stored_as_a_grid_still_draws_rows() {
    let mut section = pinned(vec![workspace("itm_pin_a"), workspace("itm_pin_b")]);
    section.arrangement = Arrangement::new(ArrangementLayout::Grid, Alignment::Leading);
    let m = standard();
    let layout = make(&band(vec![section], 240.0, LookVariant::Quiet, m));
    let rows: Vec<&Row> =
        layout.rows.iter().filter(|r| !matches!(r.kind, RowKind::Header { .. })).collect();
    assert_eq!(rows.len(), 2);
    for row in &rows {
        assert!(
            matches!(row.kind, RowKind::Item { .. }),
            "a pinned workspace drew as {:?}",
            row.kind
        );
        assert_eq!(row.frame.width, 240.0 - m.trailing_trim, "a row spans the sidebar width");
        assert_eq!(row.frame.height, m.row_height);
    }
    assert!((rows[1].frame.min_y() - rows[0].frame.max_y() - m.row_gap).abs() < 0.01);
}

#[test]
fn a_band_rows_trim_is_none_on_a_card() {
    let item = Item::new("itm_column_band", ItemRef::new("builtin", "home"), true);
    let section = section("sec_column_band", Some("Band"), vec![item]);
    let m = standard();
    for look in LOOKS {
        let layout = make(&band(vec![section.clone()], 260.0, look, m));
        let Some(header_row) =
            layout.rows.iter().find(|r| matches!(r.kind, RowKind::Header { .. }))
        else {
            assert!(!look.shows_headers());
            continue;
        };
        let trim = item_trailing_trim(&section, look, &m);
        assert_eq!(trim, if look == LookVariant::Card { 0.0 } else { m.trailing_trim });
        if let Some(item_row) = layout.rows.iter().find(|r| matches!(r.kind, RowKind::Item { .. }))
        {
            assert_eq!(item_row.frame.width, header_row.frame.width - trim, "{look:?}");
        }
    }
}

#[test]
fn lines_looks_draw_no_line_under_home_and_tray_tiles_built_ins() {
    let home = section(
        TOP_SECTION,
        None,
        vec![Item::new("itm_home", ItemRef::new("builtin", "home"), true)],
    );
    let rest = section("sec_more", None, vec![workspace("itm_a")]);
    let layout = make(&band(
        vec![home, rest.clone(), section("sec_x", None, vec![workspace("itm_b")])],
        240.0,
        LookVariant::Lines,
        standard(),
    ));
    assert_eq!(layout.separator_keys, vec!["sec_x".to_owned()]);
    assert_eq!(mode(&rest, LookVariant::Tray), Some(Mode::Grid { columns: None }));
    assert_eq!(mode(&rest, LookVariant::LinesIcons), Some(Mode::Inline { icons_only: true }));
    let mut listed = rest;
    listed.look = Look::List;
    assert_eq!(mode(&listed, LookVariant::Tray), None);
}

#[test]
fn a_drop_lands_after_the_built_in_rows() {
    let home = Item::new("itm_home", ItemRef::new("builtin", "home"), true);
    let top = section(TOP_SECTION, None, vec![home, workspace("itm_a"), workspace("itm_b")]);
    let sections = vec![top];
    let layout = make(&band(sections.clone(), 240.0, LookVariant::Quiet, standard()));
    let first = layout.rows.first().map(|r| r.frame).expect("row");
    let drop = drop_target(10.0, first.min_y() + 1.0, &layout, &sections, 4.0).expect("drop");
    assert_eq!((drop.section.as_str(), drop.index), (TOP_SECTION, 1));
    let last = layout.rows.last().map(|r| r.frame).expect("row");
    assert_eq!(
        drop_target(10.0, last.max_y() + 1.0, &layout, &sections, 4.0).map(|d| d.index),
        Some(3)
    );
    assert_eq!(drop_target(10.0, last.max_y() + 3.0, &layout, &sections, 4.0), None);
}

#[test]
fn band_heights_shrink_in_proportion_and_keep_their_floor() {
    let p = BandHeights {
        above_capped: 300.0,
        below_capped: 100.0,
        available: 300.0,
        pinned_bands_scroll: false,
        top_band_max_share: 0.0,
        bottom_band_max_share: 0.0,
        minimum_list: 100.0,
        band_floor: 60.0,
    };
    assert_eq!(band_heights(&p), Heights { above: 150.0, below: 60.0 });
}

/// JSON equality that reads every number as f64.
fn same(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    use serde_json::Value;
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn region_vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    let cases = doc["regions"].as_array().expect("regions");
    assert!(cases.len() >= 200);
    for (index, case) in cases.iter().enumerate() {
        let request: Request = serde_json::from_value(case.clone()).expect("request");
        let reply = serde_json::to_value(respond(&request)).expect("reply");
        for key in ["layout", "drops", "pinned_height"] {
            let (got, want) = (&reply[key], &case["reply"][key]);
            if key == "layout" {
                for (field, value) in want.as_object().expect("layout") {
                    assert!(
                        same(&got[field], value),
                        "case {index} layout.{field}: {} vs {value}",
                        got[field]
                    );
                }
            }
            assert!(same(got, want), "case {index} {key}");
        }
    }
}

#[test]
fn band_heights_vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc["band_heights"].as_array().expect("band_heights").iter().enumerate() {
        let request: BandHeights = serde_json::from_value(case.clone()).expect("request");
        let got = serde_json::to_value(band_heights(&request)).expect("heights");
        assert!(same(&got, &case["heights"]), "case {index}");
    }
}
