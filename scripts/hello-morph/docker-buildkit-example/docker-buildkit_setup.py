# /// script
# dependencies = [
#   "morphcloud",
#   "requests",
# ]
# ///

#!/usr/bin/env python3
"""
Setup script for creating a Morph Cloud VM with Docker and BuildKit support.
Demonstrates multi-stage builds and parallel execution in BuildKit.
"""

import os
import sys
import time

import requests
from morphcloud.api import MorphCloudClient


def run_ssh_command(instance, command, sudo=False, print_output=True):
    """Run a command on the instance via SSH and return the result"""
    if sudo and not command.startswith("sudo "):
        command = f"sudo {command}"

    print(f"Running: {command}")
    result = instance.exec(command)

    if print_output:
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(f"ERR: {result.stderr}", file=sys.stderr)

    if result.exit_code != 0:
        print(f"Command failed with exit code {result.exit_code}")

    return result


def setup_docker_environment(instance):
    """Set up Docker with BuildKit"""
    print("\n--- Setting up Docker environment ---")

    # Install Docker and essentials
    run_ssh_command(
        instance,
        "DEBIAN_FRONTEND=noninteractive apt-get update && "
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "docker.io python3-docker git curl",
        sudo=True,
    )

    # Enable BuildKit for faster builds
    run_ssh_command(
        instance,
        "mkdir -p /etc/docker && "
        'echo \'{"features":{"buildkit":true}}\' > /etc/docker/daemon.json && '
        "echo 'DOCKER_BUILDKIT=1' >> /etc/environment",
        sudo=True,
    )

    # Restart Docker and make sure it's running
    run_ssh_command(instance, "systemctl restart docker", sudo=True)

    # Wait for Docker to be fully started
    print("Waiting for Docker to be ready...")
    for i in range(5):
        result = run_ssh_command(
            instance,
            "docker info >/dev/null 2>&1 || echo 'not ready'",
            sudo=True,
            print_output=False,
        )
        if result.exit_code == 0 and "not ready" not in result.stdout:
            print("Docker is ready")
            break
        print(f"Waiting for Docker... ({i+1}/5)")
        time.sleep(3)


def create_health_check_app(instance):
    """Create a simple Python health check web server"""
    print("\n--- Creating health check application ---")

    # Create health_check.py
    health_check_py = """#!/usr/bin/env python3
import http.server
import socketserver
import json
import os
from datetime import datetime
import socket

PORT = 8080

class HealthCheckHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            health_data = {
                'status': 'healthy',
                'timestamp': datetime.now().isoformat(),
                'container': socket.gethostname(),
                'environment': {k: v for k, v in os.environ.items() if not k.startswith('_')},
                'services': {
                    'health_check': 'running on port 8080',
                    'web_server': 'running on port 8081'
                }
            }
            
            self.wfile.write(json.dumps(health_data, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')
    
    def log_message(self, format, *args):
        print(f"[{datetime.now().isoformat()}] {format % args}")

print(f"Starting health check server on port {PORT}")
with socketserver.TCPServer(("", PORT), HealthCheckHandler) as httpd:
    print("Health check server running. Access /health endpoint for health status.")
    httpd.serve_forever()
"""

    run_ssh_command(instance, f"cat > health_check.py << 'EOF'\n{health_check_py}\nEOF")
    print("Created health_check.py server")


def create_index_html(instance):
    """Create index.html with morph labs message and orange cat SVG"""
    print("\n--- Creating index.html ---")

    index_html = """<!DOCTYPE html>
<html>
<head>
    <title>Morph Labs Demo</title>
    <style>
        body {
            font-family: sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            margin: 0;
            background-color: #f5f5f5;
        }
        h1 {
            color: #333;
            text-align: center;
            max-width: 800px;
            line-height: 1.4;
        }
        .cat-container {
            margin: 2rem;
            max-width: 300px;
        }
    </style>
</head>
<body>
    <h1>anything you want can be built with morph labs</h1>
    <div class="cat-container">
        <!-- Orange Cat SVG -->
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
            <path fill="#FF9800" d="M448,96c0-35.3-28.7-64-64-64c-6.6,0-13,1-19,2.9C341.9,13.7,307.6,0,270.1,0
            c-37.5,0-71.8,13.7-94.9,34.9c-6-1.9-12.4-2.9-19-2.9c-35.3,0-64,28.7-64,64c0,23.7,12.9,44.3,32,55.4v28.6
            c-19.1,11.1-32,31.7-32,55.4c0,35.3,28.7,64,64,64c2.4,0,4.8-0.1,7.1-0.4c17.3,24.9,45.9,41.4,78.5,42.3
            c0.1,0,0.3,0,0.4,0h64c0.1,0,0.3,0,0.4,0c32.6-0.9,61.2-17.4,78.5-42.3c2.3,0.3,4.7,0.4,7.1,0.4c35.3,0,64-28.7,64-64
            c0-23.7-12.9-44.3-32-55.4v-28.6C435.1,140.3,448,119.7,448,96z"/>
            <path fill="#FFA726" d="M383.5,192c-2.5,0-4.9,0.2-7.3,0.6C354.8,166.5,324.1,151,290,151h-68
            c-34.1,0-64.8,15.5-86.2,41.6c-2.4-0.4-4.8-0.6-7.3-0.6c-26.5,0-48,21.5-48,48s21.5,48,48,48c1.6,0,3.2-0.1,4.7-0.3
            C151.4,312.9,183.9,335,222,335h68c38.1,0,70.6-22.1,88.8-47.3c1.5,0.2,3.1,0.3,4.7,0.3c26.5,0,48-21.5,48-48
            S410,192,383.5,192z"/>
            <circle fill="#784719" cx="176" cy="208" r="24"/>
            <circle fill="#784719" cx="336" cy="208" r="24"/>
            <circle fill="#FFFFFF" cx="176" cy="200" r="8"/>
            <circle fill="#FFFFFF" cx="336" cy="200" r="8"/>
            <path fill="#4D342E" d="M336,276.1h-4c-6.6,0-12-5.4-12-12v-8c0-6.6,5.4-12,12-12h4c6.6,0,12,5.4,12,12v8
            C348,270.7,342.6,276.1,336,276.1z"/>
            <path fill="#4D342E" d="M176,276.1h-4c-6.6,0-12-5.4-12-12v-8c0-6.6,5.4-12,12-12h4c6.6,0,12,5.4,12,12v8
            C188,270.7,182.6,276.1,176,276.1z"/>
            <path fill="#E65100" d="M284,252.1h-56c-4.4,0-8-3.6-8-8s3.6-8,8-8h56c4.4,0,8,3.6,8,8S288.4,252.1,284,252.1z"/>
        </svg>
    </div>
</body>
</html>
"""

    # Create directory for web content
    run_ssh_command(instance, "mkdir -p www")

    # Create index.html
    run_ssh_command(instance, f"cat > www/index.html << 'EOF'\n{index_html}\nEOF")
    print("Created index.html with orange cat SVG")


def create_entrypoint_script(instance):
    """Create entrypoint script to run both servers"""
    print("\n--- Creating entrypoint script ---")

    entrypoint_sh = """#!/bin/bash
# Start the health check server in the background
python3 /app/health_check.py &
HEALTH_PID=$!

# Start a simple HTTP server for the index.html in the background
cd /app/www && python3 -m http.server 8081 &
HTTP_PID=$!

echo "Health check server started on port 8080 (PID: $HEALTH_PID)"
echo "HTTP server started on port 8081 (PID: $HTTP_PID)"

# Handle termination
trap 'kill $HEALTH_PID $HTTP_PID; exit' SIGTERM SIGINT

# Keep the container running
wait
"""

    run_ssh_command(instance, f"cat > entrypoint.sh << 'EOF'\n{entrypoint_sh}\nEOF")
    run_ssh_command(instance, "chmod +x entrypoint.sh")
    print("Created entrypoint.sh script")


def create_requirements_file(instance):
    """Create requirements.txt file"""
    print("\n--- Creating requirements.txt ---")

    requirements = """requests==2.28.1
"""

    run_ssh_command(instance, f"cat > requirements.txt << 'EOF'\n{requirements}\nEOF")
    print("Created requirements.txt")


def create_dockerfile(instance):
    """Create a multi-stage Dockerfile with BuildKit features"""
    print("\n--- Creating BuildKit-optimized Dockerfile ---")

    dockerfile = """# syntax=docker/dockerfile:1.4
FROM ubuntu:22.04 AS base

# Base dependencies
RUN apt-get update && apt-get install -y \\
    curl \\
    && rm -rf /var/lib/apt/lists/*

# Python stage
FROM base AS python-builder
RUN apt-get update && apt-get install -y \\
    python3 \\
    python3-pip \\
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
WORKDIR /build
COPY requirements.txt .
RUN pip3 install --upgrade pip && \\
    pip3 install -r requirements.txt

# Web content stage
FROM base AS web-content
WORKDIR /build/www
COPY www/ .

# Final image
FROM python-builder AS final
WORKDIR /app

# Copy Python application
COPY health_check.py .
RUN chmod +x health_check.py

# Copy web content
COPY --from=web-content /build/www ./www

# Copy entrypoint script
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Expose ports
EXPOSE 8080 8081

# Health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \\
    CMD curl -f http://localhost:8080/health || exit 1

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
"""

    run_ssh_command(instance, f"cat > Dockerfile << 'EOF'\n{dockerfile}\nEOF")
    print("Created BuildKit-optimized Dockerfile")


def build_and_run_container(instance):
    """Build and run the Docker container with BuildKit"""
    print("\n--- Building Docker image with BuildKit ---")
    build_result = run_ssh_command(
        instance,
        "DOCKER_BUILDKIT=1 docker build --progress=plain -t morph-demo:latest .",
        sudo=True,
    )

    if build_result.exit_code != 0:
        print("Failed to build Docker image")
        return None

    print("\n--- Starting container ---")
    # Expose both HTTP services
    instance.expose_http_service("health-check", 8080)
    instance.expose_http_service("web-server", 8081)
    print("Exposed HTTP services on ports 8080 and 8081")

    # Run container with environment variables
    result = run_ssh_command(
        instance,
        "docker run -d -p 8080:8080 -p 8081:8081 "
        "-e APP_ENV=production "
        "-e APP_VERSION=1.0.0 "
        "--name morph-demo morph-demo:latest",
        sudo=True,
    )

    if result.exit_code != 0:
        print("Failed to start container")
        return None

    container_id = result.stdout.strip()

    # Verify container is running
    time.sleep(2)
    check_result = run_ssh_command(
        instance,
        f"docker ps -q --filter id={container_id}",
        sudo=True,
        print_output=False,
    )

    if not check_result.stdout.strip():
        print("\nWarning: Container started but exited immediately.")
        print("Container logs:")
        run_ssh_command(instance, f"docker logs {container_id}", sudo=True)
        return None

    print(f"\nContainer {container_id} is running")

    # Show running containers
    print("\nRunning containers:")
    run_ssh_command(instance, "docker ps", sudo=True)

    return container_id


def wait_for_health_check(client, instance, max_retries=20, delay=3):
    """Wait for both health check and web server to be available (at least 1 minute)"""
    instance = client.instances.get(instance.id)  # Refresh instance info

    health_url = None
    web_url = None

    for service in instance.networking.http_services:
        if service.name == "health-check":
            health_url = f"{service.url}/health"
        elif service.name == "web-server":
            web_url = service.url

    if not health_url or not web_url:
        print("❌ Could not find expected HTTP service URLs")
        return False

    print(f"Checking health endpoint: {health_url}")
    health_ok = False

    for i in range(max_retries):
        try:
            response = requests.get(health_url, timeout=5)
            if response.status_code == 200:
                print(f"✅ Health endpoint available (status {response.status_code})")
                print(f"Response: {response.json()}")
                health_ok = True
                break
            print(f"Attempt {i+1}/{max_retries}: HTTP status {response.status_code}")
        except requests.RequestException as e:
            print(f"Attempt {i+1}/{max_retries}: {str(e)}")

        time.sleep(delay)

    print(f"\nChecking web server: {web_url}")
    web_ok = False

    for i in range(max_retries):
        try:
            response = requests.get(web_url, timeout=5)
            if response.status_code == 200:
                print(f"✅ Web server available (status {response.status_code})")
                web_ok = True
                break
            print(f"Attempt {i+1}/{max_retries}: HTTP status {response.status_code}")
        except requests.RequestException as e:
            print(f"Attempt {i+1}/{max_retries}: {str(e)}")

        time.sleep(delay)

    return health_ok and web_ok


def main():
    client = MorphCloudClient()

    # VM configuration
    VCPUS = 2
    MEMORY = 2048
    DISK_SIZE = 4096

    print("Creating snapshot...")
    snapshot = client.snapshots.create(
        vcpus=VCPUS,
        memory=MEMORY,
        disk_size=DISK_SIZE,
    )

    print(f"Starting instance from snapshot {snapshot.id}...")
    instance = client.instances.start(
        snapshot_id=snapshot.id,
        ttl_seconds=60 * 30,
        ttl_action="pause",
    )

    try:
        # Setup Docker environment with BuildKit
        setup_docker_environment(instance)

        # Create application files
        create_health_check_app(instance)
        create_index_html(instance)
        create_entrypoint_script(instance)
        create_requirements_file(instance)
        create_dockerfile(instance)

        # Build and run container with BuildKit
        container_id = build_and_run_container(instance)
        if not container_id:
            return

        # Display information
        print("\nSetup complete!")
        print(f"Instance ID: {instance.id}")
        print(f"Container ID: {container_id}")

        # Check health endpoint and web server (wait at least 1 minute)
        print("\nChecking services (waiting at least 1 minute)...")
        if wait_for_health_check(client, instance):
            print("\n✅ All services are up and running!")
        else:
            print("\n⚠️ Some services might not be fully operational")

        print("\nURLs to access:")
        instance = client.instances.get(instance.id)  # Refresh instance info
        for service in instance.networking.http_services:
            print(f"- {service.name}: {service.url}")

        print("\nUseful commands:")
        print(f"SSH access: morphcloud instance ssh {instance.id}")
        print(
            f"View logs: morphcloud instance ssh {instance.id} -- sudo docker logs {container_id}"
        )
        print(
            f"Stop container: morphcloud instance ssh {instance.id} -- sudo docker stop {container_id}"
        )

        # Create final snapshot
        print("\nCreating final snapshot of configured environment...")
        snapshot = instance.snapshot()
        print(f"Final snapshot created: {snapshot.id}")
        print(
            f"You can start new instances from this snapshot with: morphcloud instance start {snapshot.id}"
        )

    except Exception as e:
        print(f"\nError: {e}")
        print(f"\nFor troubleshooting: morphcloud instance ssh {instance.id}")
        raise


if __name__ == "__main__":
    main()
