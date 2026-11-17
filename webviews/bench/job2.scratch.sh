O=${FAST_CHECKS_OUT:-/tmp}
BASE=99927d67183f34bd5fcf0b404b16c010086ac08a
A=src/agent-session/acpmux
cd webviews
NEW="$A/longChatShedOneTool.test.ts $A/longChatShedOpenTurn.test.ts"
OLD="$A/longChatShed.test.ts $A/longChatCut.test.ts $A/longChatNeverEnding.test.ts $A/longChatCost.test.ts $A/longChatHeld.test.ts $A/carriedSteerOrder.test.ts $A/olderPageAtRest.test.ts $A/orderedRowsPerf.test.ts $A/subagents $A/conversation/ShellBlock.test.tsx $A/conversation/pinnedToolRows.test.tsx"
{
  echo "== HEAD new"
  bun test $NEW 2>&1 | grep -E "\(fail\)|\(pass\)|Expected|Received|one-call|open-turn| pass$| fail$|error:"
  echo "== HEAD existing"
  bun test $OLD 2>&1 | grep -E "\(fail\)|Expected|Received| pass$| fail$|error:" | head -40
  echo "== LINT"
  bunx vp lint $A/direct.ts $A/model.ts $A/conversation/CommandRow.tsx $A/conversation/ToolRow.tsx $NEW 2>&1 | tail -3
  echo "== TSC"
  bunx tsc --noEmit -p . 2>&1 | grep -E "acpmux/(direct|model|longChatShed)" | head
} > "$O/tests.txt" 2>&1
cat "$O/tests.txt"
cd ..
git fetch -q --depth=1 origin $BASE
mkdir -p webviews-base
tar -C webviews --exclude=./node_modules -cf - . | tar -C webviews-base -xf -
ln -sfn "$PWD/webviews/node_modules" webviews-base/node_modules
for f in $A/direct.ts $A/model.ts $A/conversation/CommandRow.tsx $A/conversation/ToolRow.tsx; do
  git show $BASE:webviews/$f > webviews-base/$f
done
cd webviews
bun bench/composer-typing-heavy.scratch.ts --lengths 1500 --modes heavy --arms base=../webviews-base,head=. --rounds 6 > "$O/bench.txt" 2>&1
grep -vE "^\s*$" "$O/bench.txt" | grep -vE "HELD-DIAG|COMPOSER-TYPING|BENCH-ARMS" | tail -30
