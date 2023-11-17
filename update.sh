#!/bin/bash

# This script automates the process of updating a Google Cloud VM running Ghost Blog
# It creates a new VM with the latest Ghost version, ensures Ghost is updated and running
# Offers to transfer the IP address from the OLD VM to the NEW VM if desired by the user

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
  gcloud compute disks update $NEW_VM_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --resource-policies='{"daily-backup-schedule":{"resources":["*"]}}'

  # Remove any existing SSH keys associated with the new IP address to prevent conflicts
  echo "Removing any existing keys for the IP: $IP_ADDRESS_NEW_VM"
  ssh-keygen -R $IP_ADDRESS_NEW_VM 2>/dev/null
}

# Function to check if the new VM instance is ready to accept SSH connections
check_vm_ready_for_ssh() {
  # Notify the user that SSH readiness is being checked
  echo "Checking SSH readiness every 5 seconds..."

  # Once again, remove any existing SSH keys associated with the new IP address to prevent conflicts
  ssh-keygen -R $IP_ADDRESS_NEW_VM 2>/dev/null

  # Maximum number of attempts to check for SSH readiness
  MAX_ATTEMPTS=36
  # Initialize a counter to keep track of the number of attempts made
  COUNT=0

  # Loop to keep trying SSH connection until it's ready or the maximum attempts are reached
  while true; do
    ssh -q -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ~/.ssh/gcp service_account@${IP_ADDRESS_NEW_VM} exit
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

    sleep 5
  done
}

# Function to SSH into the new VM and perform Ghost Blog software updates
ssh_update_Ghost() {
  # SSH into the VM to run pre-update commands like stopping Ghost, updating system packages and rebooting VM
  echo "SSHing into the VM to stop Ghost, update system packages and enable Snap package manager..."
  ssh -t -vvv -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -i ~/.ssh/gcp service_account@$IP_ADDRESS_NEW_VM << "ENDSSH1"
    cd /var/www/ghost
    ghost stop
    sudo snap enable snapd
    sudo apt update && sudo apt -y upgrade
    sudo apt clean && sudo apt autoclean && sudo apt autoremove
    nohup sudo reboot &
    exit
ENDSSH1

  # Call function to check if VM is ready for SSH post-reboot
  sleep 30
  check_vm_ready_for_ssh

  # SSH into the VM again to run post-update commands like updating npm and Ghost CLI, and starting Ghost
  echo "SSHing into the updated VM to update Node Package Manager (NPM), Ghost, disable Snap service and start Ghost..."
  ssh -t -vvv -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -i ~/.ssh/gcp service_account@${IP_ADDRESS_NEW_VM} << "ENDSSH2"
    cd /var/www/ghost
    sudo npm install -g npm@latest
    sudo npm install -g ghost-cli@latest
    sudo find ./ ! -path "./versions/*" -type f -exec chmod 664 {} \;
    sudo chown -R ghost:ghost ./content
    ghost update
    sudo snap disable snapd
    ghost start
ENDSSH2
}

# Function to check the Ghost Blog software version and its running status on the VM
check_vm_ghost_version() {
  # SSH into the VM and fetch both Ghost version and status in a single SSH session
  local output
  output=$(ssh -t -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -i ~/.ssh/gcp service_account@$IP_ADDRESS_NEW_VM "cd /var/www/ghost && ghost version && ghost status") || {
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


# Function to prompt the user for re-assigning the IP address to the new VM instance
prompt_update_ip() {
  # Prompt user for decision on re-assigning IP address
  read -p "Do you want to re-assign the IP address for: $NEW_VM_NAME? (y/n): " answer

  # Execute if user opts for IP re-assignment
  if [ "$answer" == "y" ]; then
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
      echo "You chose not to re-assign the IP address. Downgrading VM..."
      downgrade_vm
    else
      echo "You chose not to re-assign the IP address. Exiting..."
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
    
    # change the machine type from e2-micro to e2-medium
    gcloud compute instances set-machine-type $NEW_VM_NAME --zone=$ZONE --machine-type=e2-medium

    # Start the new instance
    gcloud compute instances start $NEW_VM_NAME --zone=$ZONE
}

# Function to downgrade the VM to save costs after updates are complete
downgrade_vm() {
    # Stop the new VM instance
    gcloud compute instances stop $NEW_VM_NAME --zone=$ZONE

    # change the machine type from e2-medium to e2-micro
    gcloud compute instances set-machine-type $NEW_VM_NAME --zone=$ZONE --machine-type=e2-micro

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

# Orchestrates the full script by calling the necessary functions in sequence
main() {
    # Checks if all prerequisites are met before running the script
    check_prerequisites
    # Prompts the user to confirm they want to update Ghost
    prompt_to_update
    # Fetches Virtual Machine information
    fetch_vm_info
    # Fetches the latest Ghost version available
    fetch_latest_ghost_version
    # Creates a Machine Image and starts a new VM from that image
    create_new_vm
    # Checks if the new VM is ready for SSH access
    check_vm_ready_for_ssh
    # SSH into the new VM and updates Ghost
    ssh_update_Ghost
    # Checks the Ghost version on the VM
    check_vm_ghost_version
    # Presents the Ghost version installed on the new VM to the user 
    present_vm_ghost_version
    # Prompts the user to update the IP address from the old VM to the new VM (if desired)
    prompt_update_ip
}

# Checks the first command-line argument and takes action accordingly.
# - "debug" runs the debug function eg ./update.sh debug
# - "speedy" changes the mode variable so that the main function passes it to functions which enable upgrade_vm and downgrade_vm (this uses beefier machines just to run the update to make this go faster) eg ./update.sh speedy
# - No argument defaults to running the main function eg ./update.sh
if [ "$1" == "debug" ]; then
    # Call debug function to run the script in debug mode
    debug
elif [ "$1" == "speedy" ]; then
    mode="speedy"
    main
else
    # No function name provided, run the default main function
    main
fi
