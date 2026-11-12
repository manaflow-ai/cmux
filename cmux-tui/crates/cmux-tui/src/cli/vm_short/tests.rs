use serde_json::json;

use super::{Resolved, Short, app_list, cloud_words, misuse, parse, resolve};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn listed() -> serde_json::Value {
    json!({"account": {"signed_in": true}, "machines": [
        {"machine_id": "vm_a1", "title": "dev"},
        {"machine_id": "vm_b2", "title": "build"},
        {"machine_id": "vm_c3", "title": "twin"},
        {"machine_id": "vm_d4", "title": "twin"},
    ]})
}

#[test]
fn a_short_verb_takes_a_name_by_position() {
    let short = parse(&words(&["vm", "pause", "dev"])).unwrap();
    assert_eq!(
        short,
        Short {
            cloud_verb: "pause-machine",
            named: Some("dev".into()),
            targeted: false,
            tail: vec![],
            api_verb: true,
        }
    );
    let resize = parse(&words(&["vm", "resize", "--size", "large", "dev"])).unwrap();
    assert_eq!((resize.cloud_verb, resize.named.as_deref()), ("resize-machine", Some("dev")));
    assert_eq!(resize.tail, words(&["--size", "large"]));
    let rm = parse(&words(&["vm", "rm", "dev", "--confirm"])).unwrap();
    assert_eq!(rm.cloud_verb, "kill-machine");
    assert_eq!(cloud_words(&rm, Some("vm_a1")), words(&["--target", "machine:vm_a1", "--confirm"]));
    let targeted = parse(&words(&["vm", "status", "--target", "machine:vm_a1"])).unwrap();
    assert!(targeted.targeted && targeted.named.is_none());
    // `--target` and its value go to the app as typed, in both spellings.
    assert_eq!(cloud_words(&targeted, None), words(&["--target", "machine:vm_a1"]));
    let inline = parse(&words(&["vm", "pause", "--target=machine:vm_a1"])).unwrap();
    assert!(inline.targeted && inline.named.is_none());
    assert_eq!(cloud_words(&inline, None), words(&["--target=machine:vm_a1"]));
    // `cloud` is `vm`'s old name: the quick start's `cmux cloud pause dev` runs the same verb.
    let old = parse(&words(&["cloud", "pause", "dev"])).unwrap();
    assert_eq!((old.cloud_verb, old.named.as_deref()), ("pause-machine", Some("dev")));
    assert_eq!(parse(&words(&["cloud", "list-machines"])), None);
    assert_eq!(parse(&words(&["vm", "ls"])).unwrap().cloud_verb, "list-machines");
    // Not short verbs, help, two names, or another scope: the old paths run.
    assert_eq!(parse(&words(&["vm", "new"])), None);
    assert_eq!(parse(&words(&["vm", "list-machines"])), None);
    assert_eq!(parse(&words(&["vm", "pause", "--help"])), None);
    assert_eq!(parse(&words(&["vm", "pause", "a", "b"])), None);
    assert_eq!(parse(&words(&["machine", "pause", "dev"])), None);
}

#[test]
fn a_name_is_an_id_or_one_title_and_none_is_the_only_vm() {
    assert_eq!(resolve(Some("dev"), &listed()), Resolved::Id("vm_a1".into()));
    assert_eq!(resolve(Some("vm_b2"), &listed()), Resolved::Id("vm_b2".into()));
    assert_eq!(resolve(Some("machine:vm_b2"), &listed()), Resolved::Id("vm_b2".into()));
    let code = |resolved: Resolved| match resolved {
        Resolved::Refused(error) => {
            assert!(error["details"]["next"].as_str().is_some(), "{error}");
            error["code"].as_str().unwrap().to_owned()
        }
        other => panic!("{other:?}"),
    };
    assert_eq!(code(resolve(Some("twin"), &listed())), "cloud.ambiguous_machine");
    assert_eq!(code(resolve(Some("nope"), &listed())), "cloud.unknown_machine");
    // An id the app does not list goes to the VM API, as before.
    assert_eq!(resolve(Some("vm_zz"), &listed()), Resolved::VmApi);
    // No name: the only VM, else say which to name or how to make one.
    let one = json!({"machines": [{"machine_id": "vm_a1", "title": "dev"}]});
    assert_eq!(resolve(None, &one), Resolved::Id("vm_a1".into()));
    assert_eq!(code(resolve(None, &listed())), "cloud.which_machine");
    // Several VMs: the next step is a command that runs, not a placeholder.
    let Resolved::Refused(several) = resolve(None, &listed()) else { panic!("refused") };
    assert_eq!(several.pointer("/details/next"), Some(&json!("cmux vm ls")));
    assert_eq!(code(resolve(None, &json!({"machines": []}))), "cloud.no_machines");
}

/// #37470's review (d3d894e9 F1, F2): the VM API keeps what it alone can do. An option only it
/// reads takes its route; a verb it has goes there when the app lists no VMs of yours.
#[test]
fn the_vm_api_keeps_its_options_and_its_verbs_without_a_signed_in_app() {
    for typed in [
        &["vm", "ls", "--team", "t"][..],
        &["vm", "ls", "--limit=5"],
        &["vm", "pause", "dev", "--base-url", "https://x"],
        &["cloud", "rm", "--config=/c", "vm_a1"],
    ] {
        assert_eq!(parse(&words(typed)), None, "{typed:?}");
    }
    // After `--`, an option is the verb's text, not the VM API's.
    assert!(parse(&words(&["vm", "rename", "dev", "--", "--team"])).is_some());

    let pause = parse(&words(&["vm", "pause", "vm_abc"])).unwrap();
    let status = parse(&words(&["vm", "status", "dev"])).unwrap();
    assert!(pause.api_verb && !status.api_verb);
    let out = json!({"account": {"signed_in": false}, "machines": []});
    let gone = json!({"code": "app.unreachable", "message": "no app"});
    assert_eq!(app_list(&pause, Ok(out.clone())), Err(None));
    assert_eq!(app_list(&pause, Err(gone.clone())), Err(None));
    let Err(Some(refused)) = app_list(&status, Ok(out)) else { panic!("refused") };
    assert_eq!(refused.get("code"), Some(&json!("cloud.signed_out")));
    assert_eq!(app_list(&status, Err(gone.clone())), Err(Some(gone)));
    assert_eq!(app_list(&pause, Ok(listed())), Ok(listed()));
}

/// #37470's review at 4942a86a (F1): an app that has not loaded its VMs, or is still making
/// one, says to retry; it never says you have none, nor sends a `vm_…` id to the VM API.
#[test]
fn an_unloaded_list_or_a_vm_being_made_is_a_retry() {
    let unloaded = json!({"account": {"signed_in": true}, "loaded": false, "machines": []});
    for named in [None, Some("dev"), Some("vm_abc")] {
        let Resolved::Refused(error) = resolve(named, &unloaded) else { panic!("{named:?}") };
        assert_eq!(error.get("code"), Some(&json!("cloud.not_loaded")), "{named:?}");
        assert_eq!(error.get("retryable"), Some(&json!(true)));
    }
    let making =
        json!({"machines": [], "creating": [{"creation_id": "c-1", "status": "creating"}]});
    let Resolved::Refused(error) = resolve(None, &making) else { panic!("making") };
    assert_eq!(error.get("code"), Some(&json!("cloud.vm_starting")));
    assert_eq!(error.get("retryable"), Some(&json!(true)));
    let failed = json!({"machines": [], "creating": [{"creation_id": "c-1", "status": "failed"}]});
    let Resolved::Refused(error) = resolve(None, &failed) else { panic!("failed") };
    assert_eq!(error.get("code"), Some(&json!("cloud.no_machines")));
}

/// F2: `ls` lists every VM, so a name is a mistake, not a filter that is dropped.
#[test]
fn ls_takes_no_name_and_a_vm_is_named_one_way() {
    let ls = |typed: &[&str]| misuse(&parse(&words(typed)).unwrap());
    assert!(ls(&["vm", "ls", "typo"]).is_some());
    assert!(ls(&["vm", "pause", "dev", "--target", "machine:vm_a1"]).is_some());
    assert_eq!(ls(&["vm", "ls"]), None);
    assert_eq!(ls(&["vm", "ls", "--json"]), None);
    assert_eq!(ls(&["vm", "pause", "dev"]), None);
}

/// Leo, 2026-11-08: "how would I be able to shut it down?" `vm shutdown` is `vm pause`, with the
/// app and without it; `vm stop` stays the VM API's own verb.
#[test]
fn shutdown_is_pause() {
    let shutdown = parse(&words(&["vm", "shutdown", "dev"])).unwrap();
    let pause = parse(&words(&["vm", "pause", "dev"])).unwrap();
    assert_eq!(shutdown, pause);
    assert_eq!(parse(&words(&["cloud", "shutdown"])).unwrap().cloud_verb, "pause-machine");
    assert_eq!(parse(&words(&["vm", "stop", "dev"])), None);
}
