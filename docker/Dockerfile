FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

RUN export \
        http_proxy="$HTTP_PROXY" \
        https_proxy="$HTTPS_PROXY" \
        all_proxy="$ALL_PROXY" \
        no_proxy="$NO_PROXY"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        ccache \
        curl \
        e2fsprogs \
        file \
        flex \
        g++-multilib \
        gcc-multilib \
        git \
        gnupg \
        gperf \
        lib32ncurses5-dev \
        lib32readline-dev \
        lib32z1-dev \
        liblz4-tool \
        libncurses5 \
        libncurses5-dev \
        libssl-dev \
        libxml2-utils \
        lz4 \
        lzop \
        openjdk-11-jdk \
        pngcrush \
        python-is-python3 \
        rsync \
        schedtool \
        squashfs-tools \
        unzip \
        xattr \
        xz-utils \
        xsltproc \
        zip \
        zlib1g-dev; \
    curl --fail --location --retry 3 \
        -o /usr/local/bin/repo \
        https://storage.googleapis.com/git-repo-downloads/repo; \
    chmod 0755 /usr/local/bin/repo; \
    repo --version; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
