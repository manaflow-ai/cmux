// l10n-allow-file: type specimens (sample replies, rows and code), gallery only, not shipped UI.
// The Quillet proof (QuilletProof.gallery.ts): one sample set three times across, in the system font,
// the Folio stand-ins (FontPack.gallery.ts) and Quillet, at 13, 15 and 17 px, so a face is judged
// beside the ones it would replace at the sizes the chat draws.
import { Fragment } from "react";
import { FACES, type FaceKey } from "./candidates";
import "./QuilletProof.css";

export type ProofSample = "body" | "rows" | "code";

/// A column: its label and its stack. `face` is a study face declared through FACES; none is the
/// system stack the app draws today.
export interface ProofColumn {
  label: string;
  face?: FaceKey;
  /// The stack when `face` is absent.
  system?: string;
}

export interface QuilletProofProps {
  sample: ProofSample;
  columns: ProofColumn[];
  sizes?: number[];
}

const REPLY = (
  <>
    The retry test fails on CI because it used <strong>real timers</strong>: on a loaded runner the third attempt landed{" "}
    <em>after</em> the assertion. The backoff is 200, 400 and 800 ms, with jitter held within ±10%. All 12 tests pass
    three times in a row (0.4 s each). Il1| O0 rn m cl d — “quotes”, 3/4 & 1,234,567.89.
  </>
);

const ROWS: [string, string, string?][] = [
  ["Fix the retry test that only fails on CI under load", "2 min · main", "Working"],
  ["Sidebar: keep a dragged row's drop where the pointer is", "39 min · feat-1"],
  ["Why does the capture draw the composer two pixels lower?", "1 h · main", "2"],
  ["Migrate the settings schema to the section JSON format", "3 h · feat-3"],
  ["Billing: entitlements for teams with more than fifty seats", "Yesterday · main", "Input"],
];

const CODE = `export async function retry<T>(run: () => Promise<T>, tries = 3): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= tries || !isRetryable(error)) throw error;
      await sleep(200 * 2 ** (attempt - 1)); // Il1| O0 => != === <= {}
    }
  }
}`;

function Sample({ sample, size }: { sample: ProofSample; size: number }) {
  if (sample === "body") return <p className="quillet-proof-body">{REPLY}</p>;
  if (sample === "code") return <pre className="quillet-proof-code">{CODE}</pre>;
  return (
    <div className="quillet-proof-rows">
      <div className="quillet-proof-group">Today</div>
      {ROWS.map(([title, meta, badge], index) => (
        <div key={title} className="quillet-proof-row" data-selected={index === 0 || undefined}>
          <span className="quillet-proof-title">{title}</span>
          <span className="quillet-proof-meta">
            {meta}
            {badge ? <span className="quillet-proof-badge">{badge}</span> : null}
          </span>
        </div>
      ))}
      <div className="quillet-proof-caption">
        {size} px titles, {size - 2} px captions
      </div>
    </div>
  );
}

const stackOf = (column: ProofColumn, sample: ProofSample) =>
  column.face
    ? `"${FACES[column.face].family}", ${sample === "code" ? "ui-monospace, monospace" : "system-ui, sans-serif"}`
    : column.system;

/** Declares the study faces the columns name (the frame waits for them before it is ready). */
function Faces({ columns }: { columns: ProofColumn[] }) {
  const css = columns
    .flatMap((column) =>
      column.face ? FACES[column.face].files.map((file) => [FACES[column.face!].family, file] as const) : [],
    )
    .map(
      ([family, file]) =>
        `@font-face{font-family:"${family}";src:url(${file.url}) format("woff2");font-weight:${file.weight};font-style:normal;font-display:block}`,
    )
    .join("");
  return <style>{css}</style>;
}

export function QuilletProof({ sample, columns, sizes = [13, 15, 17] }: QuilletProofProps) {
  return (
    <div className="quillet-proof" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(0, 1fr))` }}>
      <Faces columns={columns} />
      {columns.map((column) => (
        <div key={column.label} className="quillet-proof-head">
          {column.label}
        </div>
      ))}
      {sizes.map((size) => (
        <Fragment key={size}>
          {columns.map((column) => (
            <div
              key={column.label}
              className="quillet-proof-cell"
              data-sample={sample}
              style={{ fontFamily: stackOf(column, sample), fontSize: sample === "code" ? size * 0.875 : size }}
            >
              <div className="quillet-proof-size">
                {sample === "code" ? `${size} px text, code at 0.875` : `${size} px`}
              </div>
              <Sample sample={sample} size={size} />
            </div>
          ))}
        </Fragment>
      ))}
    </div>
  );
}
