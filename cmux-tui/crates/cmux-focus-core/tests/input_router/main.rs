//! The input router's tests (handoff/rewrites/R-INPUT/DESIGN.md, stages S1a
//! and S1b):
//! a scenario for every defect class the rewrite ends (STATUS item numbers in
//! each test), and the model-based fuzz of the router against a reference
//! model, with the mutants it must catch. Run them alone with the test-name
//! filter `key_router::`.

mod key_router {
    mod allocations;
    mod fuzz;
    mod lifetimes;
    mod model;
    mod mutants;
    mod scenarios;
    mod sessions;
    mod support;
    mod window_focus;
}
