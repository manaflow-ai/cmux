import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { ChatHeaderStatus } from "./ChatHeaderStatus";
import { installDom, press, render, restoreDom, settle, unmount } from "../../../../test/viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

test("connected is quiet; a failure is keyboard focusable with complete portaled detail", async () => {
  const quiet = await render(<ChatHeaderStatus status="" />);
  expect(quiet.querySelector("output")).toBeNull();
  const detail = `Gateway failed: https://example.com/${"long-path/".repeat(30)}`;
  const root = await render(<ChatHeaderStatus status="Failed" detail={detail} />);
  const status = root.querySelector<HTMLElement>(".acpmux-status")!;
  expect(status.textContent).toBe("Failed");
  expect(status.title).toBe(detail);
  const trigger = root.querySelector<HTMLElement>("[tabindex='0']");
  expect(trigger).not.toBeNull();
  // Base UI distinguishes keyboard focus from pointer focus.
  await press(document.body, "Tab");
  trigger!.focus();
  await settle();
  const tooltip = document.querySelector('[role="tooltip"]');
  expect(tooltip?.textContent).toContain(detail);
  expect(root.contains(tooltip)).toBe(false);
  await press(trigger!, "Escape");
  expect(document.querySelector('[role="tooltip"]')).toBeNull();
});
