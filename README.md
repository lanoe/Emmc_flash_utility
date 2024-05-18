# Procedure to install Dsi system on eMMC disk.  

This procedure permit to install from an SD card, the Dsi Sytem on eMMc.

Hardware :
- SD card with Bridge system. 
- Linux PC.
- Board with jumper selection.

## 1. Compress Bridge system 

First action is the compression of DsiBridge Operating system to reduce the delay of eMMC burn.

Mount SD card with Bridge system on a Linux PC (root right will be needed).

execute :

    sudo ./generate_bridge_img.sh /media/user/rootfs Bridge_compress_image

Once completed, you should have the message "generation end !".

This script will generate compress Bridge image named "Bridge_compress_image.gz".

## 2. Prepare SD card

Now we are going to update the SD card to install the necessary environnment to burn eMMC.

Mount SD card with Bridge system on a Linux PC (root right will be needed).

execute : 

     sudo ./prepare_sd_card.sh /media/user/rootfs Bridge_compress_image
     
Once completed, you should have the message "sdcard ready !".

## 3. Write on eMMC card

- PowerOff the board

- Mount the SD card (prepared on step 2) on a compatible board with jumpers for boot selection.

- Set the jumper to boot on SD card : 3-4 and 5-6

- PowerOn the board

- Once connected to the board,

execute :

    sudo ./emmc_flash.sh Bridge_compress_image no_encryption
    
Once completed, you should have the message "emmc ready !".

To update another board, you can follow this procedure (just step 3).

If you remove "no_encryption", the encrypted partition will be created.

If you add "fuse_boot_on_emmc", the fuse will be burned in the aim to boot from the eMMc. (independently of DIP switch selection).

You can burn the emmc with a compressed image stored on USB (plugged on the board) by adding "/media/usb_drive/" :

execute :

    sudo ./emmc_flash.sh /media/usb_drive/Bridge_compress_image
    

## 4. Check the system start on eMMc

- PowerOff the board

- Remove the SD card from the board

- Set the jumper to boot on eMMc : 1-2, 3-4 and 7-8

- PowerOn the board
