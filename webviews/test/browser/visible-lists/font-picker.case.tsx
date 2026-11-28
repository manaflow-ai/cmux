// Settings' FontPicker over N families (the default row, two recent ones, then the rest), opened on
// the picked family in the middle of the list. Previews land in `window.__previews`.
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { FontPicker } from "../../../src/pages/settings/components/FontPicker";
import "../../../src/pages/settings/page.css";
import { caseItems, type VisibleListCase } from "./case";
import { openPopover, popoverControls, settingsStrings } from "./popoverCase";

function Fonts({ n }: { n: number }) {
  const [names] = useState(() => caseItems(n).map((item) => item.label));
  const log = window as unknown as { __submitted: string[]; __previews: (string | null)[] };
  return (
    <FontPicker
      value={names[Math.floor(n / 2)]!}
      names={names}
      recent={[names[7]!, names[9]!].filter(Boolean)}
      labelId="case-font-label"
      disabled={false}
      title="Font"
      defaultLabel="Default"
      onPick={(name) => void log.__submitted.push(name ?? "")}
      onPreview={(name) => void log.__previews.push(name)}
    />
  );
}

export default {
  async mount(root, n) {
    await settingsStrings();
    Object.assign(window, { __submitted: [], __previews: [] });
    flushSync(() => createRoot(root).render(<Fonts n={n} />));
    await openPopover(root.querySelector<HTMLElement>("[data-font-picker]")!);
    return popoverControls(["ComboboxOption"]);
  },
} satisfies VisibleListCase;
