# Launch read component measurements

`hub/launch_read_bench_tests.rs` adds ignored component benches for 5 and 500 synthetic sessions.
It measures store reads, constructors and bounded list replies; the daemon's current
`new_loading_with_wireguard` path loads metadata after readiness. These are not GUI TTI measurements.

Timing excludes dropping returned values: record elapsed time before teardown. The detector is the
ignored `launch_read_bench` test, run in release mode. Earlier constructor figures included teardown
and need a fresh run before being described as construction cost. Production behavior is unchanged.
