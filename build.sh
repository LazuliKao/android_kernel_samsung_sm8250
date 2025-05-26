#!/bin/bash
official_source="SM-T870_EUR_13_Opensource.zip" # change it with you downloaded file
build_root=$(pwd)
kernel_root="$build_root/kernel_source"
toolchains_root="$build_root/toolchains"
kernel_su_next_branch="next-susfs-dev"
susfs_branch="kernel-4.19"

function clean() {
    rm -rf "$kernel_root"
}

custom_config_name="pineapple_gki_defconfig"
custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
function get_kernel_version() {
    cd "$kernel_root"
    if command -v make &>/dev/null; then
        make kernelversion 2>/dev/null
    else
        echo "make command not found. Please install the build tools."
        exit 1
    fi
}
_set_config() {
    key=$1
    value=$2
    original=$(grep "^$key=" "$custom_config_file" | cut -d'=' -f2)
    echo "Setting $key=$value (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1$value/" "$custom_config_file"
}
_set_config_quote() {
    key=$1
    value=$2
    original=$(grep "^$key=" "$custom_config_file" | cut -d'=' -f2)
    echo "Setting $key=\"$value\" (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1\"$value\"/" "$custom_config_file"
}
_get_config() {
    key=$1
    grep "^$key=" "$custom_config_file" | cut -d'=' -f2
}
_set_or_add_config() {
    key=$1
    value=$2
    if grep -q "^$key=" "$custom_config_file"; then
        _set_config "$key" "$value"
    else
        echo "$key=$value" >>"$custom_config_file"
        echo "Added $key=$value to $custom_config_file"
    fi
}
function download_toolchains() {
    mkdir -p "$toolchains_root"
    # Clone proton clang 12 if not already done
    if [ ! -d "$toolchains_root/proton-12" ]; then
        git clone --depth=1 https://github.com/ravindu644/proton-12.git "$toolchains_root/proton-12"
    fi
    # Download and extract Linaro 7.5 if not already done
    if [ ! -d "$toolchains_root/aarch64-linaro-7.5" ]; then
        cd "$toolchains_root"
        wget https://kali.download/nethunter-images/toolchains/linaro-aarch64-7.5.tar.xz
        tar -xvf linaro-aarch64-7.5.tar.xz && rm linaro-aarch64-7.5.tar.xz
    fi
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
        lz4 -d -f boot.img.lz4 boot.img
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
    tail -n +2 boot.img.build.conf >"$custom_config_file"
    echo "[+] Kernel config updated successfully."
    echo "[+] Kernel config file: $custom_config_file"
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
function add_kernelsu_next() {
    echo "[+] Adding KernelSU Next..."
    cd "$kernel_root"
    curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -s "$kernel_su_next_branch"
    cd "$build_root"
    echo "[+] KernelSU Next added successfully."
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
    patch -p1 <50_add_susfs_in_$susfs_branch.patch 2>&1 | tee patch_output.log
    echo "[+] Checking for rejected patches..."
# 2 out of 16 hunks FAILED -- saving rejects to file fs/namespace.c.rej
# 1 out of 4 hunks FAILED -- saving rejects to file fs/notify/fdinfo.c.rej
# 1 out of 1 hunk FAILED -- saving rejects to file fs/overlayfs/readdir.c.rej
# 1 out of 3 hunks FAILED -- saving rejects to file fs/proc/task_mmu.c.rej
# 1 out of 5 hunks FAILED -- saving rejects to file fs/readdir.c.rej
# 1 out of 1 hunk FAILED -- saving rejects to file include/linux/mount.h.rej
# 2 out of 2 hunks FAILED -- saving rejects to file include/linux/sched.h.rej
    local patch_result=$(patch -p1 <"$build_root/kernel_patches/51_solve_rejected_susfs.patch")
    if [ $? -ne 0 ]; then
        echo "$patch_result"
        echo "[-] Failed to apply SuSFS patches."
        echo "$patch_result" | grep -q ".rej"
        exit 1
    else
        echo "[+] SuSFS patches applied successfully."
        echo "$patch_result" | grep -q ".rej"
    fi
    echo "[+] SuSFS added successfully."
}
function fix_kernel_su_next_susfs() {
    echo "[+] Applying kernel config tweaks fix susfs with ksun..."
    _set_or_add_config CONFIG_KSU_SUSFS_SUS_SU n
    echo "[+] Fix building KernelSU Next with SuSFS..."
    cd "$kernel_root"
    patch -p1 <"$build_root/kernel_patches/fix_ksun_with_susfs.patch"
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply fix patch for KernelSU Next with SuSFS."
        exit 1
    fi
    echo "[+] KernelSU Next with SuSFS fix applied successfully."
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

    #Force Load Kernel Modules
    _set_or_add_config CONFIG_MODULES y
    _set_or_add_config CONFIG_MODULE_FORCE_LOAD y
    _set_or_add_config CONFIG_MODULE_UNLOAD y
    _set_or_add_config CONFIG_MODULE_FORCE_UNLOAD y
    _set_or_add_config CONFIG_MODVERSIONS y
    _set_or_add_config CONFIG_MODULE_SRCVERSION_ALL n
    _set_or_add_config CONFIG_MODULE_SIG n
    _set_or_add_config CONFIG_MODULE_COMPRESS n
    _set_or_add_config CONFIG_TRIM_UNUSED_KSYMS n

    echo "[+] Driver fix patch applied successfully."
}
function fix_samsung_securities() {
    # Disable Samsung Securities
    _set_or_add_config CONFIG_UH n
    _set_or_add_config CONFIG_UH_RKP n
    _set_or_add_config CONFIG_UH_LKMAUTH n
    _set_or_add_config CONFIG_UH_LKM_BLOCK n
    _set_or_add_config CONFIG_RKP_CFP_JOPP n
    _set_or_add_config CONFIG_RKP_CFP n
    _set_or_add_config CONFIG_SECURITY_DEFEX n
    _set_or_add_config CONFIG_PROCA n
    _set_or_add_config CONFIG_FIVE n
}
function add_build_script() {
    echo "[+] Adding build script..."
    cp "$build_root/build_kernel_4.19.sh" "$kernel_root/build.sh"
    sed -i "s/gki_defconfig/$custom_config_name/" "$kernel_root/build.sh"
    chmod +x "$kernel_root/build.sh"
    echo "[+] Build script added successfully."
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
    docker build -t sm8250-kernel-builder .

    if [ $? -ne 0 ]; then
        echo "[-] Failed to build Docker image."
        return 1
    fi

    echo "[+] Docker image 'sm8250-kernel-builder' built successfully."
    echo "[+] You can now use the container to build the kernel."
    echo ""
    echo "To run a one-time container and build the kernel, use:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" -v \"$toolchains_root:/toolchains\" sm8250-kernel-builder /workspace/build.sh"
    echo ""
    echo "This will mount your current directory to /workspace in the container"
    echo "and run the build.sh script inside the container."
    echo ""
    echo "If you want to open a shell in the container for manual operations:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" -v \"$toolchains_root:/toolchains\" sm8250-kernel-builder /bin/bash"

    return 0
}

function main() {
    if [ "$1" = "container" ]; then
        build_container
        return $?
    fi

    download_toolchains
    clean
    prepare_source
    extract_kernel_config
    add_kernelsu_next
    add_susfs
    fix_kernel_su_next_susfs
    fix_driver_check
    fix_samsung_securities
    add_build_script

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
