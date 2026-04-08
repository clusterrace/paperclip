FROM node:lts-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl git openssh-client wget ripgrep python3 \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -nv -O/etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && echo "20e0125d6f6e077a9ad46f03371bc26d90b04939fb95170f5a1905099cc6bcc0  /etc/apt/keyrings/githubcli-archive-keyring.gpg" | sha256sum -c - \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY patches/ patches/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
ARG TARGETARCH
WORKDIR /app
COPY --chown=node:node --from=build /app /app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

# Install kubectl 1.30.14
RUN curl -fsSL "https://dl.k8s.io/release/v1.30.14/bin/linux/$(dpkg --print-architecture)/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    mkdir -p /paperclip/.kube && \
    chmod 700 /paperclip/.kube

# Install DevSpace CLI v6.3.20
RUN curl -fsSL "https://github.com/devspace-sh/devspace/releases/download/v6.3.20/devspace-linux-${TARGETARCH}" -o /usr/local/bin/devspace && \
    chmod +x /usr/local/bin/devspace

# Install buildctl (BuildKit client) v0.28.0
RUN curl -fsSL "https://github.com/moby/buildkit/releases/download/v0.28.0/buildkit-v0.28.0.linux-${TARGETARCH}.tar.gz" | \
    tar -xz -C /usr/local/bin --strip-components=1 bin/buildctl

# Install crane v0.21.2
RUN CRANE_ARCH=$([ "$TARGETARCH" = "amd64" ] && echo "x86_64" || echo "arm64") && \
    curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v0.21.2/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" | \
    tar -xz -C /usr/local/bin crane

# Install talosctl v1.10.5
RUN TALOSCTL_ARCH=$([ "$TARGETARCH" = "amd64" ] && echo "amd64" || echo "arm64") && \
    curl -fsSL "https://github.com/siderolabs/talos/releases/download/v1.10.5/talosctl-linux-${TALOSCTL_ARCH}" -o /usr/local/bin/talosctl && \
    chmod +x /usr/local/bin/talosctl && \
    mkdir -p /paperclip/.talos && \
    chmod 700 /paperclip/.talos

# Setup SSH for GitHub
RUN mkdir -p /paperclip/.ssh && chmod 700 /paperclip/.ssh && \
    printf 'Host github.com\n  User git\n  Hostname github.com\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/clusterrace-robot-github-key\n  StrictHostKeyChecking accept-new\n\n' > /paperclip/.ssh/config && \
    printf 'Host 192.168.0.30\n  User susverwimp\n  Hostname 192.168.0.30\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/desktop-key\n  StrictHostKeyChecking accept-new\n\n' >> /paperclip/.ssh/config && \
    printf 'Host 192.168.0.31\n  User susverwimp\n  Hostname 192.168.0.31\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/laptop-key\n  StrictHostKeyChecking accept-new\n\n' >> /paperclip/.ssh/config && \
    printf 'Host 192.168.0.32\n  User brett\n  Hostname 192.168.0.32\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/mac-laptop-key\n  StrictHostKeyChecking accept-new\n\n' >> /paperclip/.ssh/config && \
    printf 'Host 192.168.0.9\n  User root\n  Hostname 192.168.0.9\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/proxmox1\n  StrictHostKeyChecking accept-new\n\n' >> /paperclip/.ssh/config && \
    printf 'Host 192.168.0.7\n  User root\n  Hostname 192.168.0.7\n  PreferredAuthentications publickey\n  IdentityFile ~/.ssh/proxmox2\n  StrictHostKeyChecking accept-new\n\n' >> /paperclip/.ssh/config && \
    chmod 600 /paperclip/.ssh/config

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true

VOLUME ["/paperclip"]
EXPOSE 3100

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
