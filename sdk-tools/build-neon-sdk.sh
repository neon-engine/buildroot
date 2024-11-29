#!/usr/bin/env bash

set -euo pipefail

BUILD_ARCH=x86_64
BUILD_TARGET=linux
TOOLCHAIN_REPO=https://github.com/neon-engine/buildroot
TOOLCHAIN_BRANCH=2024.02.x
VULKAN_SDK_VERSION=1.3.296

ERR_OPTIONS=1
ERR_CANCEL=2
ERR_TARGET_NOT_SUPPORTED=3
ERR_CANCEL_REBUILD=4

trap 'echo "build interrupted"; exit' SIGINT

OPTIONS=$(getopt -o "" --long "help,arch:,force" -n "$0" -- "$@")
# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
  echo "error setting OPTIONS"
  exit ${ERR_OPTIONS}
fi

eval set -- "${OPTIONS}"

function help() {
  cat << EOF
  Description: Builds cross-compilation SDK for C/C++
  Usage:
    ${0} [options]

  options:
    --help ) Displays this dialog
    --arch ) The architecture to build the SDK for, supported values are: x86_64
    --force ) Forces the script to remove SDK if it exists and rebuild it
EOF
}

function get_podman_arch() {
  case "$1" in
    x86_64)
      echo "amd64"
      break
      ;;
    aarch64)
      echo "arm64"
      break
      ;;
    *)
      break
      ;;
  esac
}

function ask_yes_or_no() {
  read -rp "$1 [yN]: "
  case $(echo "$REPLY" | tr "[:upper:]" "[:lower:]") in
      y|yes) echo "yes" ;;
      n|no)  echo "no"  ;;
      *)     echo "no"   ;;
  esac
}

FORCE_REBUILD=
while true; do
  case "$1" in
    --help)
      help
      exit 0
      ;;
    --arch)
      BUILD_ARCH=$2
      shift 2
      ;;
    --force)
      FORCE_REBUILD=1
      shift 1
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

TARGET_SDK_LOCATION="/opt/neon-sdk/${BUILD_ARCH}-${BUILD_TARGET}"

echo "Building SDK for:"
echo "Platform: ${BUILD_TARGET}"
echo "Arch: ${BUILD_ARCH}"
echo "SDK will be deployed to: ${TARGET_SDK_LOCATION}"
echo ""

if [[ -z "${FORCE_REBUILD}" ]]; then
  response=$(ask_yes_or_no "Would you like to proceed?")
  if [[ "${response}" = "no" ]]; then
    echo "Operation cancelled, exiting!"
    exit "${ERR_CANCEL}"
  fi
fi

if [[ -d "${TARGET_SDK_LOCATION}" ]] && [[ -n "${FORCE_REBUILD}" ]]; then
  echo "forcing removal of ${TARGET_SDK_LOCATION}, and rebuilding it"
  rm -rf "${TARGET_SDK_LOCATION}"
fi

if [[ -d "${TARGET_SDK_LOCATION}" ]]; then
  response=$(ask_yes_or_no "Found ${TARGET_SDK_LOCATION}, keep it?")
  if [[ "${response}" = "yes" ]]; then
    echo "keeping the existing toolchain, will overwrite new files"
  else
    rm -rf "${TARGET_SDK_LOCATION}"
  fi
fi

if [[ ! -d "/opt/neon-sdk" ]]; then
  sudo mkdir /opt/neon-sdk
  # add the sticky bit so only root and owners can delete files
  sudo chmod 1777 /opt/neon-sdk
fi

if [[ ! -d "${TARGET_SDK_LOCATION}" ]]; then
  mkdir -p "${TARGET_SDK_LOCATION}"
fi

BUILDROOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

if [[ "${BUILD_TARGET}" == "linux" ]]; then
  podman build -t neon-sdk-builder -f $(dirname "${0}")/neon-sdk-builder.dockerfile
  podman run -i --rm \
    -v "${TARGET_SDK_LOCATION}:/sdk:z" \
    -v "${BUILDROOT_ROOT}:/build:z" \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    -e HOME=/home \
    --userns=keep-id \
    -w /build \
    neon-sdk-builder:latest -c "
      make clean
      rm -f .config
      cp neon-${BUILD_ARCH}.config .config;
      make syncconfig;
      make sdk;
      rsync -a --progress --delete --delete-delay --prune-empty-dirs /build/output/host/ /sdk/;
    "
    "${TARGET_SDK_LOCATION}/relocate-sdk.sh"
    PODMAN_ARCH=$(get_podman_arch ${BUILD_ARCH})
    if [[ -z "${PODMAN_ARCH}" ]]; then
      echo "${BUILD_ARCH} not valid for building vulkan"
    else
      VULKAN_SDK_LOCATION=${TARGET_SDK_LOCATION}/${BUILD_ARCH}-neon-${BUILD_TARGET}-gnu/opt/vulkan
      mkdir -p ${VULKAN_SDK_LOCATION}
      podman build --build-arg ARCH=${PODMAN_ARCH} -t vulkan-sdk-builder-${PODMAN_ARCH} -f $(dirname "${0}")/vulkan-sdk-builder.dockerfile
      podman run -i --rm \
        -v "${VULKAN_SDK_LOCATION}:/sdk:z" \
        -e FORCE_UNSAFE_CONFIGURE=1 \
        -e HOME=/home \
        --userns=keep-id \
        -w /sdk \
        neon-sdk-builder:latest -c "
          wget https://sdk.lunarg.com/sdk/download/${VULKAN_SDK_VERSION}.0/linux/vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz

          tar -xvf vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz \
            ${VULKAN_SDK_VERSION}.0/setup-env.sh \
            ${VULKAN_SDK_VERSION}.0/vulkansdk \
            ${VULKAN_SDK_VERSION}.0/LICENSE.txt \
            ${VULKAN_SDK_VERSION}.0/README.txt \
            ${VULKAN_SDK_VERSION}.0/config/vk_layer_settings.txt

          rm -f vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz
          cd ${VULKAN_SDK_VERSION}.0
          ./vulkansdk --skip-deps --maxjobs
        "
    fi
else
  echo "The target ${BUILD_TARGET} is not supported"
  exit "${ERR_TARGET_NOT_SUPPORTED}"
fi
