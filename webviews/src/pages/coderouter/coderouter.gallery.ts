// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { ProviderRow, CodeRouterStatus } from "./types";
function fixture(count: number): BridgePageVariant {
  const providers: ProviderRow[] = Array.from({ length: count }, (_, i) => ({
    provider: `sample-${i}`,
    name:
      count > 4
        ? `Sample provider ${i + 1} for a very long project and organization name`
        : ["Claude", "Codex", "Gemini", "Sample provider"][i]!,
    status: i % 2 ? "expired" : "signed_in",
    account: `acct_sample${i}`,
    label: "Sample account",
    plan: "Pro",
    phase: "idle",
    can_connect: true,
    linkable: true,
    linked: [
      {
        id: `link-${i}`,
        account: `acct_sample${i}`,
        label: "Sample team account",
        state: i % 2 ? "expired" : "active",
        visibility: "private",
      },
    ],
  }));
  const status: CodeRouterStatus = { signed_in: true, scope: "personal", health: "ok" };
  return { replies: { "cmux.coderouter.status": status, "cmux.coderouter.detect": { providers } } };
}
export default bridgePageEntry({
  id: "pages.coderouter",
  title: "CodeRouter",
  area: "Pages",
  page: "coderouter",
  covers: ["page:cmux.coderouter", "pages/coderouter/CodeRouterPage.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.coderouter.status": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.coderouter.status"] },
  },
});
