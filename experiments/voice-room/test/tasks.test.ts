import { describe, expect, test } from "bun:test";
import { extractTasks, parseTasks } from "../src/digest.ts";
import type { Complete } from "../src/model.ts";
import { costUSD, HAIKU_4_5_PRICE, metered } from "../src/model.ts";
import { chiefMessage, isAddressed, type RoomTask, TaskBoard } from "../src/tasks.ts";

const ask = (over: Partial<RoomTask> = {}) => ({
  title: "Fix login page",
  ask: "Fix the login page redirect loop on staging",
  speaker: "ana",
  quote: "Chief, fix the login page redirect loop",
  addressed: true,
  ...over,
});

describe("tasks", () => {
  test("an ask spoken to Chief goes to Chief by itself; others wait for Send", async () => {
    const sent: string[] = [];
    const board = new TaskBoard(async (task) => void sent.push(task.title));
    await board.add([ask(), ask({ title: "Order lunch", ask: "Order lunch for the team", quote: "we should order lunch", addressed: false })]);
    expect(sent).toEqual(["Fix login page"]);
    expect(board.tasks.map((task) => task.state)).toEqual(["sent", "proposed"]);
    await board.dispatch(2);
    expect(sent).toEqual(["Fix login page", "Order lunch"]);
  });

  test("the model saying addressed is not enough: the quote must name the AI", () => {
    expect(isAddressed(ask({ quote: "someone should fix the login page" }))).toBe(false);
    expect(isAddressed(ask({ quote: "hey cmux, fix it", addressed: false }))).toBe(false);
    expect(isAddressed(ask())).toBe(true);
  });

  test("a repeated ask is not added twice, and a failed send can be retried", async () => {
    let fail = true;
    const board = new TaskBoard(async () => {
      if (fail) throw new Error("chief offline");
    });
    await board.add([ask()]);
    await board.add([ask({ quote: "Chief, fix the login page redirect loop please" })]);
    expect(board.tasks.length).toBe(1);
    expect(board.tasks[0]!.state).toBe("failed");
    fail = false;
    await board.dispatch(1);
    expect(board.tasks[0]!.state).toBe("sent");
  });

  test("parseTasks takes the model's JSON and ignores junk", () => {
    expect(parseTasks('Sure! {"tasks":[{"title":"A","ask":"do a","speaker":"x","quote":"q","addressed":true},{"title":""}]}')).toEqual([
      { title: "A", ask: "do a", speaker: "x", quote: "q", addressed: true },
    ]);
    expect(parseTasks("no json")).toEqual([]);
    expect(parseTasks('{"tasks": "nope"}')).toEqual([]);
  });

  test("extractTasks sends memory plus only the new lines, and is skipped when nobody spoke", async () => {
    const requests: string[] = [];
    const usage = { inputTokens: 0, outputTokens: 0, calls: 0 };
    const fake: Complete = async (request) => {
      requests.push(request.user);
      return { text: '{"tasks":[]}', inputTokens: 1000, outputTokens: 50 };
    };
    const complete = metered(fake, usage);
    expect(await extractTasks(complete, "1+1|ana: hi", [{ id: 2, kind: "screen", speaker: "ana", text: "Safari", at: 0 }])).toEqual([]);
    expect(requests.length).toBe(0);
    await extractTasks(complete, "1+1|ana: hi", [{ id: 2, kind: "speech", speaker: "bo", text: "Chief, check CI", at: 0 }]);
    expect(requests[0]).toContain("1+1|ana: hi");
    expect(requests[0]).toContain("NEW lines:\nbo: Chief, check CI");
    expect(costUSD(usage, HAIKU_4_5_PRICE)).toBeCloseTo(0.00125, 6);
  });

  test("the Chief message carries the title line, the ask, the quote and the room", () => {
    const text = chiefMessage({ ...ask(), id: 1, state: "proposed", at: 0 }, "https://mac.ts.net:4789/");
    expect(text.split("\n")[0]).toBe("Fix login page");
    expect(text).toContain("Their words: \"Chief, fix the login page redirect loop\"");
    expect(text).toContain("Room: https://mac.ts.net:4789/");
  });
});
