// The reader's open and close choices are kept past a row's unmount (useRowDisclosure), so a long
// session's store must stay bounded: 600 choices per chat and view, the least recently set going
// first, and 40 chats and views in all (transcriptDisclosureModel.ts DISCLOSURE_LIMIT, SESSION_LIMIT).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { resetTranscriptDisclosure, useRowDisclosure } from "./transcriptDisclosureModel";
import { settleReact } from "../../../../test/support/domTeardown";

const STORAGE_KEY = "cmux.acpmux.transcriptDisclosure";
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const setters = new Map<string, (open: boolean) => void>();
function Call({ id }: { id: string }) {
  const [, setOpen] = useRowDisclosure(id);
  setters.set(id, setOpen);
  return null;
}

async function mount(sessions: Record<string, string[]>) {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "localStorage", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetTranscriptDisclosure();
  setters.clear();
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(
      <>
        {Object.entries(sessions).map(([session, ids]) => (
          <TranscriptDisclosureProvider key={session} sessionId={session}>
            {ids.map((id) => (
              <Call key={id} id={`${session}/${id}`} />
            ))}
          </TranscriptDisclosureProvider>
        ))}
      </>,
    );
  });
}

const stored = (): Record<string, Record<string, boolean>> =>
  JSON.parse(dom!.window.localStorage.getItem(STORAGE_KEY) ?? "{}");

test("a long session keeps its latest 600 choices, the least recently set going first", async () => {
  const ids = Array.from({ length: 700 }, (_, at) => `c${at}`);
  await mount({ long: ids });
  await act(async () => {
    for (const id of ids) setters.get(`long/${id}`)!(true);
    // The first call set again: it is recent now, and stays.
    setters.get("long/c0")!(false);
  });
  const keys = Object.keys(stored().long ?? {});
  expect(keys).toHaveLength(600);
  expect(keys).toContain("row:long/c0");
  expect(keys).toContain("row:long/c699");
  // The oldest ones the reader did not touch again are gone: they draw at their default.
  expect(keys).not.toContain("row:long/c1");
  expect(keys).not.toContain("row:long/c100");
  expect(keys).toContain("row:long/c101");
});

test("choices are kept for at most 40 chats and views", async () => {
  const sessions = Object.fromEntries(Array.from({ length: 45 }, (_, at) => [`chat${at}`, ["c"]]));
  await mount(sessions);
  await act(async () => {
    for (const session of Object.keys(sessions)) setters.get(`${session}/c`)!(true);
  });
  const chats = Object.keys(stored());
  expect(chats).toHaveLength(40);
  expect(chats).not.toContain("chat0");
  expect(chats).toContain("chat44");
});
