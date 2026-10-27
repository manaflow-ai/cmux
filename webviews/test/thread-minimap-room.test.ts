// The rail's room in any pane, down to the transcript's 96 px minimum (conversation.css), for 1 to 70
// prompts and every band the reader can scroll to (Leo 2026-10-22: "it wouldn't show the highlighted
// bottom ... it just didn't go to the bottom"). Every prompt on screen (the band) must draw whole
// inside the rail's list: the rail is never shorter than the band, and when the list's edge fades
// and the band compete for room, the fades give way. Where the pane has room, the band also stays
// clear of the transcript's own faded edges (its mask: 18 px at the top, up to 56 px at the foot).
// Pure geometry (model.ts), so it sweeps every case; thread-minimap-tiny.test.tsx renders a sample.
import { expect, test } from "bun:test";
import { railHeight, railScrollTop, railTop, ROW_PITCH } from "../src/agent-session/acpmux/threadMinimap/model";

/// The transcript mask's bands at their widest (conversation.css .acpmux-scroll[data-fade-*]).
const MASK_TOP = 18;
const MASK_BOTTOM = 56;
const MAX_BAND = 4;

test("every lit tick draws whole inside the rail, at every pane height from 96 px, for 1 to 70 prompts", () => {
  const failures: string[] = [];
  for (let viewport = 96; viewport <= 640 && failures.length < 20; viewport += 2) {
    const window = viewport + 120;
    for (let count = 1; count <= 70 && failures.length < 20; count += 1) {
      for (let size = 1; size <= Math.min(MAX_BAND, count); size += 1) {
        // The band's prompts can only be on screen together if their rows fit the view.
        if (size * ROW_PITCH > viewport) continue;
        // The rail knows how many prompts are on screen (the 5th argument).
        const height = railHeight(count, window, viewport, viewport, size);
        if (height < ROW_PITCH) {
          failures.push(`${viewport} px, ${count} prompts: the rail is hidden (${height} px)`);
          continue;
        }
        const top = railTop(height, viewport, viewport);
        const clearRoom = viewport - MASK_TOP - MASK_BOTTOM - 8;
        // Down the chat and back up, as a reader scrolls: the list keeps its offset between bands.
        const bands = Array.from({ length: count - size + 1 }, (_, first) => first);
        let current = 0;
        for (const first of [...bands, ...[...bands].reverse()]) {
          const last = first + size - 1;
          current = railScrollTop({ first, last }, count, height, current);
          for (let index = first; index <= last; index += 1) {
            const y = index * ROW_PITCH - current;
            if (y < 0 || y + ROW_PITCH > height) {
              failures.push(
                `${viewport} px, ${count} prompts, band ${first}-${last}: tick ${index} at ${y}..${y + ROW_PITCH} in a ${height} px rail`,
              );
              break;
            }
            if (height <= clearRoom && (top + y < MASK_TOP || top + y + ROW_PITCH > viewport - MASK_BOTTOM)) {
              failures.push(
                `${viewport} px, ${count} prompts, band ${first}-${last}: tick ${index} at ${top + y} px, under the transcript's fade`,
              );
              break;
            }
          }
        }
      }
    }
  }
  expect(failures).toEqual([]);
});
