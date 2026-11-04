import { describe, expect, test } from "bun:test";
import { SlackConnectionController, type SlackConnection } from "./slackConnection";

const connected: SlackConnection = {
  connected: true,
  teams: [{ slackTeamId: "T1", name: "Example workspace", cmuxTeamId: "team-1" }],
};
const disconnected = { connected: false, teams: [] };
function harness(reply: (method: string, op: string) => unknown | Promise<unknown>) {
  const calls: Array<{ op: string; method?: string; url?: string }> = [];
  const controller = new SlackConnectionController({
    async call<R>(op: string, params: unknown): Promise<R> {
      const args = params as { method?: string; url?: string };
      calls.push({ op, ...args });
      return (await reply(args.method ?? "open", op)) as R;
    },
  });
  return { controller, calls };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("Slack connection", () => {
  test("opens the install link once and confirms only the server's connection", async () => {
    let installed = false;
    const { controller, calls } = harness((method) =>
      method === "POST"
        ? { url: "https://platform.example/v1/slack/install?ticket=one-use" }
        : method === "GET"
          ? installed
            ? connected
            : disconnected
          : {},
    );
    await controller.refresh();
    await Promise.all([controller.connect(), controller.connect()]);
    expect(calls.filter((call) => call.method === "POST")).toHaveLength(1);
    expect(calls.at(-1)).toEqual({
      op: "cmux.settings.slack.open",
      url: "https://platform.example/v1/slack/install?ticket=one-use",
    });
    expect(controller.getSnapshot().phase).toBe("awaiting");
    await controller.refresh(true);
    expect(controller.getSnapshot().confirmed).toBe(false);
    installed = true;
    await controller.refresh(true);
    expect(controller.getSnapshot()).toMatchObject({ phase: "ready", teams: connected.teams, confirmed: true });
  });

  test("rejects unsafe install URLs and lets a failed connect retry", async () => {
    let url = "javascript:alert(1)";
    const { controller, calls } = harness(() => ({ url }));
    await controller.connect();
    expect(controller.getSnapshot().error).toBe("failed");
    expect(calls.some((call) => call.op.endsWith(".open"))).toBe(false);
    url = "https://platform.example/install";
    await controller.connect();
    expect(controller.getSnapshot().phase).toBe("awaiting");
  });

  test("late refresh cannot overwrite a new connect", async () => {
    const read = deferred<SlackConnection>();
    const { controller } = harness((method) =>
      method === "GET" ? read.promise : { url: "https://platform.example/install" },
    );
    const refresh = controller.refresh();
    await controller.connect();
    read.resolve(disconnected);
    await refresh;
    expect(controller.getSnapshot().phase).toBe("awaiting");
  });

  test("a callback during browser opening is refreshed after opening finishes", async () => {
    const opening = deferred<object>();
    const { controller } = harness((method) =>
      method === "open" ? opening.promise : method === "GET" ? connected : { url: "https://platform.example/install" },
    );
    const connect = controller.connect();
    await controller.refresh(true);
    opening.resolve({});
    await connect;
    expect(controller.getSnapshot().confirmed).toBe(true);
  });

  test("failed disconnect preserves the workspace and permits retry", async () => {
    let fail = true;
    let installed = true;
    const { controller } = harness((method) => {
      if (method === "DELETE") {
        if (fail) throw new Error("offline");
        installed = false;
      }
      return installed ? connected : disconnected;
    });
    await controller.refresh();
    await controller.disconnect();
    expect(controller.getSnapshot()).toMatchObject({ teams: connected.teams, error: "failed" });
    fail = false;
    await controller.disconnect();
    expect(controller.getSnapshot()).toMatchObject({ teams: [], error: null });
  });

  test("disposed account ignores late replies and browser opens", async () => {
    const install = deferred<{ url: string }>();
    const { controller, calls } = harness(() => install.promise);
    const connecting = controller.connect();
    controller.dispose();
    install.resolve({ url: "https://platform.example/install" });
    await connecting;
    expect(calls).toHaveLength(1);
  });

  test("auth and deployment errors have useful messages without exposing server text", async () => {
    for (const [code, expected] of [
      ["slack.unauthorized", "signIn"],
      ["slack.not_found", "unavailable"],
    ] as const) {
      const { controller } = harness(() => {
        throw { code, message: "private details" };
      });
      await controller.refresh();
      expect(controller.getSnapshot().error).toBe(expected);
    }
  });

  test("rejects malformed team entries instead of exposing them to the row", async () => {
    for (const teams of [[null], [{}], [{ slackTeamId: "T1", name: "", cmuxTeamId: "team-1" }]]) {
      const { controller } = harness(() => ({ connected: true, teams }));
      await controller.refresh();
      expect(controller.getSnapshot()).toMatchObject({ phase: "ready", teams: [], error: "failed" });
    }
  });
});
