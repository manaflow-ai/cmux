FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    openssh-server \
    openssh-client \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
ARG ZIG_VERSION=0.15.2
RUN set -e; \
    arch="$(uname -m)"; \
    case "$arch" in \
        aarch64|arm64) zig_arch="aarch64" ;; \
        x86_64|amd64) zig_arch="x86_64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt; \
    ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:$PATH"

# Copy repo
WORKDIR /opt/cmuxterm
COPY . /opt/cmuxterm

# Build cmuxd
RUN cd /opt/cmuxterm/cmuxd && zig build -Doptimize=ReleaseSafe

# Setup sshd and user
RUN useradd -m cmux \
    && mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && mkdir -p /home/cmux/.ssh \
    && chmod 700 /home/cmux/.ssh \
    && ssh-keygen -t ed25519 -N "" -f /root/.ssh/cmux_test \
    && cat /root/.ssh/cmux_test.pub > /home/cmux/.ssh/authorized_keys \
    && chown -R cmux:cmux /home/cmux/.ssh

RUN sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

# Install test deps
RUN pip3 install -r /opt/cmuxterm/tests/e2e/requirements.txt

COPY tests/e2e/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
