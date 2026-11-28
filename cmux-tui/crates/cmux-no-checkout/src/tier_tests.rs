use super::*;

fn task(github_repo: bool, folder: Option<Folder>, run: Run) -> Task {
    Task { github_repo, folder, run, projection_served: true }
}

const BIG_LOCAL: Folder = Folder { local_work: true, past_copy_limits: true };
const SMALL_LOCAL: Folder = Folder { local_work: true, past_copy_limits: false };
const CLEAN: Folder = Folder { local_work: false, past_copy_limits: true };
const ONE_TEST: Run = Run::Paths { files: 21, bytes: 600_000 };

#[test]
fn a_small_task_on_a_github_repository_has_no_checkout() {
    for run in [Run::Nothing, ONE_TEST] {
        assert_eq!(choose(&task(true, None, run)).tier, Tier::NoCheckout, "{run:?}");
    }
    // A clean folder whose work GitHub already has changes nothing: GitHub is the source.
    assert_eq!(choose(&task(true, Some(CLEAN), ONE_TEST)).tier, Tier::NoCheckout);
}

#[test]
fn a_whole_tree_run_or_a_projection_as_big_as_a_clone_is_a_checkout() {
    assert_eq!(choose(&task(true, None, Run::WholeTree)).tier, Tier::Checkout);
    assert_eq!(choose(&task(true, Some(CLEAN), Run::WholeTree)).tier, Tier::Checkout);
    let many = Run::Paths { files: PROJECT_MAX_FILES + 1, bytes: 1 };
    let big = Run::Paths { files: 1, bytes: PROJECT_MAX_BYTES + 1 };
    let at = Run::Paths { files: PROJECT_MAX_FILES, bytes: PROJECT_MAX_BYTES };
    assert_eq!(choose(&task(true, None, many)).tier, Tier::Checkout);
    assert_eq!(choose(&task(true, None, big)).tier, Tier::Checkout);
    assert_eq!(choose(&task(true, None, at)).tier, Tier::NoCheckout);
}

#[test]
fn work_only_the_mac_holds_is_projected_when_big_and_copied_when_small() {
    for github_repo in [true, false] {
        for run in [Run::Nothing, ONE_TEST, Run::WholeTree] {
            let big = choose(&task(github_repo, Some(BIG_LOCAL), run));
            assert_eq!(big.tier, Tier::Projection, "{github_repo} {run:?}");
            let small = choose(&task(github_repo, Some(SMALL_LOCAL), run));
            assert_eq!(small.tier, Tier::Checkout, "{github_repo} {run:?}");
        }
    }
    // A folder with no GitHub remote is the Mac's own work even when "clean".
    assert_eq!(choose(&task(false, Some(CLEAN), Run::Nothing)).tier, Tier::Projection);
}

#[test]
fn a_machine_without_projection_copies_the_big_folder() {
    let mut t = task(true, Some(BIG_LOCAL), ONE_TEST);
    t.projection_served = false;
    assert_eq!(choose(&t).tier, Tier::Checkout);
}

#[test]
fn nothing_to_read_from_is_a_checkout_and_every_choice_says_why() {
    assert_eq!(choose(&task(false, None, Run::Nothing)).tier, Tier::Checkout);
    for github_repo in [true, false] {
        for folder in [None, Some(BIG_LOCAL), Some(SMALL_LOCAL), Some(CLEAN)] {
            for run in [Run::Nothing, ONE_TEST, Run::WholeTree] {
                let choice = choose(&task(github_repo, folder, run));
                assert!(!choice.why.is_empty());
            }
        }
    }
}
