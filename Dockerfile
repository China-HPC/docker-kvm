FROM ubuntu:18.04
LABEL MAINTAINER="xhzhang zzz332191120@gmail.com"

RUN \
  apt-get update && \
  apt-get install -y qemu-kvm qemu-utils bridge-utils dnsmasq uml-utilities iptables wget net-tools && \
  apt-get autoclean && \
  apt-get autoremove && \
  rm -rf /var/lib/apt/lists/*

ADD runvm.sh /

ENV OS_ISO=/kvm/cn_windows_10_multiple_editions_x64_dvd_6848463.iso
ENV DRV_ISO=/kvm/drv.iso
ENV RAM=2048
ENV SMP=1
ENV SOCKETS=1
ENV CORES=2
ENV THREADS=1
ENV MAXCPUS=2
ENV VM_NAME=virtual-desktop
ENV VGAID='8086 01916'
ENV VGAHOST='0000:00:02.0'
ENV VGAHOST_SHORT='00:02.0'
ENV QEMU_AUDIO_DRV=alsa
ENV VNC='0.0.0.0:1'
ENV ROM_FILE='/kvm/vbios.bin'
ENV AUDIO_DEVICE='AC97'
ENV BOOT_ORDER='c'
ENV DISK_FILE=/kvm/disk.qcow2
ENV TELNET='127.0.0.1:55555'
ENV KBD_DEVICE_EVENT='/dev/input/event4'
ENV MOUSE_DEVICE_EVENT='/dev/input/by-path/pci-0000:00:14.0-usb-0:8:1.0-event-mouse'

VOLUME /data

ENTRYPOINT ["/runvm.sh"]
