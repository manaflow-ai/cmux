import { expect, test } from "bun:test";
import { restoreForkSource } from "./restoreForkSource";

function fixture() {
  const state = {
    selected: "target",
    handoffId: "fork",
    token: 0,
    persisted: [] as string[],
    selections: [] as string[],
  };
  const recovery = {
    source: "source",
    target: "target",
    handoffId: "fork",
    selectionToken: state.token,
    currentSelectionToken: () => state.token,
    currentHandoffId: () => state.handoffId,
    selectedSession: () => state.selected,
    select: async (id: string): Promise<string | undefined> => {
      state.selections.push(id);
      state.selected = id;
      state.token += 1;
      return id;
    },
    persist: async (id: string) => {
      state.persisted.push(id);
    },
  };
  return { state, recovery };
}

test("a failed fork restores and persists the source chat", async () => {
  const { state, recovery } = fixture();
  await restoreForkSource(recovery);
  expect(state.selected).toBe("source");
  expect(state.selections).toEqual(["source"]);
  expect(state.persisted).toEqual(["source"]);
});

test("a late failure leaves a different selected chat alone", async () => {
  const { state, recovery } = fixture();
  state.selected = "another-chat";
  await restoreForkSource(recovery);
  expect(state.selections).toEqual([]);
  expect(state.persisted).toEqual([]);
});

test("a late failure leaves a replacement handoff alone", async () => {
  const { state, recovery } = fixture();
  state.handoffId = "another-fork";
  await restoreForkSource(recovery);
  expect(state.selections).toEqual([]);
  expect(state.persisted).toEqual([]);
});

test("navigation during source attachment is not persisted over", async () => {
  const { state, recovery } = fixture();
  let finish!: (id: string) => void;
  recovery.select = (id) => {
    state.selected = id;
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const restoring = restoreForkSource(recovery);
  expect(state.selected).toBe("source");
  state.selected = "another-chat";
  finish("source");
  await restoring;
  expect(state.selected).toBe("another-chat");
  expect(state.persisted).toEqual([]);
});

test("failed source attachment does not persist a session", async () => {
  const { state, recovery } = fixture();
  recovery.select = async () => {
    throw new Error("offline");
  };
  await expect(restoreForkSource(recovery)).rejects.toThrow("offline");
  expect(state.persisted).toEqual([]);
});

test("a late failure does not undo leaving and returning to the target", async () => {
  const { state, recovery } = fixture();
  await recovery.select("another-chat");
  await recovery.select("target");
  state.selections = [];
  await restoreForkSource(recovery);
  expect(state.selected).toBe("target");
  expect(state.selections).toEqual([]);
  expect(state.persisted).toEqual([]);
});

test("leaving and returning during source attachment does not persist the old selection", async () => {
  const { state, recovery } = fixture();
  const select = recovery.select;
  let finish!: (id: string) => void;
  recovery.select = (id) => {
    void select(id);
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const restoring = restoreForkSource(recovery);
  await select("another-chat");
  await select("source");
  finish("source");
  await restoring;
  expect(state.selected).toBe("source");
  expect(state.persisted).toEqual([]);
});
