import { describe, expect, test } from "bun:test";
import { createPopupHost, type PopupEvent } from "./popupHost";
import type { NativePopupEvent, NativePopupModel } from "./generated/popupProtocol";

describe("declarative native popup transport", () => {
  test("sends rows without a DOM surface and binds hide to its popup", async () => {
    const calls: { call: string; params: Record<string, unknown> }[] = [];
    let receive: ((event: PopupEvent) => void) | undefined;
    const host = createPopupHost(
      async (call, params) => {
        calls.push({ call, params });
        return { shown: true };
      },
      (listener) => {
        receive = listener;
        return () => {
          receive = undefined;
        };
      },
    );
    const model: NativePopupModel = {
      schemaVersion: 1,
      id: "model-picker",
      revision: 3,
      anchor: { left: 20, top: 30, right: 120, bottom: 60 },
      side: "top",
      align: "start",
      width: 320,
      search: { id: "query", value: "", placeholder: "Search models" },
      rows: [{ id: "model:a", kind: "action", label: "Model A", description: "Current account" }],
      rail: [{ id: "harness:a", kind: "action", label: "Harness A", keepOpen: true }],
      railWidth: 44,
      footer: [
        { id: "effort", kind: "choice", label: "Effort", value: "high", options: [{ id: "high", label: "High" }] },
      ],
    };
    const native = host.native!;
    await native.show(model);
    expect(calls[0]).toEqual({ call: "show", params: { ...model } });
    const events: NativePopupEvent[] = [];
    const stop = native.listen((event) => events.push(event));
    receive?.({ type: "pick", id: "0" });
    expect(events).toEqual([]);
    const event: NativePopupEvent = { type: "pick", popupId: model.id, revision: 3, id: "model:a" };
    receive?.(event as unknown as PopupEvent);
    expect(events).toEqual([event]);
    native.update({ ...model, revision: 4 });
    native.hide(model.id, 4);
    expect(calls.at(-1)).toEqual({ call: "hide", params: { schemaVersion: 1, id: model.id, revision: 4 } });
    stop();
    expect(receive).toBeUndefined();
  });
});
