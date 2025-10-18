# /// script
# dependencies = [
#   "morphcloud",
#   "requests",
# ]
# ///

#!/usr/bin/env python3


import dotenv
from morphcloud.api import MorphCloudClient

dotenv.load_dotenv()

client = MorphCloudClient()

print("Getting instance")
instance = client.instances.get(
    # "morphvm_kakl0q87",
    # "morphvm_mfj8jeox",
    # "morphvm_s0u45lsl",
    "morphvm_4q7p96ec",
)

print("Exposing ports")
ports_to_expose = [
    5173,
    9777,
    9778,
    6791,
    39378,
    39377,
    39379,
    39380,
    39381,
    39383,
]
for port in ports_to_expose:
    print(f"Exposing port {port}")
    instance.expose_http_service(f"port-{port}", port)

print("Networking")
print(instance.networking.http_services)

print("Creating snapshot...")
# make a snapshot
snapshot = instance.snapshot()

print("Snapshot")
print(snapshot.id)
