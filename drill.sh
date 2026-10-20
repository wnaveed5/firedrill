#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CNPG=1.30.1
BARMAN=0.15.1
CERT_MANAGER=1.21.2
CTX=kind-firedrill
PIN='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]}}}}'

k() { kubectl --context "$CTX" "$@"; }
now() { date +%s; }
primary() { k get cluster pg -o jsonpath='{.status.currentPrimary}'; }
sql() { timeout 10 kubectl --context "$CTX" exec "$1" -c postgres -- psql -qtAX -c "$2"; }

wait_for() {
  local end=$(( $(now) + 900 ))
  until "$@"; do
    (( $(now) < end )) || { echo "timeout: $*" >&2; exit 1; }
    sleep 1
  done
}

writable_new() {
  local p
  p=$(primary)
  [[ -n $p && $p != "$1" ]] && sql "$p" "insert into drill default values" >/dev/null 2>&1
}

ready() { [[ $(k get cluster "$1" -o jsonpath='{.status.readyInstances}') == "$2" ]]; }
pod_gone() { ! k get pod "$1" >/dev/null 2>&1; }
archived() { [[ $(sql "$(primary)" "select last_archived_wal >= '$1' from pg_stat_archiver") == t ]]; }

table() { sql "$(primary)" "create table if not exists drill (id serial primary key, at timestamptz default now())" >/dev/null 2>&1; }

up() {
  kind create cluster --name firedrill --config kind.yaml
  k apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG/cnpg-$CNPG.yaml"
  k -n cnpg-system patch deploy cnpg-controller-manager --type merge -p "$PIN"
  k -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s
  k apply -f "https://github.com/cert-manager/cert-manager/releases/download/v$CERT_MANAGER/cert-manager.yaml"
  k -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
  k apply -f "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v$BARMAN/manifest.yaml"
  k -n cnpg-system rollout status deploy/barman-cloud --timeout=300s
  k apply -f s3.yaml
  k rollout status deploy/s3 --timeout=300s
  k apply -f cluster.yaml
  wait_for ready pg 3
  table
}

failover() {
  table
  local p t0
  p=$(primary)
  t0=$(now)
  k delete pod "$p" --grace-period=0 --force >/dev/null 2>&1
  wait_for writable_new "$p"
  echo "failover     $(( $(now) - t0 ))s  primary $p -> $(primary)"
  wait_for ready pg 3
}

nodekill() {
  table
  local p node t0
  p=$(primary)
  node=$(k get pod "$p" -o jsonpath='{.spec.nodeName}')
  t0=$(now)
  docker stop "$node" >/dev/null
  wait_for writable_new "$p"
  echo "nodekill     $(( $(now) - t0 ))s  primary $p -> $(primary)"
  docker start "$node" >/dev/null
  wait_for ready pg 3
}

volumeloss() {
  table
  local r t0
  r=$(k get pods -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
  t0=$(now)
  k delete pvc "$r" --wait=false >/dev/null
  k delete pod "$r" --grace-period=0 --force >/dev/null 2>&1
  wait_for pod_gone "$r"
  wait_for ready pg 3
  echo "volumeloss   $(( $(now) - t0 ))s  replica $r rebuilt"
}

pitr() {
  table
  local p b rows target seg t0 restored
  p=$(primary)
  b=base-$(now)
  k apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $b
spec:
  cluster:
    name: pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  k wait "backup/$b" --for=jsonpath='{.status.phase}'=completed --timeout=600s >/dev/null
  sql "$p" "insert into drill (at) select now() from generate_series(1, 1000)" >/dev/null
  rows=$(sql "$p" "select count(*) from drill")
  target=$(sql "$p" "select now()")
  sleep 1
  sql "$p" "drop table drill" >/dev/null
  seg=$(sql "$p" "select pg_walfile_name(pg_switch_wal())")
  wait_for archived "$seg"
  t0=$(now)
  k apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-restore
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: pg
      recoveryTarget:
        targetTime: "$target"
  externalClusters:
    - name: pg
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: store
          serverName: pg
EOF
  wait_for ready pg-restore 1
  restored=$(sql pg-restore-1 "select count(*) from drill")
  echo "pitr         $(( $(now) - t0 ))s  rows $restored/$rows restored after drop table"
  k delete cluster pg-restore >/dev/null
  table
}

down() { kind delete cluster --name firedrill; }

all() { failover; nodekill; volumeloss; pitr; }

"${1:?usage: drill.sh up|failover|nodekill|volumeloss|pitr|all|down}"
