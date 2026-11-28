import { useState } from "react";
import { t } from "../i18n";
import { encodeCtrlKey } from "../lib/mobile";

interface ExtraKeysBarProps {
  visible: boolean;
  onSend(text: string): void;
  onKey?(key: string): void;
}

export function ExtraKeysBar({ visible, onSend, onKey }: ExtraKeysBarProps) {
  const [ctrlActive, setCtrlActive] = useState(false);
  if (!visible) return null;

  const send = (text: string) => {
    onSend(text);
    setCtrlActive(false);
  };
  const sendKey = (key: string, fallback: string) => {
    if (onKey === undefined) onSend(fallback);
    else onKey(key);
    setCtrlActive(false);
  };
  const keepTerminalFocus = (event: React.PointerEvent<HTMLButtonElement>) => event.preventDefault();

  return (
    <div className="extra-keys" role="toolbar" aria-label={t("extraKeys")}>
      <button type="button" onPointerDown={keepTerminalFocus} onClick={() => sendKey("escape", "\u001b")}>{t("keyEscape")}</button>
      <button type="button" onPointerDown={keepTerminalFocus} onClick={() => sendKey("tab", "\t")}>{t("keyTab")}</button>
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
          <button type="button" aria-label={t("keyLeft")} onPointerDown={keepTerminalFocus} onClick={() => sendKey("left", "\u001b[D")}>←</button>
          <button type="button" aria-label={t("keyDown")} onPointerDown={keepTerminalFocus} onClick={() => sendKey("down", "\u001b[B")}>↓</button>
          <button type="button" aria-label={t("keyUp")} onPointerDown={keepTerminalFocus} onClick={() => sendKey("up", "\u001b[A")}>↑</button>
          <button type="button" aria-label={t("keyRight")} onPointerDown={keepTerminalFocus} onClick={() => sendKey("right", "\u001b[C")}>→</button>
          <button type="button" onPointerDown={keepTerminalFocus} onClick={() => send("\u0002")}>{t("keyPrefix")}</button>
        </>
      )}
    </div>
  );
}
