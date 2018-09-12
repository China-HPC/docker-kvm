#!/bin/bash

# https://github.com/intel/gvt-linux/wiki/GVTd_Setup_Guide
# https://heiko-sieger.info/running-windows-10-on-linux-using-kvm-with-vga-passthrough/
# https://github.com/qemu/qemu/blob/master/docs/igd-assign.txt
# http://vfio.blogspot.com/2016/07/intel-graphics-assignment.html
# https://www.reddit.com/r/VFIO/comments/746t4h/getting_rid_of_audio_crackling_once_and_for_all/  sound

# ls -l /dev/input/by-id
# xinput list --long
# cat /proc/bus/input/devices
# I: Bus=0011 Vendor=0001 Product=0001 Version=ab54
# N: Name="AT Translated Set 2 keyboard"
# P: Phys=isa0060/serio0/input0
# S: Sysfs=/devices/platform/i8042/serio0/input/input3
# U: Uniq=
# H: Handlers=sysrq kbd event3 leds
# B: PROP=0
# B: EV=120013
# B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
# B: MSC=10
# B: LED=7


# https://www.cnblogs.com/york-hust/archive/2012/06/12/2546334.html, how to change cd
#ISO_WIN10=./cn_windows_10_pro_10240.16393_x64_pip.iso
ISO_WIN10=/mnt/share/ISO/cn_windows_10_multiple_editions_x64_dvd_6848463.iso #./cn_windows_10_pro_10240.16393_x64_pip.iso
ISO_DRV=./drv.iso  #mkisofs -r -l -o destination-filename.iso source
QEMU=/usr/bin/qemu-system-x86_64
#QEMU=/usr/bin/qemu-system-x86_64 #qemu-system-x86_64
#QEMU=/usr/qemu2.12.1/bin/qemu-system-x86_64
#QEMU=/usr/qemu3/bin/qemu-system-x86_64
MEM=6G #OOM Killer, sysctl -w vm.overcommit_memory=2,https://blog.csdn.net/fm0517/article/details/73105309/
BOOT_SPLASH='./gnu_tux-800x600.jpg'

vmname="windows10vm"
if ps -A | grep -q $vmname; then
  echo "$vmname is already running." &
  exit 1
fi

# lspci -nnk
# intel igd driver: https://www.intel.cn/content/www/cn/zh/support/products/80939/graphics-drivers.html
VGAID='8086 01916'
VGAHOST='0000:00:02.0'

func_sig_exit () 
{
  echo "signal caught"
  func_hugepage_reset
  func_audio_reset
  func_vfio_reset
  exit 0
}
trap func_sig_exit SIGKILL SIGINT SIGTERM

func_vfio_init () {
  echo "vfio init.."
  echo $VGAHOST > /sys/bus/pci/devices/$VGAHOST/driver/unbind
  echo $VGAID > /sys/bus/pci/drivers/vfio-pci/new_id
}

func_vfio_reset () {
  echo "vfio reset"
  echo "1" > /sys/bus/pci/devices/$VGAHOST/remove
  echo "1" > /sys/bus/pci/rescan
 # echo $VGAHOST > /sys/bus/pci/drivers/vfio-pci/unbind
 # echo $VGAHOST > /sys/bus/pci/drivers/i915/bind
}

# Audio in win10 GUEST
# Using ac97 driver
# -- Disable win10 driver check: "bcdedit/set testsigning on"
# -- Install AC97 driver

# some commands for audio debug
# usermod -a -G pulse,audio root
# pulseaudio --start
# pulseaudio -k
# aplay -l
# aplay -L
# pulseaudio
# pactl list sinks
# pactl stat/info
# alsamixer to control volume / mute ...
# /etc/pulse/default.pa:
# comment this line: load-module module-suspend-on-idle
func_audio_init () {
  # apt-get install pulseaudio pulseaudio-utils oss4-base osspd-pulseaudio
  echo "sound init.."
  # https://www.reddit.com/r/VFIO/comments/746t4h/getting_rid_of_audio_crackling_once_and_for_all/
  # ./configure --prefix=/usr --target-list=x86_64-softmmu --audio-drv-list=pa,alsa
  export QEMU_AUDIO_DRV=alsa #none #spice #pa #alsa
  export QEMU_PA_SAMPLES=2205 #128 #2205
  export QEMU_PA_LATENCY_OUT=20
  export QEMU_AUDIO_TIMER_PERIOD=0
  #export QEMU_PA_SERVER=/run/user/0/pulse/native
}

func_audio_reset () {
  echo "audio reset"
  #pulseaudio -k
}

func_hugepage_init () {
  echo "hugepage init.."
  #https://heiko-sieger.info/running-windows-10-on-linux-using-kvm-with-vga-passthrough/#Configure_hugepages
  #hugeadm --explain
  mount -t hugetlbfs hugetlbfs /dev/hugepages
  sysctl vm.nr_hugepages=3072 #6G memory
}

func_hugepage_reset () {
  echo "hugepage reset"
  umount /dev/hugepages
  sysctl vm.nr_hugepages=0
  echo 3 > /proc/sys/vm/drop_caches #drop cache
}

func_idv_start() {
  echo "idv starting..."
  $QEMU \
  -nodefaults \
  -enable-kvm \
  -name $vmname,process=$vmname \
  -machine type=pc,accel=kvm,igd-passthru=on \
  -cpu host,kvm=off \
  -smp 2,sockets=2,cores=1,threads=1,maxcpus=2 \
  -m $MEM \
  -rtc clock=host,base=localtime \
  -vnc 0.0.0.0:1 \
  -serial none \
  -parallel none \
  -vga none \
  -device vfio-pci,host=00:02.0,id=hostdev0,bus=pci.0,addr=0x02,romfile=./vbios.bin \
  -device AC97 \
  -drive file=$ISO_DRV,index=2,media=cdrom \
  -boot order=c,menu=on,splash=./boot.jpg,splash-time=5000 \
  -drive id=disk0,cache=writeback,if=virtio,format=qcow2,file=./win10.qcow2 \
  -device virtio-net-pci,netdev=net0,mac=00:16:3e:00:01:01 \
  -netdev type=user,hostfwd=tcp::3389-:3389,id=net0 \
  -chardev file,id=seabios,path=/tmp/bios.log \
  -device isa-debugcon,iobase=0x402,chardev=seabios \
  -monitor telnet:127.0.0.1:55555,server,nowait \
  -object input-linux,id=kbd1,evdev=/dev/input/event4,grab_all=on,repeat=on \
  -object input-linux,id=mouse,evdev=/dev/input/by-path/pci-0000:00:14.0-usb-0:8:1.0-event-mouse \
  -mem-path /dev/hugepages -mem-prealloc
  echo "idv stoped"
}

func_vfio_init
func_audio_init
func_hugepage_init
func_idv_start
func_sig_exit

#-boot order=d,menu=on,splash=$BOOT_SPLASH,splash-time=10,reboot-timeout=10 \
#  -drive file=$ISO_WIN10,index=1,media=cdrom \
#-device isa-vga \
#-vga none
#x-igd-gms=1
#-device vfio-pci,host=00:02.0,id=hostdev0,bus=pci.0,addr=0x02,romfile=./vbios.bin \ #need rom-fixer, https://www.redhat.com/archives/vfio-users/2017-March/msg00152.html
#  -bios ./seabios-latest.bin \
