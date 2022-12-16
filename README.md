# Proxmox VM remote backup script

This is a script originally designed for internal use at Privex for backing up both internal and customer VMs to a remote
storage such as Backblaze B2, Amazon S3, or SFTP servers using RClone.

It assumes you store your VMs on an LVM, and will try to automatically identify the VG your VMs are on, based off of
a list of known VG names under `KNOWN_PREFIXES`, it falls back to `FALLBACK_PREFIX` if it can't auto-detect the
correct VG. You can force it to use a specific VG by setting `VG_PREFIX` either in the `.env` file, or passed
as an environment variable.

## Basic usage

```sh
git clone https://github.com/Privex/backup-vm-script.git
cd backup-vm-script

# You'll want to adjust at least RCLONE_DST to point to the rclone remote you want to use
cp example.env
nano .env

# View the built-in help for more usage info + examples
./backupvm.sh

# Backup the full disk 0 of VM1234 as a compressed image file via Rclone
./backupvm.sh image 1234

# Mount and Tar all partitions on disk 0 of VM1234, compress them on-the-fly, and upload them via Rclone
./backupvm.sh tar 1234

# Mount and Tar just partition 5 of VM1234's disk 0 and upload to rclone
./backupvm.sh tar 1234 5
```

## License

Released under GNU GPL 3.0

```text
(C) 2023 Privex Inc. - [https://www.privex.io](https://www.privex.io)
Originally written by Someguy123 for use at Privex
```
