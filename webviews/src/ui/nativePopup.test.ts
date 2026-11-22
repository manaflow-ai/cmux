import { describe, expect, test } from "bun:test";
import { createPopupHost, type PopupEvent } from "./popupHost";
import type { NativePopupEvent, NativePopupModel } from "./popupProtocol";

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
  test("native events cannot activate legacy rows or leave a legacy owner", async () => {
    const listeners = new Set<(event: PopupEvent) => void>();
    const calls: string[] = [];
    const host = createPopupHost(
      async (call) => {
        calls.push(call);
        return { shown: true };
      },
      (listener) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    );
    const legacy: PopupEvent[] = [];
    const native: NativePopupEvent[] = [];
    const stopLegacy = host.listen((event) => legacy.push(event));
    const stopNative = host.native!.listen((event) => native.push(event));
    const owner = {};
    await host.show(
      {
        items: [{ id: "0", label: "Legacy" }],
        highlighted: null,
        anchor: { left: 0, top: 0, right: 10, bottom: 10 },
        side: "bottom",
        align: "start",
        width: 240,
      },
      owner,
    );
    await host.native!.show({
      schemaVersion: 1,
      id: "native",
      revision: 1,
      anchor: { left: 0, top: 0, right: 10, bottom: 10 },
      side: "bottom",
      align: "start",
      width: 240,
      rows: [{ id: "0", kind: "action", label: "Native" }],
    });
    expect(host.owner()).toBeNull();
    const event: NativePopupEvent = { type: "pick", popupId: "native", revision: 1, id: "0" };
    listeners.forEach((listener) => listener(event as unknown as PopupEvent));
    expect(legacy).toEqual([]);
    expect(native).toEqual([event]);
    host.hide(owner);
    expect(calls).toEqual(["show", "show"]);
    stopNative();
    stopLegacy();
  });
});
