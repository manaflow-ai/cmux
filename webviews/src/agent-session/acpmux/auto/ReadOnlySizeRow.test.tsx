import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AutoComputerRows } from "./AutoComputerRows";
import { STATES } from "./AutoComputer.fixtures";
import { ReadOnlySizeRow } from "./ReadOnlySizeRow";

const noop = () => undefined;
const rows = (extra: Partial<Parameters<typeof AutoComputerRows>[0]>) =>
  renderToStaticMarkup(
    <AutoComputerRows
      status={STATES.cloudAwake}
      onAutoSize={noop}
      onPinSize={noop}
      onSleep={noop}
      onOpenTerminal={noop}
      onOpenDetails={noop}
      {...extra}
    />,
  );

test("with no view from the core (setting off) the old Auto / Pin row is drawn", () => {
  const html = rows({});
  expect(html).toContain("Pin…");
  expect(html).not.toContain("More room");
});

test("with a view the Size row is read-only and offers More room, naming no size", () => {
  const html = rows({
    sizeView: { now: { vcpu: 2, memory_gib: 4 }, more_room: "offered", raises_to: { vcpu: 8, memory_gib: 32 } },
  });
  expect(html).toContain("now 2 vCPU · 4 GB, grows as it works");
  expect(html).toMatch(/<button[^>]*>More room<\/button>/);
  expect(html).not.toContain("Pin…");
  expect(html).not.toContain("8 vCPU");
});

test("once asked it reads More room: on, with no button", () => {
  const html = renderToStaticMarkup(
    <ReadOnlySizeRow view={{ now: { vcpu: 8, memory_gib: 32 }, more_room: "on" }} onMoreRoom={noop} />,
  );
  expect(html).toContain("More room: on");
  expect(html).not.toContain("<button");
});

test("hidden draws the size alone, and nothing without a cloud computer", () => {
  const html = renderToStaticMarkup(<ReadOnlySizeRow view={{ more_room: "hidden" }} onMoreRoom={noop} />);
  expect(html).not.toContain("<button");
  expect(html).not.toContain("vCPU");
});
