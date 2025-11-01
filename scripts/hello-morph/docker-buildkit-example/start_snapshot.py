# snapshot_2lj87jj7

from dotenv import load_dotenv
from morphcloud.api import MorphCloudClient

load_dotenv()


client = MorphCloudClient()

snapshot_id = "snapshot_ojixukjb"
# snapshot_id = "snapshot_2lj87jj7"

instance = client.instances.start(
    snapshot_id=snapshot_id,
    ttl_seconds=60 * 30,
    ttl_action="pause",
)
print(f"Created instance: {instance.id}")

instance.expose_http_service("openvscode", 39378)
instance.expose_http_service("worker", 39377)
instance.expose_http_service("proxy", 39379)
instance.expose_http_service("vnc", 39380)
instance.expose_http_service("cdp", 39381)

for service in instance.networking.http_services:
    if service.name == "openvscode":
        print(f"- OpenVSCode: {service.url}/?folder=/root/workspace")
        continue
    if service.name == "vnc":
        print(f"- VNC: {service.url}/vnc.html")
        continue
    if service.name == "cdp":
        print(f"- DevTools: {service.url}/json/version")
        continue
    print(f"- {service.name}: {service.url}")
