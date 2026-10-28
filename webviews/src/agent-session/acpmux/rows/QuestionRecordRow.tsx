// The `questionRecord` row: a decided question's record.
import { memo } from "react";
import { QuestionCard } from "../question/QuestionCard";
import type { RowProps } from "./rowProps";

/// A decided question's record (question/record.ts): the card's own answered or cancelled form,
/// which answers nothing.
export const QuestionRecordRow = memo(
  function QuestionRecordRow({ row }: RowProps) {
    return row.question ? <QuestionCard question={row.question} onReply={ignoreReply} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

const ignoreReply = () => {};
