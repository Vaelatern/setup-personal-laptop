# Set these variables, then execute.
: ${USERNAME:=iforgottosetausername}
: ${HOSTNAME:=iforgottosetahostname}
: ${USER_PASSWORD:=voidlinux}
: ${ROOT_PASSWORD:=voidlinux}
: ${TIMEZONE:=America/Chicago}
: ${REPO:=https://alpha.de.repo.voidlinux.org/current/musl/}
: ${ARCH:=x86_64-musl}

# Start with a hostname in case hostname leaks in setup later (such as mdadm)
hostname "${HOSTNAME}"

# Format single nvme disk
# Swap at 72 gigs for 64 gig max (hibernation) and sqrt(64) more gigs just in case
printf "o
Y
n\n1\n
+1G
EF00
n\n2\n
+72G
8200
n\n3\n\n
8300
w
Y
" | gdisk /dev/nvme0n1

# Prepare the three partitions
mkswap /dev/nvme0n1p2
swapon /dev/nvme0n1p2
mkfs.vfat /dev/nvme0n1p1
zpool create root -m none /dev/nvme0n1p3

# Prepare mountpoints for the rest
zfs create -o mountpoint=none root/void
zfs create -o mountpoint=/sysroot root/void/root
zfs create -o mountpoint=/sysroot/var root/void/var
zfs create -o mountpoint=/sysroot/home root/homes
zfs create -o mountpoint=/sysroot/home/"${USERNAME}" root/homes/"${USERNAME}"

mkdir -p /sysroot/boot/EFI

mount /dev/nvme0n1p1 /sysroot/boot/EFI

# Install Void
mkdir -p /sysroot/var/db/xbps/keys
cp /var/db/xbps/keys/* /sysroot/var/db/xbps/keys
XBPS_ARCH="${ARCH}" xbps-install -Sy -r /sysroot -R "${REPO}" base-system zfs grub-x86_64-efi

# This is the part where we chroot
mount --rbind /sys /sysroot/sys && mount --make-rslave /sysroot/sys
mount --rbind /dev /sysroot/dev && mount --make-rslave /sysroot/dev
mount --rbind /proc /sysroot/proc && mount --make-rslave /sysroot/proc
cp /etc/resolv.conf /sysroot/etc/

######################
# Inside the chroot....
cat <<SETUP_EOF | PS1='(chroot) # ' chroot /sysroot/ /bin/bash
# We set the ... timezone
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
#            ... hostname
hostname "${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
#            ... user account
useradd -m -G wheel,lp,audio,video,cdrom,scanner,kvm,input,users,xbuilder "${USERNAME}"
#            ... user password
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd -c SHA512
#            ... root password
echo "root:${ROOT_PASSWORD}" | chpasswd -c SHA512
#            ... default services
ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -s /etc/sv/sshd /etc/runit/runsvdir/default/
#            ... fstab
extract_uuid() {
	blkid_line="$(blkid "$1")";
	tmp="${blkid_line#*' UUID="'}";
	uuid="${tmp%%\"*}";
	end_of_line="$2";
	full_line="UUID=${uuid} ${end_of_line}"
	echo "$full_line"
}
extract_uuid /dev/nvme0n1p1 "/boot/efi vfat defaults 0 2" >> /etc/fstab
extract_uuid /dev/nvme0n1p2 "swap swap defaults 0 0" >> /etc/fstab
#            ... dkms
# musl doesn't yet care about this
# dd if=/dev/urandom bs=1 count=4 > /etc/hostid
zpool set cachefile=/etc/zfs/zpool.cache root
#            ... grub https://openzfs.github.io/openzfs-docs/Getting%20Started/RHEL-based%20distro/RHEL%208-based%20distro%20Root%20on%20ZFS/5-bootloader.html
rm -f /etc/zfs/zpool.cache
touch /etc/zfs/zpool.cache
chmod a-w /etc/zfs/zpool.cache
chattr +i /etc/zfs/zpool.cache
zpool set bootfs=root/void/root root
echo 'GRUB_ENABLE_BLSCFG=false' >> /etc/default/grub
echo 'export ZPOOL_VDEV_NAME_PATH=YES' >> /etc/profile.d/zpool_vdev_name_path.sh
source /etc/profile.d/zpool_vdev_name_path.sh
mkdir -p /boot/EFI/rocky        # EFI GRUB dir
mkdir -p /boot/grub2
disk=/dev/nvme0n1
efibootmgr -cgp 1 -l "\EFI\rocky\shimx64.efi" -L "rocky-${disk##*/}" -d ${disk}
tee /etc/grub.d/09_fix_root_on_zfs <<EOF
#!/bin/sh
echo 'insmod zfs'
echo 'set root=(hd0,gpt2)'
EOF
chmod +x /etc/grub.d/09_fix_root_on_zfs
grub2-mkconfig -o /boot/EFI/rocky/grub.cfg
cp /boot/EFI/rocky/grub.cfg /boot/EFI/rocky/grub2/grub.cfg
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id="Void"
#            ... home permissions
chmod "${USERNAME}:${USERNAME}" /home/"${USERNAME}"
#            ... everything
xbps-reconfigure -fa
SETUP_EOF

# Now fix the roots
umount -R /sysroot

zfs set mountpoint=/ root/void/root
zfs set mountpoint=/var root/void/var
zfs set mountpoint=/home root/homes
zfs set mountpoint=/home/"${USERNAME}" root/homes/"${USERNAME}"

zfs snapshot -r root@first-boot

reboot
