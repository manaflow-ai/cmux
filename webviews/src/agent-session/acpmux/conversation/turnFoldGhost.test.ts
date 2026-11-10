// A closing "Worked for" draws a ghost of each row it hides while the rows under it slide up
// (turnFold.ts ghostOf). The ghost is a copy of the row as drawn: it must not replay an entrance the
// row already played. A row that arrived while the chat loaded keeps the load fade's class for its
// whole life (VirtualTranscript `loadFading`, shared/loadFade.ts), and a PR card in it keeps its own
// (`data-load-fade`): copied, the ghost started that fade over from opacity 0 and blinked out.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LOAD_FADE_CLASS } from "../../shared/loadFade";
import { ghostOf } from "./turnFold";

test("a ghost never replays the load fade of the row it copies, or of a card inside it", () => {
  const { document } = new JSDOM("<!doctype html><body></body>").window;
  const row = document.createElement("div");
  row.className = `acpmux-row acpmux-assistant acpmux-row--enter ${LOAD_FADE_CLASS}`;
  row.innerHTML = `<p class="${LOAD_FADE_CLASS}">reply</p><div class="acpmux-pr-card__body" data-load-fade=""></div>`;
  const ghost = ghostOf(row);
  expect(ghost.classList.contains(LOAD_FADE_CLASS)).toBe(false);
  expect(ghost.classList.contains("acpmux-row--enter")).toBe(false);
  expect(ghost.querySelector(`.${LOAD_FADE_CLASS}`)).toBeNull();
  expect(ghost.querySelector("[data-load-fade]")).toBeNull();
  // The row itself keeps what it drew.
  expect(row.classList.contains(LOAD_FADE_CLASS)).toBe(true);
});
