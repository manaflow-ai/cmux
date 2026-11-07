// The transcript's strings: its own table (the Swift transcript's keys, Localizable.xcstrings beside
// this file) over the Channels table, whose parts it reuses (attachment tiles and tray, the emoji
// picker, typing and upload lines). One `Strings` reads both.
import channels from "../../home-channels/generated/strings.json";
import { createStrings, type StringTable, type Strings } from "../../shared/i18n";
import transcript from "./generated/strings.json";

/** Both tables, per language; the transcript's keys win. */
export function transcriptTable(): StringTable {
  const out: StringTable = {};
  const languages = new Set([...Object.keys(channels), ...Object.keys(transcript)]);
  for (const language of languages) {
    out[language] = {
      ...(channels as StringTable)[language],
      ...(transcript as StringTable)[language],
    };
  }
  return out;
}

export function createTranscriptStrings(tags?: readonly string[]): Strings {
  return createStrings(transcriptTable(), tags);
}
