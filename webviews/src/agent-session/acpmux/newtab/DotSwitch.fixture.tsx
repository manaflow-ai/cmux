// l10n-allow-file: synthetic gallery labels, not shipped UI.
import { useRef, useState } from "react";
import { DotSwitch } from "./StyleSwitch";

const options = ["Minimal", "Quick actions", "Compact"] as const;

export default function DotSwitchFixture() {
  const [current, setCurrent] = useState<(typeof options)[number]>("Minimal");
  const returnTarget = useRef<HTMLButtonElement>(null);
  return (
    <div className="dot-focus-fixture">
      <button ref={returnTarget} type="button">
        Before dots
      </button>
      <DotSwitch<(typeof options)[number]>
        options={options}
        current={current}
        label="Page look"
        name={(option) => option}
        onPick={setCurrent}
        onCancel={() => returnTarget.current?.focus()}
      />
      <button type="button">After dots</button>
    </div>
  );
}
