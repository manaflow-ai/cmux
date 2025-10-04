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

with open("Dockerfile", "r") as f:
    dockerfile = f.read()

print("Dockerfile:")
print(dockerfile)

print("Creating snapshot")

# Create a snapshot with terminal server
snapshot = client.snapshots.create(
    vcpus=8,
    memory=16384,
    disk_size=32768,
)


# Install Docker and dependencies
snapshot = (
    snapshot.exec(
        "DEBIAN_FRONTEND=noninteractive apt-get update && "
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "docker.io docker-compose python3-docker git curl && "
        "rm -rf /var/lib/apt/lists/*"
    )
    .exec(
        "mkdir -p /etc/docker && "
        'echo \'{"features":{"buildkit":true}}\' > /etc/docker/daemon.json && '
        "echo 'DOCKER_BUILDKIT=1' >> /etc/environment && "
        "systemctl restart docker && "
        "for i in {1..30}; do "
        "  if docker info >/dev/null 2>&1; then "
        "    echo 'Docker ready'; break; "
        "  else "
        "    echo 'Waiting for Docker...'; "
        "    [ $i -eq 30 ] && { echo 'Docker failed to start after 30 attempts'; exit 1; }; "
        "    sleep 2; "
        "  fi; "
        "done && "
        "docker --version && docker-compose --version && "
        "(docker compose version 2>/dev/null || echo 'docker compose plugin not available') && "
        "echo 'Docker commands verified'"
    )
    .exec("echo '::1     localhost' >> /etc/hosts")
    .upload(".", "/")
    .as_container(dockerfile=dockerfile, ports=[39376, 39377, 39378, 39379])
)

print(f"Snapshot ID: {snapshot.id}")
