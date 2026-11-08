import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test, vi } from "vitest";
import { StuckBanner } from "./StuckBanner";

describe("StuckBanner", () => {
  test("keeps the diagnosis visible and offers an editable nudge", () => {
    const onNudge = vi.fn();
    const html = renderToStaticMarkup(
      <StuckBanner diagnosis="Repeated cargo test 3 times; the same call keeps failing" onNudge={onNudge} />,
    );
    expect(html).toContain("Agent may be stuck");
    expect(html).toContain("Repeated cargo test 3 times");
    expect(html).toContain("Nudge with hint");
    expect(html).toContain('role="status"');
  });
});
