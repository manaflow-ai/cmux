// l10n-allow-file: test fixture messages, not shipped UI.
// Leo, 2026-11-06: "do we not have a good path for them sending images to you? Linking images to
// you? Having them show up as previews?" A Codex lane handed over screenshots as ChatGPT library
// ids (`libfile_…`) that nobody here can open. The chat names such an id as one it cannot open,
// never as a file, a link or an image, in a message from another agent and in a prompt alike.
import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { foreignFileIds } from "../src/agent-session/acpmux/chips/paths";
import { AgentMessageBody } from "../src/agent-session/acpmux/conversation/AgentMessageBody";
import { PromptText } from "../src/agent-session/acpmux/conversation/PromptText";
import { translate } from "../src/agent-session/acpmux/i18n";
import { useDom } from "./support/unknownWrite";

useDom();

const SENT =
  "Screenshot IMG_6165.png, library file libfile_c11cc7d347448191ac0b4dbb221437bf. See also sediment://file_00000000abc.";

test("finds ChatGPT's file ids and nothing else", () => {
  expect(foreignFileIds(SENT).map((id) => id.value)).toEqual([
    "libfile_c11cc7d347448191ac0b4dbb221437bf",
    "sediment://file_00000000abc",
  ]);
  expect(foreignFileIds("the libfile_ prefix, a/libfile_c11cc7d3474481 path, my_libfile_c11cc7d3474481")).toEqual([]);
});

async function render(node: React.ReactNode): Promise<HTMLElement> {
  const host = document.createElement("div");
  document.body.append(host);
  await act(async () => createRoot(host).render(node));
  return host;
}

for (const [name, node] of [
  ["another agent's message", <AgentMessageBody key="message" text={SENT} />],
  ["a prompt", <PromptText key="prompt" rowId="r1" text={SENT} show={(text) => text} />],
] as const)
  test(`${name} shows a foreign file id as one it cannot open`, async () => {
    const host = await render(node);
    const refs = [...host.querySelectorAll(".cv-foreign-file")];
    expect(refs.map((ref) => ref.querySelector(".cv-foreign-file__id")?.textContent)).toEqual([
      "libfile_c11cc7d3…",
      "sediment://file_…",
    ]);
    for (const ref of refs) {
      expect(ref.querySelector(".cv-foreign-file__note")?.textContent).toBe(translate("message.foreignFile"));
      expect(ref.closest("a, button")).toBeNull();
    }
    expect(host.querySelector("img")).toBeNull();
    expect(host.textContent).toContain("Screenshot IMG_6165.png");
  });

// Review of #37203: an id in a code span or as an image's source, and one in a prompt too large to
// draw as anything but literal text (#29840), is named the same way.
const ID = "libfile_c11cc7d347448191ac0b4dbb221437bf";
for (const [name, node] of [
  ["a code span", <AgentMessageBody key="code" text={`The shot is \`${ID}\`.`} />],
  ["an image's source", <AgentMessageBody key="image" text={"Here: ![the card](sediment://file_00000000abc)"} />],
  [
    "a huge prompt",
    <PromptText key="huge" rowId="r2" text={`see ${ID} ${"x".repeat(210_000)}`} show={(text) => text} />,
  ],
] as const)
  test(`${name} shows a foreign file id as one it cannot open`, async () => {
    const host = await render(node);
    const refs = [...host.querySelectorAll(".cv-foreign-file")];
    expect(refs.length).toBe(1);
    expect(refs[0]!.querySelector(".cv-foreign-file__note")?.textContent).toBe(translate("message.foreignFile"));
    expect(host.querySelector("img, code")).toBeNull();
  });

// Review of #37560: a prompt of ids alone stops the scan past the cap, so it never collects every
// id, and stays one text node.
test("a huge prompt of ids stops collecting past the cap and stays plain text", async () => {
  const ids = Array.from({ length: 5000 }, (_, i) => `libfile_${String(i).padStart(12, "0")}`).join(" ");
  expect(foreignFileIds(ids, 64).length).toBe(65);
  const host = await render(<PromptText rowId="r3" text={`${ids} ${"x".repeat(210_000)}`} show={(text) => text} />);
  expect(host.querySelectorAll(".cv-foreign-file").length).toBe(0);
});
