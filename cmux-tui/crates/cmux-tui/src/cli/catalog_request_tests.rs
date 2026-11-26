//! A catalog request row (`cmux-action-catalog`'s `Action::request`, which the app sends from
//! the command palette with no handler of its own) sends what its CLI verb sends: the same
//! lane, operation and params. So the palette and the CLI cannot drift apart.

use cmux_action_catalog::{Action, ParamSource, RequestLane, actions, request};
use serde_json::{Map, Value, json};

/// A request row's CLI form: the argv that runs it, and the value each of the row's argument
/// (`argument:NAME`) and target (`target:KIND`) sources takes in that argv.
struct Case {
    id: &'static str,
    argv: &'static [&'static str],
    values: Vec<(&'static str, Value)>,
}

/// One case per catalog row with a request (`every_request_row_has_a_cli_case`).
fn cases() -> Vec<Case> {
    vec![
        Case {
            id: "history.removeSite",
            argv: &["history", "remove-site", "example.com"],
            values: vec![("argument:host", json!("example.com"))],
        },
        Case { id: "closed.clear", argv: &["closed", "clear"], values: vec![] },
        Case {
            id: "closed.delete",
            argv: &["closed", "cl_1", "delete"],
            values: vec![("argument:closed", json!("cl_1"))],
        },
        Case { id: "errors.clear", argv: &["errors", "clear"], values: vec![] },
        Case {
            id: "workspace.unpinFromSpace",
            argv: &["room", "unpin", "--workspace", "ws_00000000000000000000000000000004"],
            values: vec![("target:workspace", json!("ws_00000000000000000000000000000004"))],
        },
    ]
}

/// Whether `argv` runs the verb `cli_name`: its words in order (an id may sit between them, as
/// in `closed <id> delete`).
fn runs_verb(argv: &[&str], cli_name: &str) -> bool {
    let mut words = argv.iter();
    cli_name.split(' ').all(|verb| words.any(|word| *word == verb))
}

type Sent = (RequestLane, String, Value);

/// What the CLI sends for `argv`: its lane, operation and params. A verb the CLI resolves
/// with a read first, or one that is not one typed request, is not a request row's verb.
fn sent_by_cli(argv: &[&str]) -> Result<Sent, String> {
    let args: Vec<String> = argv.iter().map(|word| (*word).to_owned()).collect();
    match super::app::parse(&args) {
        Ok(Some(super::app::AppCommand::Call { method, params, .. })) => {
            return Ok((RequestLane::App, method.to_owned(), params));
        }
        Ok(Some(other)) => {
            return Err(format!("`{}` is not one app call: {other:?}", argv.join(" ")));
        }
        Ok(None) => {}
        Err(error) => return Err(format!("`{}`: {}", argv.join(" "), error.0)),
    }
    match super::command::parse(&args, super::Surface::Cmux) {
        Ok(super::command::CommandPlan::Protocol(plan)) => {
            if !plan.resolve.is_empty() {
                return Err(format!("`{}` reads before it sends: give ids", argv.join(" ")));
            }
            let operation = plan.operation.name().map_err(|error| error.0)?;
            Ok((RequestLane::Session, operation, plan.params))
        }
        Ok(_) => Err(format!("`{}` is not one typed request", argv.join(" "))),
        Err(error) => Err(format!("`{}`: {}", argv.join(" "), error.0)),
    }
}

/// What the app sends for `action` with `values`: `request::params`, plus the routing defaults
/// the app's session requests fill as the CLI does (`ResourceRequestEnvelope.wireParams`).
fn sent_by_catalog(action: &Action, values: &[(&str, Value)]) -> Sent {
    let request = action.request.as_ref().expect("a request row");
    let value = |key: String| values.iter().find(|(k, _)| *k == key).map(|(_, v)| v.clone());
    let mut params: Map<String, Value> = request::params(
        request,
        |source| match source {
            ParamSource::Argument(name) => value(format!("argument:{name}")),
            ParamSource::Target(kind) => value(format!("target:{kind}")),
            ParamSource::Constant(_) | ParamSource::IdempotencyKey => {
                unreachable!("resolved by request::params")
            }
        },
        super::cloud_retention::fresh_key,
    );
    if request.lane == RequestLane::Session {
        params.entry("machine").or_insert_with(|| json!("current"));
        params.entry("session").or_insert_with(|| json!("current"));
    }
    (request.lane, request.operation.to_owned(), Value::Object(params))
}

fn drift(action: &Action, case: &Case) -> Option<String> {
    let cli = match sent_by_cli(case.argv) {
        Ok(sent) => sent,
        Err(error) => return Some(format!("{}: {error}", action.id)),
    };
    compare(action, cli, sent_by_catalog(action, &case.values))
}

fn compare(action: &Action, cli: Sent, mut palette: Sent) -> Option<String> {
    for param in action.request.as_ref().unwrap().params {
        if param.source == ParamSource::IdempotencyKey {
            let expected = &cli.2[param.name];
            let actual = &palette.2[param.name];
            if expected.as_str().is_none_or(str::is_empty)
                || actual.as_str().is_none_or(str::is_empty)
            {
                return Some(format!(
                    "{}: missing or empty key {}: CLI {expected}, palette {actual}",
                    action.id, param.name
                ));
            }
            palette.2[param.name] = expected.clone();
        }
    }
    (cli != palette)
        .then(|| format!("{}: the CLI sends {cli:?}, the palette {palette:?}", action.id))
}

#[test]
fn catalog_request_matches_cli() {
    let cases = cases();
    let mut errors = Vec::new();
    for action in actions().filter(|a| a.request.is_some()) {
        let Some(case) = cases.iter().find(|c| c.id == action.id) else {
            errors.push(format!("{}: a request row with no case in cases()", action.id));
            continue;
        };
        if !runs_verb(case.argv, action.cli_name) {
            errors.push(format!("{}: the case does not run `{}`", action.id, action.cli_name));
        }
        errors.extend(drift(action, case));
    }
    for case in &cases {
        if !actions().any(|a| a.id == case.id && a.request.is_some()) {
            errors.push(format!("{}: a case for no request row", case.id));
        }
    }
    assert!(errors.is_empty(), "{errors:#?}");
}

const REMOVE_SITE: Action = Action {
    id: "test.history.removeSite",
    cli_name: "history remove-site",
    request: Some(cmux_action_catalog::Request {
        lane: RequestLane::Session,
        operation: "history.site.remove",
        params: &[cmux_action_catalog::RequestParam {
            name: "host",
            source: ParamSource::Argument("host"),
        }],
    }),
    ..Action::DEFAULT
};

/// The comparison itself: a row that sends what its verb sends passes, and one whose
/// operation, params or lane moved fails.
#[test]
fn a_drifted_row_is_caught() {
    let case = Case {
        id: REMOVE_SITE.id,
        argv: &["history", "remove-site", "example.com"],
        values: vec![("argument:host", json!("example.com"))],
    };
    assert_eq!(drift(&REMOVE_SITE, &case), None);

    let renamed = Action {
        request: Some(cmux_action_catalog::Request {
            operation: "history.site.delete",
            ..REMOVE_SITE.request.unwrap()
        }),
        ..REMOVE_SITE
    };
    assert!(drift(&renamed, &case).is_some(), "an operation the CLI does not send");

    let other_value = Case { values: vec![("argument:host", json!("other.com"))], ..case };
    assert!(drift(&REMOVE_SITE, &other_value).is_some(), "a param the CLI sends otherwise");

    let app = Action {
        request: Some(cmux_action_catalog::Request {
            lane: RequestLane::App,
            ..REMOVE_SITE.request.unwrap()
        }),
        ..REMOVE_SITE
    };
    assert!(drift(&app, &other_value).is_some(), "another lane");

    let errors_clear = Action {
        id: "test.errors.clear",
        cli_name: "errors clear",
        request: Some(cmux_action_catalog::Request {
            lane: RequestLane::App,
            operation: "errors.clear",
            params: &[],
        }),
        ..Action::DEFAULT
    };
    let case = Case { id: errors_clear.id, argv: &["errors", "clear"], values: vec![] };
    assert_eq!(drift(&errors_clear, &case), None, "the app lane");
}

#[test]
fn drift_compares_everything_except_the_generated_key_value() {
    use super::cloud_retention::{Parsed, op_of};

    // The retention CLI uses raw apps-run after identify. Exercise its key here without
    // declaring a typed catalog row for that transport.
    let cli_op = op_of(&Parsed::Archive { machine: "vm-1".into() }, None).unwrap();
    let action = Action {
        request: Some(cmux_action_catalog::Request {
            lane: RequestLane::App,
            operation: "test.archive",
            params: &[
                cmux_action_catalog::RequestParam {
                    name: "machine",
                    source: ParamSource::Argument("machine"),
                },
                cmux_action_catalog::RequestParam {
                    name: "idempotency_key",
                    source: ParamSource::IdempotencyKey,
                },
            ],
        }),
        ..Action::DEFAULT
    };
    let mut cli_params = cli_op.args;
    cli_params["idempotency_key"] = json!(cli_op.idempotency_key.unwrap());
    let cli = (RequestLane::App, "test.archive".into(), cli_params);
    let values = [("argument:machine", json!("vm-1"))];
    let palette = sent_by_catalog(&action, &values);
    let next = sent_by_catalog(&action, &values);
    assert_ne!(palette.2["idempotency_key"], next.2["idempotency_key"]);
    assert_ne!(cli.2["idempotency_key"], palette.2["idempotency_key"]);
    assert_eq!(compare(&action, cli.clone(), palette.clone()), None);
    let mut different = cli.clone();
    different.2["machine"] = json!("vm-2");
    assert!(compare(&action, different, palette.clone()).is_some());
    let mut missing = cli;
    missing.2.as_object_mut().unwrap().remove("idempotency_key");
    assert!(compare(&action, missing, palette).is_some());
}
