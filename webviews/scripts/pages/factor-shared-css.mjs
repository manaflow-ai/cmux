import postcss from "postcss";

/**
 * Factors only bytes that are identical in every stylesheet and end at a top-level PostCSS node.
 * A character-prefix check alone can cut through an @media/@layer block or a quoted value.
 */
export function factorSharedCss(styles) {
  if (!styles.length) throw new Error("Pages CSS has no stylesheets");
  const first = styles[0];
  let commonLength = 0;
  while (styles.every((style) => style.length > commonLength && style[commonLength] === first[commonLength])) {
    commonLength += 1;
  }
  const boundaries = styles.map(
    (style) =>
      new Set(
        postcss
          .parse(style)
          .nodes.map((node) => node.source?.end?.offset)
          .filter((offset) => typeof offset === "number"),
      ),
  );
  while (commonLength > 0 && !boundaries.every((set) => set.has(commonLength))) commonLength -= 1;
  if (!commonLength) throw new Error("Pages CSS has no exact shared complete-rule prefix");
  const shared = first.slice(0, commonLength);
  // Moving CSS from an inline <style> to __shared changes the base directory for relative URLs.
  // Fragment/data URLs are document-independent; keep a future asset-bearing prefix inline.
  const urls = [...shared.matchAll(/url\(\s*(?:(['"])(.*?)\1|([^\s)]+))\s*\)/gi)];
  const unsafe = urls.find((match) => !/^(?:#|data:|blob:|about:)/i.test(match[2] ?? match[3] ?? ""));
  if (unsafe) throw new Error(`Pages CSS shared prefix contains a relative URL: ${unsafe[0]}`);
  return { shared, remainders: styles.map((style) => style.slice(commonLength)) };
}
