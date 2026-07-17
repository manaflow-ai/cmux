import type { RenderRun, RenderUnderline } from "cmux/browser";

export const renderAttrs = {
  bold: 0x0001,
  italic: 0x0002,
  strikethrough: 0x0004,
  inverse: 0x0008,
  dim: 0x0010,
  invisible: 0x0020,
  blink: 0x0040,
} as const;

export interface RunPresentation {
  className: string;
  style: {
    color: string;
    backgroundColor: string;
    textDecorationLine?: string;
    width?: string;
  };
}

const underlineClasses: Record<RenderUnderline, string> = {
  single: "render-underline-single",
  double: "render-underline-double",
  curly: "render-underline-curly",
  dotted: "render-underline-dotted",
  dashed: "render-underline-dashed",
};

export function runPresentation(run: RenderRun, defaultFg: string, defaultBg: string): RunPresentation {
  const inverse = (run.attrs & renderAttrs.inverse) !== 0;
  const resolvedFg = run.fg ?? defaultFg;
  const resolvedBg = run.bg ?? defaultBg;
  const classes = ["render-run"];
  if ((run.attrs & renderAttrs.bold) !== 0) classes.push("render-run-bold");
  if ((run.attrs & renderAttrs.italic) !== 0) classes.push("render-run-italic");
  if ((run.attrs & renderAttrs.dim) !== 0) classes.push("render-run-dim");
  if ((run.attrs & renderAttrs.invisible) !== 0) classes.push("render-run-invisible");
  if ((run.attrs & renderAttrs.blink) !== 0) classes.push("render-run-blink");
  if (inverse) classes.push("render-run-inverse");
  if (run.underline !== undefined) classes.push("render-run-underline", underlineClasses[run.underline]);

  const decorations: string[] = [];
  if (run.underline !== undefined) decorations.push("underline");
  if ((run.attrs & renderAttrs.strikethrough) !== 0) {
    classes.push("render-run-strikethrough");
    decorations.push("line-through");
  }

  return {
    className: classes.join(" "),
    style: {
      color: inverse ? resolvedBg : resolvedFg,
      backgroundColor: inverse ? resolvedFg : resolvedBg,
      ...(decorations.length > 0 ? { textDecorationLine: decorations.join(" ") } : {}),
      ...(run.width_hint === undefined
        ? {}
        : { width: `calc(var(--render-cell-width) * ${run.width_hint})` }),
    },
  };
}
