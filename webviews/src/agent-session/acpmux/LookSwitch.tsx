// The composer's look dots in a chat (Leo 2026-10-22: "when you're in a chat you can also switch the
// dots if you hover on that bottom area"): the New Tab page's first two dots (newtab/PageDots.tsx),
// Claude's look then Codex's (composerLook.ts), in the composer's bottom area. With Claude's look
// they sit in the quiet row's empty middle, with Codex's in the box's internal dead-space row; either way they
// show while the pointer is over that area or a dot has the keyboard, and fade when it leaves
// (composerLook.css `.acpmux-look-dots`). ComposerBox keeps one LookSwitch across a look change, so
// arrow keys go on switching and Escape goes back to the prompt.
import { COMPOSER_LOOK_NAMES, COMPOSER_LOOKS, setComposerLook, useComposerLook } from "./composerLook";
import { useT } from "./i18n";
import { DotSwitch } from "./newtab/StyleSwitch";

export function LookSwitch({ onDone }: { onDone(): void }) {
  const t = useT();
  const look = useComposerLook();
  return (
    <span className="acpmux-look-slot">
      <DotSwitch
        options={COMPOSER_LOOKS}
        current={look}
        label={t("composer.look.label")}
        name={(option) => COMPOSER_LOOK_NAMES[option]}
        className="nt-style acpmux-look-dots"
        nameAside
        onPick={setComposerLook}
        onCancel={onDone}
      />
    </span>
  );
}
