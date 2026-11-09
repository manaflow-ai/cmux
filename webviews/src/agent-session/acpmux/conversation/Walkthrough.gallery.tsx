// l10n-allow-file: gallery fixture data (synthetic steps and screenshots), not shipped UI.
// A browser walkthrough under a turn's answer (Walkthrough.tsx): what `verifyFlow` printed, as the
// pass/fail strip of screenshots.
import { componentEntry } from "../../../gallery/format";
import { BUILD_TIMES_PNG, LOGIN_SCREENSHOT_PNG } from "../../../gallery/fixtures/toolImages";
import { ImageViewerContext } from "./imageViewerContext";
import { parseWalkthrough } from "./walkthroughModel";
import type { Walkthrough as WalkthroughComponent } from "./Walkthrough";

type Props = { report: string };

const login = "/tmp/cmux-browser-host/walkthrough/run-1.jpg";
const form = "/tmp/cmux-browser-host/walkthrough/run-2.jpg";
const chipHost = {
  images: {
    [login]: `data:image/png;base64,${LOGIN_SCREENSHOT_PNG}`,
    [form]: `data:image/png;base64,${BUILD_TIMES_PNG}`,
  },
};
const shot = (path: string) => `[Image 1280x800 jpeg: ${path}]`;

const report = (value: object) => JSON.stringify({ walkthrough: 1, ...value });

const PASSED = report({
  url: "http://127.0.0.1:5173/",
  passed: true,
  steps: [
    { n: 1, line: "Open the sign-in page", ok: true, screenshot: shot(login) },
    { n: 2, line: 'Type "ada@example.com" into #email', ok: true, screenshot: shot(login) },
    { n: 3, line: "Click Sign in", ok: true, screenshot: shot(form) },
    { n: 4, line: 'See "Build times"', ok: true, screenshot: shot(form) },
  ],
});

const FAILED = report({
  url: "http://127.0.0.1:5173/settings",
  passed: false,
  steps: [
    { n: 1, line: "Open Settings", ok: true, screenshot: shot(login) },
    { n: 2, line: 'Type "Ada" into #name', ok: true, screenshot: shot(login) },
    { n: 3, line: 'See "Saved"', ok: false, error: 'Timeout 5000ms exceeded waiting for text "Saved"', screenshot: shot(form) },
    { n: 4, line: "Reload and see the new name", ok: false, skipped: true },
  ],
});

const NO_SERVER = report({
  url: "http://127.0.0.1:5173/",
  passed: false,
  error: "No dev server answers at http://127.0.0.1:5173. Start it (bg_start) and run verifyFlow again.",
  steps: [
    { n: 1, line: "Open /", ok: false, error: "No dev server answers at http://127.0.0.1:5173." },
    { n: 2, line: 'See "Welcome back"', ok: false, skipped: true },
  ],
});

const LONG = report({
  url: "http://localhost:3000/checkout",
  passed: true,
  steps: Array.from({ length: 9 }, (_, i) => ({
    n: i + 1,
    line: ["Open the cart", "Add a second item", "Click Checkout", "Fill the address", "Pick express", "Click Pay", "See the receipt", "Open Orders", "See the new order first"][i],
    ok: true,
    screenshot: shot(i % 2 ? form : login),
  })),
});

function galleryWalkthrough(Walkthrough: typeof WalkthroughComponent) {
  return function GalleryWalkthrough({ report }: Props) {
    const walkthrough = parseWalkthrough(report)!;
    return (
      <ImageViewerContext.Provider value={() => {}}>
        <div style={{ padding: 16 }}>
          <p style={{ margin: "0 0 8px" }}>The settings form saves the name now; I checked it in the browser.</p>
          <Walkthrough id="gallery" walkthrough={walkthrough} />
        </div>
      </ImageViewerContext.Provider>
    );
  };
}

export default componentEntry<Props>({
  id: "agent-pane.verify-walkthrough",
  title: "Verify walkthrough",
  area: "Agent pane",
  pane: true,
  height: 280,
  covers: ["agent-session/acpmux/conversation/Walkthrough.tsx#Walkthrough"],
  load: async () => galleryWalkthrough((await import("./Walkthrough")).Walkthrough),
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("./Walkthrough.css"),
    ]),
  widths: { narrow: 420, normal: 720 },
  variants: {
    passed: {
      note: "Every step passed: a green head, then one shot per step with its line.",
      props: { report: PASSED },
      chipHost,
    },
    "failed-expectation": {
      note: "Step 3's expected text never showed: a red head names the step, the shot is ringed red with the reason under it, and the step after it is skipped.",
      props: { report: FAILED },
      chipHost,
    },
    "no-dev-server": {
      note: "Nothing answered at the address: the head says so, the reason tells the agent to start the server, and no shot is taken.",
      props: { report: NO_SERVER },
      chipHost,
    },
    "long-flow": {
      note: "Nine steps scroll sideways in the strip; the transcript's height does not grow with the step count.",
      props: { report: LONG },
      chipHost,
    },
  },
});
