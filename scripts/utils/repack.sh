prepare_magiskboot() {
    local tools_dir="./tools"
    local tools_bin_dir="$tools_dir/bin"
    local magiskboot="$tools_bin_dir/magiskboot"
    if [ ! -f "$magiskboot" ]; then
        echo "[-] magiskboot not found. Downloading..."
        if [ ! -d "$tools_dir" ]; then
            mkdir -p "$tools_dir"
        fi
        if [ ! -d "$tools_bin_dir" ]; then
            mkdir -p "$tools_bin_dir"
        fi
        local temp_dir="$tools_dir/temp"
        mkdir -p "$temp_dir"
        local magiskzip="$temp_dir/magisk.zip"
        wget https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk -O "$magiskzip"
        local magiskzip_extracted_dir="$temp_dir/magisk_extracted"
        if [ ! -d "$magiskzip_extracted_dir" ]; then
            mkdir -p "$magiskzip_extracted_dir"
        fi
        local magiskboot_path="lib/x86_64/libmagiskboot.so"
        unzip -o "$magiskzip" "$magiskboot_path" -d "$magiskzip_extracted_dir"
        mv "$magiskzip_extracted_dir/$magiskboot_path" "$magiskboot"
        rm -rf "$temp_dir"
        chmod +x "$magiskboot"
    fi
    if [ ! -f "$magiskboot" ]; then
        echo "[-] Failed to prepare magiskboot. Please check your internet connection."
        exit 1
    fi
    echo "[+] magiskboot is ready: $magiskboot"
    export MAGISKBOOT_BIN=$(realpath $magiskboot)
}

repack_stock_img() {
    local stock_boot_img=$(realpath "$1")
    local new_kernel=$(realpath "$2")
    prepare_magiskboot
    local temp_unpack_dir="./tmp_unpack"
    mkdir -p "$temp_unpack_dir"
    pushd "$temp_unpack_dir" >/dev/null
    "$MAGISKBOOT_BIN" unpack "$stock_boot_img"
    if [ -f "kernel" ]; then
        echo "[+] Removing old kernel from boot.img..."
        rm -f kernel
    else
        echo "[-] No kernel found in boot.img to remove."
        exit 1
    fi
    if [ -f "$new_kernel" ]; then
        echo "[+] Copying new kernel to boot.img..."
        cp "$new_kernel" kernel
    else
        echo "[-] New kernel not found: $new_kernel"
        exit 1
    fi
    echo "[+] New kernel added to boot.img."
    # repack the boot.img
    echo "[+] Repacking boot.img..."
    if [ ! -d "../dist" ]; then
        mkdir -p ../dist
    fi
    cp "$new_kernel" ../dist/kernel
    local target_boot_img="../dist/boot.img"
    "$MAGISKBOOT_BIN" repack "$stock_boot_img" "$target_boot_img"
    echo "[+] Repacked boot.img: $(realpath "$target_boot_img")"
    echo "[+] file: $(file "$target_boot_img")"
    popd >/dev/null
    echo "[+] Repacked boot.img successfully. You can flash it using odin."
}

update_kernel_prop() {
    # anykernel.sh
    local kernel_name="$1"
    local device_names="$2"

    sed -i "s|^kernel.string=.*|kernel.string=$kernel_name|" anykernel.sh
    # remove device.name\d=.*
    sed -i "/^device.name[1-5]/d" anykernel.sh
    # add device.name\d=r0q before supported.versions=
    local idx=1
    for device_name in $(echo "$device_names" | tr ',' ' '); do
        sed -i "s|^supported.versions=|device.name${idx}=$device_name\\nsupported.versions=|" anykernel.sh
        idx=$((idx + 1))
    done
    sed -i "s|^BLOCK=.*|BLOCK=/dev/block/by-name/boot;|" anykernel.sh
    if [ -z "$SPLIT_BOOT" ]; then
        SPLIT_BOOT="true"
    fi
    if [ "$SPLIT_BOOT" = "true" ]; then
        sed -i "s|^IS_SLOT_DEVICE=.*|IS_SLOT_DEVICE=auto;|" anykernel.sh
        # comment all line after dump_boot
        sed -i '/^dump_boot/,$ s/^/#/' anykernel.sh
        echo "split_boot;" >>anykernel.sh
        echo "flash_boot;" >>anykernel.sh
    fi
}

pack_anykernel() {
    local new_kernel=$(realpath "$1")
    local device_names="${2:-r0q,r0p,r0x}"
    local kernel_name="${3:-CustomKernel-${LOCALVERSION}}"

    local anykernel_dir="./AnyKernel3"

    if [ -d "$anykernel_dir" ]; then
        rm -rf "$anykernel_dir"
        echo "[+] Removed existing AnyKernel directory."
    fi

    echo "[+] Cloning AnyKernel3..."
    git clone --depth 1 https://github.com/osm0sis/AnyKernel3 "$anykernel_dir"
    rm -rf "$anykernel_dir/.git"
    echo "[+] Cloning arm64-tools branch of AnyKernel3..."
    git clone --depth 1 --branch arm64-tools https://github.com/osm0sis/AnyKernel3 "$anykernel_dir/tools_arm64"
    rm -rf "$anykernel_dir/tools_arm64/.git"
    cp -r "$anykernel_dir/tools_arm64"/* "$anykernel_dir/tools/"
    rm -rf "$anykernel_dir/tools_arm64"

    pushd "$anykernel_dir" >/dev/null
    cp "$new_kernel" zImage
    update_kernel_prop "$kernel_name" "$device_names"

    local targetZip="../dist/AnyKernel.zip"
    if [ ! -d "../dist" ]; then
        mkdir -p ../dist
    fi
    if [ -f "$targetZip" ]; then
        rm -f "$targetZip"
        echo "[+] Removed existing AnyKernel.zip."
    fi

    zip -r9 "$targetZip" * -x "*.zip" "*.git*" "README.md"
    echo "[+] AnyKernel.zip created: $(realpath "$targetZip")"
    popd >/dev/null
}

# Get kernel version from Makefile
__get_kernel_version() {
    local kernel_root="$KERNEL_ROOT"
    if [ -z "$kernel_root" ]; then
        echo "[-] Error: kernel_root is not set"
        return 1
    fi

    if [ ! -f "$kernel_root/Makefile" ]; then
        echo "[-] Error: Makefile not found in $kernel_root"
        return 1
    fi

    # Get the kernel version from the Makefile
    local version=$(grep -E '^VERSION =|^PATCHLEVEL =|^SUBLEVEL =' "$kernel_root/Makefile" | awk '{print $3}' | tr '\n' '.')
    # Remove the trailing dot
    version=${version%.}
    echo "$version"
}

__get_susfs_version() {
    pushd "$KERNEL_ROOT" >/dev/null
    local SUSFS_VERSION=""
    if [ -f "include/linux/susfs.h" ]; then
        SUSFS_VERSION=$(cat include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')
    fi
    echo "${SUSFS_VERSION:-Not found}"
    popd >/dev/null
}
__get_ksu_version() {
    pushd "$KERNEL_ROOT" >/dev/null
    local KSU_VERSION=""
    if [ -d "drivers/kernelsu" ]; then
        cd drivers/kernelsu
        local KSU_LOCAL_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo "0")
        KSU_VERSION=$((10000 + $KSU_LOCAL_VERSION + 200))
        cd - >/dev/null
    fi
    echo "${KSU_VERSION:-Not found}"
    popd >/dev/null
}
__get_config_value() {
    if [ -z "$KERNEL_ROOT" ]; then
        echo "[-] KERNEL_ROOT is not set. Please set it to the root of your kernel source."
        exit 1
    fi
    local source_details_file="$KERNEL_ROOT/source_details.config"
    if [ ! -f "$source_details_file" ]; then
        echo "[-] source_details.config not found in $KERNEL_ROOT. Please run the script to save source details."
        return 1
    fi
    local value=$(grep "^$1=" "$source_details_file" | cut -d'=' -f2-)
    if [ -z "$value" ]; then
        return 1
    fi
    echo "$value"
}

generate_info() {
    if [ -z "$KERNEL_ROOT" ]; then
        echo "[-] KERNEL_ROOT is not set. Please set it to the root of your kernel source."
        exit 1
    fi
    if [ ! -d "./dist" ]; then
        mkdir -p ./dist
    fi
    local CONFIG_FILE=$(__get_config_value "CONFIG_FILE")
    local KERNEL_SOURCE_URL=$(__get_config_value "KERNEL_SOURCE_URL")
    local KERNEL_BOOT_IMG_URL=$(__get_config_value "KERNEL_BOOT_IMG_URL")
    local TOOLCHAINS_URL=$(__get_config_value "TOOLCHAINS_URL")
    local ksu_platform=$(__get_config_value "ksu_platform")
    local ksu_install_script=$(__get_config_value "ksu_install_script")
    local ksu_branch=$(__get_config_value "ksu_branch")
    local ksu_add_susfs=$(__get_config_value "ksu_add_susfs")
    local susfs_repo=$(__get_config_value "susfs_repo")
    local susfs_branch=$(__get_config_value "susfs_branch")

    local build_date=$(date '+%Y-%m-%d %H:%M:%S')
    local kernel_version=$(__get_kernel_version)
    local susfs_version=$(__get_susfs_version)
    local ksu_version=$(__get_ksu_version)

    cat >"./dist/build_info.txt" <<EOF
Kernel Build Information
========================
Build Date: $build_date
Kernel Version: $kernel_version
Local Version: $LOCALVERSION
SUSFS Version: $susfs_version
KSU Version: $ksu_version
Architecture: $ARCH
Compiler: $(clang --version | head -n1)

Configuration Details
=====================
CONFIG_FILE: $CONFIG_FILE
KERNEL_SOURCE_URL: $KERNEL_SOURCE_URL
KERNEL_BOOT_IMG_URL: $KERNEL_BOOT_IMG_URL
TOOLCHAINS_URL: $TOOLCHAINS_URL
KSU Platform: $ksu_platform
KSU Install Script: $ksu_install_script
KSU Branch: $ksu_branch
KSU Add SUSFS: $ksu_add_susfs
SUSFS Repo: $susfs_repo
SUSFS Branch: $susfs_branch
EOF
    echo "[+] Build info saved to ./dist/build_info.txt"
}
