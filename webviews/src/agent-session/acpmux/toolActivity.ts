// How one ACP update folds into an activity item: a tool call merged with its update, a thought
// chunk, a background shell. Its bodies live in direct/toolItems.ts and direct/sessionUpdates.ts
// (leaves apart from direct.ts), so the transcript model reads them without the connection client.
export {
  objectValue,
  toolDiffs,
  inputDiffs,
  mergeToolItem,
  callDescription,
  shellCommand,
  textFromContent,
  appendThought,
  withRecipient,
} from "./direct/toolItems";
export { backgroundTask, type BackgroundUpdate } from "./direct/sessionUpdates";
