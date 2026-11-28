import type { DiffViewerAppearance } from "../../appearance";
import type { GalleryEnv } from "../env";
import type { GhosttyTheme } from "../theme/ghostty";
import type { ThemeTokens } from "../theme/tokens";

/** What a host gets besides its state: the controls, resolved to the app's inputs. */
export type StageContext = {
  env: GalleryEnv;
  /** The theme the window shows, and the pair the two-sided pages get. */
  theme: GhosttyTheme;
  pair: { dark: GhosttyTheme; light: GhosttyTheme };
  tokens: ThemeTokens;
  /** AgentPaneTheme.values for the theme. */
  agentTheme: Record<string, unknown>;
  /** The appearance the diff and markdown pages get. */
  appearance: DiffViewerAppearance;
  /** Records a host call (the stage's log, for debugging a fixture). */
  log(method: string, params?: unknown): void;
};
