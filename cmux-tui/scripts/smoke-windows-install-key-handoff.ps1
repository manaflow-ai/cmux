# Behavior check (Windows, cx-jdb.8): the app's install key reaches only the
# daemon that `server ensure --install-key-stdin` starts (on the owner's
# stdin pipe, never in argv or the environment), and a connection that
# proves the key in `client-hello` gets origin user: `user_origin_allowed`
# is true and `history.visit.record` succeeds. A wrong key, no hello, a
# key handed to an already running owner and an owner started without a
# key all stay refused. Runs against a real cmux-tui.exe over its socket.
#
#   pwsh -NoProfile -File cmux-tui/scripts/smoke-windows-install-key-handoff.ps1 -Binary <cmux-tui.exe>
#
# Exit 0 when every check holds; any failed check throws (exit 1).

param(
    [Parameter(Mandatory = $true)][string]$Binary
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$KeyHex = '8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100'
$OtherKeyHex = '1111111111111111111111111111111111111111111111111111111111111111'
$Binary = (Resolve-Path $Binary).Path
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ("cmux-ik-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Root | Out-Null
$env:CMUX_TUI_STATE_DIR = Join-Path $Root 'state'
$env:CMUX_TUI_CONFIG = Join-Path $Root 'config.json'
Set-Content -Path $env:CMUX_TUI_CONFIG -Value '{}'
foreach ($name in 'CMUX_TUI_SOCKET', 'CMUX_SOCKET_PATH', 'CMUX_TUI_TERMINAL_ID') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

function Check([bool]$condition, [string]$what) {
    if (-not $condition) { throw "FAILED: $what" }
    Write-Host "ok: $what"
}

# $stdin and $payload stay [object]: a [string] parameter turns $null into "".
function Invoke-Cli([string[]]$arguments, [AllowNull()][object]$stdin) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Binary)
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -ne $stdin) { $process.StandardInput.Write($stdin) }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw "cmux-tui $arguments timed out" }
    # A detached owner that inherited this command's stdout/stderr pipes
    # would keep them open: a caller reading to end of file never finishes.
    if (-not [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 20000)) {
        throw "FAILED: cmux-tui $arguments exited but its output pipes stayed open (an owner inherited them)"
    }
    [pscustomobject]@{ Code = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
}

function Ensure-Owner([string]$session, [string]$socket, [AllowNull()][object]$payload) {
    $arguments = @('server', 'ensure', '--json', '--session', $session, '--socket', $socket)
    if ($null -ne $payload) { $arguments += '--install-key-stdin' }
    $result = Invoke-Cli $arguments $payload
    if ($result.Code -ne 0) { throw "ensure failed ($($result.Code)): $($result.Stdout) $($result.Stderr)" }
    $result.Stdout | ConvertFrom-Json
}

function Stop-Owner([string]$session, [string]$socket) {
    Invoke-Cli @('server', 'stop', '--json', '--session', $session, '--socket', $socket) $null | Out-Null
}

function Hex-Bytes([string]$hex) {
    [byte[]]$bytes = for ($i = 0; $i -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) }
    , $bytes
}

class Client {
    [System.Net.Sockets.Socket]$Socket
    [System.IO.StreamReader]$Reader
    [System.IO.StreamWriter]$Writer

    Client([string]$path) {
        $this.Socket = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::Unix,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Unspecified)
        $this.Socket.Connect([System.Net.Sockets.UnixDomainSocketEndPoint]::new($path))
        $this.Socket.ReceiveTimeout = 15000
        $stream = [System.Net.Sockets.NetworkStream]::new($this.Socket, $true)
        $this.Reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
        $this.Writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        $this.Writer.NewLine = "`n"
        $this.Writer.AutoFlush = $true
    }

    [object] Rpc([hashtable]$request) {
        $this.Writer.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
        $line = $this.Reader.ReadLine()
        if ($null -eq $line) { throw "connection closed after $($request | ConvertTo-Json -Compress)" }
        return $line | ConvertFrom-Json
    }

    # The two-step hello; the last reply.
    [object] Hello([string]$installId, [string]$keyHex) {
        $challenge = $this.Rpc(@{ id = 1; cmd = 'client-hello'; role = 'main'; install_id = $installId })
        $nonce = $challenge.data.PSObject.Properties['nonce']
        if ($null -eq $nonce) { return $challenge }
        $message = [System.Collections.Generic.List[byte]]::new()
        $message.AddRange([System.Text.Encoding]::ASCII.GetBytes('cmux-frontend-hello-v1'))
        $message.Add(0)
        $message.AddRange([System.Text.Encoding]::ASCII.GetBytes($installId))
        $message.Add(0)
        $message.AddRange([byte[]](Hex-Bytes $nonce.Value))
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]](Hex-Bytes $keyHex))
        $proof = [Convert]::ToHexString($hmac.ComputeHash($message.ToArray())).ToLowerInvariant()
        return $this.Rpc(@{ id = 2; cmd = 'client-hello'; install_id = $installId; proof = $proof })
    }

    [object] RecordVisit([string]$url) {
        return $this.Rpc(@{
                protocol = 'cmux.protocol/2'; type = 'request'; id = 'visit'
                operation = 'history.visit.record'; idempotency_key = "k-$([guid]::NewGuid())"
                params = @{ machine = 'current'; session = 'current'; profile = 'default'; url = $url
                    at_ms = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
            })
    }

    [void] Close() { $this.Socket.Dispose() }
}

function Field($object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    $property.Value
}

$keyed = @{ Session = 'ik-handoff'; Socket = (Join-Path $Root 'keyed.sock') }
$keyless = @{ Session = 'ik-nokey'; Socket = (Join-Path $Root 'nokey.sock') }
try {
    $started = Ensure-Owner $keyed.Session $keyed.Socket "cmuxik1 inst_app $KeyHex`n"
    Check ($started.status -eq 'started') "ensure --install-key-stdin starts an owner ($($started | ConvertTo-Json -Compress))"
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($started.pid)").CommandLine
    Check ($commandLine -like '*--owner-install-key-stdin*') "the owner was told to read its key from stdin"
    Check (-not $commandLine.Contains($KeyHex) -and -not $commandLine.Contains('inst_app')) "the key and install id are not in the owner's argv"

    $app = [Client]::new($keyed.Socket)
    $proved = $app.Hello('inst_app', $KeyHex)
    Check ((Field $proved.data 'verified') -eq $true) "the app key proves client-hello ($($proved | ConvertTo-Json -Compress))"
    Check ((Field $proved.data 'user_origin_allowed') -eq $true) "the proved app connection may use origin user"
    $visit = $app.RecordVisit('https://example.com/windows-install-key')
    Check ($visit.ok -eq $true) "history.visit.record succeeds for the proved app ($($visit | ConvertTo-Json -Compress -Depth 6))"
    $app.Close()

    $wrong = [Client]::new($keyed.Socket)
    $refused = $wrong.Hello('inst_app', $OtherKeyHex)
    Check ((Field $refused 'error_code') -eq 'client_hello.refused') "a wrong key is refused ($($refused | ConvertTo-Json -Compress))"
    $forged = $wrong.RecordVisit('https://forged.test/wrong-key')
    Check ($forged.ok -eq $false -and $forged.error.code -eq 'origin.forbidden') "a refused connection cannot record a visit"
    $wrong.Close()

    $plain = [Client]::new($keyed.Socket)
    $forged = $plain.RecordVisit('https://forged.test/no-hello')
    Check ($forged.ok -eq $false -and $forged.error.code -eq 'origin.forbidden') "a connection with no hello cannot record a visit"
    $plain.Close()

    $unproved = [Client]::new($keyed.Socket)
    $challenge = $unproved.Rpc(@{ id = 1; cmd = 'client-hello'; role = 'main' })
    Check ((Field $challenge.data 'user_origin_allowed') -eq $false) "a role-main hello with no proof gets no origin user"
    $unproved.Close()

    $again = Ensure-Owner $keyed.Session $keyed.Socket "cmuxik1 inst_other $OtherKeyHex`n"
    Check ($again.status -eq 'running') "a second ensure finds the owner running"
    $other = [Client]::new($keyed.Socket)
    Check ((Field ($other.Hello('inst_other', $OtherKeyHex)) 'error_code') -eq 'client_hello.refused') "a running owner never takes another key"
    $other.Close()

    $none = Ensure-Owner $keyless.Session $keyless.Socket $null
    Check ($none.status -eq 'started') "ensure without a key starts an owner"
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($none.pid)").CommandLine
    Check ($commandLine -notlike '*--owner-install-key-stdin*') "an owner started without a key reads no key"
    $client = [Client]::new($keyless.Socket)
    Check ((Field ($client.Hello('inst_app', $KeyHex)) 'error_code') -eq 'client_hello.refused') "an owner started without a key refuses every proof"
    $client.Close()

    Write-Host 'PASS: Windows install key handoff and origin user'
}
finally {
    Stop-Owner $keyed.Session $keyed.Socket
    Stop-Owner $keyless.Session $keyless.Socket
    Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
}
