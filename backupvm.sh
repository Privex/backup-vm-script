#!/usr/bin/env bash
################################################################
#                                                              #
#               Proxmox VM Remote Backup Script                #
#              (C) 2023 Privex Inc.   GNU GPL v3               #
#                  https://www.privex.io                       #
#                                                              #
#   Backs up a VM stored on LVM as either a disk/partition     #
#   image, or tar's individual partitions, then compresses     #
#   them on the fly while uploading via Rclone to a user       #
#   configurable remote (B2, AWS, Google Cloud, Azure, etc.)   #
#                                                              #
#   Github Repo: https://github.com/Privex/backup-vm-script    #
#                                                              #
#   Basic Usage:                                               #
#                                                              #
#      Show help:                                              #
#        ./backupvm.sh                                         #
#                                                              #
#      Image full disk of VM1234 + upload via rclone:          #
#        ./backupvm.sh image 1234                              #
#                                                              #
#      Tar all partitions of VM1234 + upload via rclone:       #
#        ./backupvm.sh tar 1234                                #
#                                                              #
################################################################

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:${PATH}"
export PATH="${HOME}/.local/bin:${PATH}"

# if find_prefix can't find the vg name to prefix while scanning /dev/mapper,
# it'll fallback to this prefix
: ${FALLBACK_PREFIX="vg0"}

KNOWN_PREFIXES=(
    pve pve-vm vms pvevms pvevg pvevg0 proxmoxvg proxmox vg0
)

#######
# Scan /dev/mapper and compare the device names against prefixes passed
# as arguments to try to automatically figure out what VG name VMs are stored under
#
# Echo's the prefix + returns 0 if it's found, otherwise returns 1
# if couldn't auto-detect the prefix
#######
find_prefix() {
    for dv in /dev/mapper/*; do
        for pfx in "$@"; do
            if grep -q "${pfx}-vm--" <<< "$dv"; then
                echo "$pfx"
                return 0
            fi
        done
    done
    return 1
}

if find_prefix "${KNOWN_PREFIXES[@]}" > /dev/null; then
    : ${VG_PREFIX="$(find_prefix "${KNOWN_PREFIXES[@]}")"}
else
    : ${VG_PREFIX="$FALLBACK_PREFIX"}
fi
# cd "$DIR"

: ${IGNORE_MISSING_CMD=0}
: ${TIMESTAMP_FORMAT="%Y-%m-%d_%H%M"}
: ${DEFAULT_DISK="0"}
: ${RCLONE_DST="pvxpublic:pvxpublic-eu/vmbackups"}
: ${COMPRESSOR="lbzip2"}
: ${COMPRESS_LEVEL="7"}
: ${ARCH_TYPE="tar"}

if [[ -f "${DIR}/.env" ]]; then
    source "${DIR}/.env"
fi

TIMESTAMP="$(date +"$TIMESTAMP_FORMAT")"


has-command() {
    command -v "$@" &> /dev/null
}

if (( IGNORE_MISSING_CMD == 0 )); then
    if ! has-command rclone; then
        echo -e " [!!!] ERROR: rclone is not installed. Please install rclone using 'apt install rclone'"
        echo -e " [!!!] and configure it with 'rclone config'\n"
        exit 2
    fi
    if ! has-command kpartx; then
        echo -e " [!!!] ERROR: kpartx is not installed. Please install kpartx using 'apt install kpartx'\n"
        exit 2
    fi
    if ! has-command pv; then
        echo -e " [!!!] ERROR: pv is not installed. Please install pv using 'apt install pv'\n"
        exit 2
    fi
    if [[ "$COMPRESSOR" == "lbzip2" || "$COMPRESSOR" == "lbz2" ]] && ! has-command lbzip2; then
        echo -e " [!!!] ERROR: lbzip2 is not installed. Please install lbzip2 using 'apt install lbzip2'\n"
        exit 2
    fi
    if [[ "$COMPRESSOR" == "lz4" ]] && ! has-command lz4; then
        echo -e " [!!!] ERROR: lz4 is not installed. Please install lz4 using 'apt install lz4'\n"
        exit 2
    fi
    if [[ "$COMPRESSOR" == "gzip" ]] && ! has-command gzip; then
        echo -e " [!!!] ERROR: gzip is not installed. Please install gzip using 'apt install gzip'\n"
        exit 2
    fi
fi

get-out-name() {
    local _vmid="$1"
    local _suffix=""
    local _name="vm-${_vmid}"
    (( $# > 1 )) && _suffix="-$2" || true
    _name+="${_suffix}-${TIMESTAMP}"

    case "$COMPRESSOR" in
        lbz*|bz*) _name+=".${ARCH_TYPE}.bz2";;
        gz*) _name+=".${ARCH_TYPE}.gz";;
        lz4) _name+=".${ARCH_TYPE}.lz4";;
        lzo) _name+=".${ARCH_TYPE}.lzo";;
        *) _name+=".${ARCH_TYPE}";;
    esac
    echo "$_name"
}

BOLD="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" WHITE="" RESET=""
if [ -t 1 ]; then
    BOLD="$(tput bold)" RED="$(tput setaf 1)" GREEN="$(tput setaf 2)" YELLOW="$(tput setaf 3)" BLUE="$(tput setaf 4)"
    MAGENTA="$(tput setaf 5)" CYAN="$(tput setaf 6)" WHITE="$(tput setaf 7)" RESET="$(tput sgr0)"
fi

# easy coloured messages function
# written by @someguy123
msg() {
    # usage: msg [color] message
    if [[ "$#" -eq 0 ]]; then
        echo ""
        return
    fi
    if [[ "$#" -eq 1 ]]; then
        echo -e "$1"
        return
    fi

    ts="no"
    if [[ "$#" -gt 2 ]] && [[ "$1" == "ts" ]]; then
        ts="yes"
        shift
    fi
    if [[ "$#" -gt 2 ]] && [[ "$1" == "bold" ]]; then
        echo -n "${BOLD}"
        shift
    fi
    [[ "$ts" == "yes" ]] && _msg="[$(date +'%Y-%m-%d %H:%M:%S %Z')] ${@:2}" || _msg="${@:2}"

    case "$1" in
        bold) echo -e "${BOLD}${_msg}${RESET}" ;;
        [Bb]*) echo -e "${CYAN}${_msg}${RESET}" ;;
        [Cc]*) echo -e "${BLUE}${_msg}${RESET}" ;;
        [Yy]*) echo -e "${YELLOW}${_msg}${RESET}" ;;
        [Rr]*) echo -e "${RED}${_msg}${RESET}" ;;
        [Gg]*) echo -e "${GREEN}${_msg}${RESET}" ;;
        [Mm]*|[Pp]*) echo -e "${MAGENTA}${_msg}${RESET}" ;;
        *) echo -e "${_msg}" ;;
    esac
}

msgerr() {
    >&2 msg "$@"
}

handle-compression() {
    case "$COMPRESSOR" in
        lbz*) lbzip2 -n $(nproc) -cvz${COMPRESS_LEVEL} "$@"; return $?;;
        gz*) gzip -cvz${COMPRESS_LEVEL} "$@"; return $?;;
        bz*) bzip -cvz${COMPRESS_LEVEL} "$@"; return $?;;
        lz4) lz4 -cvz${COMPRESS_LEVEL} "$@"; return $?;;
        *) dd; return $?;;
    esac
}

get-disk-path() {
    local _vmid="$1"
    local _disk_id="$DEFAULT_DISK"
    (( $# > 1 )) && _disk_id="$2" || true
    echo "/dev/mapper/${VG_PREFIX}-vm--${_vmid}--disk--${_disk_id}"
}

# backup-disk-image vmid [part_id] [disk_id] [out_name]
backup-disk-image() {
    local vmid="$1" dpath orig_dpath out_name out_path
    local part_id=""
    local disk_id="$DEFAULT_DISK"
    (( $# > 1 )) && part_id="$2" || true
    (( $# > 2 )) && disk_id="$3" || true
    orig_dpath="$(get-disk-path "$vmid" "$disk_id")"
    if [[ -n "$part_id" ]]; then
        msg green " [...] Expanding partitions from disk (kpartx -av '${dpath}')"
        kpartx -av "$orig_dpath"
        dpath="${orig_dpath}p${part_id}"
        out_name="$(ARCH_TYPE=img get-out-name "$vmid" "p${part_id}")"
    else
        dpath="${orig_dpath}"
        out_name="$(ARCH_TYPE=img get-out-name "$vmid")"
    fi
    (( $# > 3 )) && out_name="$4" || true
    out_path="${RCLONE_DST%/}/${out_name}"
    msg green " >> Dumping disk '$dpath' (vmid: ${vmid}) compressed with '$COMPRESSOR' to rclone dest '$out_path'"
    pv "$dpath" | handle-compression - | rclone rcat "$out_path"
    _ret=$?
    if (( _ret )); then
        msgerr red " [!!!] ERROR - non-zero return code returned by pv, the compressor, or rclone while dumping '$dpath' to '$out_path' - return code: $_ret"
    else
        msg bold green " [+++] Finished dumping disk to '$dpath' (vmid: ${vmid}) compressed with '$COMPRESSOR' to rclone dest '$out_path'"
    fi
    if [[ -n "$part_id" ]]; then
        msg yellow " [...] Un-expanding partitions from disk (kpartx -dv '${dpath}')"
        kpartx -dv "$orig_dpath"
    fi
    return $_ret
}

# _backup-disk-tar vmid part_id disk_id
_backup-disk-tar() {
    local vmid="$1" out_name dpath
    local part_id="$2"
    local disk_id="$3"
    local part_dir="/mnt/backupvm/${vmid}/part_${part_id}"
    dpath="$(get-disk-path "$vmid" "$disk_id")"
    local part_dev="${dpath}p${part_id}"
    out_name="$(get-out-name "$vmid" "p$part_id")"
    out_path="${RCLONE_DST%/}/${out_name}"

    if ! mkdir -p "${part_dir}"; then
        msgerr red " [!!!] Failed to auto-create $part_dir"
        return 4
    fi
    msg cyan  "        > Mounting $part_dev onto $part_dir ..."

    if ! mount -v "${part_dev}" "$part_dir"; then
        msgerr red " [!!!] Failed to mount $part_dev onto $part_dir"
        return 4
    fi
    msg green "        + Mounted $part_dev onto $part_dir"

    cd "$part_dir"

    msg cyan  "        > Tarring '${part_dir}' + compressing with $COMPRESSOR + outputting onto rclone at $out_path"

    tar cf - . | pv | handle-compression - | rclone rcat "$out_path"
    cd - &>/dev/null

    _ret=$?
    if (( _ret )); then
        msgerr red "        !!! ERROR - non-zero return code returned by tar, the compressor, or rclone while dumping '$dpath' to '$out_path' - return code: $_ret"
    else
        msg bold green "        + Finished tarring disk to '$dpath' (vmid: ${vmid}) compressed with '$COMPRESSOR' to rclone dest '$out_path'"
    fi
    umount -v "$part_dir"


    return $_ret
}

# backup-disk-tar vmid [part_id] [disk_id] [out_name]
backup-disk-tar() {
    local vmid="$1" dpath out_name out_path
    local part_id=""
    local disk_id="$DEFAULT_DISK"
    (( $# > 1 )) && part_id="$2" || true
    (( $# > 2 )) && disk_id="$3" || true
    dpath="$(get-disk-path "$vmid" "$disk_id")"
    out_name="$(get-out-name "$vmid" "p$part_id")"
    (( $# > 3 )) && out_name="$4" || true
    out_path="${RCLONE_DST%/}/${out_name}"

    msg green " >> Dumping disk '$dpath' (vmid: ${vmid}) compressed with '$COMPRESSOR' to rclone dest '$out_path' \n"

    msg cyan  "    > Expanding partitions from disk"
    if kpartx -av "$dpath"; then
        msg green  "    + Successfully expanded partitions from disk\n"
    else
        msg red     "    !!! Failed to expand partitions, cannot continue!\n"
        return 3
    fi
    if [[ -n "$part_id" ]]; then
        _backup-disk-tar "$vmid" "$part_id" "$disk_id"
        _ret=$?
    else
        msg cyan "    > Backing up ALL partitions for VMID $vmid"
        _count=0 success_count=0 failed_count=0
        for d in "${dpath}"p*; do
            _part_id="$(grep -Eo '[0-9]+$' <<< "$d")"
            msg cyan "    > Backing up partition $_part_id ..."
            _backup-disk-tar "$vmid" "$_part_id" "$disk_id"
            _ret=$?
            _count=$(( _count + 1))
            if (( _ret )); then
                msg red "    ! Failed to back up partition $_part_id ...\n"
                failed_count=$(( failed_count + 1))
            else
                msg green "    + Backed up partition $_part_id ...\n"
                success_count=$(( success_count + 1))
            fi
        done
        msg green  " [+++] Finished backing up ${_count} partitions for VMID $vmid disk $disk_id \n"
        msg green  "    #Num. Successfully backed up: $success_count"
        msg red    "         #Num. Failed to back up: $failed_count"
        msg yellow "                     #Num. Total: $_count"
        msg "\n"
        (( success_count == 0 )) && _ret=1 || true
    fi
    msg yellow " [...] Un-expanding partitions from disk (kpartx -dv '${dpath}')"
    kpartx -dv "$dpath"

    # pv "$dpath" | handle-compression - | rclone rcat "$out_path"
    # _ret=$?
    # if (( _ret )); then
    #     msgerr red " [!!!] ERROR - non-zero return code returned by pv, the compressor, or rclone while dumping '$dpath' to '$out_path' - return code: $_ret"
    # else
    #     msg bold green " [+++] Finished dumping disk to '$dpath' (vmid: ${vmid}) compressed with '$COMPRESSOR' to rclone dest '$out_path'"
    # fi
    return $_ret
}

show-help() {
    msg cyan "Usage: ${BOLD}$0 (image|tar) vmid [partition_id] [disk_id=0] [out_name]"
    msg cyan "Backs up and compresses a VM's disk to a remote (or local) storage using rclone"
    msg cyan "Can either image the whole disk, image a single partition, tar all partitions, or tar a single partition\n"
    msg
    msg cyan "(C) 2023 Privex Inc. https://www.privex.io - Written by Someguy123 at Privex for our own usage"
    msg cyan "    Git: https://github.com/Privex/backup-vm-script"
    msg
    msg bold cyan "Backup Commands/Types:\n"
    msg cyan "    image|dumpimage|dump-image:"
    msg cyan "        Dumps the whole VM disk by default, optionally you can specify the partition ID as the 2nd arg"
    msg cyan "        if you just want to dump a single partition e.g. to image just partition 5: '$0 image 1234 5'"
    msg
    msg cyan "    tar|dumptar|dump-tar|archive|partition:"
    msg cyan "        Expands the partitions, then if no partition ID is specified, will mount and tar up ALL partitions"
    msg cyan "        individually and upload them with rclone. If you specify a partition ID, only that"
    msg cyan "        partition will be mounted and tarred"
    msg
    msg bold cyan "Examples:\n"
    msg cyan "    Backup the whole disk (0) of VM 1234 as a BZ2 compressed image via rclone:"
    msg cyan "        $0 image 1234\n"
    msg cyan "    Backup just partition 5 of VM 1234 as a BZ2 compressed image via rclone:"
    msg cyan "        $0 image 1234 5\n"
    msg cyan "    Backup just partition 5 of VM 1234's Disk 2 as a BZ2 compressed image via rclone with the output name 'vm1234.tar.bz2':"
    msg cyan "        $0 image 1234 5 2 vm1234.tar.bz2\n"
    msg cyan "    Backup all partitions of disk 2 for VM 1234 as a BZ2 compressed image via rclone:"
    msg cyan "        $0 image 1234 5 2\n"

    msg cyan "    Backup all partitions for VM 1234's disk (0) as individually BZ2 compressed tar files via rclone:"
    msg cyan "        $0 tar 1234\n"
    msg cyan "    Backup all partitions for VM 1234's disk 3 as individually BZ2 compressed tar files via rclone:"
    msg cyan "        $0 tar 1234 '' 3\n"
    msg cyan "    Backup just partition 5 for VM 1234's disk (0) as an individually BZ2 compressed tar file via rclone:"
    msg cyan "        $0 tar 1234 5\n"
    msg cyan "    Backup just partition 2 for VM 1234's disk 1 as an individually BZ2 compressed tar file via rclone with the custom output name 'pvx1234.tar.bz2:"
    msg cyan "        $0 tar 1234 2 1 pvx1234.tar.bz2\n"

}

if (( $# < 2 )); then
    msgerr red " [!!!] ERROR: $0 requires at least two argument (backup-type, vmid)"
    show-help
    exit 1
fi

case "$1" in
    image|dumpimage|dump-image)
        shift
        backup-disk-image "$@"
        exit $?
        ;;
    tar|dumptar|dump-tar|arch*|part*)
        shift
        backup-disk-tar "$@"
        exit $?
        ;;
    *)
        msgerr red " [!!!] ERROR: Invalid backup type '$1'. Valid backup types: tar, dumptar, dump-tar, partition, image, dumpimage, dump-image"
        show-help
        exit 1
        ;;
esac

exit $?
