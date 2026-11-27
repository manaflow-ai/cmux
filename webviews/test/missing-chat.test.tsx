// A tab whose chat is not in the acpmux it attached to (Lawrence 2026-10-21: "i keep seeing this
// issue"): the pane named neither the machine nor the session and offered no way on. The line now
// says where the chat ran and which session it was, and offers Resume from Transcript and Close Tab.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { MissingChat } from "../src/agent-session/acpmux/MissingChat";

const session = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc";

test("a missing chat names its machine and session and offers a way on", () => {
  const html = renderToStaticMarkup(
    <MissingChat session={session} machine="Lawrence's MacBook Pro" onResume={() => {}} onClose={() => {}} />,
  );
  expect(html).toContain("This chat isn");
  expect(html).toContain("It ran on Lawrence&#x27;s MacBook Pro (session 01a1201b-d3c3).");
  expect(html).toContain("Resume from Transcript…");
  expect(html).toContain("Close Tab");
});

test("without a machine name the line still offers both ways on", () => {
  const html = renderToStaticMarkup(<MissingChat session={session} onResume={() => {}} onClose={() => {}} />);
  expect(html).not.toContain("It ran on");
  expect(html).toContain("Resume from Transcript…");
  expect(html).toContain("Close Tab");
});
