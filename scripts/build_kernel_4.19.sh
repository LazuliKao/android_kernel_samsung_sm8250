#!/bin/bash

export KERNEL_ROOT="$(pwd)"
export ARCH=arm64
export KBUILD_BUILD_USER="@lk"
LOCALVERSION=-android12-lk
TARGET_DEFCONFIG=${1:-gki_defconfig}
DEVICE_NAME_LIST="gts7lwifi"

function add_secgetspf() {
    #> grep -r secgetspf .
    # ./drivers/net/wireless/qualcomm/qca6390/qcacld-3.0/Kbuild:ifeq ($(shell secgetspf SEC_PRODUCT_FEATURE_WLAN_SUPPORT_MIMO), TRUE)
    # ./Makefile:  ifneq ($(shell secgetspf SEC_PRODUCT_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_TZ), false)
    # ./Makefile:ifneq ($(shell secgetspf SEC_PRODUCT_FEATURE_COMMON_CONFIG_SEP_VERSION),)
    # ./Makefile:      SEP_MAJOR_VERSION := $(shell secgetspf SEC_PRODUCT_FEATURE_COMMON_CONFIG_SEP_VERSION | cut -f1 -d.)
    # ./Makefile:      SEP_MINOR_VERSION := $(shell secgetspf SEC_PRODUCT_FEATURE_COMMON_CONFIG_SEP_VERSION | cut -f2 -d.)
    echo "[+] Adding secgetspf function to fix Samsung features..."
    cat >"$KERNEL_ROOT/scripts/secgetspf.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (argc != 2) {
        return 0;
    }
    // Simulate Samsung's feature detection based on feature name
    if (strstr(argv[1], "WLAN_SUPPORT_MIMO") != NULL) {
        printf("FALSE\n");
    } else if (strstr(argv[1], "BIOAUTH_CONFIG_FINGERPRINT_TZ") != NULL) {
        printf("false\n");
    } else if (strstr(argv[1], "COMMON_CONFIG_SEP_VERSION") != NULL) {
        printf("0.0\n");
    } else {
        printf("\n");
    }
    
    return 0;
}
EOF

    # Compile the secgetspf utility
    gcc -o "$KERNEL_ROOT/scripts/secgetspf" "$KERNEL_ROOT/scripts/secgetspf.c"
    export PATH="$PATH:$KERNEL_ROOT/scripts"
}

function prepare_toolchain() {
    # Install the requirements for building the kernel when running the script for the first time
    local TOOLCHAIN=$(realpath "../toolchains")

    if [ ! -f ".requirements" ]; then
        sudo apt update && sudo apt install -y git device-tree-compiler lz4 xz-utils zlib1g-dev openjdk-17-jdk gcc g++ python3 p7zip-full android-sdk-libsparse-utils \
            default-jdk git gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev libx11-dev libreadline-dev libgl1 libgl1-mesa-dev \
            python3 make sudo gcc g++ bc grep tofrodos python3-markdown libxml2-utils xsltproc zlib1g-dev libc6-dev libtinfo5 \
            make repo cpio kmod openssl libelf-dev libssl-dev --fix-missing && touch .requirements
    fi

    # Create necessary directories
    mkdir -p "$TOOLCHAIN"

    # Clone proton clang 12 if not already done
    if [ ! -d "$TOOLCHAIN/proton-12" ]; then
        git clone --depth=1 https://github.com/ravindu644/proton-12.git "$TOOLCHAIN/proton-12"
    fi

    # Download and extract Linaro 7.5 if not already done
    if [ ! -d "$TOOLCHAIN/aarch64-linaro-7.5" ]; then
        cd "$TOOLCHAIN" && wget https://kali.download/nethunter-images/toolchains/linaro-aarch64-7.5.tar.xz
        tar -xvf linaro-aarch64-7.5.tar.xz && rm linaro-aarch64-7.5.tar.xz
        cd "${KERNEL_ROOT}"
    fi

    # Export toolchain paths
    export PATH="${PATH}:$TOOLCHAIN/proton-12/bin"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:$TOOLCHAIN/proton-12/lib"

    # Set cross-compile environment variables
    export BUILD_CROSS_COMPILE="$TOOLCHAIN/aarch64-linaro-7.5/bin/aarch64-linux-gnu-"
    export BUILD_CC="$TOOLCHAIN/proton-12/bin/clang"
}
function prepare_config() {
    mkdir -p "${KERNEL_ROOT}/out" "${KERNEL_ROOT}/build"
    # Build options for the kernel
    export BUILD_OPTIONS="
-j$(nproc) \
-C ${KERNEL_ROOT} \
O=${KERNEL_ROOT}/out \
ARCH=arm64 \
DTC_EXT=${KERNEL_ROOT}/tools/dtc \
CROSS_COMPILE=${BUILD_CROSS_COMPILE} \
CC=${BUILD_CC} \
CLANG_TRIPLE=aarch64-linux-gnu- \
LOCALVERSION=${LOCALVERSION} \
LTO=${LTO} \
"
    # Make default configuration.
    make ${BUILD_OPTIONS} $TARGET_DEFCONFIG

    # Configure the kernel (GUI)
    # make ${BUILD_OPTIONS} menuconfig

    # Set the kernel configuration, Disable unnecessary features
    # ./scripts/config --file out/.config \
    #     -d UH \
    #     -d RKP \
    #     -d KDP \
    #     -d SECURITY_DEFEX \
    #     -d INTEGRITY \
    #     -d FIVE \
    #     -d TRIM_UNUSED_KSYMS \
    #     -d PROCA \
    #     -d PROCA_GKI_10 \
    #     -d PROCA_S_OS \
    #     -d PROCA_CERTIFICATES_XATTR \
    #     -d PROCA_CERT_ENG \
    #     -d PROCA_CERT_USER \
    #     -d GAF_V6 \
    #     -d FIVE \
    #     -d FIVE_CERT_USER \
    #     -d FIVE_DEFAULT_HASH


    # use thin lto
    if [ "$LTO" = "thin" ]; then
        ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL
    fi
}

function build_kernel() {
    if [ -d "${KERNEL_ROOT}/drivers/kernelsu" ]; then
        make M=drivers/kernelsu clean
    fi
    # Build the kernel
    make ${BUILD_OPTIONS} Image || exit 1
    # Copy the built kernel to the build directory
    local output_kernel="${KERNEL_ROOT}/build/kernel"
    cp "${KERNEL_ROOT}/out/arch/arm64/boot/Image" "$output_kernel"
    echo -e "\n[INFO]: Kernel built successfully and copied to $output_kernel\n"
}

function repack() {
    local stock_boot_img="$KERNEL_ROOT/stock/boot.img"
    local new_kernel="$KERNEL_ROOT/out/arch/arm64/boot/Image"

    if [ ! -f "$new_kernel" ]; then
        echo "[-] Kernel not found. Skipping repack."
        return 0
    fi

    source "repack.sh"

    # Create build directory and navigate to it
    local build_dir="${KERNEL_ROOT}/build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    generate_info "$KERNEL_ROOT"

    # AnyKernel
    echo "[+] Creating AnyKernel package..."
    pack_anykernel "$new_kernel" "$DEVICE_NAME_LIST"

    # boot.img
    if [ ! -f "$stock_boot_img" ]; then
        echo "[-] boot.img not found. Skipping repack."
        return 0
    fi
    echo "[+] Repacking boot.img using repack.sh..."
    repack_stock_img "$stock_boot_img" "$new_kernel"

    cd "$KERNEL_ROOT"
    echo "[+] Repack completed. Output files in ./build/dist/"
}

main() {
    echo -e "\n[INFO]: BUILD STARTED..!\n"
    add_secgetspf
    prepare_toolchain
    prepare_config
    build_kernel
    repack
    echo -e "\n[INFO]: BUILD FINISHED..!"
}
main
