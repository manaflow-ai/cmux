use serde_json::json;

use super::{Resolved, Short, cloud_words, parse, resolve};

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
            tail: vec![]
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
    assert_eq!(code(resolve(None, &json!({"machines": []}))), "cloud.no_machines");
}
