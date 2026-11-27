# Shared web builds and live-base validation

Leo, 2026-11-27: "The cpu time is the true cost" and "we should probably just get these cuts in asap".

The PR router's producer publishes bundles for the event's fixed merge commit. Browser and size-budget jobs
consume those bytes, verify the source/toolchain key and output digests, and keep their source checks. The
executable stand-in bundler in `tests/test_ci_compile_preflight.py` measures two build invocations before,
one build plus one install after. This is an invocation count, not a production CPU measurement.

Preflight also merges the head onto the live base. Its web inputs may differ from the event merge's inputs:
equal source/toolchain keys need no second build; different keys require a separate validation build. Only
the fixed-tree artifact is published to fixed-tree consumers. React's head/base producers pin their own
source refs and do not replace those refs with a live-base merge. The test
`SharedWebArtifact.test_fixed_tree_artifact_and_live_base_validate_distinct_sources` exercises the workflow
comparison and build commands with equal and different keys: zero and one additional build respectively.

Both R2 and GitHub cache hits restore bytes and suppress the fixed-tree build. Toolchains still initialize
if a distinct live-base validation build is necessary. A producer output carries its complete artifact name,
including its attempt, so a consumer-only rerun reads the retained producer's artifact. A successful producer
followed by failed delivery fails the consumer; it does not start another build.

Five natural-PR cgroup CPU/wall pairs and deployed artifact-consumption receipts remain outstanding. No CPU
percentage or wall-time saving is established by these local invocation tests.
