import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Avatar } from "../src/pages/home-channels/Avatar";

test("Home avatars limit complete initials at both display sizes", () => {
  for (const [name, small, large] of [
    ["🦊 Fox", "🦊", "🦊F"],
    ["👩🏽‍💻 Priya", "👩🏽‍💻", "👩🏽‍💻P"],
    ["🇯🇵 Japan", "🇯🇵", "🇯🇵J"],
    ["𠮷田", "𠮷", "𠮷田"],
    ["e\u0301lodie", "E\u0301", "E\u0301L"],
    ["  Sam Lee", "S", "SL"],
    ["ß", "S", "SS"],
    ["", "?", "?"],
    ["   ", "?", "?"],
  ]) {
    for (const [size, expected] of [
      [20, small],
      [24, large],
    ] as const) {
      const html = renderToStaticMarkup(
        <Avatar participant={{ id: "person", kind: "human", name: name!, chief: false }} size={size} />,
      );
      expect(html).toContain(`>${expected}</span>`);
    }
  }
});
