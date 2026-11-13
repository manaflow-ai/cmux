import showcase from "../../../../../skills/cmux-customization/showcase.json";
import { useStore } from "../context";
import { ActionRow } from "./ActionRow";
import { Button } from "../../../ui/Button";
import { t } from "../strings";

type Example = { id: string; file: string; manifest: string };
// Pin installs and source links to the reviewed tree. A moving branch would let
// the Settings card silently install code that was never reviewed with the app.
const SHOWCASE_REF = "69da562de66ba80604f7f2c8559ae7abe8d98446";
const RAW_BASE = `https://raw.githubusercontent.com/manaflow-ai/cmux/${SHOWCASE_REF}/`;
const SOURCE_BASE = `https://github.com/manaflow-ai/cmux/blob/${SHOWCASE_REF}/`;
const shellQuote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
const HELP_LIMIT = 60;

// Settings keeps helper lines compact in every locale. The catalog may contain a
// fuller translation, but the card must never turn a short example into a tall
// block when a locale expands the copy.
function compactHelp(value: string): string {
  return value
    .split("\n")
    .map((line) => {
      const characters = [...line];
      return characters.length > HELP_LIMIT ? `${characters.slice(0, HELP_LIMIT - 1).join("")}…` : line;
    })
    .join("\n");
}

export function templateInstallCommand(example: Example): string {
  return [
    "(",
    `  example_dir=$(mktemp -d ${shellQuote(`./cmux-example-${example.id}.XXXXXX`)}) &&`,
    `  curl -fsSL --connect-timeout 10 --max-time 60 ${shellQuote(RAW_BASE + example.file)} -o "$example_dir/main.js" &&`,
    `  curl -fsSL --connect-timeout 10 --max-time 60 ${shellQuote(RAW_BASE + example.manifest)} -o "$example_dir/cmux-app.json" &&`,
    '  cd "$example_dir" &&',
    "  cmux ext dev",
    ")",
  ].join("\n");
}

export function CustomizeExamplesCard() {
  const store = useStore();
  return (
    <section className="group" data-card="customization-examples">
      <h3 className="group-title">{t("settingsPage.customization.examples")}</h3>
      <p className="row-help">{compactHelp(t("settingsPage.customization.help"))}</p>
      <div className="rows">
        {showcase.samples.map((example) => (
          <ActionRow
            key={example.id}
            title={t(`settingsPage.customization.sample.${example.id}.title`)}
            help={compactHelp(t(`settingsPage.customization.sample.${example.id}.description`))}
          >
            <a className="button" href={SOURCE_BASE + example.file} target="_blank" rel="noreferrer">
              {t("settingsPage.customization.source")}
            </a>
            <a
              className="button"
              href={`${SOURCE_BASE}docs/cmux-next/customization-showcase.gallery.md#${example.galleryAnchor}`}
              target="_blank"
              rel="noreferrer"
            >
              {t("settingsPage.customization.gallery")}
            </a>
            <Button type="button" className="button" onClick={() => void store.copy(templateInstallCommand(example))}>
              {t("settingsPage.customization.copyInstall")}
            </Button>
          </ActionRow>
        ))}
      </div>
    </section>
  );
}
