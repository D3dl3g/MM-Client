#!/bin/bash

# Define the correct config.txt path
CONFIG_PATH="/boot/firmware/config.txt"

# Check if config.txt exists, if not, create it
if [ ! -f "$CONFIG_PATH" ]; then
  echo -e "\033[0;33mconfig.txt not found, creating a new one...\033[0m"
else
  echo -e "\033[0;31mWarning: $CONFIG_PATH already exists, it will be overwritten.\033[0m"
fi

# Backup the existing config.txt if it exists
if [ -f "$CONFIG_PATH" ]; then
  echo -e "\033[0;31mBacking up the existing config.txt to config.bk...\033[0m"
  sudo mv "$CONFIG_PATH" /boot/firmware/config.bk
fi

# Create a new config.txt with the desired content
echo -e "\033[0;33mCreating the new config.txt...\033[0m"

# Use sudo tee to write the new config.txt
sudo tee /boot/firmware/config.txt > /dev/null <<EOF
# For more options and information see
# http://rptl.io/configtxt
# Some settings may impact device functionality. See link above for details

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Additional overlays and parameters are documented
# /boot/firmware/overlays/README

# Automatically load overlays for detected cameras
#camera_auto_detect=1

# Automatically load overlays for detected DSI displays
#display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
#dtoverlay=vc4-kms-v3d
#max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
# Use the kernel's default instead.
#disable_fw_kms_setup=1

# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

# Run as fast as firmware / board allows
arm_boost=1

[cm4]
# Enable host mode on the 2711 built-in XHCI USB controller.
# This line should be removed if the legacy DWC2 controller is required
# (e.g. for USB device mode) or if USB support is not required.
#otg_mode=1

[cm5]
#dtoverlay=dwc2,dr_mode=host

[all]
gpu_mem=256
EOF

# Success message with padding
echo -e "\033[0;32mconfig.txt has been created and updated successfully!\033[0m"
echo -e "\n"  # Blank line

# Prompt user for the URL
echo -e "\033[0;33mPlease enter the URL for the kiosk (default: http://mm-server:8080):\033[0m"
read -r kiosk_url
kiosk_url=${kiosk_url:-http://mm-server:8080}  # Default to http://mm-server:8080 if no input is provided
echo -e "\033[0;32mKiosk URL set to: $kiosk_url\033[0m"
echo -e "\n"  # Blank line

# Update system and install necessary packages
echo -e "\033[0;33mUpdating system and installing required packages...\033[0m"
sudo apt update -y > /dev/null 2>&1 && sudo apt upgrade -y > /dev/null 2>&1 && sudo apt autoremove -y > /dev/null 2>&1
sudo apt install --no-install-recommends xserver-xorg x11-xserver-utils xinit openbox chromium konsole -y > /dev/null 2>&1
echo -e "\033[0;32mSystem updated and packages installed.\033[0m"
echo -e "\n"  # Blank line

# Replace Openbox autostart file
echo -e "\033[0;33mSetting up Openbox autostart...\033[0m"
mkdir -p ~/.config/openbox
cat <<EOF > ~/.config/openbox/autostart
xrandr --output HDMI-1 --mode 1920x1080
chromium-browser --noerrdialogs --disable-infobars --kiosk --incognito $kiosk_url &
xset s off
xset -dpms
xset s noblank
EOF
echo -e "\033[0;32mOpenbox autostart configured.\033[0m"
echo -e "\n"  # Blank line

# Replace .xinitrc file
echo -e "\033[0;33mConfiguring .xinitrc to start Openbox...\033[0m"
cat <<EOF > ~/.xinitrc
exec openbox-session
EOF
echo -e "\033[0;32m.xinitrc configured.\033[0m"
echo -e "\n"  # Blank line

# Replace autologin configuration for tty1
echo -e "\033[0;33mSetting up autologin for tty1...\033[0m"
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I \$TERM
EOF
echo -e "\033[0;32mAutologin for tty1 configured.\033[0m"
echo -e "\n"  # Blank line

# Replace .bash_profile
echo -e "\033[0;33mConfiguring .bash_profile to start X on tty1...\033[0m"
cat <<EOF > ~/.bash_profile
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF
echo -e "\033[0;32m.bash_profile configured to start X.\033[0m"
echo -e "\n"  # Blank line

# Final message in bold green
echo -e "\033[1;32mSetup complete. Reboot your system to apply the changes.\033[0m"

# Countdown timer with Ctrl+C cancellation
echo -e "\033[0;33mThe system will reboot in 10 seconds. Press Ctrl+C to cancel.\033[0m"
for i in {10..1}; do
    printf "\rRebooting in %d seconds... " "$i"
    sleep 1
done

# Reboot if the countdown is not interrupted
echo -e "\n\033[0;32mRebooting now...\033[0m"
sudo reboot
