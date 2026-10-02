import React, { useEffect, useLayoutEffect, useRef } from "react";
export function ContinueMenu({
  label,
  targets,
  disabled,
  open,
  setOpen,
  onChoose,
}: {
  label: string;
  targets: { id: string; name: string }[];
  disabled: boolean;
  open: boolean;
  setOpen: (value: boolean) => void;
  onChoose: (harness: string) => void;
}) {
  const button = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (open && !disabled) menu.current?.querySelector<HTMLElement>("button")?.focus();
  }, [open, disabled]);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => {
      if (!menu.current?.contains(event.target as Node) && !button.current?.contains(event.target as Node))
        setOpen(false);
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
  }, [open, setOpen]);
  return (
    <span className="acpmux-handoff-targets">
      <button
        ref={button}
        type="button"
        aria-haspopup="menu"
        aria-expanded={open && !disabled}
        disabled={disabled}
        onClick={() => setOpen(!open)}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown" || e.key === "ArrowUp") {
            e.preventDefault();
            setOpen(true);
          }
        }}
      >
        {label}
      </button>
      {open && !disabled && (
        <div
          ref={menu}
          role="menu"
          tabIndex={-1}
          aria-label={label}
          onKeyDown={(e) => {
            const items = [...(menu.current?.querySelectorAll<HTMLElement>("button") ?? [])];
            const index = items.indexOf(document.activeElement as HTMLElement);
            if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
              setOpen(false);
              button.current?.focus();
            } else if (e.key === "Tab") setOpen(false);
            else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              items[(index + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length]?.focus();
            }
          }}
        >
          {targets.map((target) => (
            <button
              key={target.id}
              type="button"
              role="menuitem"
              tabIndex={-1}
              onClick={() => {
                setOpen(false);
                onChoose(target.id);
              }}
            >
              {target.name}
            </button>
          ))}
        </div>
      )}
    </span>
  );
}
