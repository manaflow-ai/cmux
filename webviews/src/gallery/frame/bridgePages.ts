// Each fixture answers the page's own wire operations before its real entry module boots.
import { installMockHost } from "../../../test/latency/mock-host";
import type { BridgePageEntry, BridgePageVariant } from "../format";
import { addPseudoLocales } from "../pseudo";
import type { StageContext } from "./context";
import { fixtureOps } from "./pageReplies";

const modules = import.meta.glob("../../pages/*/main.tsx");
const tables = import.meta.glob("../../pages/*/generated/strings.json", { import: "default" });

export async function mountBridgePage(
  entry: BridgePageEntry,
  state: BridgePageVariant,
  context: StageContext,
): Promise<void> {
  const table = await tables[`../../pages/${entry.page}/generated/strings.json`]!();
  addPseudoLocales(table as Record<string, Record<string, string>>);
  if (entry.page === "editor") addPseudoLocales((await import("../../viewer-empty/generated/strings.json")).default);
  const host = installMockHost(
    fixtureOps(state, context.appearance),
    ["cmux.page.command", "cmux.page.connection", ...(state.streams ?? []), ...Object.keys(state.initialEvents ?? {})],
    state.initialEvents,
  );
  host.delayMs = 0;
  history.replaceState(null, "", `${location.pathname}${location.search}${state.hash ?? ""}`);
  document.documentElement.dataset.cmuxPage = entry.page;
  document.documentElement.dataset.cmuxWebviewKind = entry.page;
  document.documentElement.lang = context.env.locale;
  await modules[`../../pages/${entry.page}/main.tsx`]!();
}
