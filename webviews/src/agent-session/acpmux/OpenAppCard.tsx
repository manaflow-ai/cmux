import { postNative } from "./native";
import { useCloudPreviewPorts, type CloudPreviewPort } from "./cloudPreviewPorts";
import { useState } from "react";

type Props = {
  enabled?: boolean;
  /** Gallery and tests can render a fixed state without mutating the live event store. */
  ports?: readonly CloudPreviewPort[];
  onOpen?: (port: number) => Promise<unknown> | unknown;
};

export function OpenAppCard({ enabled = true, ports: suppliedPorts, onOpen }: Props): React.ReactNode {
  const livePorts = useCloudPreviewPorts();
  const ports = suppliedPorts ?? livePorts;
  const [errors, setErrors] = useState<Record<number, string>>({});
  const [opening, setOpening] = useState<number>();
  if (!enabled) return null;
  const open = async (port: number) => {
    setOpening(port);
    setErrors((current) => ({ ...current, [port]: "" }));
    try {
      await (onOpen ? onOpen(port) : postNative("cloud.preview.open", { port }));
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not open preview";
      setErrors((current) => ({ ...current, [port]: message }));
    } finally {
      setOpening((current) => (current === port ? undefined : current));
    }
  };
  return (
    <div className="acpmux-open-app-cards" aria-label="New apps">
      {ports.map((app) => (
        <div className="acpmux-open-app-card" key={app.port}>
          <div className="acpmux-open-app-card__copy">
            <strong>Open app</strong>
            <span>
              Port {app.port}
              {app.process ? ` · ${app.process}` : ""}
            </span>
            {errors[app.port] ? <span className="acpmux-open-app-card__error">{errors[app.port]}</span> : null}
          </div>
          <button
            type="button"
            className="acpmux-open-app-card__button"
            disabled={opening === app.port}
            onClick={() => void open(app.port)}
          >
            {opening === app.port ? "Opening…" : errors[app.port] ? "Retry" : "Open"}
          </button>
        </div>
      ))}
    </div>
  );
}
