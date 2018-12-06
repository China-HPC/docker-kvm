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

: ${DEBUG:='N'}
: ${USE_NET_BRIDGES:='Y'}
: ${LAUNCHER:='qemu-system-x86_64'}
: ${DNSMASQ_CONF_DIR:='/etc/dnsmasq.d'}
: ${DNSMASQ:='/usr/sbin/dnsmasq'}
: ${QEMU_CONF_DIR:='/etc/qemu/'}
: ${ENABLE_DHCP:='Y'}
: ${DISABLE_VGA:='N'}

: ${DISK_FILE:='/kvm/disk.qcow2'}
: ${KVM_BLK_OPTS:="-drive id=disk0,cache=writeback,if=virtio,format=qcow2,file=$DISK_FILE"}

: ${AUTO_ATTACH:='Y'}
mkdir -p /etc/qemu
# https://www.cnblogs.com/york-hust/archive/2012/06/12/2546334.html, how to change cd
QEMU=qemu-system-x86_64
MEM=$RAM #OOM Killer, sysctl -w vm.overcommit_memory=2,https://blog.csdn.net/fm0517/article/details/73105309/
BOOT_SPLASH='/kvm/boot.jpg'

func_sig_exit ()
{
  echo "signal caught"
  func_audio_reset
  func_vfio_reset
}
trap func_sig_exit SIGKILL SIGINT SIGTERM

vmname=$VM_NAME
if ps -A | grep -q $vmname; then
  echo "$vmname is already running." &
  exit 1
fi

# lspci -nnk
# intel igd driver: https://www.intel.cn/content/www/cn/zh/support/products/80939/graphics-drivers.html
VGAID=$VGAID
VGAHOST=$VGAHOST

log () {
  case "$1" in
    INFO | WARNING | ERROR )
      echo "$1: ${@:2}"
      ;;
    DEBUG)
      [[ $DEBUG -eq 1 ]] && echo "$1: ${@:2}"
      ;;
    *)
      echo "-- $@"
      ;;
  esac
}
# ContainsElement: checks if first parameter is among the array given as second parameter
# returns 0 if the element is found in the list and 1 if not
# usage: containsElement $item $list

containsElement () {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

# Generate random MAC address
genMAC () {
  hexchars="0123456789ABCDEF"
  end=$( for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g' )
  echo "FE:05$end"
}


# atoi: Returns the integer representation of an IP arg, passed in ascii
# dotted-decimal notation (x.x.x.x)
atoi() {
  IP=$1
  IPnum=0
  for (( i=0 ; i<4 ; ++i ))
  do
    ((IPnum+=${IP%%.*}*$((256**$((3-${i}))))))
    IP=${IP#*.}
  done
  echo $IPnum
}

# itoa: returns the dotted-decimal ascii form of an IP arg passed in integer
# format
itoa() {
  echo -n $(($(($(($((${1}/256))/256))/256))%256)).
  echo -n $(($(($((${1}/256))/256))%256)).
  echo -n $(($((${1}/256))%256)).
  echo $((${1}%256))
}


cidr2mask() {
  local i mask=""
  local full_octets=$(($1/8))
  local partial_octet=$(($1%8))

  for ((i=0;i<4;i+=1)); do
    if [ $i -lt $full_octets ]; then
      mask+=255
    elif [ $i -eq $full_octets ]; then
      mask+=$((256 - 2**(8-$partial_octet)))
    else
      mask+=0
    fi
    test $i -lt 3 && mask+=.
  done

  echo $mask
}

# Generates and returns a new IP and MASK in a superset (inmediate wider range)
# of the given IP/MASK
# usage: getNonConflictingIP IP MASK
# returns NEWIP MASK
getNonConflictingIP () {
    local IP="$1"
    local CIDR="$2"

    let "newCIDR=$CIDR-1"

    local i=$(atoi $IP)
    let "j=$i^(1<<(32-$CIDR))"
    local newIP=$(itoa j)

    echo $newIP $newCIDR
}


# generates unused, random names for macvlan or bridge devices
# usage: generateNetDevNames DEVICETYPE
#   DEVICETYPE must be either 'macvlan' or 'bridge'
# returns:
#   - bridgeXXXXXX if DEVICETYPE is 'bridge'
#   - macvlanXXXXXX, macvtapXXXXXX if DEVICETYPE is 'macvlan'
generateNetdevNames () {
  devicetype=$1

  local netdevinterfaces=($(ip link show | awk "/$devicetype/ { print \$2 }" | cut -d '@' -f 1 | tr -d :))
  local randomID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 6 | head -n 1)

  # check if the device already exists and regenerate the name if so
  while containsElement "$devicetype$randomID" "${netdevinterfaces[@]}"; do randomID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 6 | head -n 1); done

  echo "$randomID"
}


setupBridge () {
  set -x
  local iface="$1"
  local mode="$2"
  local deviceID=$(generateNetdevNames $mode)
  local bridgeName="$mode$deviceID"

  if [[ $mode == "bridge" ]]; then
    brctl addbr "$bridgeName"
    brctl addif "$bridgeName" "$iface"
  else # use macvlan devices by default
    vtapdev="macvtap${deviceID}"
    until $(ip link add link $iface name $vtapdev type macvtap mode bridge); do
      sleep 1
    done

    ip link set $vtapdev address "$MAC"
    ip link set $vtapdev up

    # create a macvlan device for the host
    ip link add link $iface name $bridgeName type macvlan mode bridge
    ip link set $bridgeName up

    # create dev file (there is no udev in container: need to be done manually)
    IFS=: read major minor < <(cat /sys/devices/virtual/net/$vtapdev/tap*/dev)
    mknod "/dev/$vtapdev" c $major $minor
  fi

  set +x
  # get a new IP for the guest machine in a broader network broadcast domain
  if ! [[ -z $IP ]]; then
    newIP=($(getNonConflictingIP $IP $CIDR))
    ip address del "$IP/$CIDR" dev "$iface"
    ip address add "${newIP[0]}/${newIP[1]}" dev "$bridgeName"
  fi

  ip link set dev "$bridgeName" up

  echo $deviceID
}


setupDhcp () {
  # dnsmasq configuration:
  if [[ "$ENABLE_DHCP" == 1 ]]; then
    log "INFO" "DHCP configured to serve IP $IP/$CIDR via ${bridgeName[0]} (attached to container's $iface)"
    DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-range=$IP,$IP --dhcp-host=$MAC,,$IP,$(hostname -s),infinite --dhcp-option=option:netmask,$(cidr2mask $CIDR)"
  else
    log "INFO" "No DHCP enabled. The VM won't get the container IP(s)"
  fi
}


# Setup macvtap device to connect later the VM and setup a new macvlan devide
# to connect the host machine to the network
configureNetworks () {
  local i=0

  local GATEWAY=$(ip r | grep default | awk '{print $3}')
  local IP

  for iface in "${local_ifaces[@]}"; do

    IPs=$(ip address show dev $iface | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/)
    IPs=($IPs)
    MAC=$(ip link show $iface | awk '/ether/ { print $2 }')
    log "DEBUG" "Container original MAC address: $MAC"

    # If the container has more than one IP configured in a given interface,
    # the user can select which one to use.
    # The SELECTED_NETWORK environment variable is used to select that IP.
    # This env variable must be in the form IP/MASK (e.g. 1.2.3.4/24).
    #
    # If this env variable is not set, the IP to be given to the VM is
    # the first in the list for that interface (default behaviour).

    if ! [[ -z "$SELECTED_NETWORK" ]]; then
      local given_ip given_mask
      IFS=/ read given_ip given_mask <<< $SELECTED_NETWORK
      local given_addr=$(atoi $given_ip)
      local given_mask=$((0xffffffff << (32 - $given_mask) & 0xffffffff))
      local given_broadcast=$((given_addr | ~given_mask & 0xffffffff))
      local given_network=$((given_addr & given_mask))

      for configured_ip in "${IPs[@]}"; do
        local configured_ip=$(atoi $configured_ip)
        if [[ $configured_ip -gt $given_network && $configured_ip -lt $given_broadcast ]]; then
          IP=$(itoa $configured_ip)
          log "INFO" "SELECTED_NETWORK ($SELECTED_NETWORK) found with ip $IP in $iface interface."
        fi
      done
      [[ -z "$IP" ]] && log "WARNING" "SELECTED_NETWORK ($SELECTED_NETWORK) not found in $iface interface."
    else
      IP=${IPs[0]}
    fi

    local CIDR=$(ip address show dev $iface | awk "/inet $IP/ { print \$2 }" | cut -f2 -d/)

    # use container MAC address ($MAC) for tap device
    # and generate a new one for the local interface
    ip link set $iface down
    ip link set $iface address $(genMAC)
    ip link set $iface up

    # setup the bridge or macvtap (default) devices for bridging the VM and the
    # container
    if [[ $USE_NET_BRIDGES == 1 ]]; then
      deviceID=$(setupBridge $iface "bridge")
      bridgeName="bridge$deviceID"
      # kvm configuration:
      echo allow $bridgeName >> $QEMU_CONF_DIR/bridge.conf
      KVM_NET_OPTS="$KVM_NET_OPTS -netdev bridge,br=$bridgeName,id=net$i"
    else
      deviceID=($(setupBridge $iface "macvlan"))
      bridgeName="macvlan$deviceID"
      # kvm configuration:
      let fd=$i+3
      KVM_NET_OPTS="$KVM_NET_OPTS -netdev tap,id=net$i,vhost=on,fd=$fd ${fd}<>/dev/macvtap$deviceID"
    fi

    setupDhcp
    log "DEBUG" "bridgeName: $bridgeName"
    KVM_NET_OPTS=" -device virtio-net-pci,netdev=net$i,mac=$MAC $KVM_NET_OPTS"
    let i++

  done
}


case "$DEBUG" in
  [Yy1]* ) DEBUG=1;;
  [Nn0]* ) DEBUG=0;;
  *      ) log "ERROR" "DEBUG incorrect or undefined. It must be one of [Yy1Nn0]"; exit 1;;
esac

case "$AUTO_ATTACH" in
  [Yy1]* ) AUTO_ATTACH=1;;
  [Nn0]* ) AUTO_ATTACH=0;;
  *      ) log "ERROR" "AUTO_ATTACH incorrect or undefined. It must be one of [Yy1Nn0]"; exit 1;;
esac

case "$ENABLE_DHCP" in
  [Yy1]* ) ENABLE_DHCP=1;;
  [Nn0]* ) ENABLE_DHCP=0;;
  *      ) log "ERROR" "ENABLE_DHCP incorrect or undefined. It must be one of [Yy1Nn0]"; exit 1;;
esac

case "$DISABLE_VGA" in
  [Yy1]* ) DISABLE_VGA=1;;
  [Nn0]* ) DISABLE_VGA=0;;
  *      ) log "ERROR" "DISABLE_VGA incorrect or undefined. It must be one of [Yy1Nn0]"; exit 1;;
esac

case "$USE_NET_BRIDGES" in
  [Yy1]* ) USE_NET_BRIDGES=1;;
  [Nn0]* ) USE_NET_BRIDGES=0;;
  *      ) log "ERROR" "USE_NET_BRIDGES incorrect or undefined. It must be one of [Yy1Nn0]"; exit 1;;
esac


if [[ "$DISABLE_VGA" -eq 0 ]]; then
  : ${KVM_VIDEO_OPTS:="-vga qxl -display none"}
else
  : ${KVM_VIDEO_OPTS:="-nographic"}
fi

if [[ $AUTO_ATTACH -eq 1 ]]; then
  # Get all interfaces:
  local_ifaces=($(ip link show | grep -v noop | grep state | grep -v LOOPBACK | awk '{print $2}' | tr -d : | sed 's/@.*$//'))
  local_bridges=($(brctl show | tail -n +2 | awk '{print $1}'))
  # Get non-bridge interfaces:
  for i in "${local_bridges[@]}"
  do
    local_ifaces=(${local_ifaces[@]//*$i*})
  done
else
  local_ifaces=($ATTACH_IFACES)
fi

DEFAULT_ROUTE=$(ip route | grep default | awk '{print $3}')

configureNetworks


if [[ "$ENABLE_DHCP" == 1 ]]; then
  # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
  /sbin/iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill

  # Build DNS options from container /etc/resolv.conf, you can edit resolv.conf on the 
  # host machine then mount it into container. You can also specify those parameters
  # by setting environment variables.
  nameservers=($(grep nameserver /etc/resolv.conf | sed 's/nameserver //'))
  searchdomains=$(grep search /etc/resolv.conf | sed 's/search //' | sed 's/ /,/g')
  domainname=$(echo $searchdomains | awk -F"," '{print $1}')

  for nameserver in "${nameservers[@]}"; do
    [[ -z $DNS_SERVERS ]] && DNS_SERVERS=$nameserver || DNS_SERVERS="$DNS_SERVERS,$nameserver"
  done
  DNSMASQ_OPTS="$DNSMASQ_OPTS                         \
    --dhcp-option=option:dns-server,$DNS_SERVERS      \
    --dhcp-option=option:router,$DEFAULT_ROUTE        \
    "
  [[ -z $searchdomains ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-search,$searchdomains"
  [[ -z $domainname ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$domainname"
  [[ -z $(hostname -d) ]] || DNSMASQ_OPTS="$DNSMASQ_OPTS --dhcp-option=option:domain-name,$(hostname -d)"
  log "INFO" "Lauching dnsmasq"
  log "DEBUG" "dnsmasq options: $DNSMASQ_OPTS"
  $DNSMASQ $DNSMASQ_OPTS
  echo $DNSMASQ $DNSMASQ_OPTS
fi

func_vfio_init () {
  echo "vfio init.."
  echo $VGAHOST > /sys/bus/pci/devices/$VGAHOST/driver/unbind
  echo $VGAID > /sys/bus/pci/drivers/vfio-pci/new_id
}

func_vfio_reset () {
  echo "vfio reset"
  echo "1" > /sys/bus/pci/devices/$VGAHOST/remove
  echo "1" > /sys/bus/pci/rescan
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
  export QEMU_AUDIO_DRV=$QEMU_AUDIO_DRV #none #spice #pa #alsa
  export QEMU_AUDIO_TIMER_PERIOD=0
  #export QEMU_PA_SERVER=/run/user/0/pulse/native
}

func_audio_reset () {
  echo "audio reset"
  #pulseaudio -k
}


func_idv_start() {
  echo "idv starting..."
  QEMUArgs=("-nodefaults" "-enable-kvm"
  "-machine type=pc,accel=kvm,igd-passthru=on"
  "-cpu host,kvm=off"
  "-rtc clock=host,base=localtime"
  "-no-hpet"
  "-serial none"
  "-parallel none"
  "-device isa-debugcon,iobase=0x402,chardev=seabios"
  "-chardev file,id=seabios,path=/tmp/bios.log"
  "-object input-linux,id=kbd1,evdev=/dev/input/by-path/`ls /dev/input/by-path|grep event-kbd`,grab_all=on,repeat=on"
  "-object input-linux,id=mouse,evdev=/dev/input/by-path/`ls /dev/input/by-path|grep event-mouse`"
  "-mem-path /dev/hugepages -mem-prealloc"
  "-global PIIX4_PM.disable_s3=1"
  "-global PIIX4_PM.disable_s4=1" 
  "-parallel none"
  "-vga none"
  "-vnc $VNC"
  "-m $MEM"
  "-smp $SMP,sockets=$SOCKETS,cores=$CORES,threads=$THREADS,maxcpus=$MAXCPUS"
  "-name $vmname,process=$vmname"
  "-device vfio-pci,host=$VGAHOST_SHORT,id=hostdev0,bus=pci.0,addr=0x02,romfile=$ROM_FILE"
  "-device $AUDIO_DEVICE"
  "-drive id=disk0,cache=writeback,if=virtio,format=qcow2,file=$DISK_FILE"
  $KVM_NET_OPTS
  "-monitor telnet:$TELNET,server,nowait"
  )
  
  ## Optional parameters
  [[ -z $OS_ISO ]] && QEMUArgs+=("-drive file=$OS_ISO,index=2,media=cdrom") && BOOT_ORDER='d'
  [[ -z $DRV_ISO ]] && QEMUArgs+=("-drive file=$DRV_ISO,index=3,media=cdrom")
  QEMUArgs+=("-boot order=$BOOT_ORDER,menu=on,splash=$BOOT_SPLASH,splash-time=5000")
 

  args=""
  for arg in ${QEMUArgs[@]}; do
    args+=" $arg"
  done
  $QEMU $args
  if [ $? -ne 0 ]; then
    echo "idv start failed"
    func_sig_exit
    exit 1
  fi
  echo "idv stoped"
  func_sig_exit
}

## call func_vfio_init on host, if running this script on host machine instead
## of container, should uncomment #func_vfio_init
#func_vfio_init
func_audio_init
func_idv_start
