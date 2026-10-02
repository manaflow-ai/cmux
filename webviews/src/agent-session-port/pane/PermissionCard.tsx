// An agent's pending permission request, docked above the composer. The ChatGPT captures
// have no inline approval; this follows their card language (the edited-files card): one
// line of title, the agent's options as quiet buttons, the allowing option first.
import type { AcpmuxPermission } from "../data/acpmux";
import { act } from "./useAcpmuxPane";

export function PermissionCard({ permission }: { permission: AcpmuxPermission }) {
  const options = [...permission.options].sort((a, b) => Number(b.allow) - Number(a.allow));
  return (
    <div className="pt-permission" role="alertdialog" aria-label="Permission required">
      <div className="pt-permission__title">{permission.title || "Permission required"}</div>
      <div className="pt-permission__actions">
        {options.map((option, index) => (
          <button
            key={option.id}
            type="button"
            className={`pt-permission__button${index === 0 && option.allow ? " is-primary" : ""}`}
            onClick={() => act("chat.permission", { permissionId: permission.permissionId, optionId: option.id })}
          >
            {option.name}
          </button>
        ))}
      </div>
    </div>
  );
}
