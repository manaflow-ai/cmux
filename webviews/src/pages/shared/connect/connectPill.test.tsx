// The status pill in each state's tone and words, when a sign-in counts as expiring, and an app
// connection drawn through the pane's connect card (`provider`): its mark, name, pill, details and
// host controls, its one named button, and Claude's own card unchanged beside it.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "../../settings/testDom";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { ConnectPill } = await import("./ConnectPill");
const { ConnectCard } = await import("../../../agent-session/acpmux/ConnectCard");
const { CONNECT_IDLE } = await import("../../../agent-session/acpmux/claudeConnect");
const { CONNECT_STATUS_KEY, CONNECT_TONE, EXPIRING_WITHIN_MS, expiryStatus } = await import("./connectStatus");
const { connectStrings } = await import("./strings");

let unmount: (() => void) | null = null;
afterEach(() => {
  unmount?.();
  unmount = null;
  document.body.replaceChildren();
});

async function draw(node: React.ReactNode): Promise<HTMLElement> {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(node));
  unmount = () => act(() => root.unmount());
  return container;
}

test("every state draws its pill in its tone and the words its host gives", async () => {
  const strings = connectStrings(["en"]);
  for (const status of Object.keys(CONNECT_TONE) as Array<keyof typeof CONNECT_TONE>) {
    const root = await draw(
      <ConnectPill status={status} label={strings.t(CONNECT_STATUS_KEY[status])} dataPrefix="connections" />,
    );
    const pill = root.querySelector<HTMLElement>(".connect-pill")!;
    expect(pill.dataset.tone).toBe(CONNECT_TONE[status]);
    expect(pill.hasAttribute("data-connections-status")).toBe(true);
    expect(pill.textContent).toBe(strings.t(`connect.status.${status}`));
    expect(pill.textContent).not.toStartWith("connect.");
    unmount?.();
    unmount = null;
  }
  const root = await draw(<ConnectPill status="connected" label="Connected · 14 tools" />);
  expect(root.textContent).toBe("Connected · 14 tools");
});

test("an app connection draws through the pane's card: its parts, one named button, its own controls", async () => {
  const ran: string[] = [];
  for (const look of ["card", "row", "steps"] as const) {
    const root = await draw(
      <ConnectCard
        look={look}
        progress={CONNECT_IDLE}
        provider={{
          mark: <span data-mark="" />,
          title: "Notion",
          line: "Pages.",
          button: "Reconnect",
          action: "reconnect",
        }}
        onBegin={() => void ran.push(look)}
        pill={<ConnectPill status="expiring" label="Expires soon" />}
        details={<span data-detail="">Sign-in expires soon.</span>}
        extra={
          <button type="button" data-extra="">
            Extra
          </button>
        }
      />,
    );
    const card = root.querySelector<HTMLElement>("[data-connect-card]")!;
    expect(card.hasAttribute("data-family")).toBe(false);
    expect(root.querySelector("[data-mark]")).not.toBeNull();
    expect(root.querySelector(".acpmux-connect-card__title")!.textContent).toBe("Notion");
    expect(root.querySelector(".acpmux-connect-card__line")!.textContent).toBe("Pages.");
    expect(root.querySelector("[data-connect-pill]")!.getAttribute("data-connect-pill")).toBe("expiring");
    expect(root.querySelector("[data-detail]")).not.toBeNull();
    expect(root.querySelector("[data-extra]")).not.toBeNull();
    // Claude's steps caption belongs to a family's sign-in, not an app's.
    expect(root.querySelector(".acpmux-connect-card__step")).toBeNull();
    const button = root.querySelector<HTMLButtonElement>('[data-connect-action="reconnect"]')!;
    expect(button.textContent).toBe("Reconnect");
    await act(async () => button.click());
    unmount?.();
    unmount = null;
  }
  expect(ran).toEqual(["card", "row", "steps"]);
});

test("Claude's card keeps its own mark, line and button", async () => {
  const root = await draw(<ConnectCard family="claude" progress={CONNECT_IDLE} onBegin={() => {}} />);
  expect(root.querySelector<HTMLElement>("[data-connect-card]")!.dataset.family).toBe("claude");
  expect(root.querySelector(".acpmux-connect-card__title")).toBeNull();
  expect(root.querySelector('[data-connect-action="begin"]')).not.toBeNull();
});

test("a sign-in is expiring inside the window, lapsed once past, and nothing without a plain date", () => {
  const now = Date.parse("2026-11-25T12:00:00Z");
  const at = (ms: number) => new Date(now + ms).toISOString();
  expect(expiryStatus(at(EXPIRING_WITHIN_MS - 1000), now)).toBe("expiring");
  expect(expiryStatus(at(EXPIRING_WITHIN_MS + 1000), now)).toBeNull();
  expect(expiryStatus(at(-1000), now)).toBe("reauth");
  expect(expiryStatus(null, now)).toBeNull();
  expect(expiryStatus("soon", now)).toBeNull();
});
