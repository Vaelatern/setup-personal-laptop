umount -R /sysroot
zpool destroy root
swapoff /dev/nvme0n1p2
wipefs /dev/nvme0n1
