# Font study rubric

How each pairing in `candidates.ts` is judged, on the `font-study.screen/long-chat` mock-app screen
(the sidebar with groups and long names, a long reply with code, a table, CJK and emoji, the
composer), dark and light, at the app's sizes (11-13 px chrome, 14 px prose, 15 px for a serif).
The UI review council (HQ `tools/ui-climb/council.py`) gets this file as its spec and compares
pairings blind, in both orders; the scores below are the written pass beside it.

Each criterion scores 1 to 5. A 1 on any criterion keeps a pairing out of the top three.

1. **Small-size legibility.** Sidebar titles, group headers, captions and tool rows at 11-13 px: open
   counters, distinct `I l 1 |`, `O 0`, `rn m`, `cl d`, no smudged joins in dark mode.
2. **Density.** How many characters a sidebar row and a reply line hold at the same size; long titles
   truncate late without looking cramped.
3. **Rhythm.** Even texture over a long reply: word spacing, the line height it wants, how the code
   block, the table and the list sit beside the prose.
4. **Character.** Whether it reads as a designed product rather than a default, and stays calm over a
   long session.
5. **Beside the macOS chrome.** How it sits next to the traffic lights, menus and SF in the system's
   own controls: neither a mismatch nor an imitation that looks off by a hair.
6. **Fallback.** CJK and emoji in the same line: the fallback's x-height, weight and baseline match
   instead of jumping.

A serif pairing is judged on prose with its chrome sans; the chrome alone is the sans's score.
