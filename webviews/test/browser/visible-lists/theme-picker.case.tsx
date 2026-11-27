// Settings' ThemePicker over N themes: the null choice, three starred themes (none the picked one) under Starred, then
// every theme under All Themes (each heading in its first row's top margin), opened on the picked
// theme in the middle of the list. Previews (the highlighted row, at once for a key) land in
// `window.__previews`; `changeOne` marks one theme custom, as an edit to its colors does.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { ThemePicker } from "../../../src/pages/settings/components/ThemePicker";
import "../../../src/pages/settings/page.css";
import { caseItems, type VisibleListCase } from "./case";
import { openPopover, popoverControls, settingsStrings } from "./popoverCase";

let changeOne = () => {};

function Themes({ n }: { n: number }) {
  const [names] = useState(() => caseItems(n).map((item) => item.label));
  const [custom, setCustom] = useState<ReadonlySet<string>>(new Set());
  const [favorites, setFavorites] = useState(() => [names[10]!, names[20]!, names[45]!].filter(Boolean));
  useEffect(() => {
    changeOne = () =>
      setCustom((previous) => {
        const next = new Set(previous);
        if (next.has(names[2]!)) next.delete(names[2]!);
        else next.add(names[2]!);
        return next;
      });
  }, [names]);
  const log = window as unknown as { __submitted: string[]; __previews: (string | null)[] };
  return (
    <ThemePicker
      value={names[Math.floor(n / 2)]!}
      names={names}
      colors={null}
      labelId="case-theme-label"
      disabled={false}
      configLabel="Ghostty config"
      configColors={undefined}
      onPick={(name) => void log.__submitted.push(name ?? "")}
      onPreview={(name) => void log.__previews.push(name)}
      custom={(name) => custom.has(name)}
      favorites={favorites}
      onToggleFavorite={(name) =>
        setFavorites((previous) =>
          previous.includes(name) ? previous.filter((other) => other !== name) : [...previous, name],
        )
      }
    />
  );
}

export default {
  async mount(root, n) {
    await settingsStrings();
    Object.assign(window, { __submitted: [], __previews: [] });
    flushSync(() => createRoot(root).render(<Themes n={n} />));
    await openPopover(root.querySelector<HTMLElement>("[data-theme-picker]")!);
    return popoverControls(["ComboboxOption", "ThemeBall"], { changeOne: () => changeOne() });
  },
} satisfies VisibleListCase;
