// The agent chat's side column as it opens (Debug Settings agentChat.sideColumn, Opt-Cmd-B; Lucas
// 2026-10-17, after T3 Code's "Open a surface"): window tiles for what the column can hold, with no
// text but each tile's name as its tooltip and label. Terminal and Browser replace this page with
// their tab; Files and Changes open beside it in the same pane; New chat turns the page into the
// usual New Tab screen. A letter picks a tile, as T3's list does.
import { useT } from "../i18n";
import { PickerButton } from "../../../ui/PickerPrimitives";
import { Icon } from "../icons/Icon";
import { useNt } from "./strings";

export type Surface = "terminal" | "browser" | "files" | "changes" | "chat";

const KEYS: Record<string, Surface> = { t: "terminal", b: "browser", f: "files", d: "changes", c: "chat" };

export function SurfaceLauncher({ onPick }: { onPick: (surface: Surface) => void }) {
  const t = useT();
  const nt = useNt();
  const tiles: { surface: Surface; label: string; icon: string }[] = [
    { surface: "terminal", label: nt("create.terminal"), icon: "terminal" },
    { surface: "browser", label: nt("create.browser"), icon: "browser" },
    { surface: "files", label: t("header.files"), icon: "folder" },
    { surface: "changes", label: t("header.changes"), icon: "diff.file" },
    { surface: "chat", label: nt("create.chat"), icon: "agent.chat" },
  ];
  return (
    <div className="nt-surfaces">
      <fieldset className="nt-surfaces__grid" aria-label={nt("create.label")}>
        {tiles.map((tile, index) => (
          <PickerButton
            key={tile.surface}
            type="button"
            className="nt-surface"
            data-surface={tile.surface}
            aria-label={tile.label}
            title={`${tile.label}  ${Object.keys(KEYS)
              .find((key) => KEYS[key] === tile.surface)
              ?.toUpperCase()}`}
            // oxlint-disable-next-line jsx-a11y/no-autofocus
            autoFocus={index === 0}
            onClick={() => onPick(tile.surface)}
            keyboard={(event) => {
              // A letter picks a tile (focus is always on one: the first takes it as the page opens).
              if (event.metaKey || event.ctrlKey || event.altKey) return;
              const surface = KEYS[event.key.toLowerCase()];
              if (!surface) return;
              event.preventDefault();
              onPick(surface);
            }}
          >
            <Icon name={tile.icon} size={20} />
          </PickerButton>
        ))}
      </fieldset>
    </div>
  );
}
