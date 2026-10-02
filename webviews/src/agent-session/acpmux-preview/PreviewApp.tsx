import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "../acpmux/App";
import { applyAgentTheme } from "../shared/theme";
import type { AcpmuxRow, AcpmuxSnapshot } from "../acpmux/model";
import { previewFixtures, type PreviewFixture } from "./fixtures";

type BridgeMessage = { id?: string; method?: string; params?: Record<string, unknown> };

class MockBridge {
  private snapshot: AcpmuxSnapshot;
  private replayTimer: number | undefined;
  private fixture: PreviewFixture;

  constructor(fixture: PreviewFixture) { this.fixture = fixture; this.snapshot = structuredClone(fixture.snapshot); }

  install(): void {
    window.webkit = { messageHandlers: { agentSession: { postMessage: (message: unknown) => Promise.resolve(this.handle(message as BridgeMessage)) } } } as unknown as typeof window.webkit;
  }

  select(fixture: PreviewFixture): void {
    if (this.replayTimer) window.clearTimeout(this.replayTimer);
    this.fixture = fixture;
    this.snapshot = structuredClone(fixture.snapshot);
    this.emit();
  }

  emit(): void { window.cmuxAcpmuxBridge?.receive(structuredClone(this.snapshot)); }

  replay(): void {
    if (!this.fixture.replay?.length) return;
    const rows = new Map<string, AcpmuxRow>();
    const events = this.fixture.replay;
    let index = 0;
    const tick = () => {
      const row = events[index];
      if (!row) return;
      rows.set(row.id, structuredClone(row));
      this.snapshot = { ...this.snapshot, rows: [...rows.values()], isWorking: index < events.length - 1 };
      this.emit();
      index += 1;
      this.replayTimer = window.setTimeout(tick, Math.min(500, index < 3 ? 140 : 70));
    };
    tick();
  }

  private handle(message: BridgeMessage): { ok: true; value: unknown } {
    switch (message.method) {
      case "ready": this.emit(); return { ok: true, value: { protocolVersion: 1, transport: "preview" } };
      case "chat.send": {
        const text = String(message.params?.text ?? "");
        const user: AcpmuxRow = { id: `preview-user-${Date.now()}`, version: 1, at: Date.now(), kind: "user", text };
        this.snapshot = { ...this.snapshot, rows: [...this.snapshot.rows, user], isWorking: true };
        this.emit();
        window.setTimeout(() => { const assistant: AcpmuxRow = { id: `preview-assistant-${Date.now()}`, version: 1, at: Date.now(), kind: "assistant", text: `Preview response for “${text}”`, streaming: false }; this.snapshot = { ...this.snapshot, rows: [...this.snapshot.rows, assistant], isWorking: false }; this.emit(); }, 400);
        break;
      }
      case "chat.cancel": this.snapshot = { ...this.snapshot, isWorking: false }; this.emit(); break;
      case "chat.permission": this.snapshot = { ...this.snapshot, permission: undefined }; this.emit(); break;
      default: break;
    }
    return { ok: true, value: null };
  }
}

function PreviewControls({ bridge, onFixture }: { bridge: MockBridge; onFixture: (fixture: PreviewFixture) => void }) {
  const [fixtureId, setFixtureId] = useState(previewFixtures[0].id);
  const [dark, setDark] = useState(true);
  const [width, setWidth] = useState(900);
  const [fps, setFps] = useState("—");
  const frameTimes = useRef<number[]>([]);
  const previousFrame = useRef(performance.now());
  const fixture = previewFixtures.find((candidate) => candidate.id === fixtureId) ?? previewFixtures[0];
  useEffect(() => {
    let frame = 0;
    const tick = (now: number) => { frameTimes.current.push(now - previousFrame.current); previousFrame.current = now; if (frame++ % 30 === 0) { const values = frameTimes.current.slice(-60); const average = values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length); setFps(`${(1000 / average).toFixed(0)} FPS · ${average.toFixed(2)} ms`); } requestAnimationFrame(tick); };
    const id = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(id);
  }, []);
  const applyThemeFile = (css: string) => { let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null; if (!style) { style = document.createElement("style"); style.id = "acpmux-user-theme"; document.head.append(style); } style.textContent = css; };
  return <aside className="acpmux-preview-controls">
    <strong>React pane preview</strong>
    <label>Fixture<select value={fixtureId} onChange={(event) => { const next = previewFixtures.find((candidate) => candidate.id === event.target.value) ?? previewFixtures[0]; setFixtureId(next.id); onFixture(next); }}>{previewFixtures.map((candidate) => <option key={candidate.id} value={candidate.id}>{candidate.label}</option>)}</select></label>
    <button type="button" onClick={() => bridge.replay()}>Replay stream</button>
    <label>Width <input type="range" aria-label="Preview width" min="420" max="1280" value={width} onChange={(event) => setWidth(Number(event.target.value))} /> {width}px</label>
    <button type="button" onClick={() => { const next = !dark; setDark(next); applyAgentTheme({ isDark: next, pageBackground: next ? "#171717" : "#f6f6f6", surfaceBackground: next ? "#202020" : "#fff", surfaceElevatedBackground: next ? "#292929" : "#fff", inputBackground: next ? "#111" : "#fafafa", border: next ? "#3a3a3a" : "#ddd", borderStrong: next ? "#555" : "#bbb", text: next ? "#f2f2f2" : "#202020", mutedText: next ? "#a1a1a1" : "#6b6b6b", softText: next ? "#c4c4c4" : "#484848", accent: next ? "#7c9cff" : "#315dcc", accentSoft: next ? "#263866" : "#e8efff", danger: "#d55", shadow: next ? "#0008" : "#0002" }); }}>Toggle {dark ? "light" : "dark"}</button>
    <label>theme.css <input type="file" aria-label="Load theme.css" accept=".css,text/css" onChange={async (event) => { const file = event.target.files?.[0]; if (file) applyThemeFile(await file.text()); }} /></label>
    <label>or paste CSS<textarea rows={3} aria-label="Paste theme CSS" placeholder=":root { --agent-accent: #e05; }" onChange={(event) => applyThemeFile(event.target.value)} /></label>
    <output>{fps}</output>
    <small>Pretext geometry is computed before paint. Rows are painted only while visible.</small>
    <span style={{ display: "none" }}>{fixture.label}</span>
  </aside>;
}

export function PreviewApp() {
  const bridge = useMemo(() => { const next = new MockBridge(previewFixtures[0]); next.install(); return next; }, []);
  const [fixture, setFixture] = useState(previewFixtures[0]);
  useEffect(() => { applyAgentTheme({ isDark: true, pageBackground: "#171717", surfaceBackground: "#202020", surfaceElevatedBackground: "#292929", inputBackground: "#111", border: "#3a3a3a", borderStrong: "#555", text: "#f2f2f2", mutedText: "#a1a1a1", softText: "#c4c4c4", accent: "#7c9cff", accentSoft: "#263866", danger: "#d55", shadow: "#0008" }); }, [bridge]);
  void fixture;
  return <main className="acpmux-preview-page"><PreviewControls bridge={bridge} onFixture={(next) => { setFixture(next); bridge.select(next); }} /><div className="acpmux-preview-frame"><AcpmuxApp /></div></main>;
}

export function mountPreview() { createRoot(document.getElementById("root")!).render(<PreviewApp />); }
