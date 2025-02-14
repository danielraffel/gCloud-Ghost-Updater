# gCloud Ghost Updater

This bash script helps automate the update process for Ghost running on a VM in Google Cloud. It was inspired by [Amazon rolling deployment](https://docs.aws.amazon.com/whitepapers/latest/overview-deployment-options/rolling-deployments.html) and designed because the author is running a micro instance which is very resource limited. It creates a machine image backup, starts a new VM, updates Ghost to the latest version, and offers to reassign your external IP. The script includes native macOS notifications to keep you informed of progress and important decisions so you can run in the background without forgetting about it.

Although not required, this script is compatible with [httpPing](https://github.com/danielraffel/httpPing) and [RestartVMService](https://github.com/danielraffel/RestartVMService) to facilitate restarting your VM if the URL it's hosting appears to be offline.

## Requirements

* Client side:
    * Google Cloud CLI
    * jq
    * curl
    * expect
    * ssh-keygen
    * ssh-keyscan
    * macOS (for notifications)
* Server side:
    * Ghost v5 with Ghost CLI
    * Ubuntu 22.04 on Google Cloud
    * Setup an SSH key for your service account (with access to the private key on your client machine running the script)
    * Added your service account SSH key to your VM

## What the script does

1. Checks for client side pre-requisites
2. Lists your Google Cloud VMs if you have more than one
3. Creates a machine image backup
4. Starts a new VM named after the latest Ghost release
5. Temporarily stops Ghost to free up RAM
6. Updates Ghost and restarts it
7. Offers to reassign your static IP to the new VM
8. Provides notifications throughout the process
<img width="410" alt="Want to reassign IPs? notification" src="https://github.com/user-attachments/assets/87ad05b7-2064-4df4-ba6d-27eec11dcdf1" />
<img width="758" alt="Update complete! notification" src="https://github.com/user-attachments/assets/1db778bc-3bbe-4a89-b8d6-eac9b04088d7" />


## Usage Modes

* Standard update: `./update.sh`
    * Shows progress notifications
    * Interactive prompts for key decisions
    * Final notification with VM IPs
* Fast update: `./update.sh speedy`
    * Temporarily upgrades VM for faster updates
    * Auto-downgrades after completion
* Test notifications: `./update.sh test-notification`
    * Verifies notification system works
* Debug mode: `./update.sh debug`
    * For troubleshooting version checks

## What the script does not do

* Run Ghost backup (instead, this creates a machine image)
* Delete old VMs or Machine Images
* Support multi-server setups with load balancers

## Potential future ideas

* Make it easy to run only certain commands with parameters
* Enable running without interactive prompts
* Cron for auto-update checks
* Offer to cleanup machine image backups and terminated VMs
* Offer to setup service_account SSH keys

## Final Note

The script was written quickly and has not been tested by anyone else or on a non macOS device. While I took precautions to generalize the script and avoid data loss I'd advise that you still use it at your own risk.

[Blog post](https://danielraffel.me/2023/09/05/updating-ghost-on-a-google-cloud-micro-instance/)

![](https://i.imgur.com/qvHIFVy.gif)
