import { createContext } from "react";

// Third-party Markdown and bare URLs also render chips. Only transcript reply prose may
// disclose the pane's IP by fetching an icon without a click; quotes opt back out.
export const ReplySourceIconsContext = createContext(false);
