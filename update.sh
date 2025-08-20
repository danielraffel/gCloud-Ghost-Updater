#!/bin/bash

set -e

# Prevent accidental double-runs
LOCK_DIR="/tmp/gcloud-ghost-updater.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another updater instance appears to be running. Exiting."
  exit 1
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# Load environment overrides if present (can be disabled with IGNORE_DOTENV=true)
if [ -f ".env" ] && [ "${IGNORE_DOTENV}" != "true" ]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

# SSH configuration (overridable via .env)
SSH_USER="${SSH_USER:-service_account}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/gcp}"

# Build SSH identity options: if key file exists, force its use; otherwise, fall back to agent/default identities
SSH_ARGS=()
if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
  SSH_ARGS=(-o IdentitiesOnly=yes -i "$SSH_KEY_PATH")
fi

# Script directory and overridable paths/configs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_NODE_VERSION_SCRIPT="${LOCAL_NODE_VERSION_SCRIPT:-"$SCRIPT_DIR/get_latest_node_version.js"}"
DEFAULT_NODE_VERSION_SCRIPT="$SCRIPT_DIR/get_latest_node_version.js"
RESOURCE_POLICY_NAME="${RESOURCE_POLICY_NAME:-daily-backup-schedule}"
SPEEDY_MACHINE_TYPE="${SPEEDY_MACHINE_TYPE:-e2-medium}"
NORMAL_MACHINE_TYPE="${NORMAL_MACHINE_TYPE:-e2-micro}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_MAX_ATTEMPTS="${SSH_MAX_ATTEMPTS:-36}"
SSH_RETRY_SLEEP="${SSH_RETRY_SLEEP:-5}"
AUTO_PRECHECK="${AUTO_PRECHECK:-true}"
DEBUG="${DEBUG:-false}"

# If someone set LOCAL_NODE_VERSION_SCRIPT to a bare number (e.g., "22"),
# treat it as a misconfiguration and fall back to the bundled script path.
if [[ "$LOCAL_NODE_VERSION_SCRIPT" =~ ^[0-9]+$ ]]; then
  if [ "$DEBUG" = "true" ]; then
    echo "Using default Node version helper (LOCAL_NODE_VERSION_SCRIPT='${LOCAL_NODE_VERSION_SCRIPT}')."
  fi
  LOCAL_NODE_VERSION_SCRIPT="$DEFAULT_NODE_VERSION_SCRIPT"
fi

# If the specified path does not exist, but the bundled script does, use it.
if [ ! -f "$LOCAL_NODE_VERSION_SCRIPT" ] && [ -f "$DEFAULT_NODE_VERSION_SCRIPT" ]; then
  if [ "$DEBUG" = "true" ]; then
    echo "Using default Node version helper (missing: '$LOCAL_NODE_VERSION_SCRIPT')."
  fi
  LOCAL_NODE_VERSION_SCRIPT="$DEFAULT_NODE_VERSION_SCRIPT"
fi

# This script automates the process of updating a Google Cloud VM running Ghost Blog
# It creates a new VM with the latest Ghost version, ensures Ghost is updated and running
# Offers to transfer the IP address from the OLD VM to the NEW VM if desired by the user

# Standard update
# ./update.sh

# Fast update with temporary VM upgrade (suggest using this for updates)
# ./update.sh speedy

# Test notifications
# ./update.sh test-notification

# Debug mode
# ./update.sh debug

# Backup only
# ./update.sh backup

# Precheck only (useful for only checking if an update is needed)
# ./update.sh precheck

# Force update (bypass precheck) really only useful if you know you need to update
# ./update.sh force

# Fast smoke test to validate the SSH parsing of Ghost version without running the full flow: runs the same ghost version && ghost status via the SSH arg handling
# ./update.sh quick-test
# # or
# ./update.sh smoke

# Function to check if all required commands and utilities are installed on the system before running script
check_prerequisites() {
  # Check if the 'mode' variable is already set to "speedy"
  if [ "$mode" != "speedy" ]; then
    # If not, set it to "normal"
    mode="normal"
  fi

  # Declare required commands and URLs
  commands=("gcloud" "jq" "curl" "expect" "ssh-keygen" "ssh-keyscan")
  urls=("https://cloud.google.com/sdk/docs/install" "https://jqlang.github.io/jq/" "https://curl.se/" "https://www.digitalocean.com/community/tutorials/expect-script-ssh-example-tutorial" "https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent" "https://man.openbsd.org/ssh-keyscan.1")

  # Check if all the commands are installed
  missing_flag=0
  for i in ${!commands[@]}; do
    cmd=${commands[$i]}
    url=${urls[$i]}
    if ! command -v $cmd > /dev/null 2>&1; then
      echo "$cmd is not installed. Learn more: $url"
      missing_flag=1
    fi
  done

  # Exit if any command is missing
  if [ $missing_flag -eq 1 ]; then
    echo "Exiting updater."
    exit 1
  fi
}

# Quick connectivity and parsing test (no VM creation)
quick_test() {
  check_prerequisites || exit 2
  fetch_vm_info || exit 2
  fetch_latest_ghost_version || exit 2
  IP_ADDRESS_NEW_VM="$OLD_IP_ADDRESS"
  echo "Running quick test on ${VM_NAME} (${IP_ADDRESS_NEW_VM})..."
  local result
  result=$(check_vm_ghost_version) || exit 2
  IFS=',' read -ra info <<< "$result"
  local found_version found_status latest_clean
  found_version=$(echo "${info[0]}" | sed 's/\x1b\[[0-9;]*m//g' | awk -F'[[:space:]]+' '{print $NF}' | sed 's/^v//')
  found_status=$(echo "${info[1]}" | xargs)
  latest_clean=$(echo "$LATEST_VERSION" | sed 's/^v//')
  echo "Expected Ghost Version: '${latest_clean}', Found Version: '${found_version}'"
  echo "Expected Ghost Status: 'running', Found Status: '${found_status}'"
}

# Function to check if user wants to update Ghost using this installer
prompt_to_update() {
  cat << "EOF"
 ██████  ██   ██  ██████  ███████ ████████ ██    ██ ██████  ██████   █████  ████████ ███████ ██████  
██       ██   ██ ██    ██ ██         ██    ██    ██ ██   ██ ██   ██ ██   ██    ██    ██      ██   ██ 
██   ███ ███████ ██    ██ ███████    ██    ██    ██ ██████  ██   ██ ███████    ██    █████   ██████  
██    ██ ██   ██ ██    ██      ██    ██    ██    ██ ██      ██   ██ ██   ██    ██    ██      ██   ██ 
 ██████  ██   ██  ██████  ███████    ██     ██████  ██      ██████  ██   ██    ██    ███████ ██   ██
EOF
  read -p "Update Ghost on GCloud? Creates a backup, starts a new VM, updates Ghost, re-assigns old IP if successful. (y/n): " answer

  case "$answer" in
    [yY]|[yY][eE][sS])
      echo "Proceeding with update."
      ;;
    [nN]|[nN][oO])
      echo "Skipping updating Ghost on Google Cloud. Exiting."
      exit 1
      ;;
    *)
      echo "Invalid input. Exiting."
      exit 1
      ;;
  esac
}

# Function to fetch information about VM from Google Cloud Platform
fetch_vm_info() {
  # Fetch the project ID using gcloud command
  PROJECT_ID=$(gcloud config list --format 'value(core.project)')

  # Fetch information about VM instances matching certain filters and format the output
  VM_INFO=$(gcloud compute instances list --filter="name ~ '^ghost|-ghost' AND status=RUNNING" --format='csv[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP)')

  # Count the number of lines in the VM information output to determine the number of VM instances
  VM_LINES=$(echo "$VM_INFO" | wc -l)

  # If there is more than one VM, prompt the user to choose one
  if [ "$VM_LINES" -gt 1 ]; then
    echo "Multiple VMs detected. Select one:"
    select OPTION in $VM_INFO; do
      IFS=',' read -ra ADDR <<< "$OPTION"
      VM_NAME=${ADDR[0]}
      ZONE=${ADDR[1]}
      OLD_IP_ADDRESS=${ADDR[2]}
      break
    done
  else
    # If only one VM instance is found, use that one
    IFS=',' read -ra ADDR <<< "$VM_INFO"
    VM_NAME=${ADDR[0]}
    ZONE=${ADDR[1]}
    OLD_IP_ADDRESS=${ADDR[2]}

    # Display found VM details
    echo "Found 1 VM:"
    printf "Name\tZone\tIP Address\n"
    printf "%s\t%s\t%s\n" "$VM_NAME" "$ZONE" "$OLD_IP_ADDRESS"
  fi

  # Extract the numeric suffix from the VM name for further processing
  NUMERIC_SUFFIX=$(echo "$VM_NAME" | awk -F'-' '{print $(NF-2)"-"$(NF-1)"-"$NF}')

  # Indicate the VM that was found
  echo "Found VM: $VM_NAME"

  # Initialize a counter for the image naming
  COUNTER=0
  IMAGE_NAME="backup-${VM_NAME}"

  # Loop to check for existing backup images and increment the counter to avoid naming conflicts
  while true; do
    if gcloud compute machine-images describe $IMAGE_NAME --project=$PROJECT_ID &>/dev/null; then
      let COUNTER=COUNTER+1
      IMAGE_NAME="backup-${VM_NAME}-v${COUNTER}"
    else
      break
    fi
  done
}

# Fetch latest version of Ghost
fetch_latest_ghost_version() {
  # Fetch the latest version of Ghost Blog from GitHub releases
  echo "Fetching latest Ghost Blog version..."
  LATEST_VERSION=$(curl --silent "https://api.github.com/repos/TryGhost/Ghost/releases/latest" | jq -r .tag_name)
  # This will remove the "v" prefix
#   LATEST_VERSION=${LATEST_VERSION:1}

  # Format the version string for usage in the new VM name
  LATEST_VERSION_FORMATTED="${LATEST_VERSION//./-}"
}

# Fast preflight: check current VM's Ghost version vs latest release
precheck_versions() {
  # Requires: fetch_vm_info (to set OLD_IP_ADDRESS/VM_NAME/ZONE) and fetch_latest_ghost_version (to set LATEST_VERSION)
  echo "Running precheck on current VM ($VM_NAME @ $OLD_IP_ADDRESS)..."
  local output
  # Do NOT allocate a TTY here to avoid colored output; keep it clean for parsing
  if ! output=$(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" ${SSH_USER}@$OLD_IP_ADDRESS "cd /var/www/ghost && ghost version" 2>/dev/null); then
    echo "Precheck SSH failed; skipping precheck."
    return 2
  fi

  local current
  current=$(echo "$output" | grep 'Ghost version:' | awk '{print $3}')
  if [ -z "$current" ]; then
    echo "Precheck could not parse Ghost version; skipping precheck."
    return 2
  fi
  local latest_stripped current_stripped
  latest_stripped=$(echo "$LATEST_VERSION" | sed 's/^v//')
  # Trim whitespace/CR and any stray color codes just in case
  current_stripped=$(echo "$current" |
    sed 's/^v//' |
    tr -d '\r' |
    xargs)

  echo "Current: $current_stripped, Latest: $latest_stripped"

  if [ "$current_stripped" = "$latest_stripped" ]; then
    echo "Already up-to-date."
    send_notification "Ghost Updater" "Current: ${current_stripped}, Latest: ${latest_stripped}\nAlready up-to-date. Nothing to update." "ok"
    return 0
  else
    echo "Update available."
    return 1
  fi
}

# Function to create an image from the existing VM and start a new Virtual Machine (VM) from that image with a snapshot schedule
create_new_vm() {
  # Create a machine image from the source VM instance
  echo "Creating machine image..."
  gcloud compute machine-images create $IMAGE_NAME \
    --project=$PROJECT_ID \
    --source-instance=$VM_NAME \
    --source-instance-zone=$ZONE

  # calls function to fetch latest version of Ghost
  fetch_latest_ghost_version

  # Create a new VM name using the base of the old name and appending the latest version
  NEW_VM_NAME="${VM_NAME%-${NUMERIC_SUFFIX}}-${LATEST_VERSION_FORMATTED}"

  # Create a new VM instance using the machine image
  echo "Creating new VM instance..."
  gcloud compute instances create $NEW_VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --source-machine-image=$IMAGE_NAME

  # Optional: speed through updates using a beefier E2-medium VM (and changing back to an E2-Micro after) requires using the command line argument "speedy" 
    if [ "$mode" == "speedy" ]; then
        upgrade_vm
    fi

  # Wait until the new VM instance reaches the "RUNNING" state
  echo "Waiting for VM to become RUNNING..."
  while true; do
    VM_STATUS=$(gcloud compute instances describe $NEW_VM_NAME \
      --project=$PROJECT_ID \
      --zone=$ZONE \
      --format='get(status)')
    if [ "$VM_STATUS" == "RUNNING" ]; then
      break
    fi
    sleep 5
  done

  # Fetch the IP address of the new VM instance
  IP_ADDRESS_NEW_VM=$(gcloud compute instances describe $NEW_VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

  # Attach the existing daily snapshot schedule to the new VM instance
  gcloud compute disks add-resource-policies $NEW_VM_NAME \
  --zone=$ZONE \
  --resource-policies=${RESOURCE_POLICY_NAME}

  # Check if the VM is ready for SSH before proceeding
  check_vm_ready_for_ssh
}

# Function to check if the new VM instance is ready to accept SSH connections
check_vm_ready_for_ssh() {
  # Notify the user that SSH readiness is being checked
  echo "Checking SSH readiness every ${SSH_RETRY_SLEEP}s..."

  # Once again, remove any existing SSH keys associated with the new IP address to prevent conflicts
  ssh-keygen -R $IP_ADDRESS_NEW_VM 2>/dev/null

  # Maximum number of attempts to check for SSH readiness
  MAX_ATTEMPTS=${SSH_MAX_ATTEMPTS}
  # Initialize a counter to keep track of the number of attempts made
  COUNT=0

  # Loop to keep trying SSH connection until it's ready or the maximum attempts are reached
  while true; do
    ssh -q -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" ${SSH_USER}@${IP_ADDRESS_NEW_VM} exit
    RESULT=$?
    # If SSH connection is successful, break the loop
    if [ $RESULT -eq 0 ]; then
      echo "SSH is ready."
      break
    fi
    # Increment the counter
    let COUNT=COUNT+1
    # If maximum attempts reached, exit the script
    if [ $COUNT -ge $MAX_ATTEMPTS ]; then
      echo "SSH not ready after $MAX_ATTEMPTS attempts. Exiting."
      exit 1
    fi

    # Notify the user about the retry
    echo "SSH not ready. Retrying ($COUNT/$MAX_ATTEMPTS)..."
    # Wait for 5 seconds before the next attempt

    sleep ${SSH_RETRY_SLEEP}
  done
}

# Function to SSH into the new VM and perform Ghost Blog software updates
ssh_update_Ghost() {
  # Copy the Node.js version script to the VM
  echo "Copying get_latest_node_version.js to the VM..."
  if [ ! -f "$LOCAL_NODE_VERSION_SCRIPT" ]; then
    echo "Local Node version script not found: $LOCAL_NODE_VERSION_SCRIPT" >&2
    exit 1
  fi
  scp -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" "$LOCAL_NODE_VERSION_SCRIPT" "${SSH_USER}@$IP_ADDRESS_NEW_VM:~/get_latest_node_version.js"

  # SSH into the VM to run pre-update commands like stopping Ghost, updating system packages and enable Snap package manager...
  echo "SSHing into the VM to stop Ghost, update system packages and enable Snap package manager..."
  ssh -t -vvv -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" ${SSH_USER}@$IP_ADDRESS_NEW_VM << "ENDSSH1"
    sudo mv ~/get_latest_node_version.js /usr/local/bin/
    cd /var/www/ghost
    ghost stop
    sudo dpkg --configure -a
    sudo snap enable snapd
    sudo apt-get update && sudo apt-get install -y jq
    sudo apt-get -y upgrade
    sudo apt-get clean && sudo apt-get autoclean && sudo apt-get autoremove
    nohup sudo reboot &
    exit
ENDSSH1

  # Call function to check if VM is ready for SSH post-reboot
  sleep 30
  check_vm_ready_for_ssh

  # SSH into the VM again to run post-update commands like updating npm and Ghost CLI, and starting Ghost
  echo "SSHing into the updated VM to update Node Package Manager (NPM), Ghost, disable Snap service and start Ghost..."
  ssh -t -vvv -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" ${SSH_USER}@${IP_ADDRESS_NEW_VM} << "ENDSSH2"
    set -e
    cd /var/www/ghost
    
    # Fetch the Node.js major version supported by the latest Ghost release (e.g., 22)
    LATEST_SUPPORTED_VERSION=$(node /usr/local/bin/get_latest_node_version.js)
    echo "Latest supported Node.js major by Ghost is: $LATEST_SUPPORTED_VERSION"

    # Discover Node engines requirement of the currently installed Ghost (from current/package.json)
    ENGINE_RANGE=""
    if command -v jq >/dev/null 2>&1 && [ -f current/package.json ]; then
      ENGINE_RANGE=$(jq -r '.engines.node // empty' current/package.json 2>/dev/null || true)
    fi
    if [ -z "$ENGINE_RANGE" ] && [ -f current/package.json ]; then
      ENGINE_RANGE=$(grep -E '"node"' current/package.json | head -n1 | sed -E 's/.*"node"\s*:\s*"([^"]+)".*/\1/' || true)
    fi
    # Parse engines range to find the allowed majors (e.g., ^18 || ^20 || ^22)
    ENGINE_MIN_MAJOR=""
    ENGINE_MAX_MAJOR=""
    if [ -n "$ENGINE_RANGE" ]; then
      ENGINE_MIN_MAJOR=$(echo "$ENGINE_RANGE" | grep -oE '[0-9]{1,2}' | sort -n | head -n1 || true)
      ENGINE_MAX_MAJOR=$(echo "$ENGINE_RANGE" | grep -oE '[0-9]{1,2}' | sort -n | tail -n1 || true)
    fi
    echo "Detected current Ghost engines.node: '${ENGINE_RANGE}' (min: '${ENGINE_MIN_MAJOR}', max: '${ENGINE_MAX_MAJOR}')"

    # Determine current installed Node major
    CURRENT_NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    echo "Current Node major detected: ${CURRENT_NODE_MAJOR}"

    # Choose a Node major to use next:
    # - Prefer not to downgrade if current satisfies engines range
    # - Otherwise, pick the highest allowed by engines but not higher than Ghost's latest supported major
    TARGET_NODE_MAJOR="$LATEST_SUPPORTED_VERSION"
    if [ -n "$ENGINE_MAX_MAJOR" ]; then
      if [ "$ENGINE_MAX_MAJOR" -lt "$LATEST_SUPPORTED_VERSION" ]; then
        TARGET_NODE_MAJOR="$ENGINE_MAX_MAJOR"
      else
        TARGET_NODE_MAJOR="$LATEST_SUPPORTED_VERSION"
      fi
    fi
    echo "Candidate Node major target: ${TARGET_NODE_MAJOR} (Ghost latest-supported: ${LATEST_SUPPORTED_VERSION})"

    sudo npm install -g n
    sudo npm install -g npm@latest
    sudo npm install -g ghost-cli@latest
    
    sudo find ./ ! -path "./versions/*" -type f -exec chmod 664 {} \;
    sudo chown -R ghost:ghost ./content
    
    # Determine current Ghost major version and handle cross-major upgrade safely
    CURRENT_VERSION_RAW=$(ghost version | grep 'Ghost version:' | awk '{print $3}')
    CURRENT_MAJOR=$(echo "$CURRENT_VERSION_RAW" | sed 's/^v//' | cut -d. -f1)
    if [ -z "$CURRENT_MAJOR" ]; then
      # Fallback: try ghost ls if parsing fails
      CURRENT_MAJOR=$(ghost ls --json | jq -r '.[0].version' 2>/dev/null | cut -d. -f1)
    fi
    echo "Detected current Ghost major version: ${CURRENT_MAJOR}"
    
    TARGET_NODE_FOR_V6=${LATEST_SUPPORTED_VERSION}
    if [ "$CURRENT_MAJOR" -lt 6 ]; then
      echo "Upgrading to latest v5.x first..."
      ghost update v5
      echo "Switching Node to v${TARGET_NODE_FOR_V6} for Ghost v6..."
      sudo n ${TARGET_NODE_FOR_V6}
      sudo npm install -g ghost-cli@latest
    else
      # For Ghost v6+ respect engines range and avoid unnecessary downgrades
      if [ -n "$ENGINE_MIN_MAJOR" ] && [ -n "$ENGINE_MAX_MAJOR" ] && [ -n "$CURRENT_NODE_MAJOR" ]; then
        if [ "$CURRENT_NODE_MAJOR" -ge "$ENGINE_MIN_MAJOR" ] && [ "$CURRENT_NODE_MAJOR" -le "$ENGINE_MAX_MAJOR" ]; then
          # Already satisfies engines range; upgrade only if below target
          if [ "$CURRENT_NODE_MAJOR" -lt "$TARGET_NODE_MAJOR" ]; then
            echo "Upgrading Node from v${CURRENT_NODE_MAJOR} to v${TARGET_NODE_MAJOR} to match allowed/highest target..."
            sudo n ${TARGET_NODE_MAJOR}
          else
            echo "Current Node v${CURRENT_NODE_MAJOR} satisfies engines; not downgrading."
          fi
        else
          echo "Current Node v${CURRENT_NODE_MAJOR} is outside engines range [${ENGINE_MIN_MAJOR}-${ENGINE_MAX_MAJOR}]; switching to v${TARGET_NODE_MAJOR}..."
          sudo n ${TARGET_NODE_MAJOR}
        fi
      else
        # No reliable engines info; ensure at least Ghost's latest-supported major
        if [ -n "$CURRENT_NODE_MAJOR" ] && [ "$CURRENT_NODE_MAJOR" -lt "$LATEST_SUPPORTED_VERSION" ]; then
          echo "No engines info; upgrading Node from v${CURRENT_NODE_MAJOR} to v${LATEST_SUPPORTED_VERSION}..."
          sudo n ${LATEST_SUPPORTED_VERSION}
        else
          echo "No engines info; keeping current Node or already at/above latest supported."
        fi
      fi
      sudo npm install -g ghost-cli@latest
    fi
    
    ghost update
    sudo snap disable snapd || true
    ghost start
ENDSSH2
}

# Function to check the Ghost Blog software version and its running status on the VM
check_vm_ghost_version() {
  # SSH into the VM and fetch both Ghost version and status in a single SSH session
  local output
  output=$(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_ARGS[@]}" ${SSH_USER}@$IP_ADDRESS_NEW_VM "cd /var/www/ghost && ghost version && ghost status" 2>/dev/null) || {
    echo "SSH command failed. Exiting."
    exit 1
  }

  # Extract the Ghost version from the 'output' variable
  local version
  version=$(echo "$output" | grep 'Ghost version:' | awk '{print $3}')
  if [ -z "$version" ]; then
    echo "Unable to fetch Ghost version. Exiting."
    exit 1
  fi

  # Extract the Ghost running status from the 'output' variable
  local status
  status=$(echo "$output" | grep -o 'running')
  if [ -z "$status" ]; then
    echo "Unable to fetch Ghost status. Exiting."
    exit 1
  fi

  # Output the fetched Ghost version and status as a comma-separated string
  echo "$version,$status"
}

# Function to display the Ghost Blog software version and its running status on the VM
present_vm_ghost_version() {
  # Define text color variables for terminal output
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  NC='\033[0m'

  # Fetch Ghost VM version and status from check_vm_ghost_version function
  IFS=',' read -ra GHOST_INFO <<< "$(check_vm_ghost_version $IP_ADDRESS_NEW_VM)"
  GHOST_VM_VERSION=$(echo "${GHOST_INFO[0]}" | sed 's/\x1b\[[0-9;]*m//g' | awk -F'[[:space:]]+' '{print $NF}')  # Remove color codes and grab the last field
  # GHOST_VM_VERSION=$(echo "${GHOST_INFO[0]}" | xargs)  # Trim whitespaces
  GHOST_STATUS=$(echo "${GHOST_INFO[1]}" | xargs)  # Trim whitespaces

  # Remove 'v' from both versions for accurate comparison
  LATEST_VERSION=$(echo "${LATEST_VERSION}" | sed 's/^v//')
  GHOST_VM_VERSION=$(echo "${GHOST_VM_VERSION}" | sed 's/^v//')

  # Present what version of Ghost was expected post update vs what version of Ghost was found and if it's running
  echo "Expected Ghost Version: '$LATEST_VERSION', Found Version: '$GHOST_VM_VERSION'"
  echo "Expected Ghost Status: 'running', Found Status: '$GHOST_STATUS'"

  # Optional: function call to debug version strings
  # version_string_debugging

  # Check if Ghost version matches the latest version and its status is running
  if [[ "$GHOST_VM_VERSION" == "${LATEST_VERSION}" && "$GHOST_STATUS" == "running" ]]; then
    echo "${BOLD}${GREEN}GOOD NEWS!!${NC} Ghost is running and is the latest version."
  else
    # Exit script if the Ghost version isn't updated or the status is not running
    echo "Ghost is either not running or not updated to the latest version. Exiting."
    exit 1
  fi
}

# Function to send macOS notification
send_notification() {
    local title="$1"
    local message="$2"
    local response_file="/tmp/ghost_notification_response"
    
    if [ "$3" = "interactive" ]; then
        # Send interactive notification with Yes/No buttons
        osascript -e "tell app \"System Events\" to display dialog \"$message\" buttons {\"Yes\", \"No\"} with title \"$title\"" > "$response_file" 2>&1
        if [ $? -eq 0 ]; then
            echo "y"
        else
            echo "n"
        fi
    elif [ "$3" = "ok" ]; then
        # Send informational OK dialog
        osascript -e "tell app \"System Events\" to display dialog \"$message\" buttons {\"OK\"} with title \"$title\"" >/dev/null 2>&1
    else
        # Send informational notification
        osascript -e "display notification \"$message\" with title \"$title\""
    fi
}

# Function to test notification system
test_notifications() {
    echo "Testing notification system..."
    send_notification "Ghost Updater Test" "This is a test notification" "info"
    sleep 2
    
    echo "Testing interactive notification..."
    local response=$(send_notification "Ghost Updater Test" "This is a test interactive notification. Click Yes or No." "interactive")
    echo "Response received: $response"
    
    if [ "$response" = "y" ] || [ "$response" = "n" ]; then
        send_notification "Ghost Updater Test" "Test completed successfully!" "info"
        echo "Notification test completed successfully."
    else
        echo "Notification test failed."
        exit 1
    fi
}

# Function to prompt the user for re-assigning the IP address to the new VM instance
prompt_update_ip() {
    local notification_message="GOOD NEWS!! Ghost is running and is the latest version ${LATEST_VERSION}. Do you want to re-assign the IP address for: $NEW_VM_NAME?"
    local response=$(send_notification "Ghost Updater" "$notification_message" "interactive")

    # Execute if user opts for IP re-assignment
    if [ "$response" = "y" ]; then
        # Fetch the access config names for both old and new VMs
        ACTUAL_ACCESS_CONFIG_NAME_OLD=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')
        ACTUAL_ACCESS_CONFIG_NAME_NEW=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')

        # Stop the old VM
        gcloud compute instances stop $VM_NAME --zone=$ZONE

        # Wait for old VM to reach 'TERMINATED' state
        while true; do
          VM_STATUS=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(status)')
          if [ "$VM_STATUS" == "TERMINATED" ]; then
               break
          fi
          sleep 5
        done

        # Delete existing access configs for both VMs
        gcloud compute instances delete-access-config $VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_OLD" --zone=$ZONE
        gcloud compute instances delete-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --zone=$ZONE

        # Add the old IP address to the new VM
        gcloud compute instances add-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --address=$OLD_IP_ADDRESS --zone=$ZONE --network-tier=STANDARD || {
          echo "Failed to add access config. Exiting."
          exit 1
        }

        # Function call to verify IP reassignment
        verify_ip_assignment

       # Optional: requires using the command line argument "speedy" which would convert the VM back to E2-micro after the update is complete
        if [ "$mode" == "speedy" ]; then
            downgrade_vm
        fi
    else
        if [ "$mode" == "speedy" ]; then
            send_notification "Ghost Updater" "Downgrading VM..." "info"
            downgrade_vm
        else
            send_notification "Ghost Updater" "IP address not reassigned. Exiting..." "info"
        fi
    fi
}

# Verify IP reassignment 
verify_ip_assignment() {
  local new_vm_ip=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
  
  if [ "$new_vm_ip" == "$OLD_IP_ADDRESS" ]; then
    echo "$NEW_VM_NAME had its IP successfully re-assigned."
  else
    echo "$NEW_VM_NAME failed to have its IP re-assigned. Exiting."  # Corrected error message
    exit 1
  fi
}

# Function to speed up updates by upgrading the VM to a larger machine type
upgrade_vm() {
    # Stop the new instance
    gcloud compute instances stop $NEW_VM_NAME --zone=$ZONE
    
    # change the machine type to SPEEDY_MACHINE_TYPE
    gcloud compute instances set-machine-type $NEW_VM_NAME --zone=$ZONE --machine-type=${SPEEDY_MACHINE_TYPE}

    # Start the new instance
    gcloud compute instances start $NEW_VM_NAME --zone=$ZONE
}

# Function to downgrade the VM to save costs after updates are complete
downgrade_vm() {
    # Stop the new VM instance
    gcloud compute instances stop $NEW_VM_NAME --zone=$ZONE

    # change the machine type back to NORMAL_MACHINE_TYPE
    gcloud compute instances set-machine-type $NEW_VM_NAME --zone=$ZONE --machine-type=${NORMAL_MACHINE_TYPE}

    # Start the new VM instance
    gcloud compute instances start $NEW_VM_NAME --zone=$ZONE

}

# Function to debug the Ghost version 
version_string_debugging() {
  # Debugging: Separate conditions to understand which one is failing
  if [[ "$GHOST_VM_VERSION" == "${LATEST_VERSION}" ]]; then
    echo "Version match."
  else
    echo "Version mismatch."

   # Additional debugging to show ASCII values
    echo -n "ASCII for GHOST_VM_VERSION: "
    echo -n "$GHOST_VM_VERSION" | od -An -tx1

    echo -n "ASCII for LATEST_VERSION: "
    echo -n "$LATEST_VERSION" | od -An -tx1
  fi

  if [[ "$GHOST_STATUS" == "running" ]]; then
    echo "Status match."
  else
    echo "Status mismatch."
  fi
}

# Function with hardcoded variables in the event one wants to debug the script after Global variables were set
hardcoded_variables() {
    VM_NAME=danielraffel-ghost-v5-62-0
    OLD_IP_ADDRESS=35.212.246.12
    NEW_VM_NAME=danielraffel-ghost-v5-63-0
    IP_ADDRESS_NEW_VM=
    ZONE=us-west1-b
}

# Optional: This function is only used by a command-line argument for debugging a NEW VM. It assumes this script was run, a VM was spunup and updated but Ghost version checking needs debugging before switching IPs.
debug() {
    # Call function with hardcoded variables in the event one wants to debug the script after Global variables were set 
    hardcoded_variables
    # Fetches the latest Ghost version available
    fetch_latest_ghost_version
    # Checks the Ghost version on the VM
    check_vm_ghost_version
    # Presents the Ghost version installed on the new VM to the user 
    present_vm_ghost_version
    # Prompts the user to update the IP address from the old VM to the new VM (if desired)
    prompt_update_ip
}

# Create a machine image backup of the current VM and exit (no updates, no new VM)
backup_only() {
    send_notification "Ghost Updater" "Starting backup only (machine image)" "info"
    check_prerequisites || {
        send_notification "Ghost Updater Error" "Prerequisites check failed" "info"
        exit 1
    }
    fetch_vm_info || {
        send_notification "Ghost Updater Error" "Failed to fetch VM info" "info"
        exit 1
    }
    echo "Creating machine image backup for $VM_NAME in $ZONE (project $PROJECT_ID)..."
    if gcloud compute machine-images create $IMAGE_NAME \
      --project=$PROJECT_ID \
      --source-instance=$VM_NAME \
      --source-instance-zone=$ZONE; then
        echo "Backup created: $IMAGE_NAME"
        send_notification "Ghost Backup Complete" "Machine image: ${IMAGE_NAME}" "ok"
    else
        echo "Failed to create machine image. Exiting."
        send_notification "Ghost Backup Failed" "Machine image: ${IMAGE_NAME}" "ok"
        exit 1
    fi
}

# Orchestrates the full script by calling the necessary functions in sequence
main() {
    send_notification "Ghost Updater" "Starting Ghost update process..." "info"
    sleep 1  # Add a 1-second delay to ensure notification appears
    
    check_prerequisites || {
        send_notification "Ghost Updater Error" "Prerequisites check failed" "info"
        exit 1
    }
    prompt_to_update
    fetch_vm_info || {
        send_notification "Ghost Updater Error" "Failed to fetch VM info" "info"
        exit 1
    }
    fetch_latest_ghost_version || {
        send_notification "Ghost Updater Error" "Failed to fetch latest Ghost version" "info"
        exit 1
    }

    # Default: auto precheck unless disabled
    if [ "$AUTO_PRECHECK" = "true" ]; then
        if precheck_versions; then
            send_notification "Ghost Updater" "Already up-to-date. Exiting." "info"
            exit 0
        fi
    fi
    create_new_vm || {
        send_notification "Ghost Updater Error" "Failed to create new VM" "info"
        exit 1
    }
    check_vm_ready_for_ssh || {
        send_notification "Ghost Updater Error" "VM not ready for SSH" "info"
        exit 1
    }
    ssh_update_Ghost || {
        send_notification "Ghost Updater Error" "Ghost update failed" "info"
        exit 1
    }
    check_vm_ghost_version || {
        send_notification "Ghost Updater Error" "Failed to check Ghost version" "info"
        exit 1
    }
    present_vm_ghost_version || {
        send_notification "Ghost Updater Error" "Version verification failed" "info"
        exit 1
    }
    prompt_update_ip
    
    # Send completion notification
    local internal_ip=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].internalIp)')
    local external_ip=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    send_notification "Ghost Updater Complete" "Instance external IP: ${external_ip}" "info"
}

# Checks the first command-line argument and takes action accordingly.
# - "debug" runs the debug function eg ./update.sh debug
# - "speedy" changes the mode variable so that the main function passes it to functions which enable upgrade_vm and downgrade_vm (this uses beefier machines just to run the update to make this go faster) eg ./update.sh speedy
# - "test-notification" runs the test_notifications function
# - No argument defaults to running the main function eg ./update.sh
case "$1" in
  test-notification)
    test_notifications
    ;;
  speedy)
    mode="speedy"
    main
    ;;
  debug)
    debug
    ;;
  precheck)
    # run only the precheck and exit with status: 0 up-to-date, 1 needs update, 2 skipped/failed
    check_prerequisites || exit 2
    fetch_vm_info || exit 2
    fetch_latest_ghost_version || exit 2
    AUTO_PRECHECK=false
    if precheck_versions; then
      exit 0
    else
      status=$?
      exit $status
    fi
    ;;
  force)
    AUTO_PRECHECK=false
    main
    ;;
  backup|image-backup)
    # Only create a machine image of the current VM, then exit
    backup_only
    ;;
  quick-test|smoke)
    quick_test
    exit 0
    ;;
  *)
    main
    ;;
esac
