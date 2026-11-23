// A button that opens a popover under it: ui/Popover anchored to the button, opened by
// usePopoverTrigger (a mouse press opens it, pressing again closes it, the trigger carries
// aria-expanded and aria-controls). Escape and a press outside close it, and focus returns.
import { useState, type ReactNode } from "react";
import { Button, type ButtonProps } from "../ui/Button";
import { Popover } from "../ui/Popover";
import { usePopoverTrigger } from "../ui/popoverTrigger";

export interface PopoverButtonProps {
  /** The popover's accessible name (role dialog). */
  label: string;
  /** What the button shows. */
  trigger: ReactNode;
  variant?: ButtonProps["variant"];
  size?: ButtonProps["size"];
  /** An icon-only trigger; `label` names it. */
  icon?: boolean;
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  align?: "start" | "end";
  disabled?: boolean;
  /** Classes for the trigger. */
  className?: string;
  /** Controlled open state; leave both out to let the button own it. */
  open?: boolean;
  onOpenChange?(open: boolean): void;
  children: ReactNode;
}

export function PopoverButton({
  label,
  trigger,
  variant = "ghost",
  size = "md",
  icon = false,
  side = "bottom",
  align = "start",
  disabled,
  className,
  open: controlled,
  onOpenChange,
  children,
}: PopoverButtonProps) {
  const [own, setOwn] = useState(false);
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const open = controlled ?? own;
  const setOpen = (next: boolean) => {
    setOwn(next);
    onOpenChange?.(next);
  };
  const press = usePopoverTrigger(open, setOpen);
  return (
    <>
      <Button
        ref={setAnchor}
        variant={variant}
        size={size}
        icon={icon}
        disabled={disabled}
        className={className}
        aria-label={icon ? label : undefined}
        data-popup-open={open ? "" : undefined}
        {...press}
      >
        {trigger}
      </Button>
      <Popover
        open={open}
        onOpenChange={(next) => setOpen(next)}
        anchor={anchor}
        label={label}
        id={press["aria-controls"]}
        side={side}
        align={align}
      >
        {children}
      </Popover>
    </>
  );
}
