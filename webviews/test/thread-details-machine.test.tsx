import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { SessionRail } from "../src/agent-session/acpmux/summary/SessionRail";
import { ThreadDetails } from "../src/agent-session/acpmux/summary/ThreadDetails";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
const cases: {
  label: string;
  summary?: Pick<Summary, "hostKind" | "host" | "peer">;
  machineName?: string;
  icon: string;
  name: string;
}[] = [
  { label: "this Mac", machineName: "Studio", icon: "machine.local", name: "Studio" },
  {
    label: "the Mac's name takes precedence over the local host",
    summary: { hostKind: "local", host: "local-host" },
    machineName: "Studio",
    icon: "machine.local",
    name: "Studio",
  },
  {
    label: "cloud",
    summary: { hostKind: "cloud", host: "build-01" },
    machineName: "Studio",
    icon: "cloud",
    name: "build-01",
  },
  {
    label: "peer with a host name",
    summary: { peer: "peer-01", host: "Remote Mac" },
    machineName: "Studio",
    icon: "machine.remote",
    name: "Remote Mac",
  },
  { label: "peer without a host name", summary: { peer: "peer-01" }, icon: "machine.remote", name: "peer-01" },
  {
    label: "cloud takes precedence over peer",
    summary: { hostKind: "cloud", peer: "peer-01", host: "build-01" },
    icon: "cloud",
    name: "build-01",
  },
  {
    label: "local host fallback",
    summary: { hostKind: "local", host: "local-host" },
    icon: "machine.local",
    name: "local-host",
  },
  { label: "localized Mac fallback", icon: "machine.local", name: "This Mac" },
  {
    label: "cloud without a host retains the rail's local fallback",
    summary: { hostKind: "cloud" },
    icon: "machine.local",
    name: "This Mac",
  },
];

for (const { label, summary, machineName, icon, name } of cases) {
  test(`Thread details names and draws ${label}`, () => {
    const dom = new JSDOM(
      renderToStaticMarkup(<ThreadDetails folder="/src/atlas" summary={summary} machine={machineName} />),
    );
    try {
      const row = dom.window.document.querySelector(".acpmux-thread-details__row");
      expect(row?.textContent).toBe(name);
      const glyph = row?.querySelector("svg");
      expect(glyph?.getAttribute("data-icon")).toBe(icon);
      expect(glyph?.getAttribute("width")).toBe("14");
      expect(glyph?.getAttribute("height")).toBe("14");
      expect(glyph?.getAttribute("viewBox")).toBe("2.5 2.5 19 19");
      expect(glyph?.classList.contains("ui-ghost-icon")).toBe(true);
    } finally {
      dom.window.close();
    }
  });

  test(`SessionRail retains its environment row for ${label}`, () => {
    const dom = new JSDOM(
      renderToStaticMarkup(
        <SessionRail summary={{ sessionId: "session-01", ...summary }} machineName={machineName} outputs={[]} />,
      ),
    );
    try {
      const row = dom.window.document.querySelector(".acpmux-rail-row");
      expect(row?.textContent).toBe(name);
      const glyph = row?.querySelector("svg");
      expect(glyph?.getAttribute("data-icon")).toBe(icon);
      expect(glyph?.getAttribute("width")).toBe("14");
      expect(glyph?.getAttribute("height")).toBe("14");
      expect(glyph?.getAttribute("viewBox")).toBe("2.5 2.5 19 19");
    } finally {
      dom.window.close();
    }
  });
}
