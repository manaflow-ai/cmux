# windows-conpty.ps1 -Mux2 DIR -Corpus DIR [-ConptyDll PATH]: mux2 under each
# ConPTY configuration: the system's with passthrough, without it, and (when
# given) the out-of-band conpty.dll + OpenConsole.exe of Windows Terminal.
# Per configuration: throughput (plain and SGR, no viewer), query latency,
# keystroke echo, API create, and whether conhost's screen matches the file.
param([string]$Mux2, [string]$Corpus, [string]$ConptyDll = '')
$ErrorActionPreference = 'Continue'
$M = "$Mux2\mux2.exe"
function Out($exe, [string[]]$a) { (& $exe @a 2>&1 | ForEach-Object { "$_" }) -join ' ' }
$configs = @(@{ name = 'system+passthrough'; env = @{} },
             @{ name = 'system'; env = @{ MUX2_CONPTY_PASSTHROUGH = '0' } })
if ($ConptyDll) {
    $configs += @{ name = 'conpty.dll+passthrough'; env = @{ MUX2_CONPTY_DLL = $ConptyDll } }
    $configs += @{ name = 'conpty.dll'; env = @{ MUX2_CONPTY_DLL = $ConptyDll; MUX2_CONPTY_PASSTHROUGH = '0' } }
}
foreach ($c in $configs) {
    $W = Join-Path ([IO.Path]::GetTempPath()) ("mux2-cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $W | Out-Null
    $env:MUX2_SOCKET = "$W\sock"
    foreach ($k in $c.env.Keys) { Set-Item "Env:\$k" $c.env[$k] }
    & $M stats | Out-Null
    $stats = Out $M @('stats')
    foreach ($f in 'plain', 'sgr') {
        $id = (Out $M @('new', '--size', '200x50', '--', "$Mux2\mux2-verify.exe", '--cat', "$Corpus\$f.txt")).Trim()
        Start-Sleep 1
        $sw = [Diagnostics.Stopwatch]::StartNew(); & $M write $id "`r" | Out-Null; & $M wait $id | Out-Null
        $mbs = [math]::Round((Get-Item "$Corpus\$f.txt").Length / $sw.Elapsed.TotalSeconds / 1e6, 1)
        & $M kill $id | Out-Null
        [pscustomobject]@{ config = $c.name; test = "tput-$f"; mb_per_s = $mbs } | ConvertTo-Json -Compress
    }
    $id = (Out $M @('new', '--size', '120x40', '--', "$Mux2\mux2-query-probe.exe", '1000')).Trim()
    & $M wait $id | Out-Null
    $q = (Out $M @('screen', $id)) -replace '\s+', ' '
    [pscustomobject]@{ config = $c.name; test = 'query'; screen = $q.Trim() } | ConvertTo-Json -Compress
    [pscustomobject]@{ config = $c.name; test = 'api'; create = (Out $M @('bench', 'create', '100')); echo = (Out $M @('bench', 'echo', '300')) } | ConvertTo-Json -Compress
    & $M stop | Out-Null
    # Fidelity: the gate with a tap, unicode and SGR, nobody watching.
    $env:MUX2_TAP_DIR = "$W\tap"
    & $M stats | Out-Null
    foreach ($f in 'unicode', 'sgr', 'cursor') {
        $v = Out "$Mux2\mux2-verify.exe" @("$Corpus\$f.txt", '--no-viewer')
        [pscustomobject]@{ config = $c.name; test = "verify-$f"; result = $v } | ConvertTo-Json -Compress
    }
    & $M stop | Out-Null
    [pscustomobject]@{ config = $c.name; stats = $stats } | ConvertTo-Json -Compress
    Remove-Item Env:\MUX2_TAP_DIR
    foreach ($k in $c.env.Keys) { Remove-Item "Env:\$k" }
    Remove-Item -Recurse -Force $W
}
Remove-Item Env:\MUX2_SOCKET
