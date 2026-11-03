import { expect, test } from "bun:test";
import { createCommitMeasurements } from "./commitMeasurements";

function harness() {
  const scheduled: Array<() => void> = [];
  const events: string[] = [];
  const queue = createCommitMeasurements(
    (run) => scheduled.push(run),
    (run) => {
      events.push("commit:start");
      run();
      events.push("commit:end");
    },
  );
  const measure = (name: string) => () => {
    events.push(`read:${name}`);
    return () => {
      events.push(`apply:${name}`);
    };
  };
  return { queue, scheduled, events, measure };
}

test("a parent drain reads every sibling before applying any correction", () => {
  const { queue, scheduled, events, measure } = harness();
  queue.enqueue(measure("a"));
  queue.enqueue(() => {
    events.push("read:unchanged");
    return undefined;
  });
  queue.enqueue(measure("b"));
  expect(events).toEqual([]);
  expect(scheduled).toHaveLength(1);

  queue.flush();
  expect(events).toEqual(["read:a", "read:unchanged", "read:b", "apply:a", "apply:b"]);
});

test("cancelling an obsolete registration leaves its replacement measurable", () => {
  const { queue, scheduled, events, measure } = harness();
  const cancel = queue.enqueue(measure("obsolete"));
  cancel();
  queue.enqueue(measure("replacement"));
  cancel();

  scheduled[0]!();
  expect(events).toEqual([]);
  scheduled[1]!();
  expect(events).toEqual(["commit:start", "read:replacement", "apply:replacement", "commit:end"]);
});

test("cancellation during an earlier read prevents a later detached-batch read", () => {
  const { queue, events, measure } = harness();
  let cancelLater = () => {};
  queue.enqueue(() => {
    events.push("read:first");
    cancelLater();
    return () => {
      events.push("apply:first");
    };
  });
  cancelLater = queue.enqueue(measure("obsolete"));

  queue.flush();
  expect(events).toEqual(["read:first", "apply:first"]);
});

test("cancellation after a read prevents its already-collected correction", () => {
  const { queue, events, measure } = harness();
  const cancel = queue.enqueue(measure("obsolete"));
  queue.enqueue(() => {
    events.push("read:replacement");
    cancel();
    return () => {
      events.push("apply:replacement");
    };
  });

  queue.flush();
  expect(events).toEqual(["read:obsolete", "read:replacement", "apply:replacement"]);
});

test("cancellation during an earlier correction prevents a later correction", () => {
  const { queue, events, measure } = harness();
  let cancelLater = () => {};
  queue.enqueue(() => {
    events.push("read:first");
    return () => {
      events.push("apply:first");
      cancelLater();
    };
  });
  cancelLater = queue.enqueue(measure("obsolete"));

  queue.flush();
  expect(events).toEqual(["read:first", "read:obsolete", "apply:first"]);
});

test("a parent drain invalidates its fallback without consuming a newer batch", () => {
  const { queue, scheduled, events, measure } = harness();
  queue.enqueue(measure("parent"));
  queue.flush();
  expect(events).toEqual(["read:parent", "apply:parent"]);
  events.length = 0;
  queue.enqueue(measure("child"));

  scheduled[0]!();
  expect(events).toEqual([]);
  scheduled[1]!();
  expect(events).toEqual(["commit:start", "read:child", "apply:child", "commit:end"]);
  events.length = 0;
  queue.flush();
  expect(events).toEqual([]);
});

test("a child-only commit drains in one microtask through the commit boundary", async () => {
  const events: string[] = [];
  const queue = createCommitMeasurements(undefined, (run) => {
    events.push("commit:start");
    run();
    events.push("commit:end");
  });
  for (const name of ["a", "b"]) {
    queue.enqueue(() => {
      events.push(`read:${name}`);
      return () => {
        events.push(`apply:${name}`);
      };
    });
  }
  expect(events).toEqual([]);

  await Promise.resolve();
  expect(events).toEqual(["commit:start", "read:a", "read:b", "apply:a", "apply:b", "commit:end"]);
});

test.each(["read", "apply"] as const)("reentrant enqueue during %s belongs to the next batch", (phase) => {
  const { queue, scheduled, events, measure } = harness();
  queue.enqueue(() => {
    events.push("read:first");
    if (phase === "read") queue.enqueue(measure("next"));
    return () => {
      events.push("apply:first");
      if (phase === "apply") queue.enqueue(measure("next"));
    };
  });
  queue.flush();
  expect(events).toEqual(["read:first", "apply:first"]);
  expect(scheduled).toHaveLength(2);
  events.length = 0;

  scheduled[0]!();
  expect(events).toEqual([]);
  scheduled[1]!();
  expect(events).toEqual(["commit:start", "read:next", "apply:next", "commit:end"]);
});

test("clear cancels cleanup work but permits a StrictMode-style setup on the same queue", () => {
  const { queue, scheduled, events, measure } = harness();
  const cancelOld = queue.enqueue(measure("old"));
  queue.clear();
  queue.clear();
  queue.enqueue(measure("remount"));
  cancelOld();

  scheduled[0]!();
  expect(events).toEqual([]);
  scheduled[1]!();
  expect(events).toEqual(["commit:start", "read:remount", "apply:remount", "commit:end"]);
});

test.each(["read", "apply"] as const)("clear during %s cancels the rest of the active batch", (phase) => {
  const { queue, events, measure } = harness();
  queue.enqueue(() => {
    events.push("read:first");
    if (phase === "read") queue.clear();
    return () => {
      events.push("apply:first");
      if (phase === "apply") queue.clear();
    };
  });
  queue.enqueue(measure("obsolete"));

  queue.flush();
  expect(events).toEqual(phase === "read" ? ["read:first"] : ["read:first", "read:obsolete", "apply:first"]);
  queue.enqueue(measure("reuse"));
  queue.flush();
  expect(events.slice(-2)).toEqual(["read:reuse", "apply:reuse"]);
});
