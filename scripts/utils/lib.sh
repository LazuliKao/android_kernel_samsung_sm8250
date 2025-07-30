#!/bin/bash
# Kernel configuration utility functions
# This library provides functions for managing kernel configuration files

# Check if custom_config_file is set
check_config_file() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    if [ -z "$custom_config_file" ]; then
        echo "[-] Error: custom_config_file is not set"
        return 1
    fi
    if [ ! -f "$custom_config_file" ]; then
        echo "[-] Error: Config file does not exist: $custom_config_file"
        return 1
    fi
    return 0
}

# Set a configuration value
_set_config() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    local key=$1
    local value=$2

    if ! check_config_file; then
        return 1
    fi

    local original=$(grep "^$key=" "$custom_config_file" | cut -d'=' -f2)
    echo "Setting $key=$value (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1$value/" "$custom_config_file"
}

# Set a configuration value with quotes
_set_config_quote() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    local key=$1
    local value=$2

    if ! check_config_file; then
        return 1
    fi

    local original=$(grep "^$key=" "$custom_config_file" | cut -d'=' -f2)
    echo "Setting $key=\"$value\" (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1\"$value\"/" "$custom_config_file"
}

# Get a configuration value
_get_config() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    local key=$1

    if ! check_config_file; then
        return 1
    fi

    grep "^$key=" "$custom_config_file" | cut -d'=' -f2
}

# Set or add a configuration value
_set_or_add_config() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    local key=$1
    local value=$2

    if ! check_config_file; then
        return 1
    fi

    if grep -q "^$key=" "$custom_config_file"; then
        _set_config "$key" "$value"
    else
        echo "$key=$value" >>"$custom_config_file"
        echo "Added $key=$value to $custom_config_file"
    fi
}

# Apply a patch file
_apply_patch() {
    local patch_path="$1"
    local patch_file=""

    if [ -z "$build_root" ]; then
        echo "[-] Error: build_root is not set"
        return 1
    fi
    # Determine patch file location: absolute, cache, or build_root
    if [[ "$patch_path" == /* ]]; then
        patch_file="$patch_path"
    elif [ -f "$cache_config_dir/kernel_patches/$patch_path" ]; then
        patch_file="$cache_config_dir/kernel_patches/$patch_path"
    else
        patch_file="$build_root/kernel_patches/$patch_path"
    fi

    if [ ! -f "$patch_file" ]; then
        echo "[-] Error: Patch file does not exist: $patch_file"
        return 1
    fi

    echo "[+] Applying patch: $patch_path"
    local patch_result=$(patch -p1 -l --forward --fuzz=3 <"$patch_file" 2>&1)
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply patch: $patch_path"
        echo "$patch_result"
        echo "[-] Please check the patch file and try again."
        return 1
    fi
    if echo "$patch_result" | grep -q ".rej"; then
        echo "[-] Patch applied with rejected hunks. Please check the .rej files."
        echo "$patch_result" | grep ".rej"
        return 1
    fi
    echo "[+] Patch applied successfully: $patch_path"
    return 0
}

_apply_patch_strict() {
    local patch_path="$1"
    local patch_file=""

    if [ -z "$build_root" ]; then
        echo "[-] Error: build_root is not set"
        return 1
    fi

    # Check if the path is absolute or relative
    if [[ "$patch_path" == /* ]]; then
        # Absolute path
        patch_file="$patch_path"
    elif [[ "$patch_path" == wild_kernels/* ]]; then
        # Wild kernels patch - use cache directory
        patch_file="$cache_config_dir/kernel_patches/$patch_path"
    else
        # Traditional relative path - use build_root
        patch_file="$build_root/kernel_patches/$patch_path"
    fi

    if [ ! -f "$patch_file" ]; then
        echo "[-] Error: Patch file does not exist: $patch_file"
        return 1
    fi

    echo "[+] Applying patch: $patch_path"
    local patch_result=$(patch -p1 -l <"$patch_file" 2>&1)
    if [ $? -ne 0 ]; then
        echo "[-] Failed to apply patch: $patch_path"
        echo "$patch_result"
        echo "[-] Please check the patch file and try again."
        return 1
    fi
    if echo "$patch_result" | grep -q ".rej"; then
        echo "[-] Patch applied with rejected hunks. Please check the .rej files."
        echo "$patch_result" | grep ".rej"
        return 1
    fi
    return 0
}

# Get kernel version from Makefile
get_kernel_version() {
    local root_path="${1:-$kernel_root}"

    if [ -z "$root_path" ]; then
        echo "[-] Error: kernel root path is not set"
        return 1
    fi

    if [ ! -f "$root_path/Makefile" ]; then
        echo "[-] Error: Makefile not found in $root_path"
        return 1
    fi

    # Get the kernel version from the Makefile
    local version=$(grep -E '^VERSION =|^PATCHLEVEL =|^SUBLEVEL =' "$root_path/Makefile" | awk '{print $3}' | tr '\n' '.')
    # Remove the trailing dot
    version=${version%.}
    echo "$version"
}

# Validate required environment variables
validate_environment() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    local required_vars=("build_root" "kernel_root" "custom_config_file")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "[-] Error: Missing required environment variables:"
        printf '    %s\n' "${missing_vars[@]}"
        return 1
    fi

    return 0
}

# Display configuration summary
show_config_summary() {
    local custom_config_file="$kernel_root/arch/arm64/configs/$custom_config_name"
    if ! check_config_file; then
        return 1
    fi

    echo "[+] Configuration Summary:"
    echo "    Config file: $custom_config_file"
    echo "    Build root: $build_root"
    echo "    Kernel root: $kernel_root"

    if [ -f "$kernel_root/Makefile" ]; then
        local version=$(get_kernel_version)
        echo "    Kernel version: $version"
    fi
}
