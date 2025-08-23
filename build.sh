#!/bin/bash
official_source="SM-T870_EUR_13_Opensource.zip" # change it with you downloaded file
build_root=$(pwd)
kernel_root="$build_root/kernel_source"

container_name="sm8250-kernel-builder"

kernel_build_script="scripts/build_kernel_4.19.sh"
support_kernel="4.19" # only support 4.19 kernel
kernel_source_link="https://opensource.samsung.com/uploadSearch?searchValue=T870"

# lineageos_source_repo="https://github.com/LineageOS/android_kernel_samsung_sm8250.git"
# lineageos_source_branch="lineage-22.2"

custom_config_name="vendor/gts7lwifi_eur_open_defconfig"
source "$build_root/scripts/utils/config.sh"
_auto_load_config
use_lineageos_source="${use_lineageos_source:-false}"
source "$build_root/scripts/utils/lib.sh"
source "$build_root/scripts/utils/core.sh"

cache_root=$(realpath ${cache_root:-./cache})
config_hash=$(generate_config_hash)
cache_config_dir="$cache_root/config_${config_hash}"
cache_platform_dir="$cache_root/sm8250"
toolchains_root="$cache_platform_dir/toolchains"

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

function fix_makefile() {
    # Disable -Werror=strict-prototypes to avoid build error on old-style function definitions
    if ! grep -q -- '-Wno-error=strict-prototypes' "$kernel_root/Makefile"; then
        sed -i 's/-Werror=strict-prototypes/-Wno-error=strict-prototypes/' "$kernel_root/Makefile"
        echo "[+] Disabled -Werror=strict-prototypes in Makefile"
    fi
    # if ! grep -q -- '-Wno-error=implicit-function-declaration' "$kernel_root/Makefile"; then
    #     sed -i 's/-Werror=implicit-function-declaration/-Wno-error=implicit-function-declaration/' "$kernel_root/Makefile"
    #     echo "[+] Disabled -Werror=implicit-function-declaration in Makefile"
    # fi
}

function fix_path_umount() {
    # Fix path umount error
    echo "[+] Adding EXPORT_SYMBOL(path_umount) to fix module loading errors..."
    if ! grep -q "EXPORT_SYMBOL(path_umount)" "$kernel_root/fs/namespace.c"; then
        # Find the end of the file
        line_number=$(wc -l <"$kernel_root/fs/namespace.c")
        sed -i '/^struct mnt_namespace \*to_mnt_ns/i EXPORT_SYMBOL(path_umount);' "$kernel_root/fs/namespace.c"
        echo "[+] EXPORT_SYMBOL(path_umount) added to fs/namespace.c"
    else
        echo "[+] EXPORT_SYMBOL(path_umount) already exists in fs/namespace.c"
    fi
}

function init_git_repo() {
    cd "$kernel_root"
    git init
    echo "*" >.gitignore
    echo '!build.sh' >>.gitignore
    git add .
    git commit -m "Initial commit"
    cd "$build_root"
    echo "[+] Fake Git repository initialized in $kernel_root"
    # TODO: fix this error
    # fatal: ambiguous argument '748142f~..HEAD': unknown revision or path not in the working tree.
    # Use '--' to separate paths from revisions, like this:
    # 'git <command> [<revision>...] -- [<file>...]'
    # > grep -r "git.*\.\.HEAD" .
    # ./drivers/net/wireless/qualcomm/qca6390/qcacld-3.0/Kbuild:      git log -50 $(CLD_CHECKOUT)~..HEAD | \
    # ./drivers/net/wireless/qualcomm/qca6390/qcacld-3.0/Kbuild:      git log -50 $(CMN_CHECKOUT)~..HEAD | \

    # it does not effect, hmm...
    # _set_or_add_config CONFIG_BUILD_TAG n

    # force disable in config
    # ifeq ($(CONFIG_BUILD_TAG), y)
    sed -i 's/ifeq ($(CONFIG_BUILD_TAG), y)/ifeq ($(CONFIG_BUILD_TAG), n)/' "$kernel_root/drivers/net/wireless/qualcomm/qca6390/qcacld-3.0/Kbuild"
    echo "[+] CONFIG_BUILD_TAG set to n in Kbuild"
}
function fix_stpcpy() {
    echo "[+] fix lib stpcpy..."
    cd "$kernel_root"
    _apply_patch "add_stpcpy.patch"
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply stpcpy patch."
        exit 1
    else
        echo "[+] stpcpy patch applied successfully."
    fi
    cd - >/dev/null
}
function add_susfs() {
    add_susfs_prepare
    echo "[+] Applying SuSFS patches..."
    cd "$kernel_root"
    local patch_result=$(patch -p1 -l <50_add_susfs_in_$susfs_branch.patch 2>&1)
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
    _apply_patch_strict "$susfs_resolve_patch"
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply SuSFS fix patch."
        exit 1
    else
        echo "[+] SuSFS fix patch applied successfully."
    fi
}

function add_susfs_fix() {
    # replace:
    # current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC
    # with:
    # susfs_is_current_non_root_user_app_proc()
    # file:
    # fs/dcache.c
    echo "[+] Adding SuSFS fix for non-root user app proc..."
    if ! grep -q "susfs_is_current_non_root_user_app_proc()" "$kernel_root/fs/dcache.c"; then
        sed -i 's/current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC/susfs_is_current_non_root_user_app_proc()/g' "$kernel_root/fs/dcache.c"
        echo "[+] SuSFS non-root user app proc fix added to fs/dcache.c"
    else
        echo "[+] SuSFS non-root user app proc fix already exists in fs/dcache.c"
    fi
}
function add_extra_config() {
    echo "[+] Adding extra kernel configurations..."
    _set_or_add_config CONFIG_CC_WERROR n
    _set_or_add_config CONFIG_DEBUG_SECTION_MISMATCH y
    _set_or_add_config CONFIG_BUILD_ARM64_DT_OVERLAY y
    _set_or_add_config CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL n

    _set_or_add_config CONFIG_GAF_V6 n

    # _set_or_add_config CONFIG_FSCRYPT_SDP n
    _set_or_add_config CONFIG_ECRYPT_FS n
    _set_or_add_config CONFIG_ECRYPT_FS_MESSAGING n
    _set_or_add_config CONFIG_WTL_ENCRYPTION_FILTER n
    _set_or_add_config CONFIG_ECRYPTFS_FEK_INTEGRITY n
}
function show_cache_info() {
    echo "[+] Cache Directory Information:"
    echo "    Root cache: $cache_root"
    echo "    Configuration hash: $config_hash"
    echo "    Config directory: $cache_config_dir"
    echo "    Toolchains (shared): $toolchains_root"
    echo "    Tools (config-specific): $cache_config_dir/tools"
    echo "    SuSFS (config-specific): $cache_config_dir/susfs"
    echo "    Wild Kernels (config-specific): $cache_config_dir/kernel_patches/wild_kernels"
    echo ""
}

function print_usage() {
    echo "Usage: $0 [container|clean|prepare|cache-info]"
    echo "  container: Build the Docker container for kernel compilation"
    echo "  clean: Clean the kernel source directory"
    echo "  prepare: Prepare the kernel source directory"
    echo "  cache-info: Show cache directory information"
    echo "  (default): Run the main build process"
    echo ""
    echo "Environment Variables:"
    echo "  CACHE_ROOT: Set custom cache directory for tools and toolchains"
    echo "              Default: $build_root/cache"
    echo "              Current: $cache_root"
    echo ""
    echo "Configuration-specific cache directory:"
    echo "  Based on KSU branch: $ksu_branch"
    echo "  Based on SuSFS branch: $susfs_branch"
    echo "  Cache subdirectory: $cache_config_dir"
}
function fix_samsung_kernel_4_1x_ksu() {
    cd "$kernel_root"
    # * Refer to tiann/KernelSU#436 , we will got "save_allow_list creat file failed: -126" on Samsung Kernel 4.14/4.19, merge upstream is not easy for Samsung devices, so we give KernelSU a patch to let samsung devices work in traditional mode.
    local search_dir="drivers/kernelsu"
    # Find all in the files and replace.
    grep -rl 'if LINUX_VERSION_CODE < KERNEL_VERSION(4, 10, 0)' "$search_dir" | xargs sed -i 's/if LINUX_VERSION_CODE < KERNEL_VERSION(4, 10, 0)/if 1/g'
    echo "[+] Samsung kernel 4.1x KSU fix applied successfully."
    cd - >/dev/null
}

function main() {
    echo "[+] Starting kernel build process..."
    echo "[+] Configuration: KSU=${ksu_branch}, SuSFS=${susfs_branch}"
    echo "[+] Cache directory: $cache_root"
    echo "[+] Shared toolchains: $toolchains_root"
    echo "[+] Configuration-specific cache: $cache_config_dir"

    # Validate environment before proceeding
    if ! validate_environment; then
        echo "[-] Environment validation failed"
        exit 1
    fi
    download_toolchains
    clean
    if [ "$use_lineageos_source" = true ]; then
        prepare_source_git "$lineageos_source_repo" "$lineageos_source_branch"
        pushd "$kernel_root" || exit 1
        git submodule update --init --recursive
        popd || exit 1
    else
        prepare_source false
    fi
    extract_kernel_config

    show_config_summary
    [ "$use_lineageos_source" = false ] && fix_stpcpy
    add_extra_config

    add_kernelsu
    [ "$use_lineageos_source" = false ] && fix_samsung_kernel_4_1x_ksu
    apply_kernelsu_manual_hooks
    [ "$ksu_platform" = "ksu-next" ] && fix_path_umount

    if [ "$ksu_add_susfs" = true ]; then
        add_susfs
        fix_kernel_su_next_susfs
        if [ "$susfs_repo" = "https://github.com/ShirkNeko/susfs4ksu.git" ]; then
            add_susfs_fix
        fi
    fi

    apply_wild_kernels_config
    [ "$ksu_platform" = "ksu-next" ] && apply_wild_kernels_fix_for_next
    # basic fixes
    # fix_driver_checks
    # fix_callsyms_for_lkm
    # add_kprobes
    fix_samsung_securities
    fix_makefile
    add_build_script
    [ "$use_lineageos_source" = false ] && init_git_repo

    echo "[+] All done. You can now build the kernel."
    echo "[+] Please 'cd $kernel_root'"
    echo "[+] Run the build script with ./build.sh"
    echo ""

    if docker images | grep -q "$container_name"; then
        print_docker_usage
    else
        echo "To build using Docker container instead:"
        echo "./build.sh container"
    fi
}

case "${1:-}" in
"container")
    build_container
    exit $?
    ;;
"clean")
    clean
    echo "[+] Cleaned kernel source directory."
    exit 0
    ;;
"prepare")
    prepare_source
    echo "[+] Prepared kernel source directory."
    exit 0
    ;;
"cache-info")
    show_cache_info
    exit 0
    ;;
"?" | "help" | "--help" | "-h")
    print_usage
    exit 0
    ;;
"kernel")
    main
    # build container if not exists
    if ! docker images | grep -q "$container_name"; then
        build_container
        if [ $? -ne 0 ]; then
            echo "[-] Failed to build Docker container."
            exit 1
        fi
    fi
    echo "[+] Building kernel using Docker container..."
    docker run --rm -i -v "$kernel_root:/workspace" -v "$toolchains_root:/toolchains" $container_name /workspace/build.sh

    exit 0
    ;;
"")
    main
    ;;
*)
    echo "[-] Unknown option: $1"
    print_usage
    exit 1
    ;;
esac
