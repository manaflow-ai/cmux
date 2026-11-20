// l10n-allow-file: the experiment gallery describes the scheduling arms.
import { defineExperiment } from "../../../experiments/experiment";

export const chatInstantUnderLoad = defineExperiment({
  id: "chat-instant-under-load",
  title: "Chat input under load",
  description: "Type while agents update the chat list shared with new tabs.",
  arms: {
    off: { label: "Off", description: "Publish the changed list when its write window opens." },
    on: { label: "On", description: "Publish the latest list during an idle slice after input." },
  },
  defaultArm: "off",
});
