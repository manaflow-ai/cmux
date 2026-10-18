FROM docker.io/oven/bun:1.4.2

ARG CMUX_SOURCE_SHA=unknown
LABEL org.opencontainers.image.revision=$CMUX_SOURCE_SHA
ENV CMUX_SOURCE_SHA=$CMUX_SOURCE_SHA

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates openssh-client \
  && rm -rf /var/lib/apt/lists/*

# Install the existing web runtime dependencies without copying the web
# checkout's local node_modules into the image.
COPY web/package.json web/bun.lock /app/web/
COPY web/patches /app/web/patches
RUN cd /app/web && bun install --frozen-lockfile --production

# The worker intentionally reuses the repository's PlanetScale schema and
# broker repository. Provider adapters are injected at deployment time.
COPY web/db /app/web/db
COPY web/services/agent-broker /app/web/services/agent-broker
COPY web/services/vms/hostLeaseTransport.ts web/services/vms/sshHostLeaseClient.ts /app/web/services/vms/
COPY web/scripts/agent-broker-worker.ts /app/web/scripts/agent-broker-worker.ts
COPY workers/agent-broker/adapters /app/workers/agent-broker/adapters

ENV NODE_ENV=production
CMD ["bun", "web/scripts/agent-broker-worker.ts"]
