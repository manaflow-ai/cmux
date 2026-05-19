FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        fluxbox \
        netcat-openbsd \
        x11-apps \
        x11-xserver-utils \
        x11vnc \
        xterm \
        xvfb && \
    rm -rf /var/lib/apt/lists/*

COPY start-vnc-demo.sh /usr/local/bin/start-vnc-demo

EXPOSE 5900

CMD ["/usr/local/bin/start-vnc-demo"]
