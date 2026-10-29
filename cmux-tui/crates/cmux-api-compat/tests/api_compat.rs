//! Behavior tests for cmux-api-compat. Every test name contains `api_compat`
//! so `scripts/ci/cmux-tui-focused-test.sh api_compat` selects them.
//!
//! Translation vectors (an input, a rule chain, the output or refusal) live in
//! `cmux-tui/spec/api-compat-fixtures.json` (`vectors`), not here: api-compat-check
//! reads the same file. Tests here cover what a vector cannot
//! say: borrowing, caching, broadcast counts, the handshake and properties.

mod api_compat {
    use std::sync::Arc;

    use cmux_api_compat::handshake::{RevisionHello, Translator, negotiate};
    use cmux_api_compat::{Change, Compat, MessageChange, Schema};

    const KIND: &str = "event:workspace";

    fn mc(change: Change) -> MessageChange {
        MessageChange { message: KIND.into(), change }
    }

    fn compat(revisions: Vec<Vec<Change>>) -> Compat {
        let mut schema = Schema::new("test", 1);
        for changes in revisions {
            schema.push("", changes.into_iter().map(mc).collect());
        }
        Compat::new(schema).unwrap()
    }

    fn tr(c: &Compat, from: u32, to: u32, input: &str) -> String {
        String::from_utf8(c.translate(KIND, from, to, input.as_bytes()).unwrap().into_owned())
            .unwrap()
    }

    fn rename(path: &str, to: &str) -> Change {
        Change::Rename { path: path.into(), to: to.into() }
    }

    #[test]
    fn api_compat_identity_chain_borrows_the_input() {
        let c = compat(vec![vec![]]);
        let input = br#"{"a":1}"#;
        assert!(matches!(c.translate(KIND, 1, 2, input).unwrap(), std::borrow::Cow::Borrowed(_)));
        assert!(matches!(
            c.translate("event:other", 1, 2, input).unwrap(),
            std::borrow::Cow::Borrowed(_)
        ));
    }

    #[test]
    fn api_compat_programs_are_cached_and_equal_chains_interned() {
        // Revision 3 does not touch KIND, so 1->2 and 1->3 are the same chain.
        let mut schema = Schema::new("test", 1);
        schema.push("", vec![mc(rename("/a", "b"))]);
        schema.push(
            "",
            vec![MessageChange { message: "event:other".into(), change: rename("/x", "y") }],
        );
        let c = Compat::new(schema).unwrap();
        let p12 = c.program(KIND, 1, 2).unwrap();
        let p13 = c.program(KIND, 1, 3).unwrap();
        assert!(Arc::ptr_eq(&p12, &p13));
        assert!(Arc::ptr_eq(&p12, &c.program(KIND, 1, 2).unwrap()));
        assert!(!Arc::ptr_eq(&p12, &c.program(KIND, 2, 1).unwrap()));
    }

    #[test]
    fn api_compat_broadcast_translates_once_per_distinct_chain() {
        let c = compat(vec![vec![rename("/a", "b")], vec![], vec![rename("/b", "c")]]);
        // Message written at rev 4; peers at revs 1, 2, 3 and 4.
        let mut broadcast = c.broadcast(KIND, 4, br#"{"c":1}"#);
        let mut outputs = Vec::new();
        for i in 0..100u32 {
            outputs.push(broadcast.for_peer(1 + i % 4).unwrap());
        }
        // rev 2 and rev 3 share a chain; rev 4 is identity: 2 rewrites in total.
        assert_eq!(broadcast.translations(), 2);
        assert_eq!(&*outputs[0], br#"{"a":1}"#);
        assert_eq!(&*outputs[1], br#"{"b":1}"#);
        assert_eq!(&*outputs[2], br#"{"b":1}"#);
        assert_eq!(&*outputs[3], br#"{"c":1}"#);
    }

    #[test]
    fn api_compat_ten_thousand_rename_chain_collapses_to_one_member() {
        let mut changes = vec![vec![rename("/w/*/name", "n1")]];
        for k in 2..=10_000 {
            changes.push(vec![rename(&format!("/w/*/n{}", k - 1), &format!("n{k}"))]);
        }
        let c = compat(changes);
        let program = c.program(KIND, 1, 10_001).unwrap();
        assert!(program.trie_size() <= 4, "trie has {} nodes", program.trie_size());
        assert_eq!(tr(&c, 1, 10_001, r#"{"w":[{"name":1}]}"#), r#"{"w":[{"n10000":1}]}"#);
        assert_eq!(tr(&c, 10_001, 1, r#"{"w":[{"n10000":1}]}"#), r#"{"w":[{"name":1}]}"#);
    }

    #[test]
    fn api_compat_schema_round_trips_through_json() {
        let text = r#"{"protocol":"cmux-mux","base":12,"revisions":[{"rev":13,"note":"n","changes":[
            {"message":"event:bell","op":"rename","path":"/surface","to":"tab"},
            {"message":"request:ping","op":"retype","path":"/n","up":{"kind":"number_to_string"},"down":{"kind":"string_to_number"}},
            {"message":"request:ping","op":"fill","path":"/m","default":0,"direction":"up"}]}]}"#;
        let schema = Schema::from_json(text.as_bytes()).unwrap();
        assert_eq!(schema.current(), 13);
        assert!(
            Schema::from_json(br#"{"protocol":"p","base":1,"revisions":[{"rev":3}]}"#).is_err()
        );
        assert!(Schema::from_json(br#"{"protocol":"p","base":1,"revisions":[{"rev":2,"changes":[{"message":"m","op":"rename","path":"","to":"x"}]}]}"#).is_err());
    }

    #[test]
    fn api_compat_handshake_picks_the_newer_side() {
        let hello =
            |api_revision, min_api_revision| RevisionHello { api_revision, min_api_revision };
        let n = negotiate(hello(14, 12), Some(hello(12, 12)), 12).unwrap();
        assert_eq!(n.translator, Translator::Us);
        let n = negotiate(hello(12, 12), Some(hello(14, 12)), 12).unwrap();
        assert_eq!(n.translator, Translator::Peer);
        assert_eq!(negotiate(hello(13, 12), None, 12).unwrap().peer, 12);
        assert_eq!(
            negotiate(hello(13, 12), Some(hello(13, 13)), 12).unwrap().translator,
            Translator::Nobody
        );
        assert!(negotiate(hello(20, 15), Some(hello(12, 12)), 12).is_err());

        // End to end: old client, new server; the server translates both ways.
        let c = compat(vec![vec![rename("/name", "title")]]);
        let n = negotiate(RevisionHello::ours(&c), Some(hello(1, 1)), 1).unwrap();
        assert_eq!(&*n.outgoing(&c, KIND, br#"{"title":"x"}"#).unwrap(), br#"{"name":"x"}"#);
        assert_eq!(&*n.incoming(&c, KIND, br#"{"name":"x"}"#).unwrap(), br#"{"title":"x"}"#);
    }

    mod coverage {
        use cmux_api_compat::coverage::{
            Snapshot, Verdict, breaking_changes, check, surface_from_sdk_schema,
        };
        use cmux_api_compat::{Change, MessageChange, Schema};
        use serde_json::{Value, json};

        fn sdk(fields: Value, event_fields: Value) -> Value {
            json!({
                "types": {"Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}},
                          "State": {"kind": "enum", "values": ["idle", "busy"]}},
                "commands": {"rename-tab": {"request": {"kind": "object", "fields": fields},
                                            "result": {"kind": "object", "fields": {}}}},
                "events": {"tab": {"payload": {"kind": "object", "fields": event_fields}}}
            })
        }

        fn field(ty: Value, required: bool) -> Value {
            json!({"type": ty, "presence": if required {"required"} else {"optional"}, "nullable": false})
        }

        fn base() -> Value {
            sdk(
                json!({"tab": field(json!({"kind": "ref", "name": "Id"}), true),
                       "title": field(json!({"kind": "scalar", "name": "string"}), false)}),
                json!({"tab": field(json!({"kind": "ref", "name": "Id"}), true),
                       "state": field(json!({"kind": "ref", "name": "State"}), true)}),
            )
        }

        #[test]
        fn api_compat_coverage_flattens_requests_and_events() {
            let surface = surface_from_sdk_schema(&base());
            assert_eq!(surface["request:rename-tab"]["/tab"].ty, "uint64");
            assert!(surface["request:rename-tab"]["/tab"].required);
            assert_eq!(surface["event:tab"]["/state"].values.len(), 2);
        }

        #[test]
        fn api_compat_coverage_additive_changes_are_not_breaks() {
            let old = surface_from_sdk_schema(&base());
            let mut new_sdk = base();
            new_sdk["commands"]["rename-tab"]["request"]["fields"]["color"] =
                field(json!({"kind": "scalar", "name": "string"}), false);
            new_sdk["events"]["tab"]["payload"]["fields"]["pinned"] =
                field(json!({"kind": "scalar", "name": "bool"}), true);
            assert!(breaking_changes(&old, &surface_from_sdk_schema(&new_sdk)).is_empty());
        }

        #[test]
        fn api_compat_coverage_breaks_need_rules() {
            let old = surface_from_sdk_schema(&base());
            let mut new_sdk = base();
            let fields = new_sdk["events"]["tab"]["payload"]["fields"].as_object_mut().unwrap();
            let tab = fields.remove("tab").unwrap();
            fields.insert("surface".into(), tab);
            new_sdk["types"]["State"]["values"] = json!(["idle", "busy", "done"]);
            new_sdk["commands"]["rename-tab"]["request"]["fields"]["title"]["presence"] =
                json!("required");
            let new = surface_from_sdk_schema(&new_sdk);
            let breaks = breaking_changes(&old, &new);
            let paths: Vec<_> =
                breaks.iter().map(|b| format!("{} {}", b.message, b.path)).collect();
            assert_eq!(
                paths,
                vec!["event:tab /state", "event:tab /tab", "request:rename-tab /title"],
                "{breaks:?}"
            );

            let snapshot = Snapshot { revision: 12, surface: old };
            let mut schema = Schema::new("cmux-mux", 12);
            assert!(
                matches!(check(&snapshot, &new, &schema), Verdict::Uncovered(m) if m.len() == 3)
            );
            schema.push(
                "tab is surface; done state; title required",
                vec![
                    MessageChange {
                        message: "event:tab".into(),
                        change: Change::Rename { path: "/tab".into(), to: "surface".into() },
                    },
                    MessageChange {
                        message: "event:tab".into(),
                        change: Change::RenameValue {
                            path: "/state".into(),
                            from: json!("busy"),
                            to: json!("done"),
                        },
                    },
                    MessageChange {
                        message: "request:rename-tab".into(),
                        change: Change::Fill {
                            path: "/title".into(),
                            default: json!(""),
                            direction: cmux_api_compat::Direction::Up,
                        },
                    },
                ],
            );
            assert!(matches!(check(&snapshot, &new, &schema), Verdict::StaleSnapshot { .. }));
            let fresh = Snapshot { revision: 13, surface: new.clone() };
            assert_eq!(check(&fresh, &new, &schema), Verdict::Clean);
        }

        #[test]
        fn api_compat_coverage_real_daemon_schema_matches_snapshot() {
            let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec");
            let sdk: Value =
                serde_json::from_slice(&std::fs::read(root.join("sdk-schema.json")).unwrap())
                    .unwrap();
            let schema =
                Schema::from_json(&std::fs::read(root.join("api-compat.json")).unwrap()).unwrap();
            let snapshot: Snapshot = serde_json::from_slice(
                &std::fs::read(root.join("api-compat.surface.json")).unwrap(),
            )
            .unwrap();
            let surface = surface_from_sdk_schema(&sdk);
            assert!(surface.len() > 300, "flattened {} message kinds", surface.len());
            assert_eq!(
                check(&snapshot, &surface, &schema),
                Verdict::Clean,
                "run api-compat-check --write"
            );
        }
    }

    mod fixtures {
        use std::collections::BTreeSet;

        use cmux_api_compat::fixtures::{
            Case, ErrorKind, Expect, Fixtures, Outcome, Translation, Vector, check_fixtures,
            check_vectors,
        };
        use cmux_api_compat::{Change, MessageChange, Schema};
        use serde_json::json;

        fn schema() -> Schema {
            let mut schema = Schema::new("cmux-mux", 12);
            schema.push(
                "tab is surface",
                vec![MessageChange {
                    message: "event:tab".into(),
                    change: Change::Rename { path: "/tab".into(), to: "surface".into() },
                }],
            );
            schema
        }

        fn case(from: u32, to: u32, input: serde_json::Value, output: serde_json::Value) -> Case {
            Case { message: "event:tab".into(), from, to, input, output }
        }

        #[test]
        fn api_compat_fixtures_every_rule_needs_both_directions() {
            let up = case(12, 13, json!({"tab": 1}), json!({"surface": 1}));
            let down = case(13, 12, json!({"surface": 1}), json!({"tab": 1}));
            let only_up = Fixtures { cases: vec![up.clone()], vectors: Vec::new() };
            let problems = check_fixtures(&schema(), &only_up);
            assert_eq!(problems.len(), 1, "{problems:?}");
            assert!(problems[0].contains("downgrade"), "{problems:?}");
            let both = Fixtures { cases: vec![up, down], vectors: Vec::new() };
            assert!(check_fixtures(&schema(), &both).is_empty());
        }

        #[test]
        fn api_compat_fixtures_wrong_output_is_reported() {
            let wrong = Fixtures {
                cases: vec![
                    case(12, 13, json!({"tab": 1}), json!({"tab": 1})),
                    case(13, 12, json!({"surface": 1}), json!({"tab": 1})),
                ],
                vectors: Vec::new(),
            };
            let problems = check_fixtures(&schema(), &wrong);
            assert_eq!(problems.len(), 1, "{problems:?}");
            assert!(problems[0].starts_with("case 0"), "{problems:?}");
        }

        #[test]
        fn api_compat_fixtures_real_spec_files_agree() {
            let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec");
            let schema =
                Schema::from_json(&std::fs::read(root.join("api-compat.json")).unwrap()).unwrap();
            let fixtures: Fixtures = serde_json::from_slice(
                &std::fs::read(root.join("api-compat-fixtures.json")).unwrap(),
            )
            .unwrap();
            assert_eq!(check_fixtures(&schema, &fixtures), Vec::<String>::new());
        }

        fn spec_fixtures() -> Fixtures {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../spec/api-compat-fixtures.json");
            serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
        }

        /// The translator's behavior vectors live in the spec file, which
        /// api-compat-check also reads.
        #[test]
        fn api_compat_fixtures_spec_vectors_pass() {
            let fixtures = spec_fixtures();
            assert_eq!(check_vectors(&fixtures), Vec::<String>::new());
        }

        /// Every rule op, both refusals a message can get, and both output
        /// forms keep a vector, so the file cannot lose a behavior unnoticed.
        #[test]
        fn api_compat_fixtures_spec_vectors_cover_every_rule_and_refusal() {
            let fixtures = spec_fixtures();
            let mut ops = BTreeSet::new();
            let mut expects = BTreeSet::new();
            for vector in &fixtures.vectors {
                for revision in &vector.translation.schema.revisions {
                    for change in &revision.changes {
                        ops.insert(
                            serde_json::to_value(&change.change).unwrap()["op"]
                                .as_str()
                                .unwrap()
                                .to_owned(),
                        );
                    }
                }
                expects.insert(
                    match &vector.expect {
                        Expect::Bytes(_) => json!("bytes"),
                        Expect::Json(_) => json!("json"),
                        Expect::Error(kind) => json!(kind),
                    }
                    .to_string(),
                );
            }
            assert_eq!(
                ops.into_iter().collect::<Vec<_>>(),
                ["add", "fill", "move", "remove", "rename", "rename_value", "retype"],
                "rule ops with a vector"
            );
            assert_eq!(
                expects.into_iter().collect::<Vec<_>>(),
                [r#""bytes""#, r#""json""#, r#""malformed""#, r#""unsupported_revision""#],
                "expectations with a vector"
            );
        }

        fn vector(id: &str, input: &str, expect: Expect) -> Vector {
            Vector {
                id: id.into(),
                title: "t".into(),
                translation: Translation {
                    schema: schema(),
                    message: "event:tab".into(),
                    from: 12,
                    to: 13,
                    input: input.into(),
                },
                expect,
            }
        }

        #[test]
        fn api_compat_fixtures_wrong_vectors_are_reported() {
            let good = vector("good", r#"{"tab":1}"#, Expect::Bytes(r#"{"surface":1}"#.into()));
            let fixtures = Fixtures {
                cases: Vec::new(),
                vectors: vec![
                    good.clone(),
                    good,
                    vector("wrong-bytes", r#"{"tab":1}"#, Expect::Bytes(r#"{"tab":1}"#.into())),
                    vector("wrong-json", r#"{"tab":1}"#, Expect::Json(json!({"tab": 1}))),
                    vector("wrong-refusal", "{", Expect::Error(ErrorKind::UnsupportedRevision)),
                    vector("no-refusal", r#"{"tab":1}"#, Expect::Error(ErrorKind::Malformed)),
                    vector("Not-A-Slug", "{}", Expect::Json(json!({}))),
                ],
            };
            let problems = check_vectors(&fixtures);
            let heads: Vec<_> =
                problems.iter().map(|p| p.split(':').next().unwrap_or_default()).collect();
            assert_eq!(
                heads,
                [
                    "vector good",
                    "vector wrong-bytes",
                    "vector wrong-json",
                    "vector wrong-refusal",
                    "vector no-refusal",
                    r#"vector "Not-A-Slug""#,
                ],
                "{problems:?}"
            );
            assert!(problems[0].ends_with("the id repeats"), "{problems:?}");
        }

        /// The outcome's wire form.
        #[test]
        fn api_compat_fixtures_outcome_wire_form() {
            let ok = vector("ok", r#"{"tab":1}"#, Expect::Json(json!({})));
            assert_eq!(
                serde_json::to_value(ok.translation.run()).unwrap(),
                json!({"output": r#"{"surface":1}"#})
            );
            let refused = vector("refused", r#"{"tab":"#, Expect::Json(json!({})));
            let outcome = serde_json::to_value(refused.translation.run()).unwrap();
            assert_eq!(outcome["error"]["kind"], json!("malformed"), "{outcome}");
            assert!(outcome["error"]["message"].as_str().is_some_and(|m| m.contains("malformed")));
            assert!(matches!(
                serde_json::from_value::<Outcome>(outcome).unwrap(),
                Outcome::Error { kind: ErrorKind::Malformed, .. }
            ));
        }
    }

    mod properties {
        use cmux_api_compat::{Change, Compat, Conversion, MessageChange, Schema};
        use proptest::prelude::*;
        use serde_json::{Map, Value, json};

        const KEYS: [&str; 5] = ["a", "b", "c", "d", "e"];

        fn doc() -> impl Strategy<Value = Value> {
            let leaf = prop_oneof![
                Just(Value::Null),
                any::<bool>().prop_map(Value::Bool),
                (-50i64..50).prop_map(Value::from),
                "[a-z0-9]{0,3}".prop_map(Value::String),
                Just(json!("12")),
            ];
            leaf.prop_recursive(4, 40, 5, |inner| {
                prop_oneof![
                    prop::collection::vec(inner.clone(), 0..4).prop_map(Value::Array),
                    prop::collection::vec((0..KEYS.len(), inner), 0..5).prop_map(|members| {
                        let mut map = Map::new();
                        for (k, v) in members {
                            map.insert(KEYS[k].to_owned(), v);
                        }
                        Value::Object(map)
                    }),
                ]
            })
        }

        /// A token: a schema key, a wildcard, or a name made by an earlier rule.
        fn token(seed: u32, fresh_so_far: u32) -> String {
            match seed % 8 {
                0 | 1 => "*".to_owned(),
                2 if fresh_so_far > 0 => format!("r{}", seed % fresh_so_far),
                _ => KEYS[(seed as usize / 8) % KEYS.len()].to_owned(),
            }
        }

        fn path(seeds: &[u32], fresh_so_far: u32, last_not_wild: bool) -> String {
            let mut out = String::new();
            for (i, seed) in seeds.iter().enumerate() {
                let mut t = token(*seed, fresh_so_far);
                if last_not_wild && i == seeds.len() - 1 && t == "*" {
                    t = KEYS[*seed as usize % KEYS.len()].to_owned();
                }
                out.push('/');
                out.push_str(&t);
            }
            out
        }

        fn conversion(seed: u32) -> (Conversion, Conversion) {
            match seed % 5 {
                0 => (Conversion::NumberToString, Conversion::StringToNumber),
                1 => (Conversion::Wrap, Conversion::Unwrap),
                2 => (Conversion::Nest { key: "v".into() }, Conversion::Unnest { key: "v".into() }),
                3 => (Conversion::BoolToNumber, Conversion::NumberToBool),
                _ => (Conversion::StringToNumber, Conversion::NumberToString),
            }
        }

        /// One rule; renames and moves always target a fresh name `r<n>`.
        fn make_change(kind: u32, seeds: &[u32], n: u32, all_kinds: bool) -> Change {
            let depth = (seeds[0] % 3 + 1) as usize;
            let p = |last_not_wild| path(&seeds[1..=depth], n, last_not_wild);
            let fresh = format!("r{n}");
            match kind % if all_kinds { 7 } else { 4 } {
                0 => Change::Rename { path: p(true), to: fresh },
                1 => Change::Add {
                    path: format!("{}/{fresh}", path(&seeds[1..depth], n, false)),
                    default: json!(n),
                },
                2 => Change::RenameValue {
                    path: p(false),
                    from: json!(seeds[5] as i64 % 50 - 25),
                    to: json!(format!("~v{n}")),
                },
                3 => {
                    let (up, down) = conversion(seeds[6]);
                    // Wrap/Unwrap and Nest/Unnest invert exactly; the scalar pairs only on matching types.
                    let (up, down) = if matches!(up, Conversion::Wrap | Conversion::Nest { .. }) {
                        (up, down)
                    } else {
                        (Conversion::Wrap, Conversion::Unwrap)
                    };
                    Change::Retype { path: p(false), up, down }
                }
                4 => Change::Remove { path: p(true), default: json!(n) },
                5 => {
                    let (up, down) = conversion(seeds[6]);
                    Change::Retype { path: p(false), up, down }
                }
                _ => {
                    let from = p(true);
                    let mut tokens: Vec<String> =
                        from.split('/').skip(1).map(str::to_owned).collect();
                    let keep = (seeds[7] as usize) % tokens.len();
                    tokens.truncate(keep);
                    let extra = seeds[8] % 2;
                    let mut to = String::new();
                    for t in &tokens {
                        to.push('/');
                        to.push_str(t);
                    }
                    if extra == 1 {
                        to.push_str(&format!("/{}", KEYS[seeds[9] as usize % KEYS.len()]));
                    }
                    to.push_str(&format!("/{fresh}"));
                    // Wildcards must sit in the shared prefix; fall back to a rename otherwise.
                    let shared = tokens.len();
                    let from_tokens: Vec<&str> = from.split('/').skip(1).collect();
                    let nested = to.starts_with(&format!("{from}/"));
                    if nested || from_tokens[shared..].contains(&"*") {
                        Change::Rename { path: from, to: format!("r{n}") }
                    } else {
                        Change::Move { from, path: to }
                    }
                }
            }
        }

        fn chain(all_kinds: bool) -> impl Strategy<Value = Vec<Change>> {
            prop::collection::vec((any::<u32>(), prop::collection::vec(0u32..1000, 10)), 1..25)
                .prop_map(move |rules| {
                    rules
                        .into_iter()
                        .enumerate()
                        .map(|(n, (kind, seeds))| make_change(kind, &seeds, n as u32, all_kinds))
                        .collect()
                })
        }

        fn build(changes: &[Change]) -> Compat {
            let mut schema = Schema::new("prop", 0);
            for change in changes {
                schema
                    .push("", vec![MessageChange { message: "m".into(), change: change.clone() }]);
            }
            Compat::new(schema).expect("generated changes are valid")
        }

        proptest! {
            #![proptest_config(ProptestConfig { cases: 2000, ..ProptestConfig::default() })]

            /// The streaming rewrite equals applying the chain rule by rule,
            /// in both directions, for compact and pretty-printed input.
            #[test]
            fn api_compat_streaming_matches_reference(doc in doc(), changes in chain(true), split in 0usize..30) {
                let compat = build(&changes);
                let top = compat.current();
                let cut = (split as u32).min(top);
                for (from, to) in [(0, top), (top, 0), (cut, top), (top, cut), (0, cut)] {
                    let program = compat.program("m", from, to).unwrap();
                    let mut expected = doc.clone();
                    program.apply_reference(&mut expected);
                    for bytes in [serde_json::to_vec(&doc).unwrap(), serde_json::to_vec_pretty(&doc).unwrap()] {
                        let out = program.rewrite(&bytes).unwrap();
                        let got: Value = serde_json::from_slice(&out).unwrap();
                        prop_assert_eq!(&got, &expected, "from {} to {} changes {:?}", from, to, changes);
                    }
                }
            }

            /// Upgrading then downgrading returns the original document for
            /// exactly invertible chains (renames, adds of new members,
            /// enum renames to new values, wrap/nest retypes).
            #[test]
            fn api_compat_upgrade_then_downgrade_round_trips(doc in doc(), changes in chain(false)) {
                let compat = build(&changes);
                let top = compat.current();
                let bytes = serde_json::to_vec(&doc).unwrap();
                let up = compat.translate("m", 0, top, &bytes).unwrap().into_owned();
                let down = compat.translate("m", top, 0, &up).unwrap();
                let got: Value = serde_json::from_slice(&down).unwrap();
                prop_assert_eq!(got, doc, "changes {:?}", changes);
            }

            /// Arbitrary bytes never panic the editor.
            #[test]
            fn api_compat_garbage_never_panics(bytes in prop::collection::vec(any::<u8>(), 0..200), changes in chain(true)) {
                let compat = build(&changes);
                let _ = compat.translate("m", 0, compat.current(), &bytes);
                let _ = compat.translate("m", compat.current(), 0, &bytes);
            }
        }
    }

    /// Wire id rules.
    mod wire;
}
