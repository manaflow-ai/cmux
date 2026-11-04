import { postNative } from "./native";
import { useCloudPreviewPorts } from "./cloudPreviewPorts";

export function OpenAppCard(): React.ReactNode {
  const ports = useCloudPreviewPorts();
  if (!ports.length) return null;
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
          </div>
          <button
            type="button"
            className="acpmux-open-app-card__button"
            onClick={() => void postNative("cloud.preview.open", { port: app.port })}
          >
            Open
          </button>
        </div>
      ))}
    </div>
  );
}
