# restore-etcd
Restore-etcd can be used to restore a etcd snapshot to an etcd cluster running on Docker Universal Control Plane (UCP). It tries to detect the running ucp-kv containers and restores the etcd snapshot inside them wihout affecting the running etcd cluster.
