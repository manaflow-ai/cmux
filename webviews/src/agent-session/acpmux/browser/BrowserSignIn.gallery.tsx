// l10n-allow-file: synthetic gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export default componentEntry({
  id: "agent-pane.browser-sign-in",
  title: "Browser sign-in",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 360, normal: 720, wide: 1100 },
  covers: ["agent-session/acpmux/browser/BrowserSignIn.tsx#BrowserSignIn"],
  load: async () => {
    const { BrowserSignIn } = await import("./BrowserSignIn");
    type Props = Parameters<typeof BrowserSignIn>[0];
    return ({
      look = "card",
      block,
      code,
      reason,
    }: {
      look?: Props["look"];
      block?: Props["block"];
      code?: boolean;
      reason?: string;
    }) => (
      <BrowserSignIn
        look={look}
        block={block}
        host="leos-macbook.tail1234.ts.net"
        initial={{ step: code ? { at: "code", email: "leo@example.com" } : undefined, reason }}
        transport={{
          start: async () => {
            await wait(400);
            return { expiresIn: 300 };
          },
          complete: async () => {
            await wait(400);
            throw Object.assign(new Error("code"), { reason: "browser.sign_in.code_refused" });
          },
          close: () => undefined,
        }}
        onSignedIn={() => undefined}
      />
    );
  },
  styles: () => Promise.all([import("../../../ui/ui.css"), import("./browserSignIn.css")]),
  variants: {
    "card-email": { props: { look: "card" } },
    "card-code": { props: { look: "card", code: true } },
    "pane-email": { props: { look: "pane" } },
    "pane-code": { props: { look: "pane", code: true } },
    "split-email": { props: { look: "split" } },
    "split-code": { props: { look: "split", code: true } },
    "code-refused": { props: { look: "card", code: true, reason: "browser.sign_in.code_refused" } },
    unconfigured: { props: { look: "card", reason: "signin.unconfigured" } },
    insecure: { props: { look: "card", block: "insecure" } },
    "no-link": { props: { look: "card", block: "noLink" } },
  },
});
