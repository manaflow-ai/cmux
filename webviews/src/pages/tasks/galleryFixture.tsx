// l10n-allow-file: public-safe gallery fixtures.
import { useEffect, useState } from "react";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockTasksProvider, sampleSnapshot } from "./mockProvider";
import { TasksStore } from "./store";
import { TasksPage } from "./TasksPage";
import type { Layout, Scope, Snapshot, Task } from "./types";

export type TasksFixtureState = "normal" | "empty" | "owner-missing" | "owner-lost" | "pending" | "rejected" | "many";

/** 400 tasks across every status: the lists stay virtualized (constant work as tasks grow). */
function manyTasks(snapshot: Snapshot): Task[] {
  const statuses = snapshot.statuses.filter((status) => status.category !== "canceled");
  return Array.from({ length: 400 }, (_, index): Task => ({
    id: `task_m${index}`,
    number: 100 + index,
    title: `Backlog item ${index + 1}: tune the ${["sidebar", "board", "inbox", "palette"][index % 4]} for long titles that wrap`,
    status: statuses[index % statuses.length]!.id,
    priority: (["none", "low", "medium", "high", "urgent"] as const)[index % 5],
    assignee: index % 3 === 0 ? { kind: "user", id: "usr_lawrence" } : null,
    labels: index % 4 === 0 ? ["lbl_perf"] : [],
    sort_key: String(1000 + index),
    updated_at: 1_759_400_000_000 - index * 60_000,
  }));
}

export function TasksGallery({
  layout = "inbox",
  state = "normal",
  scope = "all",
}: {
  layout?: Layout;
  state?: TasksFixtureState;
  scope?: Scope;
}) {
  const [strings] = useState(() => createStrings(table));
  const [store] = useState(() => {
    const snapshot = sampleSnapshot();
    if (state === "empty") snapshot.tasks = [];
    if (state === "many") snapshot.tasks = [...snapshot.tasks, ...manyTasks(snapshot)];
    const provider = new MockTasksProvider(snapshot);
    provider.ownerDown = state === "owner-missing";
    if (state === "pending") provider.answerImmediately = false;
    if (state === "rejected") provider.rejectKeys.add("gallery-1");
    let key = 0;
    const created = new TasksStore(provider, { visible: () => false, newKey: () => `gallery-${++key}` });
    created.setScope(scope);
    return { created, provider };
  });
  useEffect(() => {
    const { created, provider } = store;
    const stop = created.subscribe(() => {});
    void created.start().then(() => {
      if (state === "owner-lost") provider.loseOwner();
      if (state === "pending") {
        created.setStatus("task_5", "st_done");
        created.createTask("Draft the release note");
      }
      if (state === "rejected") created.archive("task_3");
      created.select(state === "many" ? "task_m3" : "task_1");
    });
    return stop;
  }, [store, state]);
  return (
    <div style={{ height: "100%" }}>
      <TasksPage store={store.created} strings={strings} layout={layout} copy={() => {}} />
    </div>
  );
}
