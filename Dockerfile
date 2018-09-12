FROM ubuntu:18.04
MAINTAINER xhzhang zzz332191120@gmail.com

RUN \
  apt-get update && \
  apt-get install -y qemu-kvm qemu-utils bridge-utils dnsmasq uml-utilities iptables wget net-tools && \
  apt-get autoclean && \
  apt-get autoremove && \
  rm -rf /var/lib/apt/lists/*

ADD runvm.sh /

VOLUME /data

ENTRYPOINT ["/runvm.sh"]
