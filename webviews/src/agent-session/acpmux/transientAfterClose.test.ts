// l10n-allow-file: test fixtures.
// A closed client keeps no toast sink (review of #37629): a late failure from it (a takeOver()
// that fails after a reconnect replaced it) must not show a toast in the new pane, nor a line.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";

test("a closed client's late feedback reaches no toast and no transcript line", () => {
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  const shown: string[] = [];
  const lines: string[] = [];
  client.toastSink = (text) => shown.push(text);
  client.notice = (text: string) => (lines.push(text), "row");
  (client as unknown as { closed: boolean }).closed = true;
  client.transient("Couldn't take over this chat");
  expect(shown).toEqual([]);
  expect(lines).toEqual([]);
});

test("an open client's feedback is a toast", () => {
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  const shown: string[] = [];
  client.toastSink = (text) => shown.push(text);
  (client as unknown as { closed: boolean }).closed = false;
  client.transient("Couldn't take over this chat");
  expect(shown).toEqual(["Couldn't take over this chat"]);
});
