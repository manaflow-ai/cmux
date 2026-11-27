use super::*;

fn spec(
    preset: Preset,
    context: Context,
    worktree: Worktree,
    machine: Machine,
    inbox: Inbox,
    owner: Owner,
) -> ForkSpec {
    ForkSpec { preset, context, worktree, machine, inbox, budget: Budget::Parent, owner }
}

#[test]
fn each_preset_is_what_its_path_does_today() {
    use Context as C;
    use Machine as M;
    use Worktree as W;
    let want = [
        spec(Preset::Chat, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
        spec(Preset::ChatThrough, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
        spec(Preset::Retarget, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
        spec(Preset::SubagentFork, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
        spec(Preset::Subsession, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Parent),
        spec(Preset::TerminalChat, C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
        spec(Preset::CloudPlace, C::None, W::Branch, M::Fork, Inbox::Own, Owner::Own),
        spec(Preset::SubVm, C::None, W::Branch, M::Fork, Inbox::Parent, Owner::Parent),
        spec(Preset::ForkRun, C::None, W::Branch, M::Fork, Inbox::Own, Owner::Own),
        spec(Preset::HarnessSubagent, C::Share, W::Share, M::Same, Inbox::Parent, Owner::Parent),
    ];
    for w in want {
        assert_eq!(ForkSpec::preset(w.preset), w, "{:?}", w.preset);
    }
}

#[test]
fn a_hub_fork_picks_its_preset_by_what_the_request_is() {
    assert_eq!(ForkSpec::hub(false, false, false, false).preset, Preset::Chat);
    assert_eq!(ForkSpec::hub(false, false, false, true).preset, Preset::ChatThrough);
    assert_eq!(ForkSpec::hub(false, false, true, false).preset, Preset::Retarget);
    assert_eq!(ForkSpec::hub(false, true, false, false).preset, Preset::SubagentFork);
    // A sub-session is the parent's child whatever else the request says.
    assert_eq!(ForkSpec::hub(true, false, false, true).preset, Preset::Subsession);
}

#[test]
fn the_logged_spec_reads_as_the_rfd_writes_it() {
    let v = serde_json::to_value(ForkSpec::preset(Preset::SubVm)).unwrap();
    assert_eq!(
        v,
        serde_json::json!({
            "preset": "sub_vm", "context": "none", "worktree": "branch", "machine": "fork",
            "inbox": "parent", "budget": {"kind": "parent"}, "owner": "parent",
        })
    );
    let own = serde_json::to_value(ForkSpec::preset(Preset::Chat)).unwrap();
    assert_eq!(own["owner"], "self");
    let carve = ForkSpec { budget: Budget::Carve(2_000_000), ..ForkSpec::preset(Preset::Chat) };
    let back: ForkSpec = serde_json::from_value(serde_json::to_value(carve).unwrap()).unwrap();
    assert_eq!(back, carve);
    assert_eq!(
        serde_json::to_value(carve).unwrap()["budget"],
        serde_json::json!({"kind": "carve", "tokens": 2_000_000})
    );
}
