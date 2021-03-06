#!/bin/bash
source function.sh
source init.sh
source docker.sh
source Toots.conf

WORK_DIR='/var/Toots'
REGISTRY_DOMAIN='registry.super.com'

check_root
check_centos
capture_ip
recover_resolve
init

if [ $REGISTRY_IP ] && [ $CA ]; then
  registry_config
fi
docker_setup
docker_compose_setup

if [ ! -d $WORK_DIR ]; then
   mkdir $WORK_DIR
fi
cd $WORK_DIR
wget -O docker-compose.yml.tpl https://raw.githubusercontent.com/CloudNil/Toots/master/docker-compose.yml.tpl
wget -O generate_yml.sh https://raw.githubusercontent.com/CloudNil/Toots/master/generate_yml.sh
chmod +x generate_yml.sh

if [ ! -d 'restricted' ]; then
  mkdir restricted
fi

MASTER="false"
SLAVE="false"
EDGE="false"

IFS=','
IPS=($MASTERS)
for i in ${!IPS[@]}
do
  ZOOKEEPER_HOSTS=$ZOOKEEPER_HOSTS"${IPS[$i]}:2181,"
  CONSUL_HOSTS=$CONSUL_HOSTS"-join=${IPS[$i]} "
  if [ $IP = ${IPS[$i]} ]; then
    ZOOKEEPER_ID=$[$i+1]
    MASTER="true"
  fi
done
if [ $ZOOKEEPER_ID ]; then
  echo '========Install Mode========'
  echo '1. Master'
  echo '2. Master + Slave'
  echo '3. Master + Slave + Edge'
  echo '============================'
  read -p 'Please enter your choice(Default:1):' option
  case "$option" in
    "1"|"" ) 
      SLAVE="false"
      EDGE="false"
      ;;
    "2" ) 
      SLAVE="true"
      EDGE="false"
      ;;
    "3" )
      SLAVE="true"
      EDGE="true"
      ;;
    * ) echo 'Error: Your choice is incorrect!' && exit 1;;
  esac
  # echo '====================Marathon Http Credentials====================='
  # echo 'Enter a credentials in the format user:password to enable'
  # echo 'or empty to disable Marathon Authentication'
  # echo '=================================================================='
  # read -p 'Auth-key:' AUTH
  # [ $AUTH ] && [[ ! "${AUTH}" =~ ^[^:]+:[^:]+$ ]] && echo 'Error: Auth-key is invalid!' && exit 1
else
  echo '========Install Mode========'
  echo '1. Slave'
  echo '2. Edge'
  echo '3. Slave + Edge'
  echo '============================'
  read -p 'Please enter your choice(Default:1):' option
   case "$option" in
    "1"|"" ) 
      SLAVE="true"
      EDGE="false"
      ;;
    "2" ) 
      SLAVE="false"
      EDGE="true"
      ;;
    "3" )
      SLAVE="true"
      EDGE="true"
      ;;
    * ) echo 'Error: Your choice is incorrect!' && exit 1;;
  esac
fi
#
if [ "$MASTER" == "true" ] && [ "$SLAVE" == "false" ]; then
 echo '============Regist Master Service============='
 echo '1. Yes'
 echo '2. No'
 echo '================================================'
 read -p 'Please enter your choice(Default:1):' option
   case "$option" in
    "1"|"" ) 
      REGISTRATOR="true"
      ;;
    "2" ) 
      REGISTRATOR="false"
      ;;
    * ) echo 'Error: Your choice is incorrect!' && exit 1;;
  esac
fi
#
if [ "$EDGE" == "true" ] && [ ! $VIP ]; then
  echo '==========================VIP Configuration==========================='
  echo 'Enter a private valid network ip to enable or empty to disable the VIP'
  echo '======================================================================'
  read -p 'VIP:' VIP
fi
#
if [ "$SLAVE" == "true" ]; then
  echo '========Slave Node Mode========'
  echo '1. Stateless'
  echo '2. Persistent'
  echo '==============================='
  read -p 'Please enter your choice(Default:1):' option
   case "$option" in
    "1"|"" ) 
      ATTRIBUTES="--attributes=type:normal"
      if [ -e "/var/store/check_sum" ]; then
        umount /var/store && rm -rf /var/store
      fi
      ;;
    "2" ) 
      ATTRIBUTES="--attributes=type:data"
      if [ ! -d "/var/store" ]; then
        mkdir /var/store
        if [ ! $NFS ]; then
          echo '===================NFS Configuration================='
          echo 'Enter remote nfs dir like : 192.168.1.9:/store'
          echo '====================================================='
          read -p 'NFS:' NFS
        fi
        install_package nfs-utils
        systemctl enable rpcbind.service
        systemctl start rpcbind.service
      
        IFS=':'
        PARAMS=($NFS)
        showmount -e ${PARAMS[0]}
        [ $? -ne 0 ] && echo 'Error: Remote nfs server is invalid!' && exit 1
        mount -t nfs4 "$NFS" /var/store -o proto=tcp -o nolock
        [ $? -ne 0 ] && echo 'Error: Remote nfs dir is invalid!' && exit 1
        #Normal Node
        echo "$NFS /var/store nfs auto,noatime,nolock,bg,nfsvers=4,intr,tcp,actimeo=1800 0 0" >> /etc/fstab
        #Aliyun Node
        #echo "mount -t nfs4 $NFS /var/store -o proto=tcp -o nolock" >> /etc/rc.d/rc.local
        #chmod +x /etc/rc.d/rc.local
      else
        echo 'Warning: dir /var/store is already exist,make sure it was mount nfs dir!'
      fi
      ;;
    * ) echo 'Error: Your choice is incorrect!' && exit 1;;
  esac
  echo '============Internal DNS and Balancing============='
  echo '1. Disable'
  echo '2. Enable'
  echo '==================================================='
  read -p 'Please enter your choice(Default:1):' option
  case "$option" in
    "1"|"" ) 
      IDB="false"
      ;;
    "2" )
      IDB="true"
      ;;
    * ) echo 'Error: Your choice is incorrect!' && exit 1;;
  esac
fi

ZOOKEEPER_HOSTS=${ZOOKEEPER_HOSTS/%,/}
CONSUL_HOSTS=${CONSUL_HOSTS/% /}
QUORUM=$[${#IPS[@]}/2+1]

echo '#Config Paramaters of Marathon' > restricted/host
echo "MASTER=$MASTER" >> restricted/host
echo "SLAVE=$SLAVE" >> restricted/host
echo "EDGE=$EDGE" >> restricted/host
echo "ZOOKEEPER_HOSTS=\"$ZOOKEEPER_HOSTS\"" >> restricted/host
echo "CONSUL_HOSTS=\"$CONSUL_HOSTS\"" >> restricted/host
echo "MESOS_MASTER_QUORUM=$QUORUM" >> restricted/host
echo "IP=$IP" >> restricted/host
echo "HOSTNAME=$IP" >> restricted/host
# By default,$IP is private network IP and LISTEN
[ "$EDGE" == "false" ] && echo "LISTEN_IP=$IP" >> restricted/host
[ $IN_DOMAIN ] && echo "CONSUL_DOMAIN=$IN_DOMAIN" >> restricted/host
[ $EX_DOMAIN ] && echo "HAPROXY_ADD_DOMAIN=$EX_DOMAIN" >> restricted/host
[ "$MASTER" == "true" ] && echo "ZOOKEEPER_ID=$ZOOKEEPER_ID" >> restricted/host
[ "$SLAVE" == "true" ] && echo "MESOS_SLAVE_PARAMS=\"$ATTRIBUTES --docker_remove_delay=1mins\"" >> restricted/host
[ $AUTH ] && echo "MARATHON_PARAMS=\"--http_credentials ${AUTH}\"" >> restricted/host
[ $VIP ] && echo "KEEPALIVED_VIP=$VIP" >> restricted/host
[ "$ZOOKEEPER_ID" == "1" ] && echo 'CONSUL_PARAMS="-bootstrap-expect 3"' >> restricted/host
[ "$REGISTRATOR" == "true" ] && echo "START_REGISTRATOR=$REGISTRATOR" >> restricted/host
[ "$IDB" == "true" ] && {
  echo 'START_CONSUL_TEMPLATE="true"' >> restricted/host
  echo 'START_DNSMASQ="true"' >> restricted/host
}
[ $REGISTRY_IP ] && echo "REGISTRY=$REGISTRY_DOMAIN/" >> restricted/host
if [ "$SLAVE" == "true" ]; then
  cover_resolve
fi
./generate_yml.sh
docker_compose_startup $PAAS_DIR
