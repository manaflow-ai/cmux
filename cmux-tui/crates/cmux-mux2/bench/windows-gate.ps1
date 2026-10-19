# windows-gate.ps1 BINDIR [PERL]: the mux2 correctness gate on Windows (the
# corpus sizes of linux-gate.sh, but all 32 MB of unicode.txt: the slow
# viewer must fall more than 16 MiB behind to take the resync path). The server runs with MUX2_TAP_DIR, so
# mux2-verify compares against the bytes conhost wrote (see mux2-verify.rs).
# PERL generates the corpus (default: MSYS2's perl).
param([string]$B, [string]$Perl = "C:\msys64\usr\bin\perl.exe")
$ErrorActionPreference = 'Continue'
$W = Join-Path ([IO.Path]::GetTempPath()) ("mux2-gate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $W | Out-Null
$env:MUX2_SOCKET = "$W\sock"; $env:MUX2_TAP_DIR = "$W\tap"
$corpus = ($W -replace '\\', '/') + '/c'
& $Perl (Join-Path $PSScriptRoot 'gen-corpus.pl') $corpus | Out-Null
foreach ($f in 'cursor') { $s = [IO.File]::Open("$W\c\$f.txt", 'Open'); $s.SetLength(8MB); $s.Close() }
foreach ($f in 'plain', 'sgr') { $s = [IO.File]::Open("$W\c\$f.txt", 'Open'); $s.SetLength(64MB); $s.Close() }
& "$B\mux2.exe" stats | Out-Null
$n = 0; $faithful = 0
foreach ($f in 'cursor', 'unicode', 'sgr', 'plain') {
    foreach ($m in '--no-viewer', '', '--attach-midway', '--slow-viewer', '--resize-midway') {
        $a = @("$W\c\$f.txt"); if ($m) { $a += $m }
        $out = (& "$B\mux2-verify.exe" @a 2>&1 | ForEach-Object { "$_" }) -join "`n"
        if ($LASTEXITCODE -eq 0) { $n++ } else { Write-Output "FAIL $f $m"; Write-Output $out }
        if ($out -match '"conpty_screen_faithful":true') { $faithful++ }
        Write-Output $out.Trim()
    }
}
Write-Output "verify passed: $n/20 (conhost screen matched the file in $faithful/20)"
$id = & "$B\mux2.exe" new --size 120x40 -- "$B\mux2-query-probe.exe" 1000
& "$B\mux2.exe" wait $id | Out-Null
& "$B\mux2.exe" screen $id | Select-String -Pattern 'query_rtt|BAD'
& "$B\mux2.exe" stop
Remove-Item -Recurse -Force $W
