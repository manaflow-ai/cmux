import {
  Box,
  CliRenderEvents,
  ScrollBox,
  Text,
  createCliRenderer,
  type CliRenderer,
  type KeyEvent,
} from "@opentui/core";
import { adapterOrder, adapters } from "./adapters";
import { groupSessionsByStatus, type GroupedSessions, type HomeSession, type HomeState } from "./state";

const theme = {
  background: "#050505",
  mutedBackground: "#101010",
  surface: "#141414",
  selected: "#102033",
  border: "#303030",
  selectedBorder: "#4FB4FF",
  text: "#F5F5F5",
  muted: "#9CA3AF",
  accent: "#7DD3FC",
  awaiting: "#F4C95D",
  working: "#7DD3FC",
  completed: "#86EFAC",
} as const;

export class HomeTui {
  private selectedIndex = 0;
  private taskDraft = "";
  private statusMessage = "Ready";
  private renderCycle = 0;
  private stopped = false;
  private readonly keyHandler = (key: KeyEvent) => this.handleKey(key);
  private readonly refreshHandler = () => this.render();

  constructor(
    private readonly renderer: CliRenderer,
    private readonly state: HomeState,
  ) {}

  start(): void {
    this.renderer.on(CliRenderEvents.RESIZE, this.refreshHandler);
    this.renderer.on(CliRenderEvents.CAPABILITIES, this.refreshHandler);
    this.renderer.keyInput.on("keypress", this.keyHandler);
    this.render();
  }

  stop(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    this.renderer.keyInput.off("keypress", this.keyHandler);
    this.renderer.off(CliRenderEvents.RESIZE, this.refreshHandler);
    this.renderer.off(CliRenderEvents.CAPABILITIES, this.refreshHandler);
    this.clearRoot();
    this.renderer.destroy();
  }

  private render(): void {
    this.renderCycle += 1;
    const cycle = this.renderCycle;
    const sessions = this.state.sessions;
    const selected = sessions[this.selectedIndex];

    this.clearRoot();
    this.renderer.root.add(
      Box(
        {
          id: "cmux-home-shell",
          width: "100%",
          height: "100%",
          flexDirection: "column",
          backgroundColor: theme.background,
        },
        this.renderHeader(),
        this.renderBody(selected),
        this.renderPrompt(),
      ),
    );

    void this.renderer.idle().then(() => {
      if (cycle !== this.renderCycle) {
        return;
      }
      this.scrollSelectedIntoView(selected);
    });
  }

  private renderHeader() {
    const counts = adapterOrder
      .map((adapter) => `${adapter}:${this.state.sessions.filter((session) => session.adapter === adapter).length}`)
      .join("  ");
    return Box(
      {
        id: "cmux-home-header",
        width: "100%",
        height: 3,
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.mutedBackground,
        paddingLeft: 1,
        paddingRight: 1,
        flexDirection: "row",
        justifyContent: "space-between",
        alignItems: "center",
      },
      Text({ content: "cmux home", fg: theme.accent }),
      Text({ content: counts, fg: theme.muted }),
    );
  }

  private renderBody(selected: HomeSession | undefined) {
    return Box(
      {
        id: "cmux-home-body",
        width: "100%",
        flexGrow: 1,
        flexDirection: "row",
        backgroundColor: theme.background,
      },
      this.renderSessionList(groupSessionsByStatus(this.state.sessions)),
      this.renderDetails(selected),
    );
  }

  private renderSessionList(groups: GroupedSessions[]) {
    return Box(
      {
        id: "cmux-home-list-pane",
        width: "48%",
        height: "100%",
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.background,
      },
      ScrollBox(
        {
          id: "cmux-home-list",
          width: "100%",
          height: "100%",
          viewportCulling: true,
          rootOptions: { backgroundColor: theme.background },
          contentOptions: { padding: 1 },
          verticalScrollbarOptions: {
            trackOptions: {
              backgroundColor: theme.mutedBackground,
              foregroundColor: theme.accent,
            },
          },
        },
        ...groups.flatMap((group) => this.renderGroup(group)),
      ),
    );
  }

  private renderDetails(selected: HomeSession | undefined) {
    const width = Math.max(18, Math.floor(this.renderer.width * 0.48) - 4);
    if (!selected) {
      return Box(
        {
          id: "cmux-home-details",
          flexGrow: 1,
          height: "100%",
          borderStyle: "single",
          borderColor: theme.border,
          backgroundColor: theme.surface,
          padding: 1,
          justifyContent: "center",
          alignItems: "center",
        },
        Text({ content: "No sessions loaded.", fg: theme.muted }),
      );
    }

    const adapter = adapters[selected.adapter];
    const lines = [
      selected.title,
      "",
      `${adapter.displayName}  ${selected.status}`,
      selected.cwd ? `cwd: ${selected.cwd}` : undefined,
      selected.branch ? `branch: ${selected.branch}` : undefined,
      selected.updatedAt ? `updated: ${selected.updatedAt}` : undefined,
      "",
      selected.preview,
      selected.details,
      "",
      selected.resumeCommand ? `resume: ${selected.resumeCommand}` : `resume: ${adapter.resumeTemplate}`,
      "",
      "known gaps:",
      ...adapter.featureGaps.map((gap) => `- ${gap}`),
    ].filter((line): line is string => line !== undefined);

    return Box(
      {
        id: "cmux-home-details",
        flexGrow: 1,
        height: "100%",
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.surface,
        padding: 1,
        flexDirection: "column",
      },
      Text({ content: wrapLines(lines, width, 24).join("\n"), fg: theme.text }),
    );
  }

  private renderPrompt() {
    const prompt = `task > ${this.taskDraft}_`;
    return Box(
      {
        id: "cmux-home-prompt",
        width: "100%",
        height: 4,
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.mutedBackground,
        paddingLeft: 1,
        paddingRight: 1,
        flexDirection: "column",
      },
      Text({ content: prompt, fg: theme.accent }),
      Text({ content: `${this.statusMessage}  j/k move  enter acknowledge  q quit`, fg: theme.muted }),
    );
  }

  private renderGroup(group: GroupedSessions) {
    if (group.sessions.length === 0) {
      return [];
    }
    return [
      Text({ content: group.status.toUpperCase(), fg: statusColor(group.status) }),
      ...group.sessions.map((session) => this.renderSessionCard(session, session === this.state.sessions[this.selectedIndex])),
    ];
  }

  private renderSessionCard(session: HomeSession, selected: boolean) {
    const textWidth = Math.max(16, Math.floor(this.renderer.width * 0.44) - 6);
    const meta = [
      adapters[session.adapter].displayName,
      session.cwd ? basename(session.cwd) : undefined,
      session.branch,
    ].filter(Boolean).join("  ");
    return Box(
      {
        id: sessionElementId(session),
        width: "100%",
        borderStyle: "rounded",
        borderColor: selected ? theme.selectedBorder : theme.border,
        backgroundColor: selected ? theme.selected : theme.surface,
        padding: 1,
        marginBottom: 1,
        flexDirection: "column",
      },
      Text({ content: clamp(session.title, textWidth), fg: theme.text }),
      Text({ content: clamp(meta, textWidth), fg: theme.muted }),
      session.preview ? Text({ content: clamp(session.preview, textWidth), fg: theme.muted }) : null,
    );
  }

  private handleKey(key: KeyEvent): void {
    if (isCtrlC(key) || isKey(key, "q")) {
      this.stop();
      process.exit(0);
    }
    if (isKey(key, "j", "down")) {
      this.moveSelection(1);
      return;
    }
    if (isKey(key, "k", "up")) {
      this.moveSelection(-1);
      return;
    }
    if (isKey(key, "backspace", "delete")) {
      this.taskDraft = this.taskDraft.slice(0, -1);
      this.render();
      return;
    }
    if (isKey(key, "return", "enter")) {
      this.statusMessage = this.taskDraft.trim()
        ? "Task capture is read-only in this prototype."
        : "Type a task to stage it for a future agent handoff.";
      this.render();
      return;
    }
    if (!key.ctrl && !key.meta && key.sequence && key.sequence.length === 1 && key.sequence >= " ") {
      this.taskDraft = `${this.taskDraft}${key.sequence}`.slice(0, 240);
      this.render();
    }
  }

  private moveSelection(delta: number): void {
    this.selectedIndex = Math.max(0, Math.min(this.state.sessions.length - 1, this.selectedIndex + delta));
    this.render();
  }

  private scrollSelectedIntoView(selected: HomeSession | undefined): void {
    if (!selected) {
      return;
    }
    const scrollBox = this.renderer.root.findDescendantById("cmux-home-list") as
      | { scrollChildIntoView?: (id: string) => void }
      | undefined;
    scrollBox?.scrollChildIntoView?.(sessionElementId(selected));
  }

  private clearRoot(): void {
    for (const child of this.renderer.root.getChildren()) {
      this.renderer.root.remove(child.id);
    }
  }
}

export async function runInteractiveHome(state: HomeState): Promise<void> {
  const renderer = await createCliRenderer({
    exitOnCtrlC: false,
    screenMode: "alternate-screen",
    useMouse: true,
    autoFocus: true,
    targetFps: 30,
  });
  const app = new HomeTui(renderer, state);
  const shutdown = () => {
    app.stop();
    process.exit(0);
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  app.start();
}

function sessionElementId(session: HomeSession): string {
  return `cmux-home-session-${session.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}

function isKey(key: KeyEvent, ...names: string[]): boolean {
  return names.includes(key.name) || names.includes(key.sequence) || names.includes(key.raw);
}

function isCtrlC(key: KeyEvent): boolean {
  return (key.ctrl && isKey(key, "c")) || key.sequence === "\u0003" || key.raw === "\u0003";
}

function statusColor(status: HomeSession["status"]): string {
  return theme[status];
}

function basename(path: string): string {
  const parts = path.split("/").filter(Boolean);
  return parts.at(-1) ?? path;
}

function clamp(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, Math.max(0, maxLength - 3))}...`;
}

function wrapLines(lines: string[], width: number, maxLines: number): string[] {
  const wrapped: string[] = [];
  for (const line of lines) {
    if (!line) {
      wrapped.push("");
      continue;
    }
    const words = line.split(/\s+/);
    let current = "";
    for (const word of words) {
      if (!current) {
        current = word;
      } else if (current.length + 1 + word.length <= width) {
        current += ` ${word}`;
      } else {
        wrapped.push(current);
        current = word;
      }
      if (wrapped.length >= maxLines) {
        return wrapped;
      }
    }
    if (current) {
      wrapped.push(current);
    }
    if (wrapped.length >= maxLines) {
      return wrapped;
    }
  }
  return wrapped;
}
