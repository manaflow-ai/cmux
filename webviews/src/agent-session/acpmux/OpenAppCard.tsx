import { postNative } from "./native";
import { useCloudPreviewPorts, type CloudPreviewPort } from "./cloudPreviewPorts";
import { useState } from "react";
import { useT } from "./i18n";

type Props = {
  enabled?: boolean;
  /** Gallery and tests can render a fixed state without mutating the live event store. */
  ports?: readonly CloudPreviewPort[];
  onOpen?: (port: number) => Promise<unknown> | unknown;
};

export function OpenAppCard({ enabled = true, ports: suppliedPorts, onOpen }: Props): React.ReactNode {
  const t = useT();
  const livePorts = useCloudPreviewPorts();
  const ports = suppliedPorts ?? livePorts;
  const [errors, setErrors] = useState<Record<number, string>>({});
  const [opening, setOpening] = useState<number>();
  if (!enabled || ports.length === 0) return null;
  const open = async (port: number) => {
    setOpening(port);
    setErrors((current) => ({ ...current, [port]: "" }));
    try {
      await (onOpen ? onOpen(port) : postNative("cloud.preview.open", { port }));
    } catch (error) {
      const message = error instanceof Error ? error.message : t("cloudPreview.openError");
      setErrors((current) => ({ ...current, [port]: message }));
    } finally {
      setOpening((current) => (current === port ? undefined : current));
    }
  };
  return (
    <div className="acpmux-open-app-cards" aria-label={t("cloudPreview.newApps")}>
      {ports.map((app) => (
        <div className="acpmux-open-app-card" key={app.port}>
          <div className="acpmux-open-app-card__copy">
            <strong>{t("cloudPreview.openApp")}</strong>
            <span className={errors[app.port] ? "acpmux-open-app-card__error" : undefined} title={errors[app.port]}>
              {errors[app.port] || (
                <>
                  {t("cloudPreview.port", { port: app.port })}
                  {app.process ? ` · ${app.process}` : ""}
                </>
              )}
            </span>
          </div>
          <button
            type="button"
            className="acpmux-open-app-card__button"
            disabled={opening === app.port}
            onClick={() => void open(app.port)}
          >
            {(
              [
                ["open", t("cloudPreview.open")],
                ["opening", t("cloudPreview.opening")],
                ["retry", t("cloudPreview.retry")],
              ] as const
            ).map(([state, label]) => (
              <span
                key={state}
                className="acpmux-open-app-card__button-label"
                aria-hidden={state !== (opening === app.port ? "opening" : errors[app.port] ? "retry" : "open")}
              >
                {label}
              </span>
            ))}
          </button>
        </div>
      ))}
    </div>
  );
}
