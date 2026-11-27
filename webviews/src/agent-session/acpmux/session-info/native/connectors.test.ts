// Session Info's native Connectors: a failed MCP server's Reconnect stays Reconnect after a failure
// (the person's call: it restarts the server or opens its sign-in), and iMessage's failed reads are
// asked again on their own with one quiet line past the deadline, never a Try again button (Leo,
// 2026-11-22: "vacuous decisions like that should be just done").
import { describe, expect, test } from "bun:test";
import type { Translate } from "../../i18n";
import { IMESSAGE_INITIAL, type IMessageData, type IMessageView } from "../imessage";
import { connectorsSection } from "./connectors";
import { NativeInfoActions } from "./model";

const t = ((key: string) => key) as Translate;

function imessage(data: Partial<IMessageData>, stillTrying = false): IMessageView {
  return {
    data: { ...IMESSAGE_INITIAL, ...data },
    busy: false,
    expanded: true,
    stillTrying,
    toggle: () => {},
    perform: async () => {},
  };
}

const labels = (section: ReturnType<typeof connectorsSection>) =>
  (section?.rows ?? []).flatMap((row) => (row.buttons ?? []).map((button) => button.label));
const titles = (section: ReturnType<typeof connectorsSection>) => (section?.rows ?? []).map((row) => row.title);

describe("native Connectors", () => {
  const failed = [{ name: "github", status: "failed" as const }];

  test("a failed reconnect keeps the Reconnect button, never Try again", () => {
    for (const reconnecting of [undefined, { github: "failed" as const }]) {
      const section = connectorsSection(
        { servers: failed, onReconnect: async () => undefined, open: true, ...(reconnecting && { reconnecting }) },
        new NativeInfoActions(),
        t,
      );
      expect(labels(section)).toEqual(["sessionInfo.connectors.reconnectAction"]);
    }
  });

  test("iMessage's failing thread read shows no Retry, and the quiet line only once it lasts", () => {
    const quiet = connectorsSection(
      { servers: [], open: true, imessage: imessage({ status: "connected", sends_enabled: true }) },
      new NativeInfoActions(),
      t,
    );
    expect(titles(quiet)).not.toContain("imessage.stillTrying");
    const lasting = connectorsSection(
      { servers: [], open: true, imessage: imessage({ status: "connected", sends_enabled: true }, true) },
      new NativeInfoActions(),
      t,
    );
    expect(titles(lasting)).toContain("imessage.stillTrying");
    expect(labels(lasting)).toEqual(["imessage.disconnect"]);
  });

  test("a missing Messages database says what to do, with no Retry", () => {
    const section = connectorsSection(
      {
        servers: [],
        open: true,
        imessage: imessage({ status: "connected", sends_enabled: true, error: "missing" }, true),
      },
      new NativeInfoActions(),
      t,
    );
    expect(titles(section)).toContain("imessage.missing");
    expect(titles(section)).not.toContain("imessage.stillTrying");
    expect(labels(section)).toEqual(["imessage.disconnect"]);
  });
});
