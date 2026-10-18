import { describe, expect, test } from "bun:test";
import { recentChatCards } from "../src/agent-session/acpmux/newtab/screenModel";
import { translate } from "../src/agent-session/acpmux/i18n";

describe("recent chat identity", () => {
  test("keeps distinct device chats that share a title", () => {
    const cards = recentChatCards(
      [],
      1_000,
      translate,
      [
        { key: "claude:newer", harness: "claude", title: "Untitled", updatedAt: 1_000 },
        { key: "claude:older", harness: "claude", title: "Untitled", updatedAt: 900 },
      ],
      3,
      false,
    );

    expect(cards.map((card) => card.chatKey)).toEqual(["claude:newer", "claude:older"]);
  });
});
