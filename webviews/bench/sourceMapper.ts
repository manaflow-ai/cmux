// l10n-allow-file: benchmark output, not shipped UI.
import fs from "node:fs";
import path from "node:path";

/// A bundle position back to its source file and line, from the build's source map (a VLQ decode, so
/// the bench needs no source-map package).
export function sourceMapper(dir: string) {
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  type Mapped = { sources: string[]; lines: number[][][] };
  const cache = new Map<string, Mapped | null>();
  function load(file: string): Mapped | null {
    const mapFile = path.join(dir, "assets", `${file}.map`);
    if (!fs.existsSync(mapFile)) return null;
    const raw = JSON.parse(fs.readFileSync(mapFile, "utf8")) as {
      sources: string[];
      mappings: string;
    };
    let source = 0;
    let line = 0;
    let column = 0;
    const lines = raw.mappings.split(";").map((segment) => {
      let generated = 0;
      return segment
        .split(",")
        .filter(Boolean)
        .map((part) => {
          const values: number[] = [];
          let shift = 0;
          let value = 0;
          for (const char of part) {
            const digit = B64.indexOf(char);
            value += (digit & 31) << shift;
            if (digit & 32) shift += 5;
            else {
              values.push(value & 1 ? -(value >> 1) : value >> 1);
              value = 0;
              shift = 0;
            }
          }
          generated += values[0]!;
          if (values.length > 1) {
            source += values[1]!;
            line += values[2]!;
            column += values[3]!;
          }
          return [generated, source, line, column];
        });
    });
    return { sources: raw.sources, lines };
  }
  return (file: string, lineNumber: number, columnNumber: number): string => {
    if (!cache.has(file)) cache.set(file, load(file));
    const map = cache.get(file);
    const segments = map?.lines[lineNumber];
    if (!map || !segments?.length) return `${file}:${lineNumber + 1}`;
    let best = segments[0]!;
    for (const segment of segments) if (segment[0]! <= columnNumber) best = segment;
    return `${map.sources[best[1]!]?.replace(/^(\.\.\/)+/, "")}:${best[2]! + 1}`;
  };
}
