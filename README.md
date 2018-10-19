# docker-kvm

Launching a Virtual Machine inside a Docker container.

## Features

- Non libvirt dependant.
- It uses QEMU/KVM to launch the VM directly with PID 1.
- Support GPU passthrough by [Intel GVT-d](https://github.com/intel/gvt-linux/wiki/GVTd_Setup_Guide#1-introduction).
- Match mouse and keyboard device automatically.
- It attaches to the VM as many NICs as the docker container has.
- The VM gets the original container IPs.
- Uses macvtap tun devices for best network throughput.
- Outputs serial console to stdio, thus visible using docker logs

Partially based on [BBVA/kvm](https://github.com/BBVA/kvm) project.

## System Requirements

### Host Operating System Requirements

- Ubuntu 18.04 has been fully validated as host, other Linux operating system like RHEL/Debian with 4.X+ kernel is also OK.

### Guest Operating System Supported

Fully validated list:

- Windows 10
- Ubuntu 18.04
- Debian 9

### Hardware Requirements

For client platforms, 5th, 6th or 7th Generation Intel® Core Processor Graphics is required. For server platforms, E3_v4, E3_v5 or E3_v6 Xeon Processor Graphics is required.

### Software Dependence

- [GVTd setup](https://github.com/intel/gvt-linux/wiki/GVTd_Setup_Guide) on host.
- (Optional)Virtual network deployed(ipv6 should be disabled if you choose Calico network due to this [issue](https://github.com/projectcalico/calico/issues/2191))

## Quick Start

### Build the docker image

```bash
git clone https://github.com/China-HPC/docker-kvm
cd docker-kvm
build -t docker-kvm .
```

### Run

Prepare a qcow2 empty disk file name as disk.qcow2, put the ISO image and drivers iso(optional) in the same directory, then run:

```bash
docker run --rm -e OS_ISO='/kvm/cn_windows_10_multiple_editions_x64_dvd_6848463.iso' -e DRV_ISO='/kvm/drv.iso' -e RAM=6G -v /dev:/dev -v /sys:/sys --privileged -v /opt/kvm/win10:/kvm --name kvm-test docker-kvm
```

### Options

The supported options list in the Dockerfile, specify them with `-e $VAR=$VAL`