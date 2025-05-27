#!/bin/bash

export KERNEL_ROOT="$(pwd)"
export ARCH=arm64
export KBUILD_BUILD_USER="@lk"
LOCALVERSION=-android12-lk
TARGET_DEFCONFIG=${1:-gki_defconfig}
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
        return 1;
    }
    // Simulate Samsung's feature detection based on feature name
    if (strstr(argv[1], "WLAN_SUPPORT_MIMO") != NULL) {
        printf("FALSE\n");
    } else if (strstr(argv[1], "BIOAUTH_CONFIG_FINGERPRINT_TZ") != NULL) {
        printf("true\n");
    } else if (strstr(argv[1], "COMMON_CONFIG_SEP_VERSION") != NULL) {
        printf("1.0\n");
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
CONFIG_DEBUG_SECTION_MISMATCH=y \
"
    # Make default configuration.
    make ${BUILD_OPTIONS} $TARGET_DEFCONFIG

    # Configure the kernel (GUI)
    make ${BUILD_OPTIONS} menuconfig

    # Set the kernel configuration, Disable unnecessary features
    ./scripts/config --file out/.config \
        -d UH \
        -d RKP \
        -d KDP \
        -d SECURITY_DEFEX \
        -d INTEGRITY \
        -d FIVE \
        -d TRIM_UNUSED_KSYMS

    # use thin lto
    if [ "$LTO" = "thin" ]; then
        ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL
    fi
}

function build_kernel() {
    # Build the kernel
    make ${BUILD_OPTIONS} Image || exit 1
    # Copy the built kernel to the build directory
    local output_kernel="${KERNEL_ROOT}/build/kernel"
    cp "${KERNEL_ROOT}/out/arch/arm64/boot/Image" "$output_kernel"
    echo -e "\n[INFO]: Kernel built successfully and copied to $output_kernel\n"
}
function repack_stock_img() {
    local stock_boot_img="$KERNEL_ROOT/stock/boot.img"
    if [ ! -f "$stock_boot_img" ]; then
        echo "[-] boot.img not found. Skipping repack."
        return 0
    fi
    local build_dir="${KERNEL_ROOT}/build"
    local output_kernel_build="$build_dir/out"
    if [ ! -d "$output_kernel_build" ]; then
        mkdir -p "$output_kernel_build"
    fi
    # local image="$output_kernel_build/boot.img"
    # cp "$stock_boot_img" "$image"
    local output_kernel_build_tools="$build_dir/tools"
    # download magiskboot
    local magiskboot="$output_kernel_build_tools/magiskboot"
    if [ ! -f "$magiskboot" ]; then
        echo "[-] magiskboot not found. Downloading..."
        mkdir -p "$output_kernel_build_tools"
        local magiskzip="$output_kernel_build/magisk.zip"
        wget https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk -O "$magiskzip"
        local output_kernel_build_tools="${KERNEL_ROOT}/build/tools"
        if [ ! -d "$output_kernel_build_tools" ]; then
            mkdir -p "$output_kernel_build_tools"
        fi
        local magiskboot_path="lib/x86_64/libmagiskboot.so"
        unzip -o "$magiskzip" "$magiskboot_path" -d "$output_kernel_build_tools"
        mv "$output_kernel_build_tools/$magiskboot_path" "$magiskboot"
        rm -rf "$output_kernel_build_tools/lib"
        chmod +x "$magiskboot"
    fi
    # Set PATCHVBMETAFLAG to enable patching of vbmeta header flags in boot image
    export PATCHVBMETAFLAG=true
    # unpack the boot.img
    cd "$output_kernel_build"
    echo "[+] Unpacking boot.img..."
    "$magiskboot" cleanup
    "$magiskboot" unpack "$stock_boot_img"
    # copy the new kernel to the boot.img
    local new_kernel="$build_dir/kernel"
    if [ ! -f "$new_kernel" ]; then
        echo "[-] Kernel not found. Skipping repack."
        return 0
    fi
    echo "[-] Old kernel: $(file kernel)"
    rm kernel
    cp "$new_kernel" kernel
    echo "[+] New kernel: $(file kernel)"
    # repack the boot.img
    echo "[+] Repacking boot.img..."
    "$magiskboot" repack "$stock_boot_img" ../boot.img
    cd -
    echo "[+] Repacked boot.img: $(file $build_dir/boot.img)"
    echo "[+] Repack: ./build/boot.img, you can flash it using odin."
    echo "[+] Repacked boot.img successfully."
}

main() {
    echo -e "\n[INFO]: BUILD STARTED..!\n"
    add_secgetspf
    prepare_toolchain
    prepare_config
    build_kernel
    repack_stock_img
    echo -e "\n[INFO]: BUILD FINISHED..!"
}
main
