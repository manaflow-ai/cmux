#!/bin/bash
# Hook: Sync Claude Code session focus to cmux tab/workspace name
# Triggered on: Stop (after Claude finishes each response)
# Reads transcript JSONL efficiently (head+tail, not full scan)
# Global hook — no-ops outside cmux.
set -e

INPUT=$(cat)

[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
command -v cmux &>/dev/null || exit 0

TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

LABEL=$(_TRANSCRIPT="$TRANSCRIPT" python3 -c "
import json, re, os, sys, collections

TRANSCRIPT = os.environ['_TRANSCRIPT']

STOP_WORDS = frozenset({
    'please','can','you','the','a','an','i','want','to','me',
    'need','help','with','this','that','for','in','on','it',
    'is','my','do','let','lets','make','also','and','or','but',
    'would','should','could','just','some','all','any','be',
    'have','has','had','will','shall','may','might','must',
    'so','very','really','from','into','about','how','what',
    'when','where','which','who','why','if','then','there',
    'here','these','those','them','their','its','our','your',
    'we','they','he','she','of','at','by','up','out','look',
    'go','see','know','get','give','take','put','tell','say',
    'try','use','way','new','now','one','two','not','no','yes',
    'ok','sure','done','thanks','right','well','think','like',
    'good','great','yeah','code','file','run','first','using',
    'option','based','hook','session','current','already',
    'def','return','import','json','sys','os','re','none',
    'true','false','print','elif','else','except','pass','break',
    'class','self','entry','entries','label','text','content',
    'isinstance','dict','list','str','int','len','type','line',
    'msg','get','set','split','replace','join','lower','pyeof',
    'collections','counter','frozenset','append','strip',
    '请','帮我','帮','我','你','能','能不能','可以','一下','看看',
    '这个','那个','的','了','吗','呢','啊','是','在','有','和','与',
    '把','给','让','对','到','从','用','被','着','过','得','地',
    '也','都','就','还','又','再','很','太','不','没','怎么','什么',
    '如何','是否','已经','然后','现在','一些','所有','还是','比较',
    '应该','可能','需要','想','要','会','去','来','做','看','或者',
})

def extract_text(entry):
    msg = entry.get('message', {})
    if isinstance(msg, dict):
        c = msg.get('content', '')
        if isinstance(c, str): return c
        if isinstance(c, list):
            return ' '.join(b.get('text','') for b in c if isinstance(b,dict) and b.get('type')=='text')
    return ''

def tokenize(text):
    # Clean markup/code
    text = re.sub(r'https?://\S+', '', text)
    text = re.sub(r'\x60{3}.*?\x60{3}', '', text, flags=re.S)
    text = re.sub(r'\x60[^\x60]+\x60', '', text)
    text = re.sub(r'[#*_>\[\]\(\){}|\":]', ' ', text)
    text = re.sub(r'^\d+[.)]\s*', '', text, flags=re.M)
    # Split CJK and Latin into separate tokens
    return re.findall(r'[\u4e00-\u9fff]{2,}|[a-zA-Z][a-zA-Z0-9]*', text)

def summarize(texts):
    tokens = []
    for t in texts:
        tokens.extend(tokenize(t))
    freq = collections.Counter()
    for w in tokens:
        low = w.lower()
        if low in STOP_WORDS or len(low) < 2:
            continue
        freq[low] += 1
    if not freq:
        return ''
    # Deduplicate, prefer original casing
    casing = {}
    for w in tokens:
        low = w.lower()
        if low not in casing and low in freq:
            casing[low] = w
    top = [casing.get(w, w) for w, _ in freq.most_common(6)]
    # Remove duplicates preserving order
    seen = set()
    deduped = []
    for w in top:
        if w.lower() not in seen:
            seen.add(w.lower())
            deduped.append(w)
    # Build label: 2-4 words, max 25 chars
    for n in (4, 3, 2):
        label = ' '.join(deduped[:n])
        if len(label) <= 25:
            return label
    return deduped[0][:25] if deduped else ''

# --- Read transcript efficiently: only parse what we need ---
lines = []
with open(TRANSCRIPT, 'r') as f:
    lines = f.readlines()

if not lines:
    sys.exit(0)

# First 3 user messages — scan from start, stop early
first_user = []
for raw in lines[:300]:  # first 300 lines is enough to find 3 user msgs
    try:
        e = json.loads(raw)
        if e.get('type') == 'user':
            t = extract_text(e)
            if t.strip():
                first_user.append(t[:300])
                if len(first_user) >= 3: break
    except: pass

# Last 5 user+assistant messages — scan from end
last_msgs = []
for raw in reversed(lines[-200:]):
    try:
        e = json.loads(raw)
        if e.get('type') in ('user', 'assistant'):
            t = extract_text(e)
            if t.strip():
                last_msgs.append(t[:300])
                if len(last_msgs) >= 5: break
    except: pass
last_msgs.reverse()

all_texts = first_user + last_msgs
if not all_texts:
    sys.exit(0)

label = summarize(all_texts)
if label:
    print(label)
" 2>/dev/null)

# Tab: always our focus summary
# Workspace sync is handled by cmux-rename-sync.sh on UserPromptSubmit
if [ -n "$LABEL" ]; then
  cmux rename-tab --surface "$CMUX_SURFACE_ID" "$LABEL" 2>/dev/null || true
fi
