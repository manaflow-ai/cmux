// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { TableBlock } from "../../agent-session/acpmux/conversation/TableBlock";
import type { Table } from "../../agent-session/acpmux/conversation/tableFormats";
import { Focus } from "./Focus";
import { Inline } from "./Inline";
import { Split } from "./Split";

type PrototypeProps = {
  mode?: "before" | "inline" | "split" | "focus";
  fixture?: "week" | "empty" | "single" | "mixed" | "large";
};
const beforeTable: Table = {
  header: ["Day", "Sessions", "Errors", "Error rate"],
  align: ["left", "right", "right", "right"],
  rows: [
    ["Mon", "184", "8", "4.3%"],
    ["Tue", "236", "7", "3.0%"],
    ["Wed", "292", "11", "3.8%"],
    ["Thu", "318", "6", "1.9%"],
    ["Fri", "364", "9", "2.5%"],
    ["Sat", "241", "5", "2.1%"],
    ["Sun", "207", "4", "1.9%"],
  ],
};
function BeforeTable() {
  return (
    <main className="tc-shell tc-before">
      <p className="tc-eyebrow">Before</p>
      <h1>Reply table</h1>
      <p className="tc-description">
        The current reply surface keeps data static and offers Copy. In the chat, Open is also available.
      </p>
      <TableBlock table={beforeTable} cell={(text) => text} />
    </main>
  );
}
function PrototypePicker({
  current,
  onChange,
  onReset,
}: {
  current: "inline" | "split" | "focus";
  onChange: (mode: "inline" | "split" | "focus") => void;
  onReset(): void;
}) {
  const picker = useRef<HTMLElement>(null);
  const highlight = useRef<HTMLSpanElement>(null);
  const items = useRef<Array<HTMLButtonElement | null>>([]);
  useEffect(() => {
    const item = items.current[["inline", "split", "focus"].indexOf(current)];
    if (item && highlight.current) {
      highlight.current.style.width = item.offsetWidth + "px";
      highlight.current.style.transform = "translateX(" + item.offsetLeft + "px)";
    }

    let second: number | undefined;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => picker.current?.setAttribute("data-ready", ""));
    });
    return () => {
      cancelAnimationFrame(first);
      if (second !== undefined) cancelAnimationFrame(second);
    };
  }, [current]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (
        event.defaultPrevented ||
        event.shiftKey ||
        !target ||
        /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) ||
        target.isContentEditable ||
        event.metaKey ||
        event.ctrlKey ||
        event.altKey
      )
        return;
      const names = ["inline", "split", "focus"] as const;
      const index = names.indexOf(current);
      const number = Number(event.key);
      if (number >= 1 && number <= 3) onChange(names[number - 1]!);
      else if (event.key === "ArrowRight") onChange(names[(index + 1) % 3]!);
      else if (event.key === "ArrowLeft") onChange(names[(index + 2) % 3]!);
      else if (event.key.toLowerCase() === "r") onReset();
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [current, onChange, onReset]);
  return (
    <nav ref={picker} className="proto-picker" aria-label="Prototype variants">
      <span ref={highlight} className="proto-picker-highlight" aria-hidden="true" />
      {(["inline", "split", "focus"] as const).map((name, index) => (
        <button
          key={name}
          ref={(element) => {
            items.current[index] = element;
          }}
          type="button"
          className="proto-picker-item"
          data-active={current === name ? "" : undefined}
          aria-current={current === name ? "true" : undefined}
          onClick={() => onChange(name)}
        >
          {name === "inline" ? "Inline" : name === "split" ? "Split" : "Focus"}
        </button>
      ))}
    </nav>
  );
}

function TableChart({ mode = "inline", fixture = "week" }: PrototypeProps) {
  const [current, setCurrent] = useState<"inline" | "split" | "focus">(() => {
    const names = ["inline", "split", "focus"] as const;
    const fromUrl = Number(new URLSearchParams(location.search).get("v"));
    const fallback = mode === "before" ? "inline" : mode;
    return names[fromUrl - 1] ?? fallback;
  });
  const [reset, setReset] = useState(0);
  const switchMode = (next: "inline" | "split" | "focus") => {
    setCurrent(next);
    const url = new URL(location.href);
    url.searchParams.set("v", String(["inline", "split", "focus"].indexOf(next) + 1));
    history.replaceState(null, "", url);
  };
  if (mode === "before") return <BeforeTable />;
  return (
    <>
      <PrototypePicker current={current} onChange={switchMode} onReset={() => setReset((value) => value + 1)} />
      {current === "split" ? (
        <Split key={reset} fixture={fixture} />
      ) : current === "focus" ? (
        <Focus key={reset} fixture={fixture} />
      ) : (
        <Inline key={reset} fixture={fixture} />
      )}
    </>
  );
}

export default componentEntry<PrototypeProps>({
  id: "prototype.table-chart",
  title: "Table to chart",
  area: "Prototypes",
  experimental: true,
  covers: [
    "prototypes/table-chart/Inline.tsx",
    "prototypes/table-chart/Split.tsx",
    "prototypes/table-chart/Focus.tsx",
    "prototypes/table-chart/shared.tsx",
  ],
  height: 720,
  widths: { narrow: 320, normal: 760, wide: 1120 },
  keywords: ["visualize", "data", "chart", "table"],
  load: async () => TableChart,
  styles: () =>
    Promise.all([import("../../agent-session/acpmux/conversation/conversation.css"), import("./table-chart.css")]),
  variants: {
    before: {
      note: "Before: the production TableBlock renders the source with its production Copy control; Open requires the chat context.",
      props: { mode: "before", fixture: "week" },
    },
    inline: {
      note: "Inline: switch between chart and source in one reply; the recommended compact layout.",
      props: { mode: "inline", fixture: "week" },
    },
    split: {
      note: "Split: source table and chart share the same reading frame.",
      props: { mode: "split", fixture: "week" },
    },
    "split-large": {
      note: "Split with the 1,000-row fixture: the source table scrolls in its own bounded region, so the chart and export controls stay in view.",
      props: { mode: "split", fixture: "large" },
    },
    focus: {
      note: "Focus: chart gets visual priority; source stays one disclosure away.",
      props: { mode: "focus", fixture: "week" },
    },
  },
});
