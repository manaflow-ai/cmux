// The composer's real model picker (acpmux/ModelPicker.tsx), open, on one harness with N models: a
// started chat's picker (harnessFixed, so no rail draws PickerOptions of its own), opened on a model
// in the middle of the list, as it opens on the chat's model. Each model is its own family's newest,
// so all N list without the More models fold; the search field is the typing step's filter.
// A row is the PickerOption each model row renders (the base had no row component of its own).
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { ModelPicker } from "../../../src/agent-session/acpmux/ModelPicker";
import type { ModelPickerProps } from "../../../src/agent-session/acpmux/modelPickerLayout";
import { modelFilterTimes } from "../../../src/agent-session/acpmux/modelSearch";
import { acpmuxPerf } from "../../../src/agent-session/acpmux/perf";
import { caseItems, type VisibleListCase } from "./case";

type Catalog = ModelPickerProps["catalog"];

function catalogOf(n: number): Catalog {
  return [
    {
      id: "claude",
      name: "Claude Code",
      models: caseItems(n).map((item, index) => ({ id: item.id, name: item.label, family: `f${index}` })),
    },
  ] as Catalog;
}

let changeOne = () => {};

function CaseModelPicker({ n }: { n: number }) {
  const [catalog, setCatalog] = useState(() => catalogOf(n));
  // In an effect, not at render, as the other cases do: a component that writes outside itself at
  // render is one the compiler leaves uncompiled.
  useEffect(() => {
    changeOne = () =>
      setCatalog((previous) =>
        previous.map((entry) => ({
          ...entry,
          // The model the picker opens on, so the changed row is a mounted one.
          models: entry.models.map((model, index) =>
            index === Math.floor(n / 2) ? { ...model, name: `${model.name}!` } : model,
          ),
        })),
      );
  }, [n]);
  return (
    // The chat column the picker keeps inside; its chip sits low, as the composer's does, so it opens above.
    <div className="acpmux-main" style={{ position: "relative", height: 680, display: "flex", alignItems: "flex-end" }}>
      <ModelPicker
        catalog={catalog}
        harness="claude"
        harnessFixed
        model={`id-${Math.floor(n / 2)}`}
        label="Claude"
        efforts={[]}
        recents={[]}
        onLand={() => {}}
        onEffort={() => {}}
      />
    </div>
  );
}

const modelPickerCase: VisibleListCase = {
  async mount(root, n) {
    // The filter's own time per key: a script turns acpmuxPerf on (the bench leaves it off).
    (window as unknown as { __modelFilter: unknown }).__modelFilter = { perf: acpmuxPerf, times: modelFilterTimes };
    flushSync(() => createRoot(root).render(<CaseModelPicker n={n} />));
    // Cmd-Ctrl-M opens the picker, as from the keyboard.
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }));
    const models = () => root.querySelector<HTMLElement>(".acpmux-mp-models")!;
    await new Promise<void>((done) => {
      const ready = () => {
        const menu = root.querySelector<HTMLElement>(".acpmux-mp");
        if (menu && getComputedStyle(menu).visibility === "visible" && models()?.querySelector('[data-key^="model:"]'))
          requestAnimationFrame(() => requestAnimationFrame(() => done()));
        else requestAnimationFrame(ready);
      };
      ready();
    });
    return {
      rowSelector: '[data-key^="model:"]',
      rowComponents: ["PickerOption"],
      scroller: () => models().closest<HTMLElement>(".ui-scroll-edge-fade")!,
      list: models,
      filter: () => root.querySelector<HTMLElement>(".acpmux-mp-search input")!,
      changeOne: () => changeOne(),
      resizeTarget: () => root.querySelector<HTMLElement>(".acpmux-mp")!,
    };
  },
};
export default modelPickerCase;
