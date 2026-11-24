// Leo 2026-11-24 (ask-97938b6c84): a terminal agent chat draws its mark as a reverse-video tile; a GUI chat keeps
// the bare mark. The tile's geometry is the native one (TerminalMarkTile.swift): a 12 mark with 4 px corners on a
// 16 tile, a 20 mark with 8 px corners on iPhone's 32.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { TerminalChatMark, terminalTileMarkSize, terminalTileRadius } from "./TerminalChatMark";

test("the tile's mark and corner follow the icon scale", () => {
  expect(terminalTileMarkSize(16)).toBe(12);
  expect(terminalTileRadius(16)).toBe(4);
  expect(terminalTileMarkSize(32)).toBe(20);
  expect(terminalTileRadius(32)).toBe(8);
  expect(terminalTileMarkSize(14)).toBe(10);
});

test("a terminal chat draws the ink tile, a GUI chat the bare mark", () => {
  const tile = renderToStaticMarkup(<TerminalChatMark agent="claude" size={16} variant="tile" tileStyle="ink" />);
  expect(tile).toContain('data-terminal-chat="tile"');
  expect(tile).toContain('data-tile-style="ink"');
  const gui = renderToStaticMarkup(
    <TerminalChatMark agent="claude" size={16} variant="tile" tileStyle="ink" terminal={false} />,
  );
  expect(gui).not.toContain("data-terminal-chat");
});
