#! /bin/bash
#
# boot-time tasks for Sensor Gnome (for debian 7.0 armhf)
# These must be run before network interfaces are brought up!

# Capture the hostname entered by the user in raspi-imager
[[ -f /etc/sensorgnome/hostname-init ]] || cp /etc/hostname /etc/sensorgnome/hostname-init

# Generate the sensorgnome unique system ID into /etc/sensorgnome/id
# This ID is associated with the CPU chip, thus if the hardware is swapped out due to a failure
# the station will get a new ID...
./gen_id.sh

# Make sure serial number-hostname for local host is in /etc/hosts
sed -i /etc/hosts \
    -e "/127.0.0.1[ \t]\+localhost/s/^.*$/127.0.0.1\tlocalhost `hostname`/" \
    -e "s/raspberrypi/`hostname`/"

# Increment the persistent bootcount in /etc/bootcount
BOOT_COUNT_FILE="/etc/sensorgnome/bootcount"
if [[ -f $BOOT_COUNT_FILE ]]; then
    COUNT=`cat $BOOT_COUNT_FILE`;
    if [[ "$COUNT" == "" ]]; then
        COUNT=0;
    fi
    echo $(( 1 + $COUNT )) > $BOOT_COUNT_FILE
else
    echo 1 > $BOOT_COUNT_FILE
fi
echo "The boot count is $(cat $BOOT_COUNT_FILE)"
sync

# Create /data partition if we don't have one yet
./create_data_part.sh

# The "Datasaver" in sensorgnome expects to write data to /media/SD_card and
# /media/diskNportM, so ensure /media/SD_card is a symlink to /data
[[ -e /media/SD_card ]] || ln -s /data /media/SD_card

# mount and move specific files from /boot/firmware into /etc/sensorgnome, the reason for this is that
# boot/firmware is a fat32 filesystem where the user can edit some config files before first boot
echo "Moving data from /boot/firmware to /etc/sensorngome"
shopt -s nullglob
if [[ -n $(echo /boot/firmware/*tag*.sqlite) ]]; then
    mv /boot/firmware/*tag*.sqlite /etc/sensorgnome/SG_tag_database.sqlite
fi
if [[ -f /boot/firmware/usb-port-map.txt ]]; then
    mv /boot/firmware/usb-port-map.txt /etc/sensorgnome/
fi
if [[ -n $(echo /boot/firmware/*.pub) ]]; then
    username=`getent passwd 1000 | cut -d: -f1`
    mkdir -p "/home/${username}/.ssh"
    cat /boot/firmware/*.pub >>"/home/${username}/.ssh/authorized_keys"
    chown -R "${username}" "/home/${username}/.ssh"
    chmod 644 /home/${username}/.ssh/*
    rm /boot/firmware/*.pub
fi

# Detect any HAT with the ability to explicitly override for HATs that don't detect properly,
# for example when stacking two HATs, which is something the rpi cannot detect.
mkdir -p /dev/sensorgnome
if [[ -f /proc/device-tree/hat/product ]]; then
    cp /proc/device-tree/hat/product /dev/sensorgnome/hat
fi
if [[ -f /etc/sensorgnome/force-hat ]]; then
    cp /etc/sensorgnome/force-hat /dev/sensorgnome/hat
fi

# ensure we're running in UTC
rm -f /etc/localtime
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# starting with 2023-106 we store an image creation timestamp in /etc/sensorgnome/image-stamp
# but when upgrading that's missing... make one up using /opt/sensorgnome
if ! [[ -f /etc/sensorgnome/image-stamp ]]; then
    stat -c %Y /opt/sensorgnome > /etc/sensorgnome/image-stamp
fi

# ensure we're close enough to a current date that chrony will sync (10 years)
if [[ $(date +%Y) -lt 2020 ]]; then
    echo "Setting date to 2020-01-01"
    date -s 2020-01-01
fi

# Update /boot/firmware/SENSORGNOME.txt (FAT32 boot partition, readable by Windows)
# - Same device: update the boot count on the last line
# - New device:  freeze current section, append separator + new section
# - First boot:  append device ID + boot count to the build header written by the pifile
update_sg_card_id() {
    local SGFILE=/boot/firmware/SENSORGNOME.txt
    local DEVICE_ID; DEVICE_ID=$(cat /etc/sensorgnome/id)
    local BOOTCOUNT; BOOTCOUNT=$(cat /etc/sensorgnome/bootcount)
    local last_device=""
    [[ -f "$SGFILE" ]] && last_device=$(awk '/^SG-/{d=$0} END{print d}' "$SGFILE")

    if [[ "$last_device" == "$DEVICE_ID" ]]; then
        # Same device: replace the last line with updated boot count
        { head -n -1 "$SGFILE"; echo "Boot $BOOTCOUNT"; } >"${SGFILE}.tmp" && mv "${SGFILE}.tmp" "$SGFILE"
    elif [[ -z "$last_device" && -f "$SGFILE" ]]; then
        # File exists with build header only (first boot after flash): append device lines
        printf '%s\n%s\n' "$DEVICE_ID" "Boot $BOOTCOUNT" >>"$SGFILE"
    else
        # New device (or file missing): write separator + full new section
        local VER; VER=$(cat /etc/sensorgnome/version 2>/dev/null || echo "unknown")
        local BUILT; BUILT=$(date -u -d @$(cat /etc/sensorgnome/image-stamp) +"%Y-%m-%d" 2>/dev/null || echo "unknown")
        printf '%s\n%s\n%s UTC\n%s\n%s\n' \
            "---" "$VER" "$BUILT" "$DEVICE_ID" "Boot $BOOTCOUNT" >>"$SGFILE"
    fi
    echo "Updated SENSORGNOME.txt: device=$DEVICE_ID boot=$BOOTCOUNT"
}
update_sg_card_id || echo "Warning: could not update SENSORGNOME.txt"
