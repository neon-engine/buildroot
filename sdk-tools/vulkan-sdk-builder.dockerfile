ARG ARCH=amd64
ARG OS_VERSION=8.10
FROM ${ARCH}/almalinux:${OS_VERSION}

ENV MENUCONFIG_COLOR=blackbg

RUN dnf update -y \
    && dnf install -y 'dnf-command(config-manager)' \
    && dnf group install -y "Development Tools" \
    && dnf config-manager --set-enabled powertools \
    && dnf install -y epel-release \
    && dnf install -y \
        @development-tools \
        which \
        glm-devel \
        cmake \
        libpng-devel \
        wayland-devel \
        libpciaccess-devel \
        libX11-devel \
        libXpresent \
        libxcb \
        xcb-util \
        libxcb-devel \
        libXrandr-devel \
        xcb-util-keysyms-devel \
        xcb-util-wm-devel \
        python \
        python3 \
        git \
        lz4-devel \
        libzstd-devel \
        python3-distutils-extra \
        qt \
        gcc-g++ \
        wayland-protocols-devel \
        ninja-build \
        python3-jsonschema \
        qt5-qtbase-devel \
        python-unversioned-command \
        python3-setuptools \
        clang-tools-extra \
    && dnf clean all \
    && mkdir -p /opt/build /opt/sdk \
    && echo ${OS_VERSION} > /etc/version_id

ENTRYPOINT [ "/bin/bash" ]
