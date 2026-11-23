//! `sidebar.workspaceRow.lines`, `linesByKind` and `linesByAgent` (CMUX-383): the shared `json`
//! kind registers all three, so Settings and `cmux settings set` write them with the same check the
//! file gets. The row's shape checks the nesting and the token names; the sidebar row reducer's
//! problems (more than three lines, more than six text tokens on a line, the name off the first
//! line, a repeated token) refuse the write and say where.

use cmux_config::schema::{DomainKind, Kind, Schema, Validation, accepts};
use cmux_config::{
    Domains, FileRead, ManagedPreferences, Op, Origin, Refusal, State, Target, TeamPolicyLayer,
    WriteMeta, apply,
};
use serde_json::{Value, json};

const LINES: &str = "sidebar.workspaceRow.lines";
const BY_KIND: &str = "sidebar.workspaceRow.linesByKind";
const BY_AGENT: &str = "sidebar.workspaceRow.linesByAgent";

fn check(key: &str, value: Value) -> Result<(), Refusal> {
    let row = Schema::embedded().row(key).unwrap_or_else(|| panic!("{key} is a schema row"));
    accepts(row, &value, &Domains::default())
}

/// The refused value's problems: `[(at, why)]`.
fn problems(key: &str, value: Value) -> Vec<(String, String)> {
    let Err(refusal) = check(key, value.clone()) else { panic!("{key} accepts {value}") };
    let data = refusal.data();
    data["accepted"]["problems"]
        .as_array()
        .expect("a json refusal lists problems")
        .iter()
        .map(|p| {
            (p["at"].as_str().unwrap_or("").to_owned(), p["why"].as_str().unwrap_or("").to_owned())
        })
        .collect()
}

#[test]
fn all_three_keys_are_registered_together_as_json_rows() {
    let schema = Schema::embedded();
    for (key, domain, top) in [
        (LINES, DomainKind::SidebarRowLines, "array"),
        (BY_KIND, DomainKind::SidebarRowLinesByKind, "object"),
        (BY_AGENT, DomainKind::SidebarRowLinesByAgent, "object"),
    ] {
        let row = schema.row(key).unwrap_or_else(|| panic!("{key} is a schema row"));
        let Kind::Json(shape) = &row.kind else { panic!("{key} is a json row: {:?}", row.kind) };
        assert_eq!(shape["type"], json!(top), "{key}");
        assert_eq!(row.validation, Validation::Domain(domain), "{key}");
        assert_eq!(row.default, None, "{key}: unset by default, the row keeps today's switches");
        assert!(row.agent_settable, "{key}: a look, like the element switches");
        // The editor schema is the owner's shape.
        let leaf = schema
            .json_schema()
            .pointer("/properties/sidebar/properties/workspaceRow/properties")
            .cloned();
        let leaf = leaf
            .and_then(|p| p.get(key.rsplit('.').next().unwrap()).cloned())
            .expect("in the JSON Schema");
        assert_eq!(leaf["type"], json!(top), "{key}");
        assert_eq!(leaf["x-cmux-key"], json!(key));
    }
}

#[test]
fn the_documented_shapes_are_accepted() {
    // design/sidebar-customization.md, "A proper customization path".
    assert!(check(LINES, json!([["icon", "name"], ["directory", "branch"]])).is_ok());
    assert!(check(LINES, json!([])).is_ok());
    assert!(
        check(
            BY_KIND,
            json!({
                "agent": [["icon", "name", "working"], ["agentStatus"]],
                "terminal": [["icon", "name"], ["process", "directory"]]
            })
        )
        .is_ok()
    );
    assert!(
        check(BY_AGENT, json!({"claude": [["icon", "name", "working"], ["lastActivity"]]})).is_ok()
    );
    // The name may be left out (it leads the first line) and slots do not count as text tokens.
    assert!(
        check(
            LINES,
            json!([[
                "icon",
                "branch",
                "directory",
                "process",
                "ports",
                "log",
                "tabCount",
                "working",
                "progress"
            ]])
        )
        .is_ok()
    );
}

#[test]
fn the_shape_refuses_what_is_not_a_layout_and_says_where() {
    assert_eq!(
        problems(LINES, json!("name")),
        [(LINES.to_owned(), "expected an array".to_owned())]
    );
    assert_eq!(
        problems(LINES, json!(["name"])),
        [(format!("{LINES}[0]"), "expected an array".to_owned())]
    );
    assert_eq!(
        problems(LINES, json!([["name", "weather"]])),
        [(format!("{LINES}[0][1]"), "not one of the allowed values".to_owned())]
    );
    assert_eq!(
        problems(LINES, json!([["name"], []])),
        [(format!("{LINES}[1]"), "too few items".to_owned())]
    );
    assert_eq!(
        problems(LINES, json!([["name", 3]])),
        [(format!("{LINES}[0][1]"), "not one of the allowed values".to_owned())]
    );
    assert_eq!(
        problems(BY_KIND, json!({"robot": [["name"]]})),
        [(format!("{BY_KIND}.robot"), "not an allowed name".to_owned())]
    );
    assert_eq!(
        problems(BY_KIND, json!([["name"]])),
        [(BY_KIND.to_owned(), "expected an object".to_owned())]
    );
    assert_eq!(
        problems(BY_AGENT, json!({"claude": "name"})),
        [(format!("{BY_AGENT}.claude"), "expected an array".to_owned())]
    );
    let many: serde_json::Map<String, Value> =
        (0..33).map(|i| (format!("agent{i}"), json!([["name"]]))).collect();
    assert_eq!(
        problems(BY_AGENT, Value::Object(many)),
        [(BY_AGENT.to_owned(), "more than 32 members".to_owned())]
    );
}

#[test]
fn the_reducer_bounds_refuse_with_its_diagnostics() {
    // Three lines.
    assert_eq!(
        problems(LINES, json!([["name"], ["branch"], ["directory"], ["process"]])),
        [(LINES.to_owned(), "more than 3 items".to_owned())]
    );
    // Six text tokens on a line besides the name: the shape cannot count slots apart, the reducer does.
    assert_eq!(
        problems(
            LINES,
            json!([[
                "name",
                "branch",
                "directory",
                "process",
                "ports",
                "log",
                "tabCount",
                "notification"
            ]])
        ),
        [(format!("{LINES}[0][7]"), "tooManyTokens".to_owned())]
    );
    // The name on line one.
    assert_eq!(
        problems(LINES, json!([["branch"], ["name"]])),
        [(format!("{LINES}[1][0]"), "nameMoved".to_owned())]
    );
    // Deduplicated across lines (within a line the shape's uniqueItems says it first).
    assert_eq!(
        problems(LINES, json!([["name", "branch"], ["branch"]])),
        [(format!("{LINES}[1][0]"), "repeated".to_owned())]
    );
    assert_eq!(
        problems(LINES, json!([["name", "name"]])),
        [(format!("{LINES}[0][1]"), "repeated".to_owned())]
    );
    // Each map entry is resolved as the row it is for, and named in `at`.
    assert_eq!(
        problems(BY_KIND, json!({"agent": [["name"]], "terminal": [["branch"], ["name"]]})),
        [(format!("{BY_KIND}.terminal[1][0]"), "nameMoved".to_owned())]
    );
    assert_eq!(
        problems(BY_AGENT, json!({"codex": [["name", "log"], ["log"]]})),
        [(format!("{BY_AGENT}.codex[1][0]"), "repeated".to_owned())]
    );
}

#[test]
fn the_refusal_message_names_the_problem() {
    let Err(refusal) = check(LINES, json!([["branch"], ["name"]])) else { panic!("refused") };
    assert_eq!(refusal.code(), "invalid_params");
    let message = refusal.to_string();
    assert!(message.contains("sidebar.workspaceRow.lines[1][0]: nameMoved"), "{message}");
    assert_eq!(refusal.data()["kind"], json!("json"));
    assert_eq!(refusal.data()["accepted"]["schema"]["maxItems"], json!(3));
}

fn state(text: &str) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

fn op(state: &State, op: Op) -> Result<Option<String>, Refusal> {
    apply(state, op).map(|applied| applied.write)
}

fn meta() -> WriteMeta {
    WriteMeta { origin: Origin::Cli, ..WriteMeta::default() }
}

/// What `cmux settings set` and `settings reset` do: the nested value is stored as written, read
/// back, refused when bad (nothing written), and reset removes the override.
#[test]
fn set_read_back_refuse_and_reset_round_trip() {
    let layout = json!({"claude": [["icon", "name", "working"], ["lastActivity"]]});
    let written = op(
        &state("{}"),
        Op::Set { target: Target::Key(BY_AGENT.into()), value: layout.clone(), meta: meta() },
    )
    .expect("accepted")
    .expect("the file changes");
    let root: Value = serde_json::from_str(&written).expect("JSON");
    assert_eq!(root.pointer("/sidebar/workspaceRow/linesByAgent"), Some(&layout), "{written}");

    let stored = state(&written);
    let row = Schema::embedded().row(BY_AGENT).expect("row");
    assert_eq!(cmux_config::schema::effective_value(row, &root, &Domains::default()), Some(layout));

    let refused = op(
        &stored,
        Op::Set {
            target: Target::Key(BY_AGENT.into()),
            value: json!({"claude": [["log"], ["log"]]}),
            meta: meta(),
        },
    );
    assert!(matches!(refused, Err(Refusal::InvalidValue { .. })), "{refused:?}");

    let reset = op(&stored, Op::Reset { target: Target::Key(BY_AGENT.into()), meta: meta() })
        .expect("reset applies")
        .expect("the file changes");
    let root: Value = serde_json::from_str(&reset).expect("JSON");
    assert_eq!(root.pointer("/sidebar/workspaceRow/linesByAgent"), None, "{reset}");
}

/// A bad value already in the file is not this row's effective value, so readers keep the last
/// good layout (the default: today's switches) until it is fixed.
#[test]
fn a_bad_value_in_the_file_reads_as_unset() {
    let root = json!({"sidebar": {"workspaceRow": {"lines": [["branch"], ["name"]]}}});
    let row = Schema::embedded().row(LINES).expect("row");
    assert_eq!(cmux_config::schema::effective_value(row, &root, &Domains::default()), None);
}
