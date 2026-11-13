import showcase from "../../../../../skills/cmux-customization/showcase.json";
import { useStore } from "../context";
import { ActionRow } from "./ActionRow";
import { Button } from "../../../ui/Button";
import { t } from "../strings";

type Example = { id: string; file: string; manifest: string };
const RAW_BASE = "https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/";
const SOURCE_BASE = "https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/";
const shellQuote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

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
      <p className="row-help">{t("settingsPage.customization.help")}</p>
      <div className="rows">
        {showcase.samples.map((example) => (
          <ActionRow
            key={example.id}
            title={t(`settingsPage.customization.sample.${example.id}.title`)}
            help={t(`settingsPage.customization.sample.${example.id}.description`)}
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
