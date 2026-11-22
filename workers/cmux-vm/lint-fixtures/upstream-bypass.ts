// Lint self-test fixture: both lines must be reported (scripts/lint-selftest.sh).
// Never imported; not type-checked.
import { makeUpstreamClient } from "../src/upstream/live.ts";

export const bypass = makeUpstreamClient;
export const direct = () => fetch("https://upstream.invalid/v5/vms");
