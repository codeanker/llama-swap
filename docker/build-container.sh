#!/bin/bash

set -euo pipefail

cd $(dirname "$0")

# use this to test locally, example:
# GITHUB_TOKEN=$(gh auth token) LOG_DEBUG=1 DEBUG_ABORT_BUILD=1 ./docker/build-container.sh rocm
# you need read:package scope on the token. Generate a personal access token with
# the scopes: gist, read:org, repo, write:packages
# then: gh auth login (and copy/paste the new token)

LOG_DEBUG=${LOG_DEBUG:-0}
DEBUG_ABORT_BUILD=${DEBUG_ABORT_BUILD:-}

log_debug() {
    if [ "$LOG_DEBUG" = "1" ]; then
        echo "[DEBUG] $*"
    fi
}

log_info() {
    echo "[INFO] $*"
}

ARCH=$1
PUSH_IMAGES=${2:-false}

# List of allowed architectures
ALLOWED_ARCHS=("cuda" "cuda13")

# Check if ARCH is in the allowed list
if [[ ! " ${ALLOWED_ARCHS[@]} " =~ " ${ARCH} " ]]; then
  log_info "Error: ARCH must be one of the following: ${ALLOWED_ARCHS[@]}"
  exit 1
fi

# Check if GITHUB_TOKEN is set and not empty
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  log_info "Error: GITHUB_TOKEN is not set or is empty."
  exit 1
fi

# Set llama.cpp base image, customizable using the BASE_LLAMACPP_IMAGE environment
# variable, this permits testing with forked llama.cpp repositories
BASE_IMAGE=${BASE_LLAMACPP_IMAGE:-ghcr.io/codeanker/llama.cpp}
SD_IMAGE=${BASE_SDCPP_IMAGE:-ghcr.io/leejet/stable-diffusion.cpp}

# Set llama-swap repository, automatically uses GITHUB_REPOSITORY variable
# to enable easy container builds on forked repos
LS_REPO=${GITHUB_REPOSITORY:-mostlygeek/llama-swap}

# Git ref to build llama-swap from (branch, tag, or commit)
LS_REF=${LS_REF:-main}

# Fetches the most recent llama.cpp tag matching the given prefix
# Handles pagination to search beyond the first 100 results
# $1 - tag_prefix (e.g., "server" or "server-vulkan")
# Returns: the version number extracted from the tag
fetch_llama_tag() {
    local tag_prefix=$1
    local page=1
    local per_page=100

    while true; do
        log_debug "Fetching page $page for tag prefix: $tag_prefix"

        local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/users/codeanker/packages/container/llama.cpp/versions?per_page=${per_page}&page=${page}")

        # Check for API errors
        if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
            local error_msg=$(echo "$response" | jq -r '.message')
            log_info "GitHub API error: $error_msg"
            return 1
        fi

        # Check if response is empty array (no more pages)
        if [ "$(echo "$response" | jq 'length')" -eq 0 ]; then
            log_debug "No more pages (empty response)"
            return 1
        fi

        # Extract matching tag from this page
        local found_tag=$(echo "$response" | jq -r \
            ".[] | select(.metadata.container.tags[]? | startswith(\"$tag_prefix\")) | .metadata.container.tags[] | select(startswith(\"$tag_prefix\"))" \
            | sort -r | head -n1)

        if [ -n "$found_tag" ]; then
            log_debug "Found tag: $found_tag on page $page"
            echo "$found_tag" | awk -F '-' '{print $NF}'
            return 0
        fi

        page=$((page + 1))

        # Safety limit to prevent infinite loops
        if [ $page -gt 50 ]; then
            log_info "Reached pagination safety limit (50 pages)"
            return 1
        fi
    done
}

if [ "$ARCH" == "cpu" ]; then
    LCPP_TAG=$(fetch_llama_tag "server")
    BASE_TAG=server-${LCPP_TAG}
else
    LCPP_TAG=$(fetch_llama_tag "server-${ARCH}")
    BASE_TAG=server-${ARCH}-${LCPP_TAG}
fi

SD_TAG=master-${ARCH}

# Abort if LCPP_TAG is empty.
if [[ -z "$LCPP_TAG" ]]; then
    log_info "Abort: Could not find llama-server container for arch: $ARCH"
    exit 1
else
    log_info "LCPP_TAG: $LCPP_TAG"
fi

if [[ ! -z "$DEBUG_ABORT_BUILD" ]]; then
    log_info "Abort: DEBUG_ABORT_BUILD set"
    exit 0
fi

# Target platform(s) for multi-arch builds, customizable via environment variable
BUILD_PLATFORM=${BUILD_PLATFORM:-linux/arm64}

for CONTAINER_TYPE in non-root root; do
  CONTAINER_TAG="ghcr.io/${LS_REPO}:${ARCH}-${LCPP_TAG}"
  CONTAINER_LATEST="ghcr.io/${LS_REPO}:${ARCH}"
  USER_UID=0
  USER_GID=0
  USER_HOME=/root

  if [ "$CONTAINER_TYPE" == "non-root" ]; then
    CONTAINER_TAG="${CONTAINER_TAG}-non-root"
    CONTAINER_LATEST="${CONTAINER_LATEST}-non-root"
    USER_UID=10001
    USER_GID=10001
    USER_HOME=/app
  fi

  PUSH_ARGS=""
  if [ "$PUSH_IMAGES" == "true" ]; then
    PUSH_ARGS="--push"
  fi

  log_info "Building $CONTAINER_TYPE $CONTAINER_TAG"
  docker buildx build --platform ${BUILD_PLATFORM} --provenance=false \
    -f llama-swap.Containerfile \
    --build-arg BASE_TAG=${BASE_TAG} --build-arg UID=${USER_UID} \
    --build-arg LS_REPO=${LS_REPO} --build-arg LS_REF=${LS_REF} \
    --build-arg GID=${USER_GID} --build-arg USER_HOME=${USER_HOME} \
    --build-arg BASE_IMAGE=${BASE_IMAGE} \
    -t ${CONTAINER_TAG} -t ${CONTAINER_LATEST} ${PUSH_ARGS} .

  # For architectures with stable-diffusion.cpp support, layer sd-server on top
  case "$ARCH" in
    "musa" | "vulkan")
      log_info "Adding sd-server to $CONTAINER_TAG"
      docker buildx build --platform ${BUILD_PLATFORM} --provenance=false \
        -f llama-swap-sd.Containerfile \
        --build-arg BASE=${CONTAINER_TAG} \
        --build-arg SD_IMAGE=${SD_IMAGE} --build-arg SD_TAG=${SD_TAG} \
        --build-arg UID=${USER_UID} --build-arg GID=${USER_GID} \
        -t ${CONTAINER_TAG} -t ${CONTAINER_LATEST} ${PUSH_ARGS} . ;;
  esac
done
