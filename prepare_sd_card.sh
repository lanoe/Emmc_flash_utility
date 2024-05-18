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
   echo " <compress_image_name> : the compressed image name (without .gz) to be flashed on eMMc"
   echo " example : sudo $0 /media/user/rootfs"
   exit 1
fi

local_rootfs=$PWD/rootfs

if grep -qs $local_rootfs /proc/mounts; then
   echo "umount $local_rootfs"
   umount $local_rootfs
fi

partition=$(lsblk | grep $1 | awk '{print $1}')
if [ "$partition" = "" ]; then
   echo "Unplug/plug the SD card and check the mount point"
   echo " Usage : "
   echo " $0 <sd_card_mount_point>"
   echo " example : sudo $0 /media/user/rootfs"
   exit 1
fi

partition=${partition:2} # remove the 2 first char
disk=${partition#*p} # remove 'p'
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

echo "prepare sdcard to flash eMMc"

if [ -f $1/boot/extlinux/extlinux.conf ]; then
   _version=stretch
   echo "create rootfs.tar.gz ..."
   current=$PWD
   cd $1
   rm -f $current/rootfs.tar.gz
   tar -cpzf $current/rootfs.tar.gz --one-file-system .
   sync
   cd -
else
   _version=jessie
fi

umount $1
sleep 2

echo "prepare sdcard : update partition"

set +e
e2fsck -fy /dev/$partition
set -e
resize2fs -f /dev/$partition

# check if an error occurs during e2fsck
if [ $? -ne 0 ]; then
   echo "Error during efsck. Cannot continue. Please check efsck version >= 1.43"
   (>&2 echo "Error during USB drive mount. Cannot continue. Please check efsck version >= 1.43")
   exit 1
fi

set +e
echo -e "p\nd\nn\np\n1\n8192\n+7000M\nw\nq\n" | fdisk /dev/$disk
set -e

sleep 2
partprobe /dev/$disk
sleep 2

if [ "$_version" = "stretch" ]; then
   echo "prepare sdcard : format partition"
   set +e
   echo -e "y\n" | mkfs.ext4 /dev/$partition
   set -e
   echo "prepare sdcard : label partition"
   e2label /dev/$partition rootfs
fi

set +e
e2fsck -fy /dev/$partition
set -e
resize2fs -f /dev/$partition

mkdir -p $local_rootfs
mount -t ext4 /dev/$partition $local_rootfs

if [ "$_version" = "stretch" ]; then
   echo "prepare sdcard : untar rootfs ..."
   tar -xpzf rootfs.tar.gz -C $local_rootfs --numeric-owner
   sync
fi

if [ ! -d "$local_rootfs/home/$_user" ]; then
   echo "SD Card mount issue OR user incoherence !"
   exit 1
fi

echo "export PATH=\$PATH:/sbin" >> $local_rootfs/home/$_user/.bashrc
echo "alias ll='ls -laF'" >> $local_rootfs/home/$_user/.bashrc

if [ -f $local_rootfs/boot/extlinux/extlinux.conf ]; then
   echo "Update for Debian Stretch ..."
   sed -i "s/sr-imx6/dsi-prod/g" $local_rootfs/etc/hosts
   sed -i "s/sr-imx6/dsi-prod/g" $local_rootfs/etc/hostname
   echo "prepare sdcard : update UUID"
   partition_uuid=$(lsblk -o name,uuid /dev/$disk | grep $partition | awk '{print $2}')
   sed -i "s/UUID=b672b195-0858-41c1-8c52-224fb06a4ea9/UUID=$partition_uuid/g" $local_rootfs/boot/extlinux/extlinux.conf
   sed -i "s/UUID=b672b195-0858-41c1-8c52-224fb06a4ea9/UUID=$partition_uuid/g" $local_rootfs/etc/fstab
else
   echo "Update for Debian Jessie ..."
   sed -i "s/linux/dsiprod/g" $local_rootfs/etc/hosts
   sed -i "s/linux/dsiprod/g" $local_rootfs/etc/hostname
   sed -i "s/Bridge/Prod-/g" $local_rootfs/etc/hosts
   sed -i "s/Bridge/Prod-/g" $local_rootfs/etc/hostname
   echo "fdt_file=imx6dl-dsibridge-som-v15.dtb" > $local_rootfs/boot/uEnv.txt
   echo "mmcroot=/dev/mmcblk0p1 rootwait rw" >> $local_rootfs/boot/uEnv.txt
   echo "mmcargs=setenv bootargs console=ttymxc0,115200n8 console=tty root=\${mmcroot} quiet" >> $local_rootfs/boot/uEnv.txt
   if [ ! -f $local_rootfs/boot/imx6dl-dsibridge-som-v15.dtb ] ; then
      cp $local_rootfs/boot/dtb/imx6dl-cubox-i-som-v15.dtb $local_rootfs/boot/imx6dl-dsibridge-som-v15.dtb
   fi
   echo "auto lo" > $local_rootfs/etc/network/interfaces
   echo "iface lo inet loopback" >> $local_rootfs/etc/network/interfaces
   echo "" >> $local_rootfs/etc/network/interfaces
   echo "auto eth" >> $local_rootfs/etc/network/interfaces
   echo "iface eth inet dhcp" >> $local_rootfs/etc/network/interfaces
   echo "" >> $local_rootfs/etc/network/interfaces
   echo "# auto wlan" >> $local_rootfs/etc/network/interfaces
   echo "# iface wlan inet dhcp" >> $local_rootfs/etc/network/interfaces
   echo "# wpa-essid <ssid_name>" >> $local_rootfs/etc/network/interfaces
   echo "# wpa-psk <ssid_passwd>" >> $local_rootfs/etc/network/interfaces
fi

echo "prepare sdcard : copy tools"
if [ -d $local_rootfs/home/$_user/dsi-storage ]; then
   rm -rf $local_rootfs/home/$_user/dsi-storage
fi
if [ -f $local_rootfs/lib/libTO.so ]; then
   rm -f $local_rootfs/lib/libTO.so
fi
cp -rf dsi-storage $local_rootfs/home/$_user/.
# patch TO136 lib to increase I2C_TIMEOUT
sed -i "s/#define TO_I2C_TIMEOUT 1000/#define TO_I2C_TIMEOUT 1500/g" $local_rootfs/home/$_user/dsi-storage/libto/wrapper/linux_generic.c
cp emmc_flash.sh $local_rootfs/home/$_user/.

if [ "$2" != "" ]; then
   echo "prepare sdcard : copy the compressed image to be flashed on SD card"
   cp $2.gz $local_rootfs/home/$_user/.
fi

sync

echo "umount sdcard"
umount $local_rootfs
udisksctl power-off -b /dev/$disk
echo "sdcard ready !"
