# gCloud Ghost Updater

This bash script helps automate the update process for Ghost running on a VM in Google Cloud. It was inspired by [Amazon rolling deployment](https://docs.aws.amazon.com/whitepapers/latest/overview-deployment-options/rolling-deployments.html) and designed because the author is running a micro instance which is very resource limited. It creates a machine image backup, starts a new VM, updates Ghost to the latest version, and offers to reassign your external IP. The script includes native macOS notifications to keep you informed of progress and important decisions so you can run in the background without forgetting about it.

**This release is built for Ghost v6 and supports updating from a v5 installation previously set up with an earlier version of this script.** _If you’re still using Ghost v5 and prefer not to upgrade v6, [use the v5-compatible version instead](https://github.com/danielraffel/gCloud-Ghost-Updater/releases/tag/0.1).

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
    * Ghost v5 or v6 with Ghost CLI
    * Ubuntu 22.04 on Google Cloud
    * Setup an SSH key for your service account (with access to the private key on your client machine running the script)
    * Added your service account SSH key to your VM

## What the script does

1. Checks for client side pre-requisites
2. Lists your Google Cloud VMs if you have more than one
3. Precheck (default): SSH to the current VM, compare its Ghost version to the latest release, and exit early if already up-to-date (configurable via `AUTO_PRECHECK`)
4. Creates a machine image backup
5. Starts a new VM named after the latest Ghost release
6. Temporarily stops Ghost to free up RAM, updates packages, and reboots
7. Determines and sets the correct Node.js major version:
   - Prefers the `engines.node` in `current/package.json`
   - Falls back to the latest Node major supported by the latest Ghost release
   - Safely handles cross-major upgrade path (v5 → v6)
8. Updates Ghost and restarts it
9. Offers to reassign your static IP to the new VM
10. Provides notifications throughout the process
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
* Precheck only: `./update.sh precheck`
    * Exits 0 if up-to-date, 1 if update available, 2 if check skipped/failed
* Force update: `./update.sh force`
    * Skips the default precheck and proceeds
* Backup only: `./update.sh backup` (alias: `image-backup`)
    * Creates a machine image of the current VM and exits (does not create a new VM, no updater run)
    * Shows a confirmation dialog on success/failure

Note: Only a single positional mode argument is supported at a time. To combine behaviors, use environment flags. Example to run speedy without precheck:

```bash
AUTO_PRECHECK=false ./update.sh speedy
```

## Configuration (.env)

Copy `.env.example` to `.env` and personalize the values. All variables are optional; sensible defaults are used if omitted.

- `SSH_USER`: SSH username (default: `service_account`)
- `SSH_KEY_PATH`: Path to SSH private key. If missing, SSH falls back to your agent/default identities (default: `$HOME/.ssh/gcp`)
- `LOCAL_NODE_VERSION_SCRIPT`: Path to `get_latest_node_version.js` (default: repo path)
- `RESOURCE_POLICY_NAME`: Disk snapshot policy attached to new VM (default: `daily-backup-schedule`)
- `SPEEDY_MACHINE_TYPE`: Temporary machine type for fast updates (default: `e2-medium`)
- `NORMAL_MACHINE_TYPE`: Machine type to downgrade back to (default: `e2-micro`)
- `SSH_CONNECT_TIMEOUT`: Seconds per SSH probe (default: `10`)
- `SSH_MAX_ATTEMPTS`: Max SSH readiness attempts (default: `36`)
- `SSH_RETRY_SLEEP`: Seconds between SSH attempts (default: `5`)
- `AUTO_PRECHECK`: Run the version precheck at script start (default: `true`)
- `IGNORE_DOTENV`: If `true`, ignore `.env` and use only shell environment variables

Precedence: the script loads `.env` first (unless `IGNORE_DOTENV=true`), then any environment variables already set in the shell will override `.env` values. Finally, built-in defaults apply for anything unset.

## Notifications

- When up-to-date, precheck shows an OK dialog with the current/latest version and exits:
  - Example: “Current: 6.0.1, Latest: 6.0.1. Already up-to-date. Nothing to update.”
- Backup-only mode shows an OK dialog indicating success or failure with the created machine image name.

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
