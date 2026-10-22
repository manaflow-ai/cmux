import { COMPOSER_LOOK_NAMES, COMPOSER_LOOKS, setComposerLook, useComposerLook } from "./composerLook";
import { useT } from "./i18n";
import { DotSwitch } from "./newtab/StyleSwitch";

/// The same appearance-only choice on New Tab and under a chat. Agent controls keep their owners.
export function ComposerLookSwitch({ className, onCancel }: { className: string; onCancel(): void }) {
  const t = useT();
  const look = useComposerLook();
  return (
    <DotSwitch
      options={COMPOSER_LOOKS}
      current={look}
      label={t("composer.look.label")}
      name={(option) => COMPOSER_LOOK_NAMES[option]}
      className={className}
      onPick={setComposerLook}
      onCancel={onCancel}
    />
  );
}
