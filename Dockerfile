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
    vim \
    nano \
    default-jdk \
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
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Download and install Verilator v5.008 directly (self-contained, no local tarball required)
ARG VERILATOR_VERSION=v5.008
RUN cd /tmp && \
    ( wget -q --timeout=30 https://github.com/verilator/verilator/archive/refs/tags/${VERILATOR_VERSION}.tar.gz -O verilator.tar.gz || \
      curl -sSL https://github.com/verilator/verilator/archive/refs/tags/${VERILATOR_VERSION}.tar.gz -o verilator.tar.gz ) && \
    tar -xzf verilator.tar.gz && \
    cd verilator-${VERILATOR_VERSION#v} && \
    autoconf && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    cd /tmp && \
    rm -rf verilator*

# Create ysyx user (UID 1000, GID 1000) with passwordless sudo
RUN groupadd -g 1000 ysyx && \
    useradd -u 1000 -g ysyx -m -s /bin/bash ysyx && \
    echo "ysyx ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Create symlinks for riscv toolchains
RUN for tool in gcc g++ as ld ar ranlib objcopy objdump readelf nm strip; do \
      if [ -f "/usr/bin/riscv64-linux-gnu-$tool" ]; then \
        ln -sf /usr/bin/riscv64-linux-gnu-$tool /usr/local/bin/riscv64-unknown-elf-$tool ; \
        ln -sf /usr/bin/riscv64-linux-gnu-$tool /usr/local/bin/riscv32-unknown-elf-$tool ; \
      fi \
    done

# Install openjdk-17-jdk for modern mill and Scala/Chisel
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jdk && \
    update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java && \
    update-alternatives --set javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac && \
    rm -rf /var/lib/apt/lists/*

USER ysyx
WORKDIR /workspace

RUN git config --global --add safe.directory '*' && \
    git config --global user.name "ysyx" && \
    git config --global user.email "ysyx@oscc.cc"

CMD ["/bin/bash"]
