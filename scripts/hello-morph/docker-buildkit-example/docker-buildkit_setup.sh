#!/bin/bash
# Setup script for creating a Morph Cloud VM with Docker and BuildKit support.
# Demonstrates multi-stage builds and parallel execution in BuildKit.

set -e  # Exit on error

# Configuration
VCPUS=2
MEMORY=2048  # 2GB
DISK_SIZE=4096  # 4GB
SNAPSHOT_TYPE="base"

# Function to find or create a snapshot with matching configuration
find_or_create_snapshot() {
  echo "Looking for existing snapshot with matching configuration..."
  
  # Try to find an existing snapshot with matching metadata
  EXISTING_SNAPSHOT=$(morphcloud snapshot list -m "type=$SNAPSHOT_TYPE" -m "vcpus=$VCPUS" -m "memory=$MEMORY" -m "disk_size=$DISK_SIZE" --json | grep '"id":' | head -1 | cut -d '"' -f 4)
  
  if [ ! -z "$EXISTING_SNAPSHOT" ]; then
    echo "Found existing snapshot $EXISTING_SNAPSHOT with matching configuration"
    SNAPSHOT_ID="$EXISTING_SNAPSHOT"
  else
    echo "No matching snapshot found. Creating new snapshot..."
    SNAPSHOT_ID=$(morphcloud snapshot create --vcpus "$VCPUS" --memory "$MEMORY" --disk-size "$DISK_SIZE")
    
    # Add metadata to the snapshot
    morphcloud snapshot set-metadata "$SNAPSHOT_ID" "type=$SNAPSHOT_TYPE" "vcpus=$VCPUS" "memory=$MEMORY" "disk_size=$DISK_SIZE" > /dev/null
  fi
  
  echo "$SNAPSHOT_ID"
}

# Function to run commands via SSH
run_ssh_command() {
  INSTANCE_ID=$1
  COMMAND=$2
  SUDO=$3
  PRINT_OUTPUT=$4
  
  if [ "$SUDO" = "true" ] && [[ ! "$COMMAND" =~ ^sudo ]]; then
    COMMAND="sudo $COMMAND"
  fi
  
  echo "Running: $COMMAND"
  if [ "$PRINT_OUTPUT" = "false" ]; then
    RESULT=$(morphcloud instance exec "$INSTANCE_ID" "$COMMAND" 2>&1)
    EXIT_CODE=$?
  else
    morphcloud instance exec "$INSTANCE_ID" "$COMMAND"
    EXIT_CODE=$?
  fi
  
  if [ $EXIT_CODE -ne 0 ]; then
    echo "Command failed with exit code $EXIT_CODE"
  fi
  
  if [ "$PRINT_OUTPUT" = "false" ]; then
    echo "$RESULT"
  fi
}

# Setup Docker environment with BuildKit
setup_docker_environment() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Setting up Docker environment ---"
  
  # Install Docker and essentials
  run_ssh_command "$INSTANCE_ID" "DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io python3-docker git curl" "true" "true"
  
  # Enable BuildKit for faster builds
  run_ssh_command "$INSTANCE_ID" "mkdir -p /etc/docker && echo '{\"features\":{\"buildkit\":true}}' > /etc/docker/daemon.json && echo 'DOCKER_BUILDKIT=1' >> /etc/environment" "true" "true"
  
  # Restart Docker and make sure it's running
  run_ssh_command "$INSTANCE_ID" "systemctl restart docker" "true" "true"
  
  # Wait for Docker to be fully started
  echo "Waiting for Docker to be ready..."
  for i in {1..5}; do
    RESULT=$(morphcloud instance exec "$INSTANCE_ID" "sudo docker info >/dev/null 2>&1 || echo 'not ready'")
    if [[ ! "$RESULT" =~ "not ready" ]]; then
      echo "Docker is ready"
      break
    fi
    echo "Waiting for Docker... ($i/5)"
    sleep 3
  done
}

# Create health check application
create_health_check_app() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Creating health check application ---"
  
  # Create health_check.py directly on the VM
  run_ssh_command "$INSTANCE_ID" "cat > health_check.py << 'EOF'
#!/usr/bin/env python3
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
        print(f\"[{datetime.now().isoformat()}] {format % args}\")

print(f\"Starting health check server on port {PORT}\")
with socketserver.TCPServer((\"\", PORT), HealthCheckHandler) as httpd:
    print(\"Health check server running. Access /health endpoint for health status.\")
    httpd.serve_forever()
EOF" "false" "true"
  
  echo "Created health_check.py server"
}

# Create index.html
create_index_html() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Creating index.html ---"
  
  # Create directory for web content
  run_ssh_command "$INSTANCE_ID" "mkdir -p www" "false" "true"
  
  # Create index.html directly on the VM
  run_ssh_command "$INSTANCE_ID" "cat > www/index.html << 'EOF'
<!DOCTYPE html>
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
    <div class=\"cat-container\">
        <!-- Orange Cat SVG -->
        <svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\">
            <path fill=\"#FF9800\" d=\"M448,96c0-35.3-28.7-64-64-64c-6.6,0-13,1-19,2.9C341.9,13.7,307.6,0,270.1,0
            c-37.5,0-71.8,13.7-94.9,34.9c-6-1.9-12.4-2.9-19-2.9c-35.3,0-64,28.7-64,64c0,23.7,12.9,44.3,32,55.4v28.6
            c-19.1,11.1-32,31.7-32,55.4c0,35.3,28.7,64,64,64c2.4,0,4.8-0.1,7.1-0.4c17.3,24.9,45.9,41.4,78.5,42.3
            c0.1,0,0.3,0,0.4,0h64c0.1,0,0.3,0,0.4,0c32.6-0.9,61.2-17.4,78.5-42.3c2.3,0.3,4.7,0.4,7.1,0.4c35.3,0,64-28.7,64-64
            c0-23.7-12.9-44.3-32-55.4v-28.6C435.1,140.3,448,119.7,448,96z\"/>
            <path fill=\"#FFA726\" d=\"M383.5,192c-2.5,0-4.9,0.2-7.3,0.6C354.8,166.5,324.1,151,290,151h-68
            c-34.1,0-64.8,15.5-86.2,41.6c-2.4-0.4-4.8-0.6-7.3-0.6c-26.5,0-48,21.5-48,48s21.5,48,48,48c1.6,0,3.2-0.1,4.7-0.3
            C151.4,312.9,183.9,335,222,335h68c38.1,0,70.6-22.1,88.8-47.3c1.5,0.2,3.1,0.3,4.7,0.3c26.5,0,48-21.5,48-48
            S410,192,383.5,192z\"/>
            <circle fill=\"#784719\" cx=\"176\" cy=\"208\" r=\"24\"/>
            <circle fill=\"#784719\" cx=\"336\" cy=\"208\" r=\"24\"/>
            <circle fill=\"#FFFFFF\" cx=\"176\" cy=\"200\" r=\"8\"/>
            <circle fill=\"#FFFFFF\" cx=\"336\" cy=\"200\" r=\"8\"/>
            <path fill=\"#4D342E\" d=\"M336,276.1h-4c-6.6,0-12-5.4-12-12v-8c0-6.6,5.4-12,12-12h4c6.6,0,12,5.4,12,12v8
            C348,270.7,342.6,276.1,336,276.1z\"/>
            <path fill=\"#4D342E\" d=\"M176,276.1h-4c-6.6,0-12-5.4-12-12v-8c0-6.6,5.4-12,12-12h4c6.6,0,12,5.4,12,12v8
            C188,270.7,182.6,276.1,176,276.1z\"/>
            <path fill=\"#E65100\" d=\"M284,252.1h-56c-4.4,0-8-3.6-8-8s3.6-8,8-8h56c4.4,0,8,3.6,8,8S288.4,252.1,284,252.1z\"/>
        </svg>
    </div>
</body>
</html>
EOF" "false" "true"

  echo "Created index.html with orange cat SVG"
}

# Create entrypoint script
create_entrypoint_script() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Creating entrypoint script ---"
  
  # Create entrypoint.sh directly on the VM
  run_ssh_command "$INSTANCE_ID" "cat > entrypoint.sh << 'EOF'
#!/bin/bash
# Start the health check server in the background
python3 /app/health_check.py &
HEALTH_PID=\$!

# Start a simple HTTP server for the index.html in the background
cd /app/www && python3 -m http.server 8081 &
HTTP_PID=\$!

echo \"Health check server started on port 8080 (PID: \$HEALTH_PID)\"
echo \"HTTP server started on port 8081 (PID: \$HTTP_PID)\"

# Handle termination
trap 'kill \$HEALTH_PID \$HTTP_PID; exit' SIGTERM SIGINT

# Keep the container running
wait
EOF" "false" "true"

  # Set executable permission
  run_ssh_command "$INSTANCE_ID" "chmod +x entrypoint.sh" "false" "true"
  echo "Created entrypoint.sh script"
}

# Create requirements.txt
create_requirements_file() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Creating requirements.txt ---"
  
  # Create requirements.txt directly on the VM
  run_ssh_command "$INSTANCE_ID" "cat > requirements.txt << 'EOF'
requests==2.28.1
EOF" "false" "true"

  echo "Created requirements.txt"
}

# Create Dockerfile
create_dockerfile() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Creating BuildKit-optimized Dockerfile ---"
  
  # Create Dockerfile directly on the VM
  run_ssh_command "$INSTANCE_ID" "cat > Dockerfile << 'EOF'
# syntax=docker/dockerfile:1.4
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
ENTRYPOINT [\"/app/entrypoint.sh\"]
EOF" "false" "true"

  echo "Created BuildKit-optimized Dockerfile"
}

# Build and run container
build_and_run_container() {
  INSTANCE_ID=$1
  
  echo -e "\n--- Building Docker image with BuildKit ---"
  run_ssh_command "$INSTANCE_ID" "DOCKER_BUILDKIT=1 docker build --progress=plain -t morph-demo:latest ." "true" "true"
  
  # Check if build was successful
  BUILD_STATUS=$(morphcloud instance exec "$INSTANCE_ID" "sudo docker images -q morph-demo:latest")
  if [ -z "$BUILD_STATUS" ]; then
    echo "Failed to build Docker image"
    return 1
  fi
  
  echo -e "\n--- Starting container ---"
  # Expose both HTTP services
  morphcloud instance expose-http "$INSTANCE_ID" "health-check" 8080
  morphcloud instance expose-http "$INSTANCE_ID" "web-server" 8081
  echo "Exposed HTTP services on ports 8080 and 8081"
  
  # Run container with environment variables
  CONTAINER_ID=$(morphcloud instance exec "$INSTANCE_ID" "sudo docker run -d -p 8080:8080 -p 8081:8081 -e APP_ENV=production -e APP_VERSION=1.0.0 --name morph-demo morph-demo:latest")
  
  if [ -z "$CONTAINER_ID" ]; then
    echo "Failed to start container"
    return 1
  fi
  
  # Verify container is running
  sleep 2
  CHECK_RESULT=$(morphcloud instance exec "$INSTANCE_ID" "sudo docker ps -q --filter id=${CONTAINER_ID}")
  
  if [ -z "$CHECK_RESULT" ]; then
    echo -e "\nWarning: Container started but exited immediately."
    echo "Container logs:"
    run_ssh_command "$INSTANCE_ID" "docker logs ${CONTAINER_ID}" "true" "true"
    return 1
  fi
  
  echo -e "\nContainer ${CONTAINER_ID} is running"
  
  # Show running containers
  echo -e "\nRunning containers:"
  run_ssh_command "$INSTANCE_ID" "docker ps" "true" "true"
  
  echo "$CONTAINER_ID"
}

# Wait for health check and web server
wait_for_health_check() {
  INSTANCE_ID=$1
  MAX_RETRIES=20
  DELAY=3
  
  # Get HTTP service URLs
  echo "Retrieving HTTP service URLs..."
  SERVICES_JSON=$(morphcloud instance get "$INSTANCE_ID" --json)
  
  HEALTH_URL=$(echo "$SERVICES_JSON" | grep -o '"url":"[^"]*"' | grep health-check | cut -d'"' -f4)
  WEB_URL=$(echo "$SERVICES_JSON" | grep -o '"url":"[^"]*"' | grep web-server | cut -d'"' -f4)
  
  if [ -z "$HEALTH_URL" ] || [ -z "$WEB_URL" ]; then
    echo "❌ Could not find expected HTTP service URLs"
    return 1
  fi
  
  # Wait for health endpoint
  echo -e "\nChecking health endpoint: ${HEALTH_URL}/health"
  HEALTH_OK=0
  
  for i in $(seq 1 $MAX_RETRIES); do
    HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}/health" 2>/dev/null)
    if [ "$HEALTH_RESPONSE" = "200" ]; then
      echo "✅ Health endpoint available (status ${HEALTH_RESPONSE})"
      echo "Response: $(curl -s "${HEALTH_URL}/health")"
      HEALTH_OK=1
      break
    fi
    echo "Attempt ${i}/${MAX_RETRIES}: HTTP status ${HEALTH_RESPONSE}"
    sleep $DELAY
  done
  
  # Wait for web server
  echo -e "\nChecking web server: ${WEB_URL}"
  WEB_OK=0
  
  for i in $(seq 1 $MAX_RETRIES); do
    WEB_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "${WEB_URL}" 2>/dev/null)
    if [ "$WEB_RESPONSE" = "200" ]; then
      echo "✅ Web server available (status ${WEB_RESPONSE})"
      WEB_OK=1
      break
    fi
    echo "Attempt ${i}/${MAX_RETRIES}: HTTP status ${WEB_RESPONSE}"
    sleep $DELAY
  done
  
  return $(( (HEALTH_OK && WEB_OK) ? 0 : 1 ))
}

# Main script execution
echo "Starting setup for Docker with BuildKit on Morph Cloud..."

# Get or create appropriate snapshot
SNAPSHOT_ID=$(find_or_create_snapshot | tail -n 1)
echo "Using snapshot $SNAPSHOT_ID"

# Start an instance from the snapshot
echo "Starting instance from snapshot $SNAPSHOT_ID..."
INSTANCE_ID=$(morphcloud instance start "$SNAPSHOT_ID" --ttl-seconds 1800 --ttl-action pause)
echo "Started instance $INSTANCE_ID"

# Setup Docker environment with BuildKit
setup_docker_environment "$INSTANCE_ID"

# Create application files
create_health_check_app "$INSTANCE_ID"
create_index_html "$INSTANCE_ID"
create_entrypoint_script "$INSTANCE_ID"
create_requirements_file "$INSTANCE_ID"
create_dockerfile "$INSTANCE_ID"

# Build and run container with BuildKit
CONTAINER_ID=$(build_and_run_container "$INSTANCE_ID")
if [ -z "$CONTAINER_ID" ]; then
  echo "❌ Failed to setup container"
  exit 1
fi

# Display information
echo -e "\nSetup complete!"
echo "Instance ID: $INSTANCE_ID"
echo "Container ID: $CONTAINER_ID"

# Check health endpoint and web server
echo -e "\nChecking services (waiting at least 1 minute)..."
if wait_for_health_check "$INSTANCE_ID"; then
  echo -e "\n✅ All services are up and running!"
else
  echo -e "\n⚠️ Some services might not be fully operational"
fi

# Display URLs and useful commands
echo -e "\nURLs to access:"
morphcloud instance get "$INSTANCE_ID" | grep -o '"url":"[^"]*"' | cut -d'"' -f4

echo -e "\nUseful commands:"
echo "SSH access: morphcloud instance ssh $INSTANCE_ID"
echo "View logs: morphcloud instance ssh $INSTANCE_ID -- sudo docker logs $CONTAINER_ID"
echo "Stop container: morphcloud instance ssh $INSTANCE_ID -- sudo docker stop $CONTAINER_ID"

# Create final snapshot
echo -e "\nCreating final snapshot of configured environment..."
FINAL_SNAPSHOT_ID=$(morphcloud instance snapshot "$INSTANCE_ID")
morphcloud snapshot set-metadata "$FINAL_SNAPSHOT_ID" "type=docker-buildkit" "description=Docker with BuildKit environment"

echo "Final snapshot created: $FINAL_SNAPSHOT_ID"
echo "To start new instances from this snapshot, run: morphcloud instance start $FINAL_SNAPSHOT_ID --ttl-seconds 1800 --ttl-action pause"
