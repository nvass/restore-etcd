#!/bin/sh

DAY=$(date '+%Y%m%d')
TAB='	'

get_value() {
  unset V

  if [ $# = 2 ]; then
    printf '%s? ' "$2"
  else
    printf '%s(%s)? ' "$2" "$3"
  fi
  read V
  if [ -z "$V" ]; then
    if [ $# = 3 ]; then
      eval "$1=$3"
    fi
  else
    eval "$1=$V"
  fi
}

get_etcd() {

  docker ps -a --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}' | awk -F "$TAB" -v p=$1 '
    BEGIN {
      healthy = 0
      ill = 0
    }

    $3 ~ /^docker\/ucp-etcd/ {
      if ($NF ~ /\(healthy\)/)
        healthy_etcd[healthy++] = $0
      else
        unhealthy_etcd[ill++] = $0
    }
    END {
      if (p == "health") {
        printf "There are %s healthy etcd containers and %s ill etcd containers:\n", healthy, ill
        for (f in healthy_etcd)
          print healthy_etcd[f]
        print ""
        if (length(unhealthy_etcd) > 0) {
          print "WARNING:"
          for (f in unhealthy_etcd)
            print unhealthy_etcd[f]
          print ""
        }
      }
      if (p == "names") {
        for (f in healthy_etcd) {
          split(healthy_etcd[f], a)
          print a[1] "|" a[2]
        }
        for (f in unhealthy_etcd) {
          split(unhealthy_etcd[f], a)
          print a[1] "|" a[2]
        }
      }
    }
  '
}

usage() {

#  echo $0 'etcd-backup-file [certs-backup-file]'
  echo $0 'etcd-backup-file'
  exit 1
}

#[ $# != 1 -a $# != 2 ] && usage
[ $# != 1 ] && usage

if [ $# = 1 ]; then
  [ ! -f "$1" ] && usage
  ETCDBACKUPFILE=$1
fi

#if [ $# = 2 ]; then
  #[ ! -f "$1" ] && usage
  #ETCDBACKUPFILE=$1
  #[ ! -f "$2" ] && usage
  #CERTSBACKUPFILE=$2
#fi

if [ -z "$DOCKER_HOST" ]; then
  echo DOCKER_HOST is empty. You need to use a UCP client bundle: 1>&2
  echo '  https://docs.docker.com/ee/ucp/user-access/cli/' 1>&2
  exit 1
fi

if ! OUTPUT_DOCKER_INFO=$(docker info 2>&1)
then
  printf 'Something went wrong:\n%s\n' "$OUTPUT_DOCKER_INFO" 1>&2
  exit 1
fi

message=$(get_etcd health)
printf '%s\n' "$message" 'Press Enter to continue or Ctrl-c to exit if something is wrong'
read message

for VOLUMEID in $(get_etcd names); do
  VOLUME=$(echo $VOLUMEID | cut -d '|' -f 1)
  ID=$(echo $VOLUMEID | cut -d '|' -f 2)
  HOST=$(echo $VOLUME | cut -d '/' -f 1)
  unset IP
  while [ -z "$IP ]; do
    get_value IP "IP address of ${HOST}"
  done
  get_value PROTO 'https or http' https
  get_value ETCD_NAME 'ETCD cluster member name' $(echo m${IP})
  get_value ETCD_CLIENT_PORT 'ETCD client port' '12379'
  get_value ETCD_PEER_PORT 'ETCD peer port' 12380
  ETCD_DATA="$ETCD_DATA|$ID,$VOLUME,$IP,$ETCD_NAME,$ETCD_CLIENT_PORT,$ETCD_PEER_PORT,$PROTO"
  ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER},${ETCD_NAME}=${PROTO}://${IP}:${ETCD_PEER_PORT}"
done

ETCD_DATA=$(echo $ETCD_DATA | sed 's/^|//')
ETCD_INITIAL_CLUSTER=$(echo $ETCD_INITIAL_CLUSTER | sed 's/^,//')

for ETCD_MEMBER in $(echo $ETCD_DATA | tr '|' ' '); do
  ID=$(echo $ETCD_MEMBER | cut -d , -f 1)
  IP=$(echo $ETCD_MEMBER | cut -d , -f 3)
  ETCD_NAME=$(echo $ETCD_MEMBER | cut -d , -f 4)
  ETCD_PEER_PORT=$(echo $ETCD_MEMBER | cut -d , -f 6)
  PROTO=$(echo $ETCD_MEMBER | cut -d , -f 7)
  docker cp $ETCDBACKUPFILE ${ID}:/data/etcdbackupfile-${DAY}.db
  docker exec --env ETCDCTL_API=3 $ID /bin/sh -cx "
    cd /data
    etcdctl snapshot restore etcdbackupfile-${DAY}.db --name $ETCD_NAME \
      --initial-cluster $ETCD_INITIAL_CLUSTER --initial-cluster-token etcd-cluster-1 \
      --initial-advertise-peer-urls ${PROTO}://${IP}:${ETCD_PEER_PORT}
    rm etcdbackupfile-${DAY}.db
  "
done
