#!/bin/bash
official_source="SM-T870_EUR_13_Opensource.zip" # change it with you downloaded file
build_root=$(pwd)
kernel_root="$build_root/kernel_source"
kernel_su_next_branch="next-susfs-dev"
susfs_branch="kernel-4.19"

function clean() {
    rm -rf "$kernel_root"
}
function get_kernel_version() {
    cd "$kernel_root"
    if command -v make &>/dev/null; then
        make kernelversion 2>/dev/null
    else
        echo "make command not found. Please install make."
        exit 1
    fi
    cd - >/dev/null
}
function prepare_source() {
    if [ ! -d "$kernel_root" ]; then
        # extract the official source code
        echo "[+] Extracting official source code..."
        if [ ! -f "Kernel.tar.gz" ]; then
            echo "[+] Kernel.tar.gz not found. Extracting from $official_source..."
            if [ ! -f "$official_source" ]; then
                echo "Please download the official source code from Samsung Open Source Release Center."
                echo "link: https://opensource.samsung.com/uploadSearch?searchValue=T870"
                exit 1
            fi
            unzip -o -q "$official_source" "Kernel.tar.gz"
        fi
        # extract the kernel source code
        local kernel_source_tar="Kernel.tar.gz"
        echo "[+] Extracting kernel source code..."
        mkdir -p "$kernel_root"
        tar -xzf "$kernel_source_tar" -C "$kernel_root"
        if [ ! -d "$kernel_root" ]; then
            echo "Kernel source code not found. Please check the official source code."
            exit 1
        fi
        cd "$kernel_root"
        echo "[+] Checking kernel version..."
        local kernel_version=$(get_kernel_version)
        local kernel_kmi_version=$(echo $kernel_version | cut -d '.' -f 1-2)
        echo "[+] Kernel version: $kernel_version, KMI version: $kernel_kmi_version"
        # only support 4.19
        if [ "$kernel_kmi_version" != "4.19" ]; then
            echo "Kernel version is not 4.19. Please check the official source code."
            exit 1
        fi
        echo "[+] Setting up permissions..."
        chmod 777 -R "$kernel_root"
        echo "[+] Kernel source code extracted successfully."
    fi
}
function add_kernelsu_next() {
    echo "[+] Adding KernelSU Next..."
    cd "$kernel_root"
    curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s "$kernel_su_next_branch"
    cd "$build_root"
    echo "[+] KernelSU Next added successfully."
}
function __fix_patch() {
    cp "$build_root/kernel_patches/fix_patch.patch" "$kernel_root"
    echo "[+] Fixing patch..."
    cd "$kernel_root"
    patch -p1 -l <fix_patch.patch
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply fix patch."
        exit 1
    fi
    echo "[+] Fix patch applied successfully."
}
function __restore_fix_patch() {
    echo "[+] Restoring fix patch..."
    cp "$build_root/kernel_patches/fix_patch_reverse.patch" "$kernel_root"
    cd "$kernel_root"
    patch -p1 -l <fix_patch_reverse.patch
    if [ $? -ne 0 ]; then
        echo "[-] Failed to restore fix patch."
        exit 1
    fi
    echo "[+] Fix patch restored successfully."
}
function add_susfs() {
    local susfs_dir="$build_root/susfs"
    if [ ! -d "$susfs_dir" ]; then
        echo "[+] Cloning susfs4ksu repository..."
        git clone https://gitlab.com/simonpunk/susfs4ksu.git --depth 1 -b "$susfs_branch" "$susfs_dir"
    else
        echo "[+] Updating susfs4ksu repository..."
        cd "$susfs_dir"
        git fetch origin "$susfs_branch"
        git checkout "$susfs_branch"
        git pull origin "$susfs_branch"
        cd "$build_root"
    fi
    if [ ! -d "$susfs_dir" ]; then
        echo "Failed to clone susfs4ksu repository."
        exit 1
    fi
    echo "[+] SuSFS4ksu repository cloned successfully."
    echo "[+] Copying SuSFS source code..."
    cp "$susfs_dir/kernel_patches/50_add_susfs_in_$susfs_branch.patch" "$kernel_root"
    if [ -d "$susfs_dir/kernel_patches/fs" ]; then
        cp -r "$susfs_dir/kernel_patches/fs/"* "$kernel_root/fs/"
    else
        echo "[-] Warning: $susfs_dir/kernel_patches/fs directory not found"
    fi

    if [ -d "$susfs_dir/kernel_patches/include" ]; then
        cp -r "$susfs_dir/kernel_patches/include/"* "$kernel_root/include/"
    else
        echo "[-] Warning: $susfs_dir/kernel_patches/include directory not found"
    fi
    echo "[+] Applying SuSFS patches..."
    cd "$kernel_root"
    __fix_patch # remove some samsung's changes, then susfs can be applied
    local patch_result=$(patch -p1 <50_add_susfs_in_$susfs_branch.patch)
    if [ $? -ne 0 ]; then
        echo "$patch_result"
        echo "[-] Failed to apply SuSFS patches."
        echo "$patch_result" | grep -q ".rej"
        exit 1
    else
        echo "[+] SuSFS patches applied successfully."
        echo "$patch_result" | grep -q ".rej"
    fi
    __restore_fix_patch # restore removed samsung's changes
    echo "[+] SuSFS added successfully."
}

function add_build_script() {
    echo "[+] Adding build script..."
    cp "$build_root/build_kernel_4.19.sh" "$kernel_root/build.sh"
    chmod +x "$kernel_root/build.sh"
    echo "[+] Build script added successfully."
}

function extract_kernel_config() {
    cd "$build_root"
    local tools_dir="$build_root/tools"
    if [ ! -d "$tools_dir" ]; then
        mkdir "$tools_dir"
    fi
    local kptools="$tools_dir/kptools-linux"
    # if kptools-linux not exists, download it
    if [ ! -f "$kptools" ]; then
        echo "kptools-linux not found, downloading..."
        wget https://github.com/bmax121/KernelPatch/releases/latest/download/kptools-linux -O "$kptools"
        chmod +x "$kptools"
    fi
    if [ -f "boot.img.lz4" ]; then
        # use lz4 to decompress it
        lz4 -d boot.img.lz4 boot.img
    else
        if [ -f "boot.img" ]; then
            echo "boot.img already exists, skipping decompression."
        else
            echo "[-] boot.img not found."
            echo "[-] boot.img.lz4 not found, please put it in the current directory."
            echo "     Where to get boot.img?"
            echo "     - Downlaod the samsung firmware match your phone, extract it, and extract the boot.img.lz4 from the 'AP_...tar.md5'"
            exit 1
        fi
    fi
    echo "[+] boot.img decompressed successfully."
    # extract official kernel config from boot.img
    "$kptools" -i boot.img -f >boot.img.build.conf
    echo "[+] Kernel config extracted successfully."
    # see the kernel version of official kernel
    echo "[+] Kernel version of official kernel:"
    "$kptools" -i boot.img -d | head -n 3
    # copy the extracted kernel config to the kernel source and build using it
    echo "[+] Copying kernel config to the kernel source..."
    tail -n +2 boot.img.build.conf >"$kernel_root/arch/arm64/configs/gki_defconfig"
    echo "[+] Applying kernel config tweaks..."
    cat <<EOF >>"$kernel_root/arch/arm64/configs/gki_defconfig"
# Disable Samsung Securities
CONFIG_UH=n
CONFIG_UH_RKP=n
CONFIG_UH_LKMAUTH=n
CONFIG_UH_LKM_BLOCK=n
CONFIG_RKP_CFP_JOPP=n
CONFIG_RKP_CFP=n
CONFIG_SECURITY_DEFEX=n
CONFIG_PROCA=n
CONFIG_FIVE=n

#Force Load Kernel Modules
CONFIG_MODULES=y
CONFIG_MODULE_FORCE_LOAD=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODULE_FORCE_UNLOAD=y
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=n
CONFIG_MODULE_SIG=n
CONFIG_MODULE_COMPRESS=n
CONFIG_TRIM_UNUSED_KSYMS=n

# fix ksun
CONFIG_KSU_SUSFS=n
EOF
    echo "[+] Kernel config updated successfully."
    echo "[+] Kernel config file: $kernel_root/arch/arm64/configs/gki_defconfig"
    echo "[+] Copying stock boot.img to the kernel source..."
    local stock_boot_img="$kernel_root/stock"
    if [ ! -d "$stock_boot_img" ]; then
        mkdir "$stock_boot_img"
    fi
    cp boot.img "$stock_boot_img"
    if [ $? -ne 0 ]; then
        echo "[-] Failed to copy stock boot.img."
        exit 1
    fi
    echo "[+] Stock boot.img copied successfully."
}

function fix_driver_check() {
    # ref to: https://github.com/ravindu644/Android-Kernel-Tutorials/blob/main/patches/010.Disable-CRC-Checks.patch
    cd "$build_root"
    cp "$build_root/kernel_patches/driver_fix.patch" "$kernel_root"
    cd "$kernel_root"
    patch -p1 <driver_fix.patch
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply driver fix patch."
        exit 1
    fi
    echo "[+] Driver fix patch applied successfully."
}

function build_container() {
    echo "[+] Building Docker container for kernel compilation..."

    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        echo "[-] Docker is not installed. Please install Docker first."
        echo "    Visit https://docs.docker.com/engine/install/ for installation instructions."
        return 1
    fi

    # Build Docker image from Dockerfile
    cd "$build_root"
    docker build -t sm8450-kernel-builder .

    if [ $? -ne 0 ]; then
        echo "[-] Failed to build Docker image."
        return 1
    fi

    echo "[+] Docker image 'sm8450-kernel-builder' built successfully."
    echo "[+] You can now use the container to build the kernel."
    echo ""
    echo "To run a one-time container and build the kernel, use:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" sm8450-kernel-builder /workspace/build.sh"
    echo ""
    echo "This will mount your current directory to /workspace in the container"
    echo "and run the build.sh script inside the container."
    echo ""
    echo "If you want to open a shell in the container for manual operations:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" sm8450-kernel-builder /bin/bash"

    return 0
}

function main() {
    if [ "$1" = "container" ]; then
        build_container
        return $?
    fi

    clean
    prepare_source
    add_kernelsu_next
    add_susfs
    add_build_script
    extract_kernel_config

    echo "[+] All done. You can now build the kernel."
    echo "[+] Please 'cd $kernel_root'"
    echo "[+] Run the build script with ./build.sh"
    echo ""
    echo "To build using Docker container instead:"
    echo "./build.sh container"
}

# If the first argument is "container", only build the container
if [ "$1" = "container" ]; then
    build_container
    exit $?
else
    main
fi
