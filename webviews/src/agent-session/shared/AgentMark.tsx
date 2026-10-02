import React, { useId, useSyncExternalStore } from "react";
import { agentKey } from "./agentKey";

export { agentKey };

/// A color, or one per theme: [on dark, on light].
export type Tone = string | readonly [dark: string, light: string];

/// A path; a multi-tone mark gives a path its own brand tone, and its mono opacity.
export type MarkPath = string | { d: string; brand?: Tone; opacity?: number };

/// A linear gradient laid over the whole mark in brand color (Gemini's highlights).
export type MarkGradient = {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  stops: readonly (readonly [offset: number, color: string, opacity?: number])[];
};

/// One agent's mark. In brand color (the default) it fills with the vendor's colors,
/// so it sits beside browser tabs' full-color favicons; in mono it fills white on a
/// dark theme and black on a light one. `source` names the artwork's origin row in
/// AGENT_MARKS.md.
export type AgentMarkSpec = {
  viewBox: string;
  paths: readonly MarkPath[];
  fillRule?: "evenodd";
  brand: Tone;
  overlays?: readonly MarkGradient[];
  source: string;
};

// The Blossom is OpenAI's mark in black or white only, and that is its brand color too.
const OPENAI_BLOSSOM: AgentMarkSpec = {
  // The official file pads the glyph with its clear space; the view crops to the glyph.
  viewBox: "176 176 364 364",
  paths: [
    "M508.749 317.399C516.777 287.314 508.991 253.884 485.389 230.282C461.788 206.681 428.36 198.895 398.273 206.923C376.231 184.928 343.39 174.956 311.148 183.596C278.906 192.234 255.45 217.292 247.36 247.361C217.291 255.451 192.233 278.91 183.595 311.149C174.957 343.391 184.927 376.232 206.924 398.274C198.896 428.359 206.683 461.789 230.284 485.391C253.885 508.992 287.313 516.779 317.401 508.75C339.442 530.745 372.286 540.717 404.525 532.079C436.767 523.441 460.223 498.384 468.313 468.315C498.383 460.224 523.44 436.766 532.078 404.526C540.716 372.285 530.747 339.443 508.749 317.402V317.399ZM470.899 244.776C486.892 260.77 493.488 282.601 490.687 303.412L415.577 260.046C412.411 258.218 408.509 258.218 405.345 260.046L317.401 310.82V277.526C317.401 275.191 318.652 273.005 320.676 271.837L387.644 233.174C414.178 218.353 448.346 222.223 470.901 244.776H470.899ZM357.837 311.144L398.275 334.491V381.185L357.837 404.532L317.398 381.185V334.491L357.837 311.144ZM264.776 269.693C265.207 239.305 285.644 211.649 316.453 203.393C338.3 197.54 360.505 202.744 377.127 215.573L302.014 258.937C298.848 260.764 296.898 264.144 296.898 267.798V369.346L268.065 352.699C266.043 351.531 264.776 349.353 264.776 347.017V269.691V269.693ZM203.391 316.454C209.244 294.608 224.854 277.978 244.276 269.999V356.73C244.276 360.384 246.226 363.763 249.392 365.591L337.337 416.365L308.503 433.013C306.481 434.181 303.961 434.188 301.939 433.02L234.971 394.357C208.868 378.789 195.138 347.261 203.391 316.454ZM244.775 470.9C228.781 454.906 222.186 433.075 224.986 412.264L300.096 455.63C303.263 457.457 307.164 457.457 310.328 455.63L398.273 404.856V438.149C398.273 440.485 397.022 442.671 394.997 443.839L328.029 482.502C301.495 497.322 267.327 493.452 244.772 470.9H244.775ZM450.897 445.982C450.466 476.371 430.029 504.027 399.22 512.283C377.373 518.136 355.168 512.932 338.547 500.102L413.659 456.738C416.826 454.911 418.775 451.532 418.775 447.877V346.329L447.609 362.977C449.631 364.145 450.897 366.323 450.897 368.659V445.985V445.982ZM512.282 399.221C506.429 421.068 490.819 437.697 471.397 445.676V358.946C471.397 355.292 469.448 351.912 466.281 350.085L378.336 299.311L407.17 282.663C409.192 281.495 411.712 281.487 413.734 282.655L480.702 321.318C506.805 336.887 520.536 368.415 512.282 399.221Z",
  ],
  brand: ["#fff", "#000"],
  source: "openai:blossom",
};

/// Marks by agent key. Each is the vendor's official artwork from its brand or press
/// assets, or, where a vendor publishes no SVG, the Lobe Icons (MIT) redraw; AGENT_MARKS.md
/// records every source, color and retrieval date. An agent without one draws the generic glyph.
export const AGENT_MARKS: Record<string, AgentMarkSpec> = {
  amp: {
    viewBox: "0 0 24 24",
    paths: [
      "M15.087 23.18L12.03 24l-2.097-7.823-5.738 5.738-2.251-2.251 5.718-5.719-7.769-2.082.82-3.057 11.294 3.08 3.08 11.295z",
      "M19.505 18.762l-3.057.82-2.564-9.573-9.572-2.564.819-3.057 11.295 3.079 3.08 11.295z",
      "M23.893 14.374l-3.057.82-2.565-9.572L8.7 3.057 9.52 0l11.295 3.08 3.079 11.294z",
    ],
    fillRule: "evenodd",
    brand: "#F34E3F",
    source: "lobe:amp",
  },
  claude: {
    viewBox: "0 0 94 94",
    paths: [
      "M18.7657 62.4437L37.1822 52.1167L37.4857 51.2122L37.1822 50.7085H36.2715L33.1852 50.5208L22.6615 50.2391L13.5545 49.8636L4.70044 49.3942L2.47428 48.9248L0.399902 46.1553L0.602281 44.794L2.47428 43.5266L5.15579 43.7613L11.0754 44.1837L19.98 44.794L26.4055 45.1695L35.9679 46.1553H37.4857L37.6881 45.545L37.1822 45.1695L36.7774 44.794L27.5692 38.5508L17.6021 31.9791L12.3908 28.1769L9.60812 26.2524L8.19147 24.4686L7.58433 20.5256L10.1141 17.7091L13.5545 17.9438L14.4146 18.1785L17.9056 20.8542L25.343 26.6279L35.0572 33.7629L36.4739 34.9364L37.0443 34.5514L37.1316 34.2792L36.4739 33.1996L31.212 23.6706L25.596 13.9539L23.0663 9.91695L22.4086 7.52296C22.1538 6.51831 22.0038 5.68714 22.0038 4.65957L24.8877 0.716544L26.5067 0.200195L30.4025 0.716544L32.0215 2.12477L34.4501 7.66379L38.3458 16.3478L44.4172 28.1769L46.188 31.6975L47.1493 34.9364L47.5035 35.9222H48.1106V35.3589L48.6166 28.6933L49.5273 20.5256L50.438 10.0108L50.7415 7.05356L52.2088 3.48605L55.1433 1.56148L57.42 2.64112L59.292 5.31674L59.039 7.05356L57.926 14.2824L55.7504 25.5952L54.3337 33.1996H55.1433L56.1046 32.2138L59.9497 27.1442L66.3752 19.0704L69.2085 15.8784L72.5478 12.3579L74.6728 10.668H78.7203L81.6548 15.0804L80.3394 19.6337L76.1906 24.8911L72.7502 29.3504L67.8172 35.9595L64.7562 41.2734L65.0307 41.7118L65.7681 41.6489L76.8989 39.255L82.9197 38.1753L90.1041 36.9549L93.3422 38.457L93.6963 40.006L92.4315 43.151L84.7411 45.0287L75.7353 46.8594L62.3244 50.0164L62.1759 50.1358L62.3512 50.3958L68.399 50.9432L70.9794 51.084H77.3037L89.0922 51.9759L92.1785 53.9944L93.9999 56.4822L93.6963 58.4068L88.9404 60.8008L82.5655 59.2987L67.6401 55.7312L62.5301 54.4638H61.8217V54.8862L66.0717 59.064L73.9139 66.1051L83.6786 75.2116L84.1845 77.4648L82.9197 79.2485L81.6042 79.0608L73.0032 72.5829L69.6639 69.6726L62.1759 63.3356H61.67V63.9928L63.3902 66.5276L72.5478 80.2812L73.0032 84.5059L72.3454 85.8672L69.9675 86.7121L67.3871 86.2427L61.9735 78.6852L56.4587 70.2359L52.0064 62.6315L51.4687 62.971L48.8189 91.2654L47.6047 92.7206L44.7714 93.8002L42.3934 92.0164L41.1286 89.1061L42.3934 83.3324L43.9113 75.8219L45.1255 69.8604L46.2386 62.4437L46.9184 59.9661L46.8583 59.8003L46.3153 59.8916L40.7238 67.5603L32.2239 79.0608L25.4948 86.2427L23.8758 86.8999L21.0931 85.4447L21.3461 82.863L22.9145 80.5629L32.2239 68.7338L37.8399 61.3641L41.4594 57.1337L41.4242 56.5218L41.2244 56.5048L16.489 72.6299L12.0873 73.1932L10.1647 71.4094L10.4176 68.4991L11.3283 67.5603L18.7657 62.4437Z",
    ],
    brand: "#D97757",
    source: "anthropic:claude-spark",
  },
  cursor: {
    viewBox: "0 0 466.73 532.09",
    paths: [
      "M457.43,125.94L244.42,2.96c-6.84-3.95-15.28-3.95-22.12,0L9.3,125.94c-5.75,3.32-9.3,9.46-9.3,16.11v247.99c0,6.65,3.55,12.79,9.3,16.11l213.01,122.98c6.84,3.95,15.28,3.95,22.12,0l213.01-122.98c5.75-3.32,9.3-9.46,9.3-16.11v-247.99c0-6.65-3.55-12.79-9.3-16.11h-.01ZM444.05,151.99l-205.63,356.16c-1.39,2.4-5.06,1.42-5.06-1.36v-233.21c0-4.66-2.49-8.97-6.53-11.31L24.87,145.67c-2.4-1.39-1.42-5.06,1.36-5.06h411.26c5.84,0,9.49,6.33,6.57,11.39h-.01Z",
    ],
    brand: ["#EDECEC", "#26251E"],
    source: "cursor:cube-2d",
  },
  gemini: {
    viewBox: "0 0 24 24",
    paths: [
      "M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z",
    ],
    fillRule: "evenodd",
    brand: "#3186FF",
    overlays: [
      {
        x1: 7,
        y1: 15.5,
        x2: 11,
        y2: 12,
        stops: [
          [0, "#08B962"],
          [1, "#08B962", 0],
        ],
      },
      {
        x1: 8,
        y1: 5.5,
        x2: 11.5,
        y2: 11,
        stops: [
          [0, "#F94543"],
          [1, "#F94543", 0],
        ],
      },
      {
        x1: 3.5,
        y1: 13.5,
        x2: 17.5,
        y2: 12,
        stops: [
          [0, "#FABC12"],
          [0.46, "#FABC12", 0],
        ],
      },
    ],
    source: "lobe:gemini",
  },
  openai: OPENAI_BLOSSOM,
  // OpenAI publishes no Codex mark; Codex is OpenAI's agent, so it wears the Blossom.
  codex: OPENAI_BLOSSOM,
  opencode: {
    viewBox: "0 0 240 300",
    // Two-tone: the frame, and a block inside it that is lighter in mono.
    paths: [
      "M180 60H60V240H180V60ZM240 300H0V0H240V300Z",
      { d: "M180 240H60V120H180V240Z", brand: ["#4B4646", "#CFCECD"], opacity: 0.35 },
    ],
    fillRule: "evenodd",
    brand: ["#F1ECEC", "#211E1E"],
    source: "opencode:logo",
  },
};

/// How marks color: each vendor's own colors (the default), or white on dark themes
/// and black on light ones.
export type AgentMarkStyle = "brand" | "mono";

/// Sets the mark style for every mark on the page.
export function setAgentMarkStyle(style: AgentMarkStyle) {
  if (typeof document === "undefined") return;
  if (style === "mono") document.documentElement.dataset.agentMarks = "mono";
  else delete document.documentElement.dataset.agentMarks;
}

// The root attributes marks follow: data-theme, which applyAgentTheme sets from the
// background-against-text luminance, and data-agent-marks. One observer for every mark.
const listeners = new Set<() => void>();
let observer: MutationObserver | undefined;
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (!observer && typeof MutationObserver !== "undefined" && typeof document !== "undefined") {
    observer = new MutationObserver(() => listeners.forEach((notify) => notify()));
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "data-agent-marks"],
    });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      observer?.disconnect();
      observer = undefined;
    }
  };
}
/// Whether the shared root observer is live. @internal, for tests.
export const agentMarkObserving = () => observer !== undefined;
// The pane is dark, in brand color, until told otherwise.
const appearance = () => {
  if (typeof document === "undefined") return "dark brand";
  const { theme, agentMarks } = document.documentElement.dataset;
  return `${theme === "light" ? "light" : "dark"} ${agentMarks === "mono" ? "mono" : "brand"}`;
};

const tone = (value: Tone, dark: boolean) => (typeof value === "string" ? value : dark ? value[0] : value[1]);

/// An agent's mark, at `size` px, for the model menu, the pane header, session rows
/// and new-tab cards. With `label` it is an image named for the agent; without, it
/// is decoration beside text that already names it. Marks pick their colors for the
/// page's theme; on a surface of the other lightness (a selected row on the accent),
/// `onDark` says which side the surface is on.
export function AgentMark({
  agent,
  size = 16,
  label,
  onDark,
}: {
  agent?: string;
  size?: number;
  label?: string;
  onDark?: boolean;
}) {
  const key = agentKey(agent);
  const [scheme, style] = useSyncExternalStore(subscribe, appearance, () => "dark brand").split(" ");
  const dark = onDark ?? scheme === "dark";
  const brand = style === "brand";
  // useId's punctuation would need escaping inside url(#…).
  const gradientId = `agent-mark${useId().replace(/[^\w-]/g, "")}`;
  const spec = key && Object.hasOwn(AGENT_MARKS, key) ? AGENT_MARKS[key] : undefined;
  const a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": true as const };
  if (!spec)
    return (
      <svg
        className="agent-mark agent-mark-generic"
        width={size}
        height={size}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.25}
        strokeLinecap="round"
        strokeLinejoin="round"
        focusable="false"
        {...a11y}
      >
        <rect x="2.25" y="2.75" width="11.5" height="10.5" rx="2.5" />
        <path d="m5.25 6.5 2 1.75-2 1.75M8.75 10h2" />
      </svg>
    );
  return (
    <svg
      className="agent-mark"
      data-agent={key}
      width={size}
      height={size}
      viewBox={spec.viewBox}
      fill={brand ? tone(spec.brand, dark) : dark ? "#fff" : "#000"}
      focusable="false"
      {...a11y}
    >
      {spec.paths.map((path, index) => {
        const { d, brand: own, opacity } = typeof path === "string" ? { d: path } : path;
        return brand ? (
          <path key={index} d={d} fill={own && tone(own, dark)} fillRule={spec.fillRule} />
        ) : (
          <path key={index} d={d} opacity={opacity} fillRule={spec.fillRule} />
        );
      })}
      {brand &&
        spec.overlays?.map((gradient, index) => (
          <React.Fragment key={`overlay${index}`}>
            <defs>
              <linearGradient
                id={`${gradientId}-${index}`}
                gradientUnits="userSpaceOnUse"
                x1={gradient.x1}
                y1={gradient.y1}
                x2={gradient.x2}
                y2={gradient.y2}
              >
                {gradient.stops.map(([offset, color, opacity], stop) => (
                  <stop key={stop} offset={offset} stopColor={color} stopOpacity={opacity} />
                ))}
              </linearGradient>
            </defs>
            {spec.paths.map((path, pathIndex) => (
              <path
                key={pathIndex}
                d={typeof path === "string" ? path : path.d}
                fill={`url(#${gradientId}-${index})`}
                fillRule={spec.fillRule}
              />
            ))}
          </React.Fragment>
        ))}
    </svg>
  );
}
