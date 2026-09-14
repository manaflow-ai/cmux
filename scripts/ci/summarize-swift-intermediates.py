import heapq
from pathlib import Path
import re
import subprocess

roots = [Path("Sources"), Path("build-universal/Build/Intermediates.noindex/cmux.build/Release/cmux.build")]
paths = sorted(set([*Path('.').glob('*.sil'), *Path('.').glob('*.ll'), *(p for root in roots for pattern in ('*.sil','*.ll') for p in root.rglob(pattern))]))
print(f"Saved intermediate files: {len(paths)}")
for kind in ['sil', 'll']:
    largest=[]
    def record(value):
        if value is None: return
        row=(value[1], value[2], value[0], value[3])
        if len(largest)<35: heapq.heappush(largest,row)
        elif row>largest[0]: heapq.heapreplace(largest,row)
    for path in paths:
        if path.suffix != '.'+kind: continue
        current=None
        for line in path.open(errors='replace'):
            if (kind=='sil' and line.startswith('sil ')) or (kind=='ll' and line.startswith('define ')):
                record(current)
                match=re.search(r'@("[^"]+"|[^\s:(]+)',line)
                current=[match[1].strip('"') if match else line[:150],0,0,str(path)]
            elif current:
                if line.startswith('}'):
                    record(current);current=None
                elif line.strip() and not line.lstrip().startswith(('//',';')):
                    current[1]+=1
                    if re.match(r'^(bb\d+|[A-Za-z0-9_.-]+):?',line) and not line.startswith(' '):current[2]+=1
        record(current)
    rows=sorted(largest,reverse=True)
    names='\n'.join(row[2] for row in rows)
    demangled=subprocess.run(['xcrun','swift-demangle','--compact'],input=names,text=True,capture_output=True,check=True).stdout.splitlines() if rows else []
    print(f"Largest {kind} functions (instructions, blocks, function, file):")
    for row,name in zip(rows,demangled):print(row[0],row[1],name,row[3])
