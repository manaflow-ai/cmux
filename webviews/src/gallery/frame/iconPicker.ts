import { HostError, installMockHost, type HostOp } from "../../../test/latency/mock-host";
import { IconPickerOps } from "../../pages/icon-picker/host";
import { MockIconPickerHost } from "../../pages/icon-picker/mockHost";
import type { IconPickerPageVariant } from "../format";
import { addPseudoLocales } from "../pseudo";
import type { StageContext } from "./context";
import { fixtureElement, fixtureSteps } from "./settingsPasswords";

export function iconPickerFixtureOps(state: IconPickerPageVariant): Record<string, HostOp> {
  const provider = new MockIconPickerHost();
  return Object.fromEntries(
    Object.values(IconPickerOps)
      .filter((op) => op !== IconPickerOps.session)
      .map((op) => [
        op,
        (params: unknown) => {
          if (op === IconPickerOps.assetFromURL || op === IconPickerOps.assetPut) {
            if (state.assetState === "loading") return new Promise(() => {});
            if (state.assetState === "error")
              throw new HostError("cmux.iconPicker.failed", "Sample asset download refused");
          }
          return provider.call(op, params);
        },
      ]),
  );
}

export async function mountIconPickerPage(state: IconPickerPageVariant, context: StageContext): Promise<void> {
  addPseudoLocales((await import("../../pages/icon-picker/generated/strings.json")).default);
  const host = installMockHost(iconPickerFixtureOps(state), [IconPickerOps.session], {
    [IconPickerOps.session]: state.session,
  });
  host.delayMs = 0;
  document.documentElement.dataset.cmuxPage = "icon-picker";
  document.documentElement.dataset.cmuxWebviewKind = "icon-picker";
  document.documentElement.lang = context.env.locale;
  await import("../../pages/icon-picker/main");
  await host.initialEventsDelivered;
  const query = state.mode === "empty" ? (state.query ?? "no matching icon") : state.query;
  if (query !== undefined) await fixtureSteps([{ selector: ".icon-picker-search", action: "input", value: query }]);
  if (state.active !== undefined) {
    const search = await fixtureElement(".icon-picker-search");
    for (let i = 0; i < state.active; i++) {
      search.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
  }
}
