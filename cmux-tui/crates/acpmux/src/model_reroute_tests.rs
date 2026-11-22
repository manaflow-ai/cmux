use super::*;

fn bundled() -> Table {
    Table::from_catalog(&crate::catalog::CatalogService::new().current())
}

fn none(_: &str) -> Option<String> {
    None
}

/// The spellings 16 lanes started on (2026-11-22, `claude-code:unrecognized_model`), and their
/// neighbours, run as the id they name.
#[test]
fn misspelled_claude_ids_reroute_to_the_catalog_id() {
    let t = bundled();
    for (from, to) in [
        ("fable-5.2", "claude-fable-5-2"),
        ("fable-5-2", "claude-fable-5-2"),
        ("claude-fable-5.2", "claude-fable-5-2"),
        ("Claude-Fable-5.2", "claude-fable-5-2"),
        ("claude/fable-5.2", "claude-fable-5-2"),
        ("anthropic/claude-opus-5.5", "claude-opus-5-5"),
        ("opus-5.5", "claude-opus-5-5"),
        ("sonnet_5_5", "claude-sonnet-5-5"),
        (" haiku-5.5 ", "claude-haiku-5-5"),
        ("fable-5.2[1m]", "claude-fable-5-2[1m]"),
    ] {
        assert_eq!(reroute_with(&t, "claude", from, none).as_deref(), Some(to), "{from}");
    }
}

/// A correct id, Claude Code's own short aliases, and names the catalog does not know (a model
/// newer than the catalog, a typo with more than one reading) are left as typed.
#[test]
fn known_ids_aliases_and_unknown_names_pass_unchanged() {
    let t = bundled();
    for name in [
        "claude-fable-5-2",
        "claude-opus-5-5",
        "claude-opus-5-5[1m]",
        "opus",
        "sonnet[1m]",
        "fable",
        "haiku",
        "default",
        "",
        "claude-opus-9-9",
        "fable-9.9",
        "claude-sr2",
    ] {
        assert_eq!(reroute_with(&t, "claude", name, none), None, "{name:?}");
    }
}

/// The per-host file wins, and may name any id: a hot patch for a name spelling cannot fix.
#[test]
fn an_override_wins_and_keeps_1m() {
    let t = bundled();
    let o = |n: &str| (n == "fable-latest").then(|| "claude-fable-5-2".to_owned());
    assert_eq!(reroute_with(&t, "claude", "fable-latest", o).as_deref(), Some("claude-fable-5-2"));
    assert_eq!(
        reroute_with(&t, "claude", "fable-latest[1m]", o).as_deref(),
        Some("claude-fable-5-2[1m]")
    );
}

/// A catalog alias with a version in it is a published reroute: the fleet-wide hot patch.
#[test]
fn a_catalog_alias_with_a_version_reroutes() {
    let mut catalog = (*crate::catalog::CatalogService::new().current()).clone();
    let claude = catalog.harnesses.iter_mut().find(|h| h.id == "claude").expect("claude");
    let fable = claude.models.iter_mut().find(|m| m.id == "claude-fable-5-2").expect("fable");
    fable.aliases.get_or_insert_with(Vec::new).push("fable52".into());
    let t = Table::from_catalog(&catalog);
    assert_eq!(reroute_with(&t, "claude", "fable52", none).as_deref(), Some("claude-fable-5-2"));
    assert_eq!(reroute_with(&t, "claude", "FABLE52", none).as_deref(), Some("claude-fable-5-2"));
}

#[test]
fn the_override_file_lowercases_its_names_and_a_bad_one_is_ignored() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(OVERRIDE_FILE);
    std::fs::write(&path, r#"{"Wrong-Name": "claude-opus-5-5"}"#).expect("write");
    assert_eq!(
        read_overrides(&path).get("wrong-name").map(String::as_str),
        Some("claude-opus-5-5")
    );
    std::fs::write(&path, "not json").expect("write");
    assert!(read_overrides(&path).is_empty());
}
