//! The process's `main` started its black box in another directory before the flow init: the
//! recording could not be in CMUX_TRACE_FLOWS, so `init` stops the recording it started and leaves
//! hops off instead of writing them where no reader looks.

#[test]
fn a_black_box_in_another_directory_leaves_flows_off() {
    let root = std::env::temp_dir().join(format!("cmux-flow-trace-other-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (main_dir, flows_dir) = (root.join("main"), root.join("flows"));
    std::fs::create_dir_all(&flows_dir).unwrap();
    let open = cmux_trace::init_blackbox(&main_dir, cmux_trace::Role::Daemon)
        .expect("this test starts the process's black box");
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &flows_dir) };

    assert!(!cmux_flow_trace::init(), "flows went on with the recording outside CMUX_TRACE_FLOWS");
    assert!(!cmux_flow_trace::enabled());
    let status = cmux_trace::status().expect("the black box runs");
    assert!(!status.recording, "init left its recording running");
    assert!(
        cmux_trace::start_recording(cmux_trace::category::KEY).is_ok(),
        "the recording state is stuck"
    );
    cmux_trace::stop().expect("the recording stops");

    let _ = open.wait();
    let _ = std::fs::remove_dir_all(&root);
}
