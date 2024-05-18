#!/bin/bash

set -e
#set -x

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

if [ $# -lt 1 ]; then
   echo "This script need a minimum of 1 argument <sd_card_mount_point>"
   echo " Usage : "
   echo " $0 <sd_card_mount_point> <compress_image_name>"
   echo " <sd_card_mount_point> : the mount point of the SD card"
   echo " <compress_image_name> : the compressed image name (without .gz)"
   echo " example : sudo $0 /media/user/rootfs"
   exit 1
fi

if [ "$2" == "" ]; then
  compress_image_name=Bridge_compress_image
else
  compress_image_name=$2
fi

partition=$(lsblk | grep $1 | awk '{print $1}')
if [ "$partition" = "" ]; then
   echo "Unplug/plug the SD card and check the mount point"
   echo " Usage : "
   echo " $0 <sd_card_mount_point> <compress_image_name>"
   echo " example : sudo $0 /media/user/rootfs"
   exit 1
fi
partition=${partition:2} # remove the 2 first char
disk=${partition/p} # remove 'p'
disk=${disk::-1} # remove the last char

if [ -d "$1/home/dsi/" ]; then
   _user=dsi
else
   if [ -d "$1/home/debian/" ]; then
      _user=debian
   else
      echo "Check if $1 is the mount point of your SD card (no user in home directory)"
      exit 1
   fi
fi

rm -rf $1/var/log/*

# clean image (remove log and db files)
if [ -d "$1/home/dsi/" ] && [ "$3" = "" ] ; then
   rm -f $1/home/dsi/DsiBridge/db/*
   rm -f $1/home/dsi/DsiBridge/log/*
   rm -f $1/home/dsi/*log
   rm -f $1/home/dsi/OpenMuc/framework/log/openmuc.*
   rm -f $1/home/dsi/openmuc_v0.17.0/framework/log/openmuc.*
   rm -f $1/home/dsi/openmuc-*/framework/log/openmuc.*
   sync
fi

if [ -f $1/boot/config-4.9.124-fuses+ ] ; then
   # remove specific SDcard 'tools' files
   rm -f $1/root/.resize
   rm -f $1/root/.to136
   rm -rf $1/var/lib/connman/*
   rm -f $1/etc/openvpn/client/*conf
fi

# Get UUID
new_uuid=$(uuidgen)
echo "new_uuid=$new_uuid"
if [ -f "$1/boot/extlinux/extlinux.conf" ] ; then
    # get uuid
    current_uuid=$(blkid | grep /dev/$partition | awk '{print $3}')
    current_uuid=${current_uuid:6:-1}
    echo "current_uuid=$current_uuid"
    if ! grep -qs $current_uuid $1/boot/extlinux/extlinux.conf ; then
        echo "UUID=$current_uuid is not set in $1/boot/extlinux/extlinux.conf ..."
        exit 1
    fi
    if ! grep -qs $current_uuid $1/etc/fstab ; then
        echo "UUID=$current_uuid is not set in $1/etc/fstab ..."
        exit 1
    fi
    # update uuid
    sed -i "s/UUID=$current_uuid/UUID=$new_uuid/g" $1/boot/extlinux/extlinux.conf
    sed -i "s/UUID=$current_uuid/UUID=$new_uuid/g" $1/etc/fstab
    sync
fi

# Read system size from SD card
du_command_res=$(du -s -B M $1)
[[ "$du_command_res" =~ ^[^0-9]*([0-9]+) ]] && system_size=${BASH_REMATCH[1]}
udisksctl unmount -b /dev/$partition && sleep 2

# Add 10% margin for size
system_size=$(echo "scale=0; (($system_size * 1.1)+0.5)/1" | bc -l)
echo "System size is $system_size"

if [ "$3" != "" ] && [ "$3" -gt "$system_size" ] && [ "$3" -lt "8000" ] ; then
   system_size=$3
   echo "Update system size to $system_size Mo"
fi

# Partition size is the system size plus margin to include first boot sectors
partition_size=$(($system_size + 20))
echo "Partition size is $partition_size"

set +e
e2fsck -fy /dev/$partition
set -e

# Update UUID
set +e
echo -e "y\n" | tune2fs /dev/$partition -U $new_uuid
set -e

resize2fs -f /dev/$partition "$system_size"M

# check if an error occurs during resize2fs
if [ $? -ne 0 ]; then
  echo "Error during resize2fs. Cannot continue. Please check resize2fs version >= 1.43"
  (>&2 echo "Error during USB drive mount. Cannot continue. Please check resize2fs version >= 1.43")
  exit 1
fi

# to create the partitions programatically (rather than manually)
# we're going to simulate the manual input to fdisk
# options used are :
# p to display parition
# d to remove first partition (the only one in our case"
# n to create new partition
# 1 for partition number
# 8192 for first sector
# $partition_size for last sector
# W to write new partition
set +e
echo -e "p\nd\nn\np\n1\n8192\n+$partition_size""M\nw\nq\n" | fdisk /dev/$disk
set -e

sleep 2
partprobe /dev/$disk
sleep 2

e2fsck -fy /dev/$partition
resize2fs -f /dev/$partition

echo "start compressed image generation"
# generate compressed image
sudo dd if=/dev/$disk bs=1M count=$partition_size status=progress | gzip > $compress_image_name.gz
sync

echo "resize the partition to the sdcard size"
set +e
echo -e "p\nd\nn\np\n1\n8192\n\nw\nq\n" | fdisk /dev/$disk
set -e
sleep 2
partprobe /dev/$disk
sleep 2
e2fsck -fy /dev/$partition
resize2fs -f /dev/$partition

mkdir -p $PWD/rootfs
mount -t ext4 /dev/$partition $PWD/rootfs
if [ -f "$PWD/rootfs/boot/extlinux/extlinux.conf" ] ; then
    # get uuid
    new_uuid=$(uuidgen)
    echo "new_uuid=$new_uuid"
    current_uuid=$(blkid | grep /dev/$partition | awk '{print $3}')
    current_uuid=${current_uuid:6:-1}
    echo "current_uuid=$current_uuid"
    if grep -qs $current_uuid $PWD/rootfs/boot/extlinux/extlinux.conf ; then
        # update uuid in extlinux.conf
        sed -i "s/UUID=$current_uuid/UUID=$new_uuid/g" $PWD/rootfs/boot/extlinux/extlinux.conf
    else
        echo "UUID=$current_uuid is not set in $PWD/rootfs/boot/extlinux/extlinux.conf ..."
        exit 1
    fi
    if grep -qs $current_uuid $PWD/rootfs/etc/fstab ; then
        # update uuid in fstab
        sed -i "s/UUID=$current_uuid/UUID=$new_uuid/g" $PWD/rootfs/etc/fstab
    else
        echo "UUID=$current_uuid is not set in $PWD/rootfs/etc/fstab ..."
        exit 1
    fi
    sync && sleep 2
fi
udisksctl unmount -b /dev/$partition && sleep 2

e2fsck -fy /dev/$partition
set +e
echo -e "y\n" | tune2fs /dev/$partition -U $new_uuid
set -e

udisksctl power-off -b /dev/$disk
echo "generation end !"
