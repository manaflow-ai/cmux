import { memo } from "react";
import { LaneNoticeBatch } from "../conversation/LaneNoticeBatch";
import { type RowProps } from "./rowProps";
import { MessageRow } from "./MessageRow";

export const LaneNoticeBatchRow = memo(function LaneNoticeBatchRow(props: RowProps) {
  return <LaneNoticeBatch row={props.row} renderMessage={(row) => <MessageRow {...props} row={row} />} />;
});
