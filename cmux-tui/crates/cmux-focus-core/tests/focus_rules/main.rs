//! The focus rules that moved from the macOS app's Swift into this crate
//! (rust-migration backlog A12), with their Swift tests ported: the close
//! successor of every kind (`FocusAfterClose`, its opener tests, its
//! exhaustive model check and the closefocus.tla cases), the Close Tab aim
//! (`PaneCloseAim`), the per-tab address bar memory (`OmnibarFocusMemory`)
//! and the input invariants (`InputInvariants`). Run them alone with the
//! test-name filter `ported::`.

mod ported {
    mod close_aim;
    mod close_successor;
    mod closefocus_tla;
    mod input_invariants;
    mod model_check;
    mod omnibar_memory;
}
