#!/usr/bin/env bash

set -euo pipefail

BUILD_ARCH=x86_64
BUILD_TARGET=linux
TOOLCHAIN_REPO=https://github.com/neon-engine/buildroot
TOOLCHAIN_BRANCH=2024.02.x
VULKAN_SDK_VERSION=1.3.296
HOST_ARCH=$(uname -m)

ERR_OPTIONS=1
ERR_CANCEL=2
ERR_TARGET_NOT_SUPPORTED=3
ERR_CANCEL_REBUILD=4

trap 'echo "build interrupted"; exit' SIGINT

OPTIONS=$(getopt -o "" --long "help,arch:,host-arch:,no-prompt,keep" -n "$0" -- "$@")
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
    --help      ) Displays this dialog
    --arch      ) The architecture to build the SDK for, supported values are: x86_64, aarch64
    --host-arch ) The architecture of the host that will consume the SDK, supported values are: x86_64, aarch64
    --no-prompt ) Does not prompt the user, will remove the existing SDK unless the user specifies otherwise
    --keep      ) Keeps the existing SDK, otherwise it is ignored
EOF
}

function get_podman_arch() {
  case "$1" in
    x86_64)
      echo "amd64"
      ;;
    aarch64)
      echo "arm64"
      ;;
    *)
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

NO_PROMPT=
KEEP=
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
    --host-arch)
      HOST_ARCH=$2
      shift 2
      ;;
    --no-prompt)
      NO_PROMPT=1
      shift 1
      ;;
    --keep)
      KEEP=1
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

TARGET_SDK_LOCATION="/opt/neon-sdk/${HOST_ARCH}-${BUILD_TARGET}-${BUILD_ARCH}"
NO_REBUILD=

echo "Building SDK for:"
echo "Platform: ${BUILD_TARGET}"
echo "Target Arch: ${BUILD_ARCH}"
echo "Host Arch: ${HOST_ARCH}"
echo "SDK will be deployed to: ${TARGET_SDK_LOCATION}"
echo ""

if [[ -z "${NO_PROMPT}" ]]; then
  response=$(ask_yes_or_no "Would you like to proceed?")
  if [[ "${response}" = "no" ]]; then
    echo "Operation cancelled, exiting!"
    exit "${ERR_CANCEL}"
  fi
fi

if [[ -d "${TARGET_SDK_LOCATION}" ]] && [[ -n "${NO_PROMPT}" ]] && [[ -z "${KEEP}" ]]; then
  echo "Forcing removal of ${TARGET_SDK_LOCATION}, and rebuilding it"
  rm -rf "${TARGET_SDK_LOCATION}"
fi

if [[ -d "${TARGET_SDK_LOCATION}" ]] && [[ -z "${NO_PROMPT}" ]] && [[ -z "${KEEP}" ]]; then
  response=$(ask_yes_or_no "Found ${TARGET_SDK_LOCATION}, keep it?")
  if [[ "${response}" = "yes" ]]; then
    echo "Keeping the existing ${TARGET_SDK_LOCATION}"
    NO_REBUILD=1
  else
    echo "Removing the existing ${TARGET_SDK_LOCATION}"
    rm -rf "${TARGET_SDK_LOCATION}"
  fi
fi

if [[ -n $"${KEEP}" ]]; then
  echo "Keeping the existing ${TARGET_SDK_LOCATION}"
  NO_REBUILD=1
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
  MOUNT_SDK=/opt/sdk
  MOUNT_BUILD=/opt/build
  PODMAN_HOST_ARCH=$(get_podman_arch ${HOST_ARCH})
  
  if [[ -z "${PODMAN_HOST_ARCH}" ]]; then
    echo "Invalid arch ${HOST_ARCH}"
    exit 1
  fi

  podman build --platform linux/${PODMAN_HOST_ARCH} -t neon-sdk-builder-${HOST_ARCH} -f $(dirname "${0}")/neon-sdk-builder.dockerfile
  podman run -i --rm \
    --arch ${PODMAN_HOST_ARCH} \
    -v "${TARGET_SDK_LOCATION}:${MOUNT_SDK}:z" \
    -v "${BUILDROOT_ROOT}:${MOUNT_BUILD}:z" \
    -e FORCE_UNSAFE_CONFIGURE=1 \
    -e HOME=/home \
    --userns=keep-id \
    -w ${MOUNT_BUILD} \
    neon-sdk-builder-${HOST_ARCH}:latest -e \
<< EOF
      if [[ -z "${NO_REBUILD}" ]]; then
        echo "Cleaning previous build"
        make clean
        echo "Staging neon-${BUILD_ARCH}.config"
        rm -f .config
        cp neon-${BUILD_ARCH}.config .config;
        echo "Building Neon SDK"
        make syncconfig;
        make sdk;
        rsync -a --progress --delete --delete-delay --prune-empty-dirs ${MOUNT_BUILD}/output/host/ ${MOUNT_SDK}/;

        cd ${MOUNT_SDK}/bin
        echo "Setting up symlinks"
        ln -sf ${BUILD_ARCH}-linux-gcc.br_real gcc
        ln -sf ${BUILD_ARCH}-linux-g++.br_real g++
      else
        echo "Skipping building the SDK"
      fi

      ${MOUNT_SDK}/relocate-sdk.sh
      source ${MOUNT_SDK}/environment-setup

      echo ''
      echo "Build environment for Vulkan"
      echo "=== cmake: ==="
      which cmake
      cmake --version
      echo "=== gcc ==="
      which gcc
      gcc --version
      echo "=== g++ ==="
      which g++
      g++ --version
      echo ''
      
      echo "Setting up vulkan SDK in \${STAGING_DIR}/opt/vulkan/${VULKAN_SDK_VERSION}.0"

      mkdir -p \${STAGING_DIR}/opt/vulkan
      cd \${STAGING_DIR}/opt/vulkan

      if [[ ! -f ${VULKAN_SDK_VERSION}.0/vulkansdk ]]; then
        echo "Fetching Vulkan SDK ${VULKAN_SDK_VERSION}"
        wget https://sdk.lunarg.com/sdk/download/${VULKAN_SDK_VERSION}.0/linux/vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz

        tar -xvf vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz \
          ${VULKAN_SDK_VERSION}.0/setup-env.sh \
          ${VULKAN_SDK_VERSION}.0/vulkansdk \
          ${VULKAN_SDK_VERSION}.0/LICENSE.txt \
          ${VULKAN_SDK_VERSION}.0/README.txt \
          ${VULKAN_SDK_VERSION}.0/config/vk_layer_settings.txt

        rm -f vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.0.tar.xz
      else
        echo "Existing vulkan files found, not redownloading"
      fi

      cd ${VULKAN_SDK_VERSION}.0

      source setup-env.sh

      cp -a vulkansdk vulkansdk.modified

      echo "Workaround #1, since we're building vulkan for the target arch we need to set the toolchain file accoridngly"

      VULKAN_BUILD_REPLACE_ARGS="-DCMAKE_TOOLCHAIN_FILE=${MOUNT_SDK}/share/buildroot/toolchainfile.cmake "
      VULKAN_BUILD_REPLACE_ARGS+="-DCMAKE_BUILD_TYPE="

      sed -i \
        "s+-DCMAKE_BUILD_TYPE=+\${VULKAN_BUILD_REPLACE_ARGS}+g" \
        vulkansdk.modified

      ./vulkansdk.modified --skip-deps --maxjobs \
        headers \
        loader \
        layers \
        vulkan-extensionlayer \
        shaderc \
        spirv-tools \
        glslang \
        spirv-cross \
        gfxrecon \
        spirv-reflect \
        vulkan-profiles \
        volk \
        vma \
        vul

      echo "Done building Vulkan SDK, note that LunarG and KHR Vulkan-Tools, as well as DXC, slang, and CDL, are excluded"
      rm -rf source
      
      cd ${MOUNT_SDK}

      echo "Setting up buildroot's environment-setup to source Vulkan SDK environment file"
      SOURCE_VULKAN_ENV="source \${STAGING_DIR}/opt/vulkan/${VULKAN_SDK_VERSION}.0/setup-env"
      if ! grep -qF "\${SOURCE_VULKAN_ENV}" environment-setup; then
        echo "\${SOURCE_VULKAN_ENV}" >> environment-setup
      fi
EOF
    echo "Done building the SDK, relocating it for the target machine"
    "${TARGET_SDK_LOCATION}/relocate-sdk.sh"
else
  echo "The target ${BUILD_TARGET} is not supported"
  exit "${ERR_TARGET_NOT_SUPPORTED}"
fi
