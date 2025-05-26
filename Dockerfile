FROM ubuntu:18.04

# Set non-interactive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Set up timezone to avoid hanging on tzdata install
ENV TZ=Etc/UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Update and install general build dependencies
RUN apt-get update && apt-get install -y file wget git device-tree-compiler xz-utils zlib1g-dev openjdk-17-jdk gcc g++ python3 p7zip-full android-sdk-libsparse-utils \
            default-jdk git gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev libx11-dev libreadline-dev libgl1 libgl1-mesa-dev \
            python3 make sudo gcc g++ bc grep tofrodos python3-markdown libxml2-utils xsltproc zlib1g-dev libc6-dev libtinfo5\
            make repo cpio kmod openssl libelf-dev libssl-dev --fix-missing \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# fix git safe directory issue
RUN git config --global --add safe.directory '*'

# Set default command
CMD ["/bin/bash"]