// Settings > Extensions: the settings each installed extension's manifest declares, one group per
// extension, drawn from the schema the daemon answers (`apps.settings.list`). A change goes to the
// daemon (`apps.settings.set`), which checks it against the manifest, stores it with the install
// and hands it to the running extension at once (`settings.changed`); the rows then show the values
// the daemon answered. Reset to Default (the row's right-click menu) sends `null`, the manifest's
// default. The card reads when it mounts.
import { useEffect, useId, useState } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import { NumberField } from "../editors/NumberField";
import type { ExtensionSetting, ExtensionSettings } from "../extensionSettings";
import type { NumberRange } from "../schema";
import { t } from "../strings";

const same = (left: unknown, right: unknown) => JSON.stringify(left) === JSON.stringify(right);

/** Editable text, whose right-click keeps WebKit's Cut, Copy and Paste (as SettingRow). */
const TEXT_FIELDS = 'input:not([type="checkbox"]):not([type="radio"]), textarea';

export function ExtensionsCard() {
  const store = useStore();
  const [apps, setApps] = useState<ExtensionSettings[] | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void store.extensionSettings().then((result) => {
      if (!live) return;
      setApps(result.apps);
      setUnavailable(result.unavailable);
      if (!result.unavailable) setError(result.error);
    });
    return () => {
      live = false;
    };
  }, [store]);

  if (apps === null && !unavailable && !error) return null;
  if (unavailable || error || !apps || apps.length === 0) {
    const [marker, message] = unavailable
      ? ["data-extensions-unavailable", t("settingsPage.extensions.unavailable")]
      : error
        ? ["data-extensions-error", error]
        : ["data-extensions-empty", t("settingsPage.extensions.empty")];
    return (
      <section className="group" data-card="extensions">
        <div className="row" {...{ [marker]: "" }}>
          <span className="row-help" role={error ? "alert" : undefined}>
            {message}
          </span>
        </div>
      </section>
    );
  }
  return (
    <div className="extension-settings" data-card="extensions">
      <p className="row-help">{t("settingsPage.extensions.help")}</p>
      {apps.map((app) => (
        <ExtensionGroup
          key={app.app}
          app={app}
          onValues={(values) =>
            setApps((rows) => (rows ?? []).map((row) => (row.app === app.app ? { ...row, values } : row)))
          }
        />
      ))}
    </div>
  );
}

function ExtensionGroup({
  app,
  onValues,
}: {
  app: ExtensionSettings;
  onValues(values: Record<string, unknown>): void;
}) {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const change = async (values: Record<string, unknown>) => {
    setBusy(true);
    try {
      const result = await store.setExtensionSettings(app.app, values);
      setProblem(result.error);
      if (result.values) onValues(result.values);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="group" data-extension={app.app}>
      <h3 className="group-title">{app.name}</h3>
      {problem && (
        <p className="row-help" role="alert" data-extension-problem="">
          {problem}
        </p>
      )}
      <div className="rows">
        {app.settings.map((setting) => (
          <ExtensionRow
            key={setting.key}
            setting={setting}
            value={app.values[setting.key] ?? setting.default}
            disabled={busy}
            onChange={(value) => void change({ [setting.key]: value })}
          />
        ))}
      </div>
    </section>
  );
}

function ExtensionRow({
  setting,
  value,
  disabled,
  onChange,
}: {
  setting: ExtensionSetting;
  value: unknown;
  disabled: boolean;
  onChange(value: unknown): void;
}) {
  const labelId = useId();
  // The page's one reset path is a row's right-click menu (useRowMenu): no Reset button.
  const menu: ContextMenuItem[] = [
    {
      id: "reset",
      label: t("settingsPage.resetToDefault"),
      disabled: disabled || same(value, setting.default),
      onSelect: () => onChange(null),
    },
  ];
  return (
    <div className="row" data-extension-setting={setting.key} tabIndex={-1}>
      <div className="row-main">
        <ContextMenu className="row-label" items={menu}>
          <div className="row-title" id={labelId}>
            {setting.title}
          </div>
          {setting.help && <div className="row-help">{setting.help}</div>}
        </ContextMenu>
        <ContextMenu className="row-control-menu" items={menu} ignore={TEXT_FIELDS}>
          <div className="row-control">
            <Control setting={setting} value={value} disabled={disabled} labelId={labelId} onChange={onChange} />
          </div>
        </ContextMenu>
      </div>
    </div>
  );
}

function Control({
  setting,
  value,
  disabled,
  labelId,
  onChange,
}: {
  setting: ExtensionSetting;
  value: unknown;
  disabled: boolean;
  labelId: string;
  onChange(value: unknown): void;
}) {
  switch (setting.kind) {
    case "toggle":
      return <Switch checked={value === true} disabled={disabled} labelId={labelId} onToggle={onChange} />;
    case "choice":
      return (
        <Select
          value={typeof value === "string" ? value : ""}
          disabled={disabled}
          labelId={labelId}
          onChange={onChange}
        >
          {setting.choices.map((choice) => (
            <option key={choice} value={choice}>
              {choice}
            </option>
          ))}
        </Select>
      );
    case "text":
      return (
        <TextField
          value={typeof value === "string" ? value : ""}
          setting={setting}
          disabled={disabled}
          labelId={labelId}
          onCommit={onChange}
        />
      );
    case "integer":
    case "number": {
      const range: NumberRange = {
        min: setting.minimum ?? Number.MIN_SAFE_INTEGER,
        max: setting.maximum ?? Number.MAX_SAFE_INTEGER,
        step: setting.kind === "integer" ? 1 : 0.1,
        unit: "count",
        placeholder: typeof setting.default === "number" ? setting.default : 0,
      };
      return (
        <NumberField
          value={typeof value === "number" ? value : null}
          range={range}
          placeholder={typeof setting.default === "number" ? String(setting.default) : ""}
          disabled={disabled}
          labelId={labelId}
          onCommit={(next) => onChange(setting.kind === "integer" ? Math.round(next) : next)}
        />
      );
    }
  }
}

/** A text setting, committed on Return or blur; Escape drops the edit. */
function TextField({
  value,
  setting,
  disabled,
  labelId,
  onCommit,
}: {
  value: string;
  setting: ExtensionSetting;
  disabled: boolean;
  labelId: string;
  onCommit(value: string): void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const commit = () => {
    if (draft === null) return;
    setDraft(null);
    if (draft !== value) onCommit(draft);
  };
  return (
    <span className="text-editor">
      <Input
        className="field text"
        type="text"
        spellCheck={false}
        value={draft ?? value}
        maxLength={setting.maxLength ?? undefined}
        placeholder={typeof setting.default === "string" ? setting.default : ""}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit();
          else if (event.key === "Escape" && draft !== null) {
            event.stopPropagation();
            setDraft(null);
          }
        }}
      />
    </span>
  );
}
