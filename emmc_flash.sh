#!/bin/bash

set -e 
#set -x

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

function print_usage {
   echo " Usage : "
   echo " $0 <compress_image_name>"
   echo " <compress_image_name> : the compressed image name (without .gz) to be flashed on eMMc"
   echo " example : sudo $0 compressed_image_name"
   echo " to get image from USB storage, add path /media/usb_drive/ for the image name"
   echo " to desactivate the creation of the encrypted partition, add argument no_encryption"
   echo " to fuse for boot on emmc, add argument fuse_boot_on_emmc"
   echo " to fuse for boot on sdcard, add argument fuse_boot_on_sdcard"
   exit 1
}

if [ $# -lt 1 ]; then
   echo "This script need a minimum of 1 argument <compress_image_name>"
   print_usage
fi

if [ "$1" = "no_encryption" ] || [ "$1" = "fuse_boot_on_emmc" ] || [ "$1" = "fuse_boot_on_sdcard" ]; then
   echo "This script need the first argument <compress_image_name>"
   print_usage
fi

if [ "$2" != "no_encryption" ] && [ "$2" != "" ] && [ "$2" != "fuse_boot_on_emmc" ] && [ "$2" != "fuse_boot_on_sdcard" ]; then
   echo "The second argument is wrong"
   print_usage
fi

if [ "$3" != "" ] && [ "$3" != "fuse_boot_on_emmc" ] && [ "$3" != "fuse_boot_on_sdcard" ] ; then
   echo "The third argument is wrong"
   print_usage
fi

# check uSOM fuses

HW_OCOTP_CFG4=$(cat /sys/fsl_otp/HW_OCOTP_CFG4)
HW_OCOTP_CFG5=$(cat /sys/fsl_otp/HW_OCOTP_CFG5)
echo "HW_OCOTP_CFG4=$HW_OCOTP_CFG4 and HW_OCOTP_CFG5=$HW_OCOTP_CFG5"

if [ "$2" = "fuse_boot_on_sdcard" ] || [ "$3" = "fuse_boot_on_sdcard" ] ; then
    if [ "$2" = "fuse_boot_on_emmc" ] || [ "$3" = "fuse_boot_on_emmc" ] ; then
       echo "You cannot have both option 'fuse_boot_on_sdcard' and 'fuse_boot_on_emmc'"
       print_usage
    fi
fi

if [ "$HW_OCOTP_CFG4" != "0x0" ] || [ "$HW_OCOTP_CFG5" != "0x0" ] ; then
    if [ "$2" = "fuse_boot_on_emmc" ] || [ "$3" = "fuse_boot_on_emmc" ] ; then
        if [ "$HW_OCOTP_CFG4" != "0x1060" ] || [ "$HW_OCOTP_CFG5" != "0x10" ] ; then
            if [ "$HW_OCOTP_CFG4" = "0x2840" ] && [ "$HW_OCOTP_CFG5" = "0x10" ] ; then
                echo "uSOM already fuses to boot on SDcard !"
            else
                echo "uSOM already fuses !"
            fi
            exit 1
        fi
    fi
    if [ "$2" = "fuse_boot_on_sdcard" ] || [ "$3" = "fuse_boot_on_sdcard" ] ; then
        if [ "$HW_OCOTP_CFG4" != "0x2840" ] || [ "$HW_OCOTP_CFG5" != "0x10" ] ; then
            if [ "$HW_OCOTP_CFG4" = "0x1060" ] && [ "$HW_OCOTP_CFG5" = "0x10" ] ; then
                echo "uSOM already fuses to boot on Emmc !"
            else
                echo "uSOM already fuses !"
            fi
            exit 1
        fi
    fi
fi

if [ $# -gt 3 ]; then
   echo "You should have less than 4 arguments"
   print_usage
fi

if grep -qs '/media/emmc_rootfs' /proc/mounts; then
    echo "umount emmc_rootfs"
    umount /media/emmc_rootfs
fi
if grep -qs '/media/emmc_home' /proc/mounts; then
    echo "umount emmc_home"
    umount /media/emmc_home
    cryptsetup luksClose /dev/mapper/dsi
fi
if grep -qs '/media/usb_drive' /proc/mounts; then
    echo "umount usb_drive"
    umount /media/usb_drive
fi

echo "Power off usb storage device ..."
if [ ! -L /sys/class/gpio/gpio86 ] && [ ! -L /sys/class/gpio/gpio90 ]; then
    echo 86 > /sys/class/gpio/export
    echo 90 > /sys/class/gpio/export
    echo out > /sys/class/gpio/gpio86/direction
    echo out > /sys/class/gpio/gpio90/direction
fi
echo 1 > /sys/class/gpio/gpio86/value
echo 1 > /sys/class/gpio/gpio90/value
echo 0 > /sys/class/gpio/gpio86/value
echo 0 > /sys/class/gpio/gpio90/value
sleep 1

emmc=$(lsblk | grep "mmcblk2 " | awk '{print $1}')
if [ "$emmc" = "mmcblk2" ]; then
    echo "Flash on eMMC ($emmc) ..."
    if [ "$2" = "fuse_boot_on_sdcard" ] || [ "$3" = "fuse_boot_on_sdcard" ] ; then
       echo "You cannot select option 'fuse_boot_on_sdcard' when flashing on eMMC !"
       exit 1
    fi
    DISK=mmcblk2
    PARTITION1="$DISK"p1
    PARTITION2="$DISK"p2
    target=emmc
else
    usb=$(lsblk -o NAME,TRAN | grep "usb" | awk '{print $1}')
    if [ "$usb" = "" ]; then
	echo "No eMMC and no USB-mSATA available to flash the image !"
	exit 1
    else
        echo "Flash on USB ($usb) ..."
        if [ "$2" = "fuse_boot_on_emmc" ] || [ "$3" = "fuse_boot_on_emmc" ] ; then
           echo "You cannot select option 'fuse_boot_on_emmc' when flashing on USB-mSata !"
           exit 1
        fi
        DISK=$usb
        PARTITION1="$DISK"1
        PARTITION2="$DISK"2
        target=usb-msata
    fi
fi

compress_image_name=$1

if [ "${compress_image_name:0:17}" = "/media/usb_drive/" ]; then
    # compressed image in USB storage device
    echo "Power on usb storage device ..."
    if [ ! -L /sys/class/gpio/gpio86 ] && [ ! -L /sys/class/gpio/gpio90 ]; then
        echo 86 > /sys/class/gpio/export
        echo 90 > /sys/class/gpio/export
        echo out > /sys/class/gpio/gpio86/direction
        echo out > /sys/class/gpio/gpio90/direction
    fi
    echo 0 > /sys/class/gpio/gpio86/value
    echo 0 > /sys/class/gpio/gpio90/value
    echo 1 > /sys/class/gpio/gpio86/value
    echo 1 > /sys/class/gpio/gpio90/value
    sleep 4

    echo "Check usb storage device ..."
    if [ "$target" = "emmc" ]; then
        usb_storage=$(lsblk -o NAME,TRAN | grep "usb" | awk '{print $1}')
    elif [ "$DISK" = "sda" ]; then
        usb_storage=$(lsblk -o NAME,TRAN | grep "usb" | grep "sdb" | awk '{print $1}')
    elif [ "$DISK" = "sdb" ]; then
        usb_storage=$(lsblk -o NAME,TRAN | grep "usb" | grep "sda" | awk '{print $1}')
    fi

    if [ "$usb_storage" = "" ]; then
        echo "Please ckeck USB storage device is correctly plugged !"
        exit 1
    else
        # mount usb drive
        echo "Mount /media/usb_drive on /dev/"$usb_storage"1"
        mkdir -p /media/usb_drive
        if grep -qs '/media/usb_drive' /proc/mounts; then
            echo "usb drive already mounted"
        else
            mount /dev/"$usb_storage"1 /media/usb_drive
        fi
        # check if an error occurs during mount action
        if [ $? -ne 0 ]; then
            echo "Error during usb drive mount. Cannot continue."
            (>&2 echo "Error during usb drive mount. Cannot continue.")
            exit 1
        fi
    fi
fi

if [ ! -f $compress_image_name.gz ]; then
    echo "Failed to open the compressed image '$compress_image_name.gz' !"
    exit 1
fi

if [ "$2" != "no_encryption" ]; then
    update=0
    if ! which vim > /dev/null; then
        if [ "$update" = "0" ] ; then
            echo "Install tools for encryption..."
            apt-get update && update=1
        fi
        apt-get install -y vim
    fi
    if ! which ifconfig > /dev/null; then
        if [ "$update" = "0" ] ; then
            echo "Install tools for encryption..."
            apt-get update && update=1
        fi
        apt-get install -y net-tools
    fi
    if ! which make > /dev/null; then
        if [ "$update" = "0" ] ; then
            echo "Install tools for encryption..."
            apt-get update && update=1
        fi
        apt-get install -y make
    fi
    if ! which cryptsetup > /dev/null; then
        if [ "$update" = "0" ] ; then
            echo "Install tools for encryption..."
            apt-get update && update=1
        fi
        apt-get install -y cryptsetup
    fi
    if ! which bc > /dev/null; then
        if [ "$update" = "0" ] ; then
            echo "Install tools for encryption..."
            apt-get update && update=1
        fi
        apt-get install -y bc
    fi

    # 3.7 Go for the first partition (debian rootfs)
    # and the available space for the second partition (encrypted home)
    rootfs_partition_size=3700
fi

# to clean first :  dd if=/dev/urandom of=/dev/$DISK bs=1M
echo "Write $compress_image_name.gz on $target ..."

gzip -dc $compress_image_name.gz | dd of=/dev/$DISK bs=2M status=progress

# check if an error occurs during flash
if [ $? -ne 0 ]; then
    echo "Error during $target flash."
    (>&2 echo "Error during $target flash.")
    if grep -qs '/media/usb_drive' /proc/mounts; then
        umount /media/usb_drive
    fi
    exit 1
fi

sleep 2
partprobe /dev/$DISK
sleep 2

# check file system
set +e
e2fsck -fy /dev/$PARTITION1
set -e
resize2fs -f /dev/$PARTITION1

if [ "$2" != "no_encryption" ]; then
    echo "Prepare encryption ..."
    echo "Mount /media/emmc_rootfs on /dev/$PARTITION1"
    mkdir -p /media/emmc_rootfs
    if grep -qs '/media/emmc_rootfs' /proc/mounts; then
        echo "emmc rootfs already mounted"
    else
        mount /dev/$PARTITION1 /media/emmc_rootfs
    fi

    # Check if an error occurs during mount action
    if [ $? -ne 0 ]; then
        echo "Error mount $target rootfs."
        (>&2 echo "Error mount $target rootfs.")
        if grep -qs '/media/usb_drive' /proc/mounts; then
            umount /media/usb_drive
        fi
        exit 1
    fi

    echo "Create home tarball ..."
    cd /media/emmc_rootfs/home/.
    rm -f /tmp/home.tar.gz
    tar -cpzf /tmp/home.tar.gz --one-file-system .
    cd -
    rm -rf /media/emmc_rootfs/home
    sync

    echo "Check the new rootfs size ..."
    du_command_res=$(du -s -B M /media/emmc_rootfs)
    [[ "$du_command_res" =~ ^[^0-9]*([0-9]+) ]] && rootfs_size=${BASH_REMATCH[1]}
    # Add 10% margin for rootfs size
    rootfs_size=$(echo "scale=0; (($rootfs_size * 1.1)+0.5)/1" | bc -l)
    echo "rootfs_size = $rootfs_size Mo"
    # remove a margin on partition size to compare with rootfs size
    if [ "$rootfs_size" -gt "$(($rootfs_partition_size-20))" ]; then
        echo "** ROOTFS SIZE GREATER THAN THE FIRST PARTITION ! **"
        if grep -qs '/media/usb_drive' /proc/mounts; then
            umount /media/usb_drive
        fi
        exit 1
    fi

    umount /media/emmc_rootfs
    sleep 2

    # check file system
    e2fsck -fy /dev/$PARTITION1
    resize2fs -f /dev/$PARTITION1 "$rootfs_size"M
fi

echo "Create partitions on $target ..."

# to create the partitions programatically (rather than manually)
# we're going to simulate the manual input to fdisk
# options used are :
# p to display parition
# d to remove first partition (the only one in our case"
# n to create new partition
# 1 for partition number
# 8192 for first sector
# $rootfs_partition_size for partition size
# Y to confirm remove signature
# n to create the dsi partition
# p for primary
# 2 for partition number
# $rootfs_partition_block for the first sector
# \n until the end of the memory for the last sector
# W to write new partition
set +e
if [ "$2" != "no_encryption" ]; then
    echo "rootfs_partition_size=$rootfs_partition_size Mo"
    next_first_sector=$(($(($rootfs_partition_size * 2048)) + 8192))
    echo "next_first_sector=$next_first_sector"
    echo -e "p\nd\nn\np\n1\n8192\n+$rootfs_partition_size""M\nY\nn\np\n2\n$next_first_sector\n\nw\nq\nY\n" | fdisk /dev/$DISK
else
    # no encrypted partition
    echo -e "p\nd\nn\np\n1\n8192\n\nY\nw\nq\n" | fdisk /dev/$DISK
fi
set -e

sleep 2
partprobe /dev/$DISK
sleep 2

e2fsck -fy /dev/$PARTITION1
resize2fs -f /dev/$PARTITION1

# Check if an error occurs during resize action
if [ $? -ne 0 ]; then
    echo "Error during system resize."
    (>&2 echo "Error during system resize.")
    if grep -qs '/media/usb_drive' /proc/mounts; then
        umount /media/usb_drive
    fi
    exit 1
fi

echo "Mount /media/emmc_rootfs on /dev/$PARTITION1"
mkdir -p /media/emmc_rootfs
if grep -qs '/media/emmc_rootfs' /proc/mounts; then
    echo "emmc rootfs already mounted"
else
    mount /dev/$PARTITION1 /media/emmc_rootfs
fi

# Check if an error occurs during mount action
if [ $? -ne 0 ]; then
    echo "Error mount $target rootfs."
    (>&2 echo "Error mount $target rootfs.")
    if grep -qs '/media/usb_drive' /proc/mounts; then
        umount /media/usb_drive
    fi
    exit 1
fi

if [ -f /media/emmc_rootfs/boot/uEnv.txt ]; then
    # debian jessie
    sed -i "s/mmcblk0p1/$PARTITION1/g" /media/emmc_rootfs/boot/uEnv.txt
fi

if [ "$2" != "no_encryption" ]; then
    echo "Start Encryption Process ..."

    if [ -d "/home/dsi/" ]; then
        sd_user=dsi
    else
        sd_user=debian
    fi

    if [ -f /boot/uEnv.txt ]; then
        # debian jessie
        if ! which autoconf > /dev/null; then
            echo "Install autotools ..."
            if [ "$update" = "0" ] ; then
                apt-get update && update=1
            fi
            apt-get install -y python3
            apt-get install -y libsigsegv2 m4
            if [ ! -f autoconf_2.69-10~bpo8+1_all.deb ]; then
                wget https://repo.solid-build.xyz/debian/jessie/bsp-imx6/./all/autoconf_2.69-10~bpo8+1_all.deb
            fi
            dpkg -i autoconf_2.69-10~bpo8+1_all.deb
            apt-get install -y automake
            apt-get install -y libtool
        fi
    else
        # debian strecth
        if ! which autoconf > /dev/null; then
            echo "Install autotools ..."
            if [ "$update" = "0" ] ; then
                apt-get update && update=1
            fi
            apt-get install -y autoconf
            apt-get install -y libtool
        fi
    fi

    # Build tools for TO136
    if [ ! -f /lib/libTO.so ] || [ ! -f /lib/libTO_i2c_wrapper.so ]; then
        echo "Build TO136 library ..."
        cd /home/$sd_user/dsi-storage/libto
        rm -rf build; mkdir build
        autoreconf -f -i
        cd build
        ../configure i2c=linux_generic i2c_dev=/dev/i2c-2 --prefix=/
        make
        make install
        if [ -f /lib/libTO.so ] && [ -f /lib/libTO_i2c_wrapper.so ]; then
            cp -f /lib/libTO.so /lib/libTO_i2c_wrapper.so /media/emmc_rootfs/lib/.
        else
            echo "Failed to build TO136 library !"
            cd /home/$sd_user/
            exit 1
        fi
        sync
    else
        cp -f /lib/libTO.so /lib/libTO_i2c_wrapper.so /media/emmc_rootfs/lib/.
        sync
    fi

    if [ ! -f /home/$sd_user/dsi-storage/decrypt-dsi-storage ] || [ ! -f /home/$sd_user/dsi-storage/encrypt-dsi-storage ]; then
        echo "Build TO136 tools ..."
        cd /home/$sd_user/dsi-storage
        make all
        if [ -f decrypt-dsi-storage ] && [ -f encrypt-dsi-storage ]; then
            cp decrypt-dsi-storage /media/emmc_rootfs/root/.
        else
            echo "Failed to build TO136 tools !"
            cd /home/$sd_user/
            exit 1
        fi
        sync
    else
        cp /home/$sd_user/dsi-storage/decrypt-dsi-storage /media/emmc_rootfs/root/.
        sync
    fi

    # Encrypt DSI partition on $PARTITION2
    echo "Encrypt DSI partition on /dev/$PARTITION2 ..."

    rm -f /root/.to136
    /home/$sd_user/dsi-storage/encrypt-dsi-storage /dev/$PARTITION2
    cp /root/.to136 /media/emmc_rootfs/root/.
    /home/$sd_user/dsi-storage/decrypt-dsi-storage /dev/$PARTITION2 dsi

    dsi_storage=$(ls /dev/mapper/ | grep dsi)
    if [ "$dsi_storage" = "dsi" ]; then
        echo "Format in EXT4"
        set +e
        echo -e "y\n" | mkfs.ext4 /dev/mapper/dsi
        set -e
    else
        echo "Failed to encrypt dsi storage !"
        umount /media/emmc_rootfs
        if grep -qs '/media/usb_drive' /proc/mounts; then
            umount /media/usb_drive
        fi
        exit 1
    fi

    # Update the new emmc encryt home directory
    echo "Mount /media/emmc_home on /dev/$PARTITION2"
    mkdir -p /media/emmc_home
    if grep -qs '/media/emmc_home' /proc/mounts; then
        echo "$target home mounted"
    else
        mount -t ext4 /dev/mapper/dsi /media/emmc_home
    fi

    if [ $? -ne 0 ]; then
        echo "Error mount $target home."
        (>&2 echo "Error mount $target home.")
        umount /media/emmc_rootfs
        if grep -qs '/media/usb_drive' /proc/mounts; then
            umount /media/usb_drive
        fi
        exit 1
    fi

    echo "untar home tarball in emmc_home"
    mkdir -p /media/emmc_rootfs/home
    cd /tmp/.
    tar -xpzf home.tar.gz -C /media/emmc_home/. --numeric-owner
    rm -f home.tar.gz
    cd -
    sync

    echo "Update emmc_rootfs"
    # Update service configuration files
    if [ ! -f /media/emmc_rootfs/root/dsi-storage ]; then
        echo "#!/bin/bash" > /media/emmc_rootfs/root/dsi-storage
        echo "[ -z \"\$1\" ] && echo \"Missing mount point\" && exit 2" >> /media/emmc_rootfs/root/dsi-storage
        echo "lsblk | grep -qs /home && echo \"\$1 already mounted\" && exit 0" >> /media/emmc_rootfs/root/dsi-storage
        echo "if [ -f /root/.to136 ]; then" >> /media/emmc_rootfs/root/dsi-storage
        echo "    /root/decrypt-dsi-storage /dev/$PARTITION2 dsi" >> /media/emmc_rootfs/root/dsi-storage
        echo "    mount -t ext4 /dev/mapper/dsi \$1" >> /media/emmc_rootfs/root/dsi-storage
        echo "fi" >> /media/emmc_rootfs/root/dsi-storage
    fi
    if [ "$target" != "emmc" ]; then
        sed -i "s/mmcblk2p2/$PARTITION2/g" /media/emmc_rootfs/root/dsi-storage
    fi
    chmod 700 /media/emmc_rootfs/root/dsi-storage
    chmod 700 /media/emmc_rootfs/root/decrypt-dsi-storage

    if [ ! -f /media/emmc_rootfs/lib/systemd/system/dsi-storage.service ]; then
        echo "[Unit]" > /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "Description=Service to mount dsi storage" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "[Service]" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "Type=oneshot" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "ExecStart=/bin/bash /root/dsi-storage /home" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "[Install]" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
        echo "WantedBy=multi-user.target" >> /media/emmc_rootfs/lib/systemd/system/dsi-storage.service
    fi

    SERVICE_FILE=/media/emmc_rootfs/lib/systemd/system/systemd-user-sessions.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            sed -i "s/After=remote-fs.target nss-user-lookup.target network.target/After=remote-fs.target nss-user-lookup.target network.target dsi-storage.service/g" $SERVICE_FILE
            line=$(awk '/After=/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/BNM.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
           line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
           line=$((line+1))
           sed -i "$line""iAfter=dsi-storage.service\nRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    if [ -f /media/emmc_rootfs/boot/uEnv.txt ]; then
        # debian jessie
        SERVICE_FILE=/media/emmc_rootfs/usr/local/lib/systemd/system/ssh.service
    else
        # debian stretch
        SERVICE_FILE=/media/emmc_rootfs/lib/systemd/system/ssh.service
    fi

    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            sed -i "s/After=network.target auditd.service/After=network.target auditd.service dsi-storage.service/g" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/wifi-manager.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iAfter=network.target dsi-storage.service\nRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/3g_manager.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iAfter=dsi-storage.service\nRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/sleepmode.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iAfter=dsi-storage.service\nRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/BLETranslator.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iAfter=dsi-storage.service\nRequires=dsi-storage.service" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    sync

    echo "Umount $target"
    umount /media/emmc_rootfs
    umount /media/emmc_home
    cryptsetup luksClose /dev/mapper/dsi
    rm -rf /media/emmc_home
    # TODO on eMMc boot board after login for Bridge version < 1.6.4
    # sudo apt-get update && sudo apt-get -y install cryptsetup
    # sudo systemctl enable dsi-storage.service && sudo reboot

else
    SERVICE_FILE=/media/emmc_rootfs/etc/systemd/system/wifi-manager.service
    if [ -f $SERVICE_FILE ]; then
        if ! grep -qs 'dsi-storage' $SERVICE_FILE ; then
            line=$(awk '/Description/{ print NR; exit }' $SERVICE_FILE)
            line=$((line+1))
            sed -i "$line""iAfter=network.target" $SERVICE_FILE
        fi
    else
        echo "Failed to find $SERVICE_FILE"
        exit 1
    fi

    sync

    echo "Umount $target"
    umount /media/emmc_rootfs
fi

if grep -qs '/media/usb_drive' /proc/mounts; then
    echo "Umount usb_drive"
    umount /media/usb_drive
fi

if [ "$2" = "fuse_boot_on_emmc" ] || [ "$3" = "fuse_boot_on_emmc" ] ; then
    echo "Blowing fuses to boot on emmc ..."
    echo 0x1060 > /sys/fsl_otp/HW_OCOTP_CFG4
    echo 0x10 > /sys/fsl_otp/HW_OCOTP_CFG5
fi

if [ "$2" = "fuse_boot_on_sdcard" ] || [ "$3" = "fuse_boot_on_sdcard" ] ; then
    echo "Blowing fuses to boot on sdcard ..."
    echo 0x2840 > /sys/fsl_otp/HW_OCOTP_CFG4
    echo 0x10 > /sys/fsl_otp/HW_OCOTP_CFG5
fi

echo "Set Silent Uboot ..."
bash /home/debian/script/update_uboot.sh $DISK

echo "$target ready !"
