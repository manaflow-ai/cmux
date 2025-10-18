# /// script
# dependencies = [
#   "morphcloud",
#   "requests",
# ]
# ///

#!/usr/bin/env python3

import signal
import sys

import dotenv
from morphcloud.api import MorphCloudClient

dotenv.load_dotenv()

client = MorphCloudClient()

instance = None


def cleanup_instance(signum=None, frame=None):
    """Clean up instance on exit"""
    global instance
    if instance:
        print("\nStopping instance...")
        try:
            instance.stop()
            print(f"Instance {instance.id} stopped successfully")
        except Exception as e:
            print(f"Error stopping instance: {e}")
    sys.exit(0)


# Register signal handler for Ctrl+C
signal.signal(signal.SIGINT, cleanup_instance)

try:
    instance = client.instances.start(
        snapshot_id="snapshot_hwmk73mg",
        ttl_seconds=3600,
        ttl_action="pause",
    )
    instance.wait_until_ready()

    print("instance id:", instance.id)

    expose_ports = [39375, 39376, 39377, 39378, 39379, 39380, 39381, 39383]
    for port in expose_ports:
        instance.expose_http_service(port=port, name=f"port-{port}")

    print(instance.networking.http_services)

    # listen for any keypress, then snapshot
    input("Press Enter to snapshot...")
    final_snapshot = instance.snapshot()
    print(f"Snapshot ID: {final_snapshot.id}")
except KeyboardInterrupt:
    cleanup_instance()
except Exception as e:
    print(f"Error: {e}")
    cleanup_instance()
