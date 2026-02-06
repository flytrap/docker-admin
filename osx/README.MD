## command

```bash
sudo apt update && sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils
sudo adduser $USER kvm
sudo adduser $USER libvirt
sudo chmod 666 /dev/kvm
qemu-img create -f qcow2 ./data/mac_hdd_ng.img 128G

lsmod | grep kvm

```

在 宿主机（运行 VMware 的那台 Windows 或 Mac） 上修改虚拟机设置。

关闭该 Ubuntu 虚拟机。

进入虚拟机设置：设置 (Settings) -> 处理器 (Processors)。

勾选 “虚拟化 Intel VT-x/EPT 或 AMD-V/RVI” (Virtualize Intel VT-x/EPT or AMD-V/RVI)。

勾选 “虚拟化 CPU 性能计数器” (Virtualize CPU performance counters)。

保存并重新启动 Ubuntu。
