// Typing prewarm for a new chat (Lawrence 2026-10-26: "the moment user opens new tab or workspace
// and starts typing a prompt we can warm it up, so after Enter it feels instant").
//
// A new chat has no session until its first Enter: that Enter used to start the harness (agent
// host, adapter, `initialize`, the harness session and its MCP servers), 1-15 s before the first
// token. The person's first typed character now hints acpmux's session pool (`_acpmux/prewarm`,
// hub/pool): a hidden session of exactly the harness and folder the Enter will use starts while
// the person types, and the Enter's `session/new` takes it.
//
// Cost stays bounded by the daemon (one hinted agent per harness across folders,
// `pool.hintedPerHarness`; idle exit, `pool.idleMinutes`; a pool RSS cap) and by this module: one
// hint per target (again only every PREWARM_REFRESH_MS while typing, to keep it from idling out),
// and the hint is taken back when the prompt stays cleared for RELEASE_AFTER_MS or the chat is
// left unsent. A sent prompt keeps it: that chat's start takes the warm agent.
import type { SwitchClock } from "./harnessSwitch";

/// What a new chat's Enter starts: its harness (undefined: acpmux's default) in its folder.
export type PrewarmTarget = { harness?: string; cwd: string };

export type PrewarmPort = {
  /// The connection can hint acpmux's pool (local origin, `_acpmux/prewarm` listed).
  supported(): boolean;
  prewarm(target: PrewarmTarget): void;
  release(target: PrewarmTarget): void;
};

/// While the person keeps typing, the hint goes again this often so the warm agent never reaches
/// acpmux's idle exit (`pool.idleMinutes`, at least one minute) under a person who is still writing.
export const PREWARM_REFRESH_MS = 60_000;
/// A prompt cleared this long (and not retyped) takes the hint back.
export const RELEASE_AFTER_MS = 3_000;

const same = (a: PrewarmTarget | undefined, b: PrewarmTarget | undefined) =>
  a?.harness === b?.harness && a?.cwd === b?.cwd;

export class NewChatPrewarm {
  /// The target hinted last and not yet sent or released.
  private hinted?: PrewarmTarget;
  private hintedAt = 0;
  private cancelRelease?: () => void;

  constructor(
    private readonly port: PrewarmPort,
    private readonly clock: SwitchClock,
  ) {}

  /// The new chat's prompt is now `text`; its Enter would start `target` (undefined: unknown, such
  /// as a chat that starts in the folder acpmux picks).
  typed(text: string, target: PrewarmTarget | undefined): void {
    if (!text.trim()) {
      if (this.hinted && !this.cancelRelease) {
        this.cancelRelease = this.clock.schedule(() => {
          this.cancelRelease = undefined;
          this.releaseNow();
        }, RELEASE_AFTER_MS);
      }
      return;
    }
    this.stopRelease();
    if (!target || !this.port.supported()) {
      this.releaseNow();
      return;
    }
    if (same(target, this.hinted) && this.clock.now() - this.hintedAt < PREWARM_REFRESH_MS) return;
    if (!same(target, this.hinted)) this.releaseNow();
    this.hinted = target;
    this.hintedAt = this.clock.now();
    this.port.prewarm(target);
  }

  /// The prompt went: the chat it starts takes the warm agent, so nothing is released.
  sent(): void {
    this.stopRelease();
    this.hinted = undefined;
  }

  /// The new chat was left unsent (its tab closed, the page went away): the hint goes back now.
  abandon(): void {
    this.stopRelease();
    this.releaseNow();
  }

  private stopRelease(): void {
    this.cancelRelease?.();
    this.cancelRelease = undefined;
  }

  private releaseNow(): void {
    const hinted = this.hinted;
    this.hinted = undefined;
    if (hinted && this.port.supported()) this.port.release(hinted);
  }
}
