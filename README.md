# gCloud Ghost Updater

This bash script helps automate the update process for Ghost running on a Google Cloud micro instance. It will fetch your Google Cloud VM info, create a machine image backup, start a new VM from that backup image and update it to the latest version of Ghost and will offer to assign your external IP address from your original VM to this new VM. It's designed to update safely from a backup and cut over to your new machine when all is working. 

It is designed to be used with [RestartVMService](https://github.com/danielraffel/RestartVMService) to help restart your VM if it becomes unavailable (which can be frequent due to its limited resources.)

## Requirements

* Client side:
    * Google Cloud CLI
    * jq
    * curl
    * expect
    * ssh-keygen
    * ssh-keyscan
* Server side:
    * Ghost v5 with Ghost CLI
    * Ubuntu 22.04 on Google Cloud
    * Setup an SSH key for your service account (with access to the private key on your client machine running the script)
    * Added your service account SSH key to your VM

## What the script does

The script does the following:

1. Checks for client side pre-requisites before running: Google Cloud CLI, jq, curl, expect, ssh-keygen, ssh-keyscan
2. Lists your Google Cloud VMs if you have more than one.
3. Offers to back up your Ghost instance to a machine image.
4. Starts a new VM from the machine image named after the latest Ghost release.
5. Temporarily stops Ghost on the new VM to free up RAM for ghost update.
6. Updates Ghost on the new VM (afterwards starts Ghost.)
7. If successful, the script will prompt if you want to reassign your free static IP to the new VM. If you opt to do this it will shutdown the old VM, and once it's stopped it will reassign the standard static IP to your new VM.

## What the script does not do

* It does not run Ghost backup since this backs up the entire instance.
* It does not delete any VMs or Machine Images. You'll need to check your Google Cloud console to clean up anything you no longer want such as terminated VMs or machine image backups.
* It does not support multi-server setups with a load balancer.

## How to run it

1. Clone the repo or just copy/paste this script to a file called `update.sh`
2. Then, run the script in your terminal: `sh update.sh`

## Potential future ideas

* Refactor the code to be modular.
* Make it easy to run only certain commands with parameters (eg backup image, update ghost, reassign IP, etc.)
* Enable running the script without the few interactive prompts.
* Cron that can check latest ghost release and offer to auto-update.
* Enable checking for client side pre-requisites.
* Offer to cleanup machine image backups and terminated VMs.
* Offer to setup service_account SSH keys.

## Final Note

The script was written quickly and has not been tested by anyone else. While I took precautions to generalize the script and avoid data loss I'd advise that you still use it at your own risk.

[Blog post](https://danielraffel.me/2023/09/05/updating-ghost-on-a-google-cloud-micro-instance/)

![](https://i.imgur.com/qvHIFVy.gif)
