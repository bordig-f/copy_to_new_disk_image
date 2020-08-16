#!/bin/bash

set -e -u -o pipefail

case "$1" in
    -h|--help)	cat <<EOF; exit 0;;
usage: $(basename "$0") {dos|gpt} OUTPUT_FILE FILE_TO_COPY...
EOF
    *)		;;
esac

declare -r PART_TABLE_TYPE="$1"
declare -r OUTPUT_FILE="$2"
shift 2
test $# -gt 0
declare -r FILES_TO_COPY=("$@")

declare -r PARTITION_NAME='part0'

case "$PART_TABLE_TYPE" in
    dos|gpt)	;;
    *)		exit 1;;
esac

function init_disk_file {
    declare -r out_file=("$1")
    declare -r part_name=("$2")
    shift 2
    declare -r files_to_copy=("$@")

    declare -r K=1
    declare -r M=$((1024 * K))

    local files_sz_k
    files_sz_k="$(du -kc "${files_to_copy[@]}" | tail -n1 | awk '{ print $1 }')"

    local part_size_k
    case "$PART_TABLE_TYPE" in
        # some extra space is needed for partition metadata
        # TODO, test this formula more
        dos)	part_size_k="$((files_sz_k * K * 120 / 100 + 40 * M))";;
        gpt)	part_size_k="$((files_sz_k * K * 120 / 100 + 2 * M))";;
    esac

    # some extra space is also needed for disk metadata
    # TODO, test this formula more
    local disk_size_k
    disk_size_k="$((part_size_k + 2 * M))"

    rm -f "$out_file"
    fallocate -l "$disk_size_k"KiB "$out_file"

    declare -r part_size_with_unit="$part_size_k"KiB
    cat <<EOF | sfdisk "$out_file"
label: $PART_TABLE_TYPE
start=2048 size=$part_size_with_unit name=$part_name
EOF
}

function copy_files_to_part {
    declare -r part_file="$1"
    declare -r mount_dir="$2"

    (
        sudo mount "$part_file" "$mount_dir"
        trap 'sudo umount "$mount_dir"' EXIT

        case "$PART_TABLE_TYPE" in
            # FAT32 doesn't support users
            # => copy files with UID 0
            dos)	sudo cp -r --parents \
                            "${FILES_TO_COPY[@]}" "$mount_dir";;
            # copy files with the UID of $USER
            gpt)    sudo chown "$USER:$USER" "$mount_dir"
                    cp -r --parents \
                        "${FILES_TO_COPY[@]}" "$mount_dir";;
        esac
    )
}

init_disk_file "$OUTPUT_FILE" "$PARTITION_NAME" "${FILES_TO_COPY[@]}"

trap 'rm -f "$OUTPUT_FILE"' ERR
(
    declare loop_file
    loop_file="$(sudo losetup --partscan --find --show "$OUTPUT_FILE")"
    trap 'sudo losetup -d "$loop_file"' EXIT

    declare part_file; part_file="$loop_file"p1
    case "$PART_TABLE_TYPE" in
        dos)	sudo mkfs.fat -F 32 "$part_file";;
        gpt)	sudo mkfs.ext4 "$part_file";;
    esac

    (
        declare temp_dir; temp_dir="$(mktemp -d)"
        trap 'rm -rf "$temp_dir"' EXIT

        copy_files_to_part "$part_file" "$temp_dir"
    )
)
