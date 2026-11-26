import { describe, expect, test } from "bun:test";

import { CMUX_REQUIRED_DOMAINS, NETWORK_POLICY_PRESETS } from "../services/vms/networkPolicy";
import { EGRESS_PRESETS, EGRESS_REQUIRED_DOMAINS } from "../../workers/cmux-vm/src/egress-allowlist";

// The VM API Worker compiles a create's egress allowlist from its own copy of these lists (it deploys alone and
// cannot import web/). A preset that differs between the two would mean the same policy opens different hosts.
describe("cmux-vm egress allowlist catalog", () => {
  test("presets match networkPolicy.ts", () => {
    expect(EGRESS_PRESETS).toEqual(Object.fromEntries(NETWORK_POLICY_PRESETS.map((preset) => [preset.id, preset.domains])));
  });

  test("required names match networkPolicy.ts", () => {
    expect(EGRESS_REQUIRED_DOMAINS).toEqual(CMUX_REQUIRED_DOMAINS);
  });
});
