FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# Use Tsinghua mirror by default for fast domestic apt updates (can be overridden)
ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s@archive.ubuntu.com@$APT_MIRROR@g" /etc/apt/sources.list && \
      sed -i "s@security.ubuntu.com@$APT_MIRROR@g" /etc/apt/sources.list ; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    gdb \
    make \
    cmake \
    ninja-build \
    autoconf \
    automake \
    autotools-dev \
    libtool \
    bison \
    flex \
    libfl-dev \
    libfl2 \
    libgoogle-perftools-dev \
    help2man \
    perl \
    python3 \
    python3-pip \
    git \
    curl \
    wget \
    rsync \
    unzip \
    tar \
    bzip2 \
    vim \
    nano \
    gtkwave \
    libreadline-dev \
    libsdl2-dev \
    libsdl2-image-dev \
    libsdl2-ttf-dev \
    libncurses5-dev \
    zlib1g-dev \
    libssl-dev \
    gcc-riscv64-linux-gnu \
    g++-riscv64-linux-gnu \
    sudo \
    ca-certificates \
    locales \
    ccache \
    bc \
    device-tree-compiler \
    openssh-client \
    iverilog \
    yosys \
    openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java && \
    update-alternatives --set javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Verilator
ARG VERILATOR_VERSION=v5.008
ARG VERILATOR_SHA256=1d19f4cd186eec3dfb363571e3fe2e6d3377386ead6febc6ad45402f0634d2a6
RUN cd /tmp && \
    ( curl -fsSL --retry 3 --connect-timeout 15 "https://github.com/verilator/verilator/archive/refs/tags/${VERILATOR_VERSION}.tar.gz" -o verilator.tar.gz || \
      wget -q --timeout=30 "https://github.com/verilator/verilator/archive/refs/tags/${VERILATOR_VERSION}.tar.gz" -O verilator.tar.gz ) && \
    echo "${VERILATOR_SHA256}  verilator.tar.gz" | sha256sum -c - && \
    tar -xzf verilator.tar.gz && \
    cd "verilator-${VERILATOR_VERSION#v}" && \
    autoconf && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    cd /tmp && \
    rm -rf verilator*

# User setup & workspace permissions
RUN groupadd -g 1000 ysyx && \
    useradd -u 1000 -g ysyx -m -s /bin/bash ysyx && \
    echo "ysyx ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN mkdir -p /workspace && chown -R ysyx:ysyx /workspace

USER ysyx
WORKDIR /workspace

ENV PATH="/home/ysyx/.local/bin:${PATH}"
ENV YSYX_HOME=/workspace
ENV NEMU_HOME=/workspace/nemu
ENV AM_HOME=/workspace/abstract-machine
ENV NPC_HOME=/workspace/npc
ENV NAVY_HOME=/workspace/navy-apps
ENV ICSPROUT55_HOME=/home/ysyx/.local/share/ecc/pdks/icsprout55/v1.10.102

# ECC EDA toolchain & PDK
ARG ECC_VERSION=v0.1.0-alpha.12
ARG ECC_INSTALLER_SHA256=fe869f19b53cfcee5508c45d5208c6fd3bf973eb9703a79574cd8a48e6b90315
ARG ECC_INSTALLER_URL=https://release.openecos.com/installers/ecc/${ECC_VERSION}/ecc-installer.sh
ARG ECC_DOWNLOAD_SOURCE=cnb
RUN curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "${ECC_INSTALLER_URL}" -o /tmp/ecc-installer.sh && \
    echo "${ECC_INSTALLER_SHA256}  /tmp/ecc-installer.sh" | sha256sum -c - && \
    chmod +x /tmp/ecc-installer.sh && \
    /tmp/ecc-installer.sh --with-toolchain --download-source "${ECC_DOWNLOAD_SOURCE}" && \
    rm -f /tmp/ecc-installer.sh && \
    test -d "${ICSPROUT55_HOME}" && \
    test -f "${ICSPROUT55_HOME}/prtech/techLEF/N551P6M_ecos.lef" && \
    ecc pdk show

CMD ["/bin/bash"]
