import { useState } from "react";
import { t } from "../i18n";
import { encodeCtrlKey } from "../lib/mobile";

interface ExtraKeysBarProps {
  visible: boolean;
  onSend(text: string): void;
}

export function ExtraKeysBar({ visible, onSend }: ExtraKeysBarProps) {
  const [ctrlActive, setCtrlActive] = useState(false);
  if (!visible) return null;

  const send = (text: string) => {
    onSend(text);
    setCtrlActive(false);
  };
  const keepTerminalFocus = (event: React.PointerEvent<HTMLButtonElement>) => event.preventDefault();

  return (
    <div className="extra-keys" role="toolbar" aria-label={t("extraKeys")}>
      <button type="button" onPointerDown={keepTerminalFocus} onClick={() => send("\u001b")}>{t("keyEscape")}</button>
      <button type="button" onPointerDown={keepTerminalFocus} onClick={() => send("\t")}>{t("keyTab")}</button>
      <button
        className={ctrlActive ? "active" : ""}
        type="button"
        aria-pressed={ctrlActive}
        onPointerDown={keepTerminalFocus}
        onClick={() => setCtrlActive((active) => !active)}
      >
        {t("keyControl")}
      </button>
      {ctrlActive && Array.from("abcdefghijklmnopqrstuvwxyz").map((letter) => (
        <button
          className="ctrl-letter"
          key={letter}
          type="button"
          onPointerDown={keepTerminalFocus}
          onClick={() => {
            const encoded = encodeCtrlKey(letter);
            if (encoded !== null) send(encoded);
          }}
        >
          {letter.toUpperCase()}
        </button>
      ))}
      {!ctrlActive && (
        <>
          <button type="button" aria-label={t("keyLeft")} onPointerDown={keepTerminalFocus} onClick={() => send("\u001b[D")}>←</button>
          <button type="button" aria-label={t("keyDown")} onPointerDown={keepTerminalFocus} onClick={() => send("\u001b[B")}>↓</button>
          <button type="button" aria-label={t("keyUp")} onPointerDown={keepTerminalFocus} onClick={() => send("\u001b[A")}>↑</button>
          <button type="button" aria-label={t("keyRight")} onPointerDown={keepTerminalFocus} onClick={() => send("\u001b[C")}>→</button>
          <button type="button" onPointerDown={keepTerminalFocus} onClick={() => send("\u0002")}>{t("keyPrefix")}</button>
        </>
      )}
    </div>
  );
}

