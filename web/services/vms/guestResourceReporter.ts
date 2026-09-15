import { shellQuote } from "./drivers/cmuxTuiDaemon";
import { vmEdgeAliasDomain, VM_PLACEHOLDER_API_KEY } from "../coderouter/vmGuestEnv";

/** CPU uses a 250 ms counter delta; memory excludes reclaimable cache. Units are MiB. */
export const GUEST_RESOURCE_SAMPLE_SCRIPT = `import json, os, time

def sample():

    def cpu():
        with open('/proc/stat') as stream:
            values = [int(value) for value in stream.readline().split()[1:9]]
        return sum(values), values[3] + values[4]

    stats = {}
    try:
        first_total, first_idle = cpu()
        time.sleep(0.25)
        total, idle = cpu()
        elapsed = total - first_total
        if elapsed > 0:
            stats['cpuPercent'] = max(0, min(100, 100 * (1 - (idle - first_idle) / elapsed)))
    except (OSError, ValueError, IndexError):
        pass
    try:
        with open('/proc/meminfo') as stream:
            memory = {parts[0].rstrip(':'): int(parts[1]) for parts in (line.split() for line in stream)}
        stats['memoryUsedMb'] = max(0, memory['MemTotal'] - memory['MemAvailable']) // 1024
    except (OSError, ValueError, KeyError, IndexError):
        pass
    try:
        disk = os.statvfs('/')
        stats['diskUsedMb'] = (disk.f_blocks - disk.f_bfree) * disk.f_frsize // (1024 * 1024)
    except OSError:
        pass
    return stats
`;

/** The awake guest publishes through its existing edge identity; no secret is stored here. */
export function guestResourceReporterScript(): string {
  return `${GUEST_RESOURCE_SAMPLE_SCRIPT}
import ssl, urllib.request
context = ssl.create_default_context()
ca = '/usr/local/share/ca-certificates/freestyle-tls.crt'
if os.path.isfile(ca):
    context.load_verify_locations(ca)
while True:
    try:
        request = urllib.request.Request(
            ${JSON.stringify(`https://${vmEdgeAliasDomain()}/api/vm/resource-usage/self`)},
            data=json.dumps(sample()).encode(), method='POST',
            headers={'Content-Type': 'application/json', 'Authorization': ${JSON.stringify(`Bearer ${VM_PLACEHOLDER_API_KEY}`)}})
        with urllib.request.urlopen(request, timeout=5, context=context) as response:
            response.read(1024)
    except Exception:
        pass
    time.sleep(30)
`;
}

/** Installed only on explicit create/attach/wake paths, never by a stats read. */
export function guestResourceReporterInstallCommand(): string {
  const script = guestResourceReporterScript();
  const unit = `[Unit]
Description=cmux resource statistics
After=network-online.target
[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/python3 /usr/local/lib/cmux/resource-stats.py
Restart=always
RestartSec=30
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
`;
  return `set -eu
install -d -m 0755 /usr/local/lib/cmux
cmux_stats_tmp=$(mktemp -d)
trap 'rm -rf "$cmux_stats_tmp"' EXIT
printf %s ${shellQuote(script)} > "$cmux_stats_tmp/script"
printf %s ${shellQuote(unit)} > "$cmux_stats_tmp/unit"
if ! cmp -s "$cmux_stats_tmp/script" /usr/local/lib/cmux/resource-stats.py || ! cmp -s "$cmux_stats_tmp/unit" /etc/systemd/system/cmux-resource-stats.service; then
    install -m 0644 "$cmux_stats_tmp/script" /usr/local/lib/cmux/resource-stats.py
    install -m 0644 "$cmux_stats_tmp/unit" /etc/systemd/system/cmux-resource-stats.service
    systemctl daemon-reload
    systemctl restart cmux-resource-stats.service
fi
systemctl enable --now cmux-resource-stats.service >/dev/null 2>&1`;
}
