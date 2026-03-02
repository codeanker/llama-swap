ARG BASE_IMAGE=ghcr.io/codeanker/llama.cpp
ARG BASE_TAG=server-cuda

# Clone source
FROM alpine/git AS source
ARG LS_REPO=mostlygeek/llama-swap
ARG LS_REF=main
RUN git clone --depth 1 --branch ${LS_REF} https://github.com/${LS_REPO}.git /src

# Build UI
FROM node:22-alpine AS ui-builder
COPY --from=source /src/ui-svelte /src/ui-svelte
WORKDIR /src/ui-svelte
RUN npm install && npm run build

# Build llama-swap from source
FROM --platform=$BUILDPLATFORM golang:1.25 AS builder
ARG TARGETARCH
COPY --from=source /src /src
COPY --from=ui-builder /src/proxy/ui_dist /src/proxy/ui_dist
WORKDIR /src
RUN CGO_ENABLED=0 GOARCH=${TARGETARCH} go build -o /llama-swap .

FROM ${BASE_IMAGE}:${BASE_TAG}

# Set default UID/GID arguments
ARG UID=10001
ARG GID=10001
ARG USER_HOME=/app

# Add user/group
ENV HOME=$USER_HOME
RUN if [ $UID -ne 0 ]; then \
  if [ $GID -ne 0 ]; then \
  groupadd --system --gid $GID app; \
  fi; \
  useradd --system --uid $UID --gid $GID \
  --home $USER_HOME app; \
  fi

# Handle paths
RUN mkdir --parents $HOME /app
RUN chown --recursive $UID:$GID $HOME /app

# Switch user
USER $UID:$GID

WORKDIR /app

# Add /app to PATH
ENV PATH="/app:${PATH}"

COPY --from=builder --chown=$UID:$GID /llama-swap /app/llama-swap

COPY --chown=$UID:$GID config.example.yaml /app/config.yaml

HEALTHCHECK CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT [ "/app/llama-swap", "-config", "/app/config.yaml" ]
