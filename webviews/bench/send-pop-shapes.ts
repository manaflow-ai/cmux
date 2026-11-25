// l10n-allow-file: bench fixture prompts, not shipped UI.
// The prompt shapes the sent-prompt pop is checked with (bench/send-pop-cases.ts, bench/send-pop-strip.ts; the
// tagged app's copy is scripts/measure/send-pop-films.py CASES). Each is what bench/send-pop-probe.js `attach` takes.
export type SendPopShape = {
  images?: number;
  tall?: boolean;
  decoding?: boolean;
  file?: boolean;
  pastedText?: number;
  text?: string;
  streaming?: boolean;
};
const LONG = Array.from({ length: 24 }, (_, index) => `line ${index + 1}: and the send behaviour too, it pops`).join(
  "\n",
);
export const SEND_POP_SHAPES: Record<string, SendPopShape> = {
  image: { images: 1 },
  images: { images: 4 },
  file: { file: true },
  tall: { tall: true },
  decoding: { decoding: true },
  "pasted-text": { pastedText: 4000 },
  "image-text": {
    images: 1,
    text: "here's an example with an attachment too, tho it doesnt necessarily change too much",
  },
  long: { text: LONG },
  streaming: { streaming: true },
};
