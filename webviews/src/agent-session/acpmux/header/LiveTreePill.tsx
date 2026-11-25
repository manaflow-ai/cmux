import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";

type Status = { available: boolean; updated?: number; lanes?: { name: string; verdict: string }[] };

/// On-demand snapshot, validated on the session host. Closing/off unmounts the read's consumer.
export function LiveTreePill({ cwd, readStatus }: { cwd?: string; readStatus: () => Promise<unknown> }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [status, setStatus] = useState<Status>();
  useEffect(() => {
    if (!open) return;
    let disposed = false;
    setStatus(undefined);
    void readStatus()
      .then((raw) => {
        if (disposed) return;
        const value = raw as Status | undefined;
        setStatus(value?.available === true && Array.isArray(value.lanes) ? value : { available: false });
      })
      .catch(() => {
        if (!disposed) setStatus({ available: false });
      });
    return () => {
      disposed = true;
    };
  }, [open, refresh, readStatus]);
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);

  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-header-live-tree"
        aria-label={t("header.liveTree")}
        {...trigger}
      >
        <Icon name="git.worktree" size={14} />
        <span>{t("header.liveTree")}</span>
      </button>
      <Popover
        id={trigger["aria-controls"]}
        open={open}
        onOpenChange={(next) => {
          if (!next) setOpen(false);
        }}
        anchor={button}
        label={t("header.liveTree")}
        className="acpmux-pr-status acpmux-live-tree-status"
        side="bottom"
        finalFocus={buttonRef}
      >
        <div className="acpmux-pr-title">{t("header.liveTree")}</div>
        <div className="acpmux-pr-facts">{t("composer.folder")}</div>
        <code className="acpmux-live-tree-path">{cwd || t("project.noFolder")}</code>
        <output className="acpmux-pr-facts">
          {!status ? "…" : !status.available ? t("header.liveTreeDisconnected") : t("header.liveTreeReport")}
        </output>
        {status?.available && (
          <ul className="acpmux-live-tree-results">
            {status.lanes?.map((lane) => (
              <li key={lane.name}>
                <code>{lane.name}</code>
                <span>
                  {lane.verdict === "passed"
                    ? t("walkthrough.stepPassed")
                    : lane.verdict === "failed"
                      ? t("header.failed")
                      : t("header.liveTreeUnknown")}
                </span>
              </li>
            ))}
          </ul>
        )}
        <button
          type="button"
          className="acpmux-header-tool acpmux-header-live-tree"
          disabled={!status}
          onClick={() => setRefresh((value) => value + 1)}
        >
          {t("git.refresh")}
        </button>
      </Popover>
    </>
  );
}
