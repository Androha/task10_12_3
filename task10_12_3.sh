#!/bin/bash

dname=$(dirname "$(readlink -f "$0")")
source "$dname/config"
cd $dname

#Making dirs and files

mkdir -p "$dname/config-drives/vm1-config"
mkdir -p "$dname/config-drives/vm2-config"
mkdir -p "$dname/networks"

touch "$dname/config-drives/vm1-config/meta-data"
touch "$dname/config-drives/vm1-config/user-data"

touch "$dname/config-drives/vm2-config/meta-data"
touch "$dname/config-drives/vm2-config/user-data"

touch "$dname/networks/external.xml"
touch "$dname/networks/internal.xml"
touch "$dname/networks/management.xml"

mkdir -p "$dname/docker/etc"
mkdir -p "$dname/docker/certs"

touch "$dname/docker/etc/nginx.conf"

mkdir -p $NGINX_LOG_DIR

#Making certificates

openssl genrsa -out $dname/docker/certs/root.key 2048
openssl req -x509 -new -key $dname/docker/certs/root.key -days 365 -out $dname/docker/certs/root.crt -subj '/C=UA/ST=KharkivskaOblast/L=Kharkiv/O=KhNURE/OU=IMI/CN=rootCA'

openssl genrsa -out $dname/docker/certs/web.key 2048
openssl req -new -key $dname/docker/certs/web.key -nodes -out $dname/docker/certs/web.csr -subj "/C=UA/ST=KharkivskaOblast/L=Karkiv/O=KhNURE/OU=IMI/CN=$(hostname -f)"

openssl x509 -req -extfile <(printf "subjectAltName=IP:${VM1_EXTERNAL_IP},DNS:${VM1_NAME}") -days 365 -in $dname/docker/certs/web.csr -CA $dname/docker/certs/root.crt -CAkey $dname/docker/certs/root.key -CAcreateserial -out $dname/docker/certs/web.crt

cat $dname/docker/certs/root.crt >> $dname/docker/certs/web.crt

#Changing network xmls
#Ext

MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
echo "<network>
  <name>${EXTERNAL_NET_NAME}</name>
  <forward mode='nat'/>
  <ip address='${EXTERNAL_NET_HOST_IP}' netmask='${EXTERNAL_NET_MASK}'>
    <dhcp>
      <range start='${EXTERNAL_NET}.2' end='${EXTERNAL_NET}.254'/>
      <host mac='${MAC}' name='${VM1_NAME}' ip='${VM1_EXTERNAL_IP}'/>
    </dhcp>
  </ip>
</network>" > $dname/networks/external.xml

#Int

echo "<network>
  <name>${INTERNAL_NET_NAME}</name>
</network>" > $dname/networks/internal.xml

#Mgmt

echo "<network>
  <name>${MANAGEMENT_NET_NAME}</name>
  <ip address='${MANAGEMENT_HOST_IP}' netmask='${MANAGEMENT_NET_MASK}'/>
</network>" > $dname/networks/management.xml

#Changing VM configs
#VM-1
#meta-data

echo "instance-id: vm1-123
hostname: ${VM1_NAME}
local-hostname: ${VM1_NAME}
public-keys:
 - `cat ${SSH_PUB_KEY}`
network-interfaces: |
  auto ${VM1_EXTERNAL_IF}
  iface ${VM1_EXTERNAL_IF} inet dhcp

  auto ${VM1_INTERNAL_IF}
  iface ${VM1_INTERNAL_IF} inet static
  address ${VM1_INTERNAL_IP}
  netmask ${INTERNAL_NET_MASK}

  auto ${VM1_MANAGEMENT_IF}
  iface ${VM1_MANAGEMENT_IF} inet static
  address ${VM1_MANAGEMENT_IP}
  netmask ${MANAGEMENT_NET_MASK}" > $dname/config-drives/vm1-config/meta-data

#user-data

echo "#!/bin/bash
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o ${VM1_EXTERNAL_IF} -j MASQUERADE
ip link add ${VXLAN_IF} type vxlan id ${VID} remote ${VM2_INTERNAL_IP} local ${VM1_INTERNAL_IP} dstport 4789
ip link set ${VXLAN_IF} up
ip addr add ${VM1_VXLAN_IP}/24 dev ${VXLAN_IF}
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable'
apt-get update
apt-get install docker-ce -y
mount /dev/cdrom /mnt
cp -r /mnt/docker /home/ubuntu
umount /dev/cdrom
docker run -d -v /home/ubuntu/docker/etc/:/etc/nginx/conf.d -v /home/ubuntu/docker/certs:/etc/ssl/certs -v ${NGINX_LOG_DIR}:/var/log/nginx -p ${NGINX_PORT}:443 ${NGINX_IMAGE}" > $dname/config-drives/vm1-config/user-data

#VM-2
#meta-data

echo "instance-id: vm2-123
hostname: ${VM2_NAME}
local-hostname: ${VM2_NAME}
public-keys:
 - `cat ${SSH_PUB_KEY}`
network-interfaces: |
  auto ${VM2_INTERNAL_IF}
  iface ${VM2_INTERNAL_IF} inet static
  address ${VM2_INTERNAL_IP}
  netmask ${INTERNAL_NET_MASK}
  gateway ${VM1_INTERNAL_IP}
  dns-nameservers ${VM_DNS}

  auto ${VM2_MANAGEMENT_IF}
  iface ${VM2_MANAGEMENT_IF} inet static
  address ${VM2_MANAGEMENT_IP}
  netmask ${MANAGEMENT_NET_MASK}" > $dname/config-drives/vm2-config/meta-data

#user-data

echo "#!/bin/bash
ip link add ${VXLAN_IF} type vxlan id ${VID} remote ${VM1_INTERNAL_IP} local ${VM2_INTERNAL_IP} dstport 4789
ip link set ${VXLAN_IF} up
ip addr add ${VM2_VXLAN_IP}/24 dev ${VXLAN_IF}
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable'
apt-get update
apt-get install docker-ce -y
docker run -d -p ${APACHE_PORT}:80 ${APACHE_IMAGE}" > $dname/config-drives/vm2-config/user-data

#nginx.conf

echo "server {
        listen 443 ssl;
        ssl on;
        ssl_certificate /etc/ssl/certs/web-bundle.crt;
        ssl_certificate_key /etc/ssl/certs/web.key;
        location / {
                proxy_pass http://${VM2_VXLAN_IP}:${APACHE_PORT};
}
}" > $dname/docker/etc/nginx.conf


#Creating networks

virsh net-define $dname/networks/external.xml
virsh net-define $dname/networks/internal.xml
virsh net-define $dname/networks/management.xml

virsh net-start external
virsh net-start internal
virsh net-start management

#Creating disks and ISOs

#mkdir -p /var/lib/libvirt/images/vm1
#mkdir -p /var/lib/libvirt/images/vm2
#wget -O /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 ${VM_BASE_IMAGE}
#cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 ${VM1_HDD}
#cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 ${VM2_HDD}

cp -r $dname/docker $dname/config-drives/vm1-config
mkisofs -o "$VM1_CONFIG_ISO" -V cidata -r -J $dname/config-drives/vm1-config
mkisofs -o "$VM2_CONFIG_ISO" -V cidata -r -J $dname/config-drives/vm2-config

#Making VMs
#VM1

virt-install --connect qemu:///system --name ${VM1_NAME} --ram ${VM1_MB_RAM} --vcpus=${VM1_NUM_CPU} --${VM_TYPE} --os-type=linux --os-variant=ubuntu16.04 --disk path=${VM1_HDD},format=qcow2,bus=virtio,cache=none --disk path=${VM1_CONFIG_ISO},device=cdrom --network network=${EXTERNAL_NET_NAME},mac=${MAC} --network network=${INTERNAL_NET_NAME} --network network=${MANAGEMENT_NET_NAME} --graphics vnc,port=-1 --noautoconsole --virt-type ${VM_VIRT_TYPE} --import

#VM2

virt-install --connect qemu:///system --name ${VM2_NAME} --ram ${VM2_MB_RAM} --vcpus=${VM2_NUM_CPU} --${VM_TYPE} --os-type=linux --os-variant=ubuntu16.04 --disk path=${VM2_HDD},format=qcow2,bus=virtio,cache=none --disk path=${VM2_CONFIG_ISO},device=cdrom --network network=${INTERNAL_NET_NAME} --network network=${MANAGEMENT_NET_NAME} --graphics vnc,port=-1 --noautoconsole --virt-type ${VM_VIRT_TYPE} --import
