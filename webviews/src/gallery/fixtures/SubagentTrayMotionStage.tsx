// l10n-allow-file: gallery fixtures (sample messages, subagent names, stage buttons), not shipped UI.
// The subagent tray's motion beside a new message arriving (subagents/trayMotion.tsx): a column of
// transcript rows over the bottom stack, the real SubagentTray above a stand-in composer card. The
// stage's buttons (outside the pane, for the play script and a person) start and end subagents and
// post a message, so the card's entrance, exit, fold and tick play next to a live row's entrance.
import { useRef, useState, type CSSProperties } from "react";
import { trayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";

const NAMES = ["Explore update code", "Check the docs agree", "Review the diff", "Run the red/green tests"];
const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-chat" as string | undefined };

type Message = { id: number; text: string; live: boolean };

export function SubagentTrayMotionStage({ start = 0 }: { start?: number }) {
  const clock = useRef(Date.now());
  const [agents, setAgents] = useState<Subagent[]>(() =>
    NAMES.slice(0, start).map((name, index) => agent(name, index, clock.current - 60_000)),
  );
  const [messages, setMessages] = useState<Message[]>([
    { id: 0, text: "Find out how the daemon updates itself, and check the docs agree.", live: false },
    { id: 1, text: "I'll send a subagent to read the update code while I check the docs.", live: false },
  ]);
  const [enters, setEnters] = useState(start === 0);
  const running = agents.filter((item) => item.state === "running");
  const items = trayItems(running, [], [], true);
  const add = () =>
    setAgents((current) => {
      const index = current.length;
      return [...current, agent(NAMES[index % NAMES.length]!, index, Date.now())];
    });
  const end = (all: boolean) =>
    setAgents((current) => {
      const live = current.filter((item) => item.state === "running");
      const ending = new Set((all ? live : live.slice(-1)).map((item) => item.id));
      return current.map((item) => (ending.has(item.id) ? { ...item, state: "completed", endedAt: Date.now() } : item));
    });
  if (items.length === 0 && !enters) setEnters(true);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div style={{ display: "flex", gap: 6, padding: 8, borderBottom: "1px solid var(--agent-border)" }}>
        <button type="button" data-stage="start" onClick={add}>
          Start subagent
        </button>
        <button type="button" data-stage="end-one" onClick={() => end(false)}>
          End one
        </button>
        <button type="button" data-stage="end-all" onClick={() => end(true)}>
          End all
        </button>
        <button
          type="button"
          data-stage="message"
          onClick={() =>
            setMessages((current) => [
              ...current,
              { id: current.length, text: `Update ${current.length - 1}: the subagent read the updater.`, live: true },
            ])
          }
        >
          New message
        </button>
      </div>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        {/* Plain rows: the transcript's own `.acpmux-row` is placed by its virtualizer. A live one takes
            the live row's entrance class, as App.tsx gives it. */}
        <div style={{ display: "flex", flexDirection: "column", padding: "12px 16px", overflow: "hidden" }}>
          {messages.map((message) => (
            <div
              key={message.id}
              className={message.live ? "acpmux-row--enter" : undefined}
              style={{ padding: "6px 0", color: "var(--agent-text)", font: "13px/18px system-ui" }}
            >
              {message.text}
            </div>
          ))}
        </div>
        <div className="acpmux-dock" style={{ "--cv-inset": "16px" } as CSSProperties}>
          {items.length > 0 && (
            <SubagentTray
              key="gallery-chat"
              items={items}
              working
              waiting={NO_WAITING}
              onOpen={() => undefined}
              shown={shown}
              enters={enters}
            />
          )}
          <div className="acpmux-composer">
            <div
              className="acpmux-composer-box"
              style={{ margin: "0 16px 16px", height: 72, borderRadius: 12, background: "var(--acpmux-composer-tray)" }}
            />
          </div>
        </div>
      </main>
    </div>
  );
}

function agent(name: string, index: number, startedAt: number): Subagent {
  return {
    id: `gallery-agent-${index}`,
    parent: null,
    name,
    task: name,
    kind: "Explore",
    action: index % 2 ? "Read docs/updates.md" : "Grep updater",
    state: "running",
    startedAt,
  };
}
