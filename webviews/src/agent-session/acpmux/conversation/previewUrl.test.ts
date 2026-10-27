// l10n-allow-file: test fixture commands and replies, not shipped UI.
// A turn's preview card is for a local page the turn started or mentioned (previewUrl.ts). Leo
// (2026-10-19) got a card for `127.0.0.1:31415` under a stopped turn: that is the model gateway
// the agent's environment points at (ANTHROPIC_BASE_URL), not a page, and its Load preview showed
// nothing useful. A setting's value and an API route are not pages; a dev server's address is.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { latestLocalUrl, turnPreviewUrl } from "./previewUrl";

const shell = (command: string, output: string): AcpmuxRow =>
  ({
    id: "a",
    version: 1,
    at: 0,
    kind: "activity",
    items: [{ tool: { kind: "execute", command, output } }],
  }) as unknown as AcpmuxRow;
const user = { id: "u", version: 1, at: 0, kind: "user", text: "Check the gateway" } as AcpmuxRow;

test("a gateway address in the environment is not a page", () => {
  const turn = [
    shell("env | grep ANTHROPIC", "ANTHROPIC_BASE_URL=http://127.0.0.1:31415\nANTHROPIC_MODEL=opus\n"),
    shell(
      'curl -s http://127.0.0.1:31415/v1/messages -d "{}"',
      '{"type":"error","error":{"type":"authentication_error"}}',
    ),
  ];
  expect(turnPreviewUrl(user, turn)).toBeUndefined();
});

test("settings' values and API routes are not pages", () => {
  expect(latestLocalUrl(['"baseUrl": "http://localhost:8080"'])).toBeUndefined();
  expect(latestLocalUrl(["proxy: http://127.0.0.1:7890"])).toBeUndefined();
  expect(latestLocalUrl(["sr --api-url http://127.0.0.1:31415 status"])).toBeUndefined();
  expect(latestLocalUrl(["POST http://localhost:3000/api/users returned 201"])).toBeUndefined();
  expect(latestLocalUrl(["see http://localhost:4000/graphql"])).toBeUndefined();
});

test("a page named after a label is still a page", () => {
  expect(latestLocalUrl(["Preview URL: http://localhost:5173"])).toBe("http://localhost:5173/");
  expect(latestLocalUrl(["App URL: http://localhost:3000/"])).toBe("http://localhost:3000/");
  expect(latestLocalUrl(["visit=http://localhost:5173 in the doc"])).toBe("http://localhost:5173/");
  expect(latestLocalUrl(["bun dev --rapid http://localhost:5173"])).toBe("http://localhost:5173/");
  expect(latestLocalUrl(['VITE_DEV_SERVER="http://localhost:5173"'])).toBeUndefined();
  expect(latestLocalUrl(["api_url: http://localhost:9000"])).toBeUndefined();
});

test("a dev server's address and a page the answer names still are", () => {
  expect(latestLocalUrl(["  VITE v6  ready\n  ➜  Local:   http://localhost:5173/\n"])).toBe("http://localhost:5173/");
  expect(latestLocalUrl(["Open http://127.0.0.1:3000/admin to see the table."])).toBe("http://127.0.0.1:3000/admin");
  expect(latestLocalUrl(["Server running at http://0.0.0.0:8000/"])).toBe("http://localhost:8000/");
  const turn = [shell("bun run dev", "  ➜  Local:   http://localhost:5173/\n")];
  expect(turnPreviewUrl(user, turn)).toBe("http://localhost:5173/");
});
