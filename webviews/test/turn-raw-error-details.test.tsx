// l10n-allow-file: simulated backend diagnostics, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { TurnFooter } from "../src/agent-session/acpmux/conversation/TurnRows";

test("an unclassified backend error is a clean assistant failure with raw diagnostics under Details", () => {
  const error = 'internal tool error: {"tool":"shell.run","stderr":"zsh:1: no such file or directory: /fast"}';
  const html = renderToStaticMarkup(
    <TurnFooter row={{ id: "failed", version: 1, kind: "summary", at: 1, status: "failed", error }} />,
  );
  const document = new JSDOM(html).window.document;
  const note = document.querySelector(".cv-turn-note")!;
  expect(note.firstElementChild!.textContent).toBe("The turn failed");
  const details = note.querySelector("details")!;
  expect(details.open).toBe(false);
  expect(details.textContent).toContain(error);
});
