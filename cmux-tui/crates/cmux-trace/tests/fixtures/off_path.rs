//! Call sites of each trace macro, which `tests/macros.rs` compiles with `-C opt-level=3` against
//! this build of the crate and reads as LLVM IR: each function's entry block is the off path.

#[unsafe(no_mangle)]
pub fn off_instant(a: u64, b: u64) {
    cmux_trace::trace_instant!(daemon, "daemon.request.parsed", a, b);
}

#[unsafe(no_mangle)]
pub fn off_async_begin(id: u64, arg: u64) {
    cmux_trace::trace_async_begin!(daemon, "daemon.url_open", id, arg);
}

#[unsafe(no_mangle)]
pub fn off_async_end(id: u64) {
    cmux_trace::trace_async_end!(daemon, "daemon.url_open", id);
}

#[unsafe(no_mangle)]
pub fn off_flow_out(flow: u64) {
    cmux_trace::trace_flow_out!(key, "key.flow", flow);
}

#[unsafe(no_mangle)]
pub fn off_counter(value: u64, track: u64) {
    cmux_trace::trace_counter!(frame, "frame.sequence", value, track);
}

#[unsafe(no_mangle)]
pub fn off_scope(a: u64, b: u64) {
    let _scope = cmux_trace::trace_scope!(daemon, "daemon.request", a, b);
}
