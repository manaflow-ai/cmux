// l10n-allow-file: gallery chrome stand-ins (sample workspace names, a sample shell), not shipped UI.
// Window mode's frame: a cmux window at its real size, drawn from the app's metrics and theme
// tokens (titlebar, sidebar, each pane's tab strip, the split), with the entry in its pane as a
// nested component frame at the pane's real size. The sidebar rows, tabs and the terminal pane
// are stand-ins for the native chrome (the native gallery draws the real ones); the entry is real.
import type { GalleryEnv } from "../env";
import type { GalleryEntry } from "../format";
import { css, type ThemeTokens } from "../theme/tokens";
import type { PlayReport } from "../play";
import { windowGeometry, windowSize, type ChromeMetrics, type Rect } from "../window";

const SAMPLE_WORKSPACES = [
  { title: "atlas-web", detail: "main · 2 chats" },
  { title: "cmux", detail: "feat-cmux-next" },
  { title: "release notes", detail: "docs" },
  { title: "infra", detail: "fleet · 1 running" },
];

function box(rect: Rect, style: Record<string, string> = {}): HTMLDivElement {
  const element = document.createElement("div");
  Object.assign(element.style, {
    position: "absolute",
    left: `${rect.x}px`,
    top: `${rect.y}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    boxSizing: "border-box",
    ...style,
  });
  return element;
}

function text(value: string, style: Record<string, string>): HTMLSpanElement {
  const element = document.createElement("span");
  element.textContent = value;
  Object.assign(element.style, { whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", ...style });
  return element;
}

/** The tab title of the entry's pane. */
function tabTitle(entry: GalleryEntry, variant: string): string {
  if (entry.host === "markdown-page") {
    const path = entry.variants[variant]?.path ?? "";
    return path.split("/").pop() || "Markdown";
  }
  if (entry.host === "diff-page") return "Changes";
  if (entry.host === "agent-pane") return entry.variants[variant]?.snapshot.summary?.title ?? "New Tab";
  return entry.title;
}

export function mountWindow(options: {
  entry: GalleryEntry;
  variant: string;
  env: GalleryEnv;
  tokens: ThemeTokens;
  metrics: ChromeMetrics;
  onReady: () => void;
  onPlay: (report: PlayReport) => void;
}): void {
  const { entry, variant, env, tokens, metrics } = options;
  const size = windowSize(env.window);
  const geometry = windowGeometry(size, env.layout, env.density, metrics);
  const root = document.documentElement;
  root.dataset.galleryFrame = "window";
  document.body.style.margin = "0";
  // The window is the stage's root element, at its real size.
  const win = document.getElementById("root")!;
  Object.assign(win.style, {
    display: "block",
    position: "relative",
    width: `${size.width}px`,
    height: `${size.height}px`,
    overflow: "hidden",
    background: css({ ...tokens.windowBackground, alpha: 1 }),
    color: css(tokens.textPrimary),
    font: "13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
  });

  // Sidebar: its tonal step over the window, the traffic lights in the titlebar band, then rows.
  const sidebar = box(geometry.sidebar, { background: css(tokens.sidebarStep) });
  ["#ff5f57", "#febc2e", "#28c840"].forEach((color, index) => {
    sidebar.append(
      box(
        { x: 20 + index * 20, y: geometry.titlebarHeight / 2 - 6, width: 12, height: 12 },
        { borderRadius: "50%", background: color },
      ),
    );
  });
  const rowHeight = metrics.sidebarRowHeightWithSubtitle?.[env.density] ?? 46;
  SAMPLE_WORKSPACES.forEach((workspace, index) => {
    const row = box(
      {
        x: 8,
        y: geometry.titlebarHeight + 8 + index * (rowHeight + 2),
        width: geometry.sidebar.width - 16,
        height: rowHeight,
      },
      {
        borderRadius: "7px",
        padding: "0 10px",
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        background: index === 0 ? css(tokens.selectionFill) : "transparent",
      },
    );
    row.append(
      text(workspace.title, { fontWeight: "600", color: css(tokens.textPrimary) }),
      text(workspace.detail, { fontSize: "11px", color: css(tokens.textSecondary) }),
    );
    sidebar.append(row);
  });
  win.append(sidebar);

  for (const pane of geometry.panes) {
    const frame = box(pane.frame, {
      borderRadius: `${geometry.radius}px`,
      border: `1px solid ${css(tokens.paneBorder)}`,
      overflow: "hidden",
      background: css({ ...tokens.contentBackground, alpha: 1 }),
    });
    const strip = box({ x: 0, y: 0, width: pane.frame.width, height: geometry.tabStripHeight });
    const titles = pane.hostsEntry ? [tabTitle(entry, variant), "Terminal"] : ["zsh", "bun test"];
    titles.forEach((title, index) => {
      const tab = box(
        {
          x: 6 + index * 168,
          y: (geometry.tabStripHeight - geometry.tabHeight) / 2,
          width: 160,
          height: geometry.tabHeight,
        },
        {
          borderRadius: "7px",
          padding: "0 10px",
          display: "flex",
          alignItems: "center",
          background: index === 0 ? css(tokens.selectionFill) : "transparent",
          color: css(index === 0 ? tokens.textPrimary : tokens.textSecondary),
        },
      );
      tab.append(text(title, { fontSize: "12px" }));
      strip.append(tab);
    });
    frame.append(strip);
    const content = {
      x: 0,
      y: geometry.tabStripHeight,
      width: pane.content.width - 2,
      height: pane.content.height - 2,
    };
    if (pane.hostsEntry) {
      // The entry itself: a component frame at the pane's real size, under the same controls.
      const params = new URLSearchParams(location.search);
      params.set("frame", "component");
      params.set("width", String(Math.round(content.width)));
      params.set("height", String(Math.round(content.height)));
      const iframe = document.createElement("iframe");
      iframe.title = `${entry.id} ${variant}`;
      iframe.src = `frame.html?${params}`;
      Object.assign(iframe.style, {
        position: "absolute",
        left: `${content.x}px`,
        top: `${content.y}px`,
        width: `${content.width}px`,
        height: `${content.height}px`,
        border: "0",
        background: "transparent",
      });
      addEventListener("message", (event: MessageEvent) => {
        const data = event.data as { type?: string; status?: string; message?: string; report?: PlayReport } | null;
        if (event.source !== iframe.contentWindow) return;
        if (data?.type === "cmux-gallery-play" && data.report) return options.onPlay(data.report);
        if (data?.type !== "cmux-gallery-stage") return;
        if (data.status === "ready") options.onReady();
        else parent.postMessage(data, "*");
      });
      frame.append(iframe);
    } else {
      // A terminal stand-in in the theme's own ANSI colors.
      const shell = box(content, {
        padding: "10px 12px",
        font: "12px ui-monospace, Menlo, monospace",
        lineHeight: "18px",
        whiteSpace: "pre",
        color: css(tokens.textPrimary),
      });
      const ansi = (index: number) => css(tokens.ansi[index] ?? tokens.textPrimary);
      for (const [color, line] of [
        [ansi(4), "~/src/atlas-web main"],
        [css(tokens.textPrimary), "❯ bun test src/net"],
        [ansi(2), " 3 pass"],
        [ansi(1), " 0 fail"],
        [css(tokens.textSecondary), "Ran 3 tests across 1 file. [118.00ms]"],
        [css(tokens.textPrimary), "❯ "],
      ] as const) {
        const row = document.createElement("div");
        row.textContent = line;
        row.style.color = color;
        shell.append(row);
      }
      frame.append(shell);
    }
    win.append(frame);
  }
}
