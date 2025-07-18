KERNELSU_INSTALL_SCRIPT="${ksu_install_script:-https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh}"
SUSFS_REPO="${susfs_repo:-https://gitlab.com/simonpunk/susfs4ksu.git}"
export GIT_ADVICE_DETACHED_HEAD=false
BUILD_USING_OVERLAY=${build_using_overlay:-true}

# OverlayFS utility function
setup_overlay() {
    local source_dir="$1"
    local overlay_base="$build_root/overlay"
    local kernel_edit_dir="$build_root/kernel_edit"
    
    if [ ! -d "$source_dir" ]; then
        echo "[-] Source directory $source_dir does not exist."
        return 1
    fi
    
    echo "[+] Setting up overlayfs for kernel source..."
    
    # Create necessary directories
    local upper_dir="$overlay_base/upper"
    local work_dir="$overlay_base/work"
    
    mkdir -p "$upper_dir"
    mkdir -p "$work_dir"
    mkdir -p "$kernel_edit_dir"
    
    # Check if overlayfs is already mounted
    if mountpoint -q "$kernel_edit_dir"; then
        echo "[+] Overlayfs already mounted at $kernel_edit_dir"
        return 0
    fi
    
    # Mount overlayfs
    echo "[+] Mounting overlayfs..."
    echo "    Lower: $source_dir"
    echo "    Upper: $upper_dir"
    echo "    Work:  $work_dir"
    echo "    Mount: $kernel_edit_dir"
    
    if ! mount -t overlay overlay \
        -o "lowerdir=$source_dir,upperdir=$upper_dir,workdir=$work_dir" \
        "$kernel_edit_dir"; then
        echo "[-] Failed to mount overlayfs. You might need root permissions."
        echo "[-] Try running with sudo or check if overlayfs is supported."
        return 1
    fi
    
    echo "[+] Overlayfs mounted successfully at $kernel_edit_dir"
    return 0
}

# Cleanup overlay mount
cleanup_overlay() {
    local kernel_edit_dir="$build_root/kernel_edit"
    
    if mountpoint -q "$kernel_edit_dir"; then
        echo "[+] Unmounting overlayfs..."
        if umount "$kernel_edit_dir"; then
            echo "[+] Overlayfs unmounted successfully."
        else
            echo "[-] Failed to unmount overlayfs. You might need root permissions."
            return 1
        fi
    fi
    return 0
}
clean() {
    # if build using overlay, remove the overlay directory
    if [ "$BUILD_USING_OVERLAY" = true ]; then
        echo "[+] Cleaning overlay directory..."
        cleanup_overlay
        local overlay_dir="$build_root/overlay"
        local kernel_edit_dir="$build_root/kernel_edit"
        if [ -d "$overlay_dir" ]; then
            rm -rf "$overlay_dir"
            echo "[+] Overlay directory cleaned."
        else
            echo "[-] Overlay directory not found, skipping clean."
        fi
        if [ -d "$kernel_edit_dir" ]; then
            rmdir "$kernel_edit_dir" 2>/dev/null || true
        fi
    else
        echo "[+] Cleaning kernel source directory..."
        rm -rf "$kernel_root"
        if [ -d "susfs" ]; then
            rm -rf "susfs"
        fi
    fi
}

prepare_source() {
    local use_strip_components=${1:-true}
    local original_kernel_root="$kernel_root"
    
    # Check if we should use overlay mode
    if [ "$BUILD_USING_OVERLAY" = true ]; then
        echo "[+] Using overlay mode for kernel source..."
        # Use a different directory name for the original source
        original_kernel_root="${kernel_root}_source"
    fi
    
    if [ ! -d "$original_kernel_root" ]; then
        # extract the official source code
        echo "[+] Extracting official source code..."
        if [ ! -f "Kernel.tar.gz" ]; then
            echo "[+] Kernel.tar.gz not found. Extracting from $official_source..."
            if [ ! -f "$official_source" ]; then
                echo "Please download the official source code from Samsung Open Source Release Center."
                echo "link: $kernel_source_link"
                exit 1
            fi
            unzip -o -q "$official_source" "Kernel.tar.gz"
        fi
        # extract the kernel source code
        local kernel_source_tar="Kernel.tar.gz"
        echo "[+] Extracting kernel source code..."
        mkdir -p "$original_kernel_root"
        if [ "$use_strip_components" = true ]; then
            tar -xzf "$kernel_source_tar" -C "$original_kernel_root" --strip-components=3 "./kernel_platform/common"
        else
            tar -xzf "$kernel_source_tar" -C "$original_kernel_root"
        fi
        if [ ! -d "$original_kernel_root" ]; then
            echo "Kernel source code not found. Please check the official source code."
            exit 1
        fi
        cd "$original_kernel_root"
        echo "[+] Checking kernel version..."
        local kernel_version=$(get_kernel_version "$original_kernel_root")
        local kernel_kmi_version=$(echo $kernel_version | cut -d '.' -f 1-2)
        echo "[+] Kernel version: $kernel_version, KMI version: $kernel_kmi_version"
        if [ "$kernel_kmi_version" != "$support_kernel" ]; then
            echo "Kernel version is not $support_kernel. Please check the official source code."
            exit 1
        fi
        echo "[+] Setting up permissions..."
        chmod 777 -R "$original_kernel_root"
        echo "[+] Kernel source code extracted successfully."
    fi
    
    # Setup overlay if enabled
    if [ "$BUILD_USING_OVERLAY" = true ]; then
        if setup_overlay "$original_kernel_root"; then
            # Override kernel_root to point to the overlay mount
            export kernel_root="$build_root/kernel_edit"
            echo "[+] Kernel root overridden to use overlay: $kernel_root"
        else
            echo "[-] Failed to setup overlay, falling back to direct mode."
            export kernel_root="$original_kernel_root"
        fi
    fi
}

prepare_source_git() {
    local kernel_source_git="$1"
    local kernel_source_branch="$2"
    if [ -z "$kernel_source_git" ] || [ -z "$kernel_source_branch" ]; then
        echo "[-] Kernel source git URL or branch is not set."
        exit 1
    fi
    
    local original_kernel_root="$kernel_root"
    
    # Check if we should use overlay mode
    if [ "$BUILD_USING_OVERLAY" = true ]; then
        echo "[+] Using overlay mode for kernel source..."
        # Use a different directory name for the original source
        original_kernel_root="${kernel_root}_source"
    fi
    
    if [ ! -d "$original_kernel_root" ]; then
        echo "[+] Cloning kernel source from git..."
        git clone --depth 1 -b "$kernel_source_branch" "$kernel_source_git" "$original_kernel_root"
        if [ $? -ne 0 ]; then
            echo "[-] Failed to clone kernel source from git."
            exit 1
        fi
        cd "$original_kernel_root"
        echo "[+] Kernel source cloned successfully."
    else
        echo "[+] Kernel source already exists, skipping clone."
        cd "$original_kernel_root"
    fi
    
    echo "[+] Checking kernel version..."
    local kernel_version=$(get_kernel_version "$original_kernel_root")
    local kernel_kmi_version=$(echo $kernel_version | cut -d '.' -f 1-2)
    echo "[+] Kernel version: $kernel_version, KMI version: $kernel_kmi_version"
    if [ "$kernel_kmi_version" != "$support_kernel" ]; then
        echo "Kernel version is not $support_kernel. Please check the official source code."
        exit 1
    fi
    echo "[+] Setting up permissions..."
    chmod 777 -R "$original_kernel_root"
    echo "[+] Kernel source code prepared successfully."
    
    # Setup overlay if enabled
    if [ "$BUILD_USING_OVERLAY" = true ]; then
        if setup_overlay "$original_kernel_root"; then
            # Override kernel_root to point to the overlay mount
            export kernel_root="$build_root/kernel_edit"
            echo "[+] Kernel root overridden to use overlay: $kernel_root"
        else
            echo "[-] Failed to setup overlay, falling back to direct mode."
            export kernel_root="$original_kernel_root"
        fi
    fi
}

extract_kernel_config() {
    cd "$build_root"
    local tools_dir="$build_root/tools"
    if [ ! -d "$tools_dir" ]; then
        mkdir "$tools_dir"
    fi
    local kptools="$tools_dir/kptools-linux"
    # if kptools-linux not exists, download it
    if [ ! -f "$kptools" ]; then
        echo "kptools-linux not found, downloading..."
        wget https://github.com/bmax121/KernelPatch/releases/download/0.11.3/kptools-linux -O "$kptools"
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
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
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
    # https://github.com/ravindu644/Android-Kernel-Tutorials/?tab=readme-ov-file#02-fix-theres-an-internal-problem-with-your-device-issue
    cd "$kernel_root"
    echo "[+] Copy stock_config to kernel source..."
    tail -n +2 "$build_root/boot.img.build.conf" >"$kernel_root/arch/arm64/configs/stock_defconfig"

    local with_patch="$1"
    if [ "$with_patch" = true ]; then
        echo "[+] Fix: 'There's an internal problem with your device.' issue."
        # $(obj)/config_data.gz: .*
        # $(obj)/config_data.gz: arch/arm64/configs/stock_defconfig FORCE
        sed -i 's/$(obj)\/config_data\.gz: .*/$(obj)\/config_data\.gz: arch\/arm64\/configs\/stock_defconfig FORCE/' "$kernel_root/kernel/Makefile"
        echo "[+] Fix applied successfully."
    fi
}

add_kernelsu_next() {
    echo "[+] Adding KernelSU Next..."
    cd "$kernel_root"
    curl -LSs "$KERNELSU_INSTALL_SCRIPT" | bash -s "$ksu_branch"
    cd "$build_root"
    echo "[+] KernelSU Next added successfully."
}

fix_kernel_su_next_susfs() {
    echo "[+] Applying kernel config tweaks fix susfs with ksun..."
    _set_or_add_config CONFIG_KSU_SUSFS_SUS_SU n
    echo "[+] KernelSU Next with SuSFS fix applied successfully."
}

apply_kernelsu_manual_hooks_for_next() {
    prepare_wild_patches
    echo "[+] Applying syscall hooks..."
    cd "$kernel_root"
    if ! _apply_patch "wild_kernels/next/syscall_hooks.patch"; then
        echo "[-] Failed to apply syscall hooks patch"
        exit 1
    fi
    echo "[+] Syscall hooks applied successfully."
    cd - >/dev/null
    _set_or_add_config CONFIG_KSU_KPROBES_HOOK n
    _set_or_add_config CONFIG_KSU_WITH_KPROBES n
    _set_or_add_config CONFIG_KSU_MANUAL_HOOK y
}

apply_wild_kernels_config() {
    # Add additional tmpfs config setting
    _set_or_add_config CONFIG_TMPFS_XATTR y
    _set_or_add_config CONFIG_TMPFS_POSIX_ACL y

    # Add additional config setting
    _set_or_add_config CONFIG_IP_NF_TARGET_TTL y
    _set_or_add_config CONFIG_IP6_NF_TARGET_HL y
    _set_or_add_config CONFIG_IP6_NF_MATCH_HL y

    # Add BBR Config
    _set_or_add_config CONFIG_TCP_CONG_ADVANCED y
    _set_or_add_config CONFIG_TCP_CONG_BBR y
    _set_or_add_config CONFIG_NET_SCH_FQ y
    _set_or_add_config CONFIG_TCP_CONG_BIC n
    _set_or_add_config CONFIG_TCP_CONG_WESTWOOD n
    _set_or_add_config CONFIG_TCP_CONG_HTCP n
}

prepare_wild_patches() {
    # check if wild_kernels directory exists
    local wild_kernels_dir="$build_root/kernel_patches/wild_kernels"
    if [ ! -d "$wild_kernels_dir" ]; then
        echo "[+] Cloning Wild Kernels repository..."
        git clone https://github.com/WildKernels/kernel_patches.git "$wild_kernels_dir" --depth 1
        if [ $? -ne 0 ]; then
            echo "[-] Failed to clone Wild Kernels repository."
            exit 1
        fi
    else
        echo "[+] Wild Kernels repository already exists, updating..."
        cd "$wild_kernels_dir"
        git fetch origin
        git reset --hard origin/main
        if [ $? -ne 0 ]; then
            echo "[-] Failed to update Wild Kernels repository."
            exit 1
        fi
        cd - >/dev/null
    fi
}

apply_wild_kernels_fix_for_next() {
    prepare_wild_patches
    echo "[+] Applying Wild Kernels fix..."
    cd "$kernel_root"

    local patches=(
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_apk_sign.c.patch"
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_core_hook.c.patch"
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_ksud.c.patch"
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_rules.c.patch"
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_selinux.c.patch"
        "wild_kernels/next/susfs_fix_patches/v1.5.9/fix_sucompat.c.patch"
        "wild_kernels/next/manager.patch"
        "wild_kernels/69_hide_stuff.patch"
    )

    for patch in "${patches[@]}"; do
        if ! _apply_patch "$patch"; then
            echo "[-] Failed to apply wild kernels patch: $patch"
            exit 1
        fi
    done

    echo "[+] Wild Kernels fix applied successfully."
    cd - >/dev/null
}

fix_driver_check() {
    # ref to: https://github.com/ravindu644/Android-Kernel-Tutorials/blob/main/patches/010.Disable-CRC-Checks.patch
    cd "$kernel_root"
    if ! _apply_patch "driver_fix.patch"; then
        echo "[-] Failed to apply driver fix patch"
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

add_kprobes() {
    _set_or_add_config CONFIG_KPROBES y
    _set_or_add_config CONFIG_HAVE_KPROBES y
    _set_or_add_config CONFIG_KPROBE_EVENTS y
}
fix_samsung_securities() {
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

    _set_or_add_config CONFIG_SECURITY_DSMS n
    _set_or_add_config CONFIG_KSM y

    _set_or_add_config CONFIG_BUILD_ARM64_KERNEL_COMPRESSION_GZIP y
    _set_or_add_config CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL n

    _set_or_add_config CONFIG_CFP n
    _set_or_add_config CONFIG_CFP_JOPP n
    _set_or_add_config CONFIG_CFP_ROPP n
}

add_build_script() {
    echo "[+] Adding build script..."
    cp "$build_root/$kernel_build_script" "$kernel_root/build.sh"
    cp "$build_root/scripts/utils/repack.sh" "$kernel_root/repack.sh"
    sed -i "s#gki_defconfig#$custom_config_name#" "$kernel_root/build.sh"
    chmod +x "$kernel_root/build.sh"
    chmod +x "$kernel_root/repack.sh"
    echo "[+] Build script added successfully."
}

print_docker_usage() {
    echo "To build the kernel using Docker, run:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" -v \"$toolchains_root:/toolchains\" $container_name /workspace/build.sh"
    echo ""
    echo "This will mount your current directory to /workspace in the container"
    echo "and run the build.sh script inside the container."
    echo ""
    echo "If you want to open a shell in the container for manual operations:"
    echo "docker run --rm -it -v \"$kernel_root:/workspace\" -v \"$toolchains_root:/toolchains\" $container_name /bin/bash"
}

build_container() {
    echo "[+] Building Docker container for kernel compilation..."

    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        echo "[-] Docker is not installed. Please install Docker first."
        echo "    Visit https://docs.docker.com/engine/install/ for installation instructions."
        return 1
    fi

    # Build Docker image from Dockerfile
    cd "$build_root"
    docker build -t $container_name .

    if [ $? -ne 0 ]; then
        echo "[-] Failed to build Docker image."
        return 1
    fi

    echo "[+] Docker image '$container_name' built successfully."
    echo "[+] You can now use the container to build the kernel."
    print_docker_usage

    return 0
}

add_susfs_prepare() {
    local susfs_dir="$build_root/susfs"
    if [ ! -d "$susfs_dir" ]; then
        echo "[+] Cloning susfs4ksu repository..."
        git clone "$SUSFS_REPO" --depth 1 -b "$susfs_branch" "$susfs_dir"
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
    local module_prop="$susfs_dir/ksu_module_susfs/module.prop"
    local version=$(grep -oP 'version=v?\K[0-9.]+(?=)' "$module_prop")
    echo "[+] SuSFS version: $version"
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

    # 判断ksu_branch是否包含susfs
    if [[ "$ksu_branch" == *"susfs"* ]]; then
        echo "[+] SusFS is already included in KernelSU Next branch."
    else
        echo "[+] SusFS is not included in KernelSU Next branch, applying patch..."
        prepare_wild_patches
        cd "$kernel_root/KernelSU-Next"
        local patch_file="0001-kernel-implement-susfs-v1.5.8-KernelSU-Next-v1.0.8.patch"
        if [[ "$version" < "1.5.8" ]]; then
            echo "[-] Warning: SusFS version is less than 1.5.8, using old patch file."
            patch_file="0001-kernel-implement-susfs-v1.5.5-v1.5.7-KSUN-v1.0.8.patch"
        fi
        if ! _apply_patch "wild_kernels/next/$patch_file"; then
            echo "[-] Failed to apply SuSFS integration patch"
            exit 1
        fi
        cd - >/dev/null
    fi
}

fix_callsyms_for_lkm() {
    echo "[+] Adding CONFIG_KALLSYMS for LKM..."
    _set_or_add_config CONFIG_KPM y
    _set_or_add_config CONFIG_KALLSYMS y
    _set_or_add_config CONFIG_KALLSYMS_ALL y
}
