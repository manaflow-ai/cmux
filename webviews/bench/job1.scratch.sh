O=${FAST_CHECKS_OUT:-/tmp}; PREV=cb578ea4fb1f6a0d3ce33e41fa1dadf99b21c96c; cd webviews; A=src/agent-session/acpmux
NEW="$A/longChatShedOneTool.test.ts $A/longChatShedOpenTurn.test.ts"
OLD="$A/longChatShed.test.ts $A/longChatCut.test.ts $A/longChatNeverEnding.test.ts $A/longChatCost.test.ts $A/longChatHeld.test.ts $A/carriedSteerOrder.test.ts $A/olderPageAtRest.test.ts $A/orderedRowsPerf.test.ts $A/subagents $A/conversation/ShellBlock.test.tsx $A/conversation/pinnedToolRows.test.tsx"
F="\(fail\)|\(pass\)|Expected|Received|one-call|open-turn| pass$| fail$|error:"
{ echo "== HEAD new"; bun test $NEW 2>&1 | grep -E "$F"
  echo "== HEAD existing"; bun test $OLD 2>&1 | grep -E "\(fail\)|Expected|Received| pass$| fail$|error:" | head -40
  echo "== LINT"; bunx vp lint $A/direct.ts $A/model.ts $A/conversation/CommandRow.tsx $A/conversation/ToolRow.tsx $NEW 2>&1 | tail -4
  echo "== TSC"; bunx tsc --noEmit -p . 2>&1 | grep -E "acpmux/(direct|model|longChatShed)" | head
} > $O/tests.txt 2>&1
cat $O/tests.txt
bun bench/composer-typing-heavy.scratch.ts --lengths 1500 --modes heavy --arms head=. --rounds 1 > $O/bench.txt 2>&1
grep -E "RUN|rror" $O/bench.txt | cut -c1-400 | tail -5
{ echo "== PREV direct.ts"; git fetch -q --depth=1 origin $PREV && git show $PREV:webviews/$A/direct.ts > $A/direct.ts && bun test $A/longChatShedOneTool.test.ts 2>&1 | grep -E "$F"; } > $O/prev.txt 2>&1
cat $O/prev.txt
