#!/usr/bin/env bash

BUILDROOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

podman build -t neon-sdk-builder -f $(dirname "${0}")/neon-sdk-builder.dockerfile
podman run -it --rm \
    -v "${BUILDROOT_ROOT}:/build:z" \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    -e HOME=/home \
    --userns=keep-id \
    -w /build \
    neon-sdk-builder:latest -c "make menuconfig"
