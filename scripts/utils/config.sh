#!/bin/bash
# Properties file processing utility functions
# This library provides functions for loading and parsing .properties files

# Default .properties file location
DEFAULT_PROPERTIES_FILE="$build_root/build.ksunext.config"

# Function to validate .properties file format
validate_properties_file() {
    local properties_file="${1:-$DEFAULT_PROPERTIES_FILE}"

    if [ ! -f "$properties_file" ]; then
        echo "[-] Warning: Properties file not found: $properties_file"
        return 1
    fi

    # Check for basic format issues
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Check for valid property assignment format (key=value or key:value)
        if ! [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[[:space:]]*[=:][[:space:]]*.* ]]; then
            echo "[-] Warning: Invalid format at line $line_num in $properties_file: $line"
        fi
    done <"$properties_file"

    return 0
}

# Function to load properties from .properties file
load_properties_file() {
    local properties_file="${1:-$DEFAULT_PROPERTIES_FILE}"
    local force_override="${2:-false}"

    if [ ! -f "$properties_file" ]; then
        echo "[-] Properties file not found: $properties_file"
        return 1
    fi

    echo "[+] Loading properties from: $properties_file"

    # Read and process each line
    local loaded_count=0
    local skipped_count=0

    while IFS= read -r line; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Extract property name and value (support both = and :)
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_.-]*)[[:space:]]*[=:][[:space:]]*(.*) ]]; then
            local prop_name="${BASH_REMATCH[1]}"
            local prop_value="${BASH_REMATCH[2]}"

            # Remove surrounding quotes if present
            if [[ "$prop_value" =~ ^\"(.*)\"$ ]] || [[ "$prop_value" =~ ^\'(.*)\'$ ]]; then
                prop_value="${BASH_REMATCH[1]}"
            fi

            # Convert property name to valid shell variable name (replace dots with underscores)
            local var_name=$(echo "$prop_name" | sed 's/\./_/g')

            # Check if variable already exists
            if [ -n "${!var_name}" ] && [ "$force_override" != "true" ]; then
                echo "[*] Skipping $var_name (already set): ${!var_name}"
                skipped_count=$((skipped_count + 1))
                continue
            fi

            # Export the variable
            export "$var_name"="$prop_value"
            echo "[+] Loaded $var_name=$prop_value"
            loaded_count=$((loaded_count + 1))
        else
            echo "[-] Warning: Ignoring invalid line: $line"
        fi
    done <"$properties_file"

    echo "[+] Properties loading complete: $loaded_count loaded, $skipped_count skipped"
    return 0
}

# Function to get a specific property from .properties file without loading all
get_property() {
    local prop_name="$1"
    local properties_file="${2:-$DEFAULT_PROPERTIES_FILE}"

    if [ -z "$prop_name" ]; then
        echo "[-] Error: Property name is required"
        return 1
    fi

    if [ ! -f "$properties_file" ]; then
        echo "[-] Properties file not found: $properties_file"
        return 1
    fi

    # Search for the property in the file (support both = and :)
    local value=$(grep -E "^[[:space:]]*$prop_name[[:space:]]*[=:]" "$properties_file" | tail -1 | sed 's/^[^=:]*[=:]//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -n "$value" ]; then
        # Remove surrounding quotes if present
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        echo "$value"
        return 0
    else
        return 1
    fi
}

# Function to set a property in .properties file
set_property() {
    local prop_name="$1"
    local prop_value="$2"
    local properties_file="${3:-$DEFAULT_PROPERTIES_FILE}"
    local quote_value="${4:-true}"

    if [ -z "$prop_name" ]; then
        echo "[-] Error: Property name is required"
        return 1
    fi

    # Create properties file if it doesn't exist
    if [ ! -f "$properties_file" ]; then
        echo "# Build configuration properties" >"$properties_file"
        echo "# Generated on $(date)" >>"$properties_file"
        echo "" >>"$properties_file"
    fi

    # Format the value
    local formatted_value="$prop_value"
    if [ "$quote_value" = "true" ] && [ -n "$prop_value" ]; then
        # Add quotes if they're not already present and value contains spaces or special chars
        if [[ "$prop_value" =~ [[:space:]\$\`\"] ]] && ! [[ "$prop_value" =~ ^[\"\']. ]]; then
            formatted_value="\"$prop_value\""
        fi
    fi

    # Check if property already exists
    if grep -q "^[[:space:]]*$prop_name[[:space:]]*[=:]" "$properties_file"; then
        # Update existing property
        sed -i "s/^[[:space:]]*$prop_name[[:space:]]*[=:].*/$prop_name=$formatted_value/" "$properties_file"
        echo "[+] Updated $prop_name in $properties_file"
    else
        # Add new property
        echo "$prop_name=$formatted_value" >>"$properties_file"
        echo "[+] Added $prop_name to $properties_file"
    fi

    return 0
}

# Function to list all properties in .properties file
list_properties() {
    local properties_file="${1:-$DEFAULT_PROPERTIES_FILE}"

    if [ ! -f "$properties_file" ]; then
        echo "[-] Properties file not found: $properties_file"
        return 1
    fi

    echo "[+] Properties in $properties_file:"
    grep -E "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_.-]*[[:space:]]*[=:]" "$properties_file" | while IFS= read -r line; do
        local prop_name=$(echo "$line" | sed 's/[=:].*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local prop_value=$(echo "$line" | sed 's/^[^=:]*[=:]//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "  $prop_name = $prop_value"
    done

    return 0
}

# Function to remove a property from .properties file
remove_property() {
    local prop_name="$1"
    local properties_file="${2:-$DEFAULT_PROPERTIES_FILE}"

    if [ -z "$prop_name" ]; then
        echo "[-] Error: Property name is required"
        return 1
    fi

    if [ ! -f "$properties_file" ]; then
        echo "[-] Properties file not found: $properties_file"
        return 1
    fi

    if grep -q "^[[:space:]]*$prop_name[[:space:]]*[=:]" "$properties_file"; then
        sed -i "/^[[:space:]]*$prop_name[[:space:]]*[=:]/d" "$properties_file"
        echo "[+] Removed $prop_name from $properties_file"
        return 0
    else
        echo "[-] Property $prop_name not found in $properties_file"
        return 1
    fi
}

# Function to create a backup of .properties file
backup_properties_file() {
    local properties_file="${1:-$DEFAULT_PROPERTIES_FILE}"
    local backup_suffix="${2:-$(date +%Y%m%d_%H%M%S)}"

    if [ ! -f "$properties_file" ]; then
        echo "[-] Properties file not found: $properties_file"
        return 1
    fi

    local backup_file="${properties_file}.backup_${backup_suffix}"
    cp "$properties_file" "$backup_file"
    echo "[+] Backup created: $backup_file"
    return 0
}

# Function to show properties file info
show_properties_info() {
    local properties_file="${1:-$DEFAULT_PROPERTIES_FILE}"

    echo "[+] Properties file information:"
    echo "  File: $properties_file"

    if [ -f "$properties_file" ]; then
        echo "  Status: EXISTS"
        echo "  Size: $(wc -c <"$properties_file") bytes"
        echo "  Lines: $(wc -l <"$properties_file")"
        echo "  Properties: $(grep -c "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_.-]*[[:space:]]*[=:]" "$properties_file" 2>/dev/null || echo 0)"
        echo "  Last modified: $(stat -c %y "$properties_file" 2>/dev/null || stat -f %Sm "$properties_file" 2>/dev/null || echo "Unknown")"
    else
        echo "  Status: NOT FOUND"
    fi
}

_auto_load_config() {
    if [ -z "$CONFIG_FILE" ]; then
        echo "[*] CONFIG_FILE is not set, using default: $DEFAULT_PROPERTIES_FILE"
        CONFIG_FILE="$DEFAULT_PROPERTIES_FILE"
    fi
    if [ -f "$build_root/$CONFIG_FILE" ]; then
        echo "[+] Loading build configuration from $CONFIG_FILE..."
        load_properties_file "$build_root/$CONFIG_FILE"
    else
        echo "[*] No config file found, using default configuration"
        echo "[*] Please set CONFIG_FILE environment variable to point to your config file"
        echo "[*] Example: CONFIG_FILE=build.config ./build.sh"
        exit 0
    fi
}
