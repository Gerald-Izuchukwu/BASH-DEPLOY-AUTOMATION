# shellcheck shell=bash

# --- Configuration & Logging ---
LOG_FILE="$SCRIPT_DIR/deployment_$(date +%Y%m%d_%H%M%S).log"

# Define global variables (will be populated by prompt_and_set)
GIT_REPO_URL=""
PAT=""
BRANCH_NAME=""
SSH_USER=""
SERVER_IP=""
SSH_KEY_PATH=""
APP_PORT=""
REPO_DIR="deployed_repo"  # Directory to clone the repository into
REPO_DIR="$SCRIPT_DIR/deployed_repo"

log_info() {
    echo -e "[\e[34mINFO\e[0m] $(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "[\e[32mSUCCESS\e[0m] $(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "[\e[33mWARN\e[0m] $(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "[\e[31mERROR\e[0m] $(date +'%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

# --- Validation Functions ---

# Basic check for IPv4 structure
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check for a valid port number (1-65535)
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Simple validation for a URL starting with http, https, or git
# validate_url() {
#     local url=$1
#     if [[ $url =~ ^(https?|git)://[a-zA-Z0-9\-\.]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
#         return 0
#     else
#         echo "not valid"
#         return 1
#     fi
# }

validate_url() {
    local url=$1
    case $url in
        http://*|https://*|git://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# --- Parameter Collection Function ---

# Prompts the user for input, validates it, and sets the corresponding global variable.
prompt_and_set() {
    local prompt_msg=$1
    local validation_func=$2
    local error_msg=$3
    local var_name=$4
    local default_val=${5:-}
    local input
    local secret=${6:-}

    while true; do
        # Append default to prompt if provided
        local full_prompt="$prompt_msg"

        if [[ -n "$default_val" ]]; then
            full_prompt+=" (Default: $default_val): "
        else
            full_prompt+=": "
        fi

        if [[ -n "$secret" ]]; then
            read -rs -p "$full_prompt" input
            echo # Move to a new line after silent input
        else
            read -r -p "$full_prompt" input
        fi
        local value="$input"

        # Apply default if input is empty
        if [[ -z "$value" ]] && [[ -n "$default_val" ]]; then
            value="$default_val"
            log_info "Using default for $var_name: $value"
        fi

        # Check if input is empty (and no default was set)
        if [[ -z "$value" ]]; then
            log_warn "Input is required for $var_name."
            continue
        fi

        # Perform custom validation
        if [[ -n "$validation_func" ]]; then
            if ! "$validation_func" "$value"; then
                log_warn "$error_msg"
                continue
            fi
        fi

        # SSH Key Existence Check
        if [[ "$var_name" == "SSH_KEY_PATH" ]]; then
            # Expand tilde (~) before checking
            value="${value/#\~/$HOME}"
            if [[ ! -f "$value" ]]; then
                log_warn "SSH Private Key file not found or is not a file at '$value'."
                continue
            fi
        fi

        # Set the global variable using eval (be cautious with eval, but safe here)
        printf -v "$var_name" '%s' "$value"
        break
    done
}

collect_parameters() {
    log_info "--- Starting Parameter Collection ---"

    # 1. Git Repository URL
    prompt_and_set "Enter Git Repository URL" \
        "validate_url" "Invalid Git URL format. Must start with http(s) or git." \
        "GIT_REPO_URL"

    # 2. Personal Access Token (PAT)
    prompt_and_set "Enter Personal Access Token (PAT)" \
        "" "PAT cannot be empty." \
        "PAT" "" "secret"

    # 3. Branch Name (Optional, defaults to 'main')
    prompt_and_set "Enter branch name" \
        "" "Branch name cannot be empty." \
        "BRANCH_NAME" "main"

    # 4. Remote Server SSH Username
    prompt_and_set "Enter Remote Server SSH Username" \
        "" "SSH Username cannot be empty." \
        "SSH_USER"

    # 5. Remote Server IP Address
    prompt_and_set "Enter Remote Server IP Address" \
        "validate_ip" "Invalid IP address format (e.g., 192.168.1.1)." \
        "SERVER_IP"

    # 6. SSH Key Path
    prompt_and_set "Enter Absolute Path to SSH Private Key (e.g., ~/.ssh/id_rsa)" \
        "" "SSH Key Path cannot be empty and file must exist." \
        "SSH_KEY_PATH"

    # 7. Application Port 
    prompt_and_set "Enter Application  Port (Port must match the one specified in docker-compose.yaml)" \
        "validate_port" "Invalid port number (must be 1-65535)." \
        "APP_PORT"

    log_success "--- Parameter Collection Complete ---"
}