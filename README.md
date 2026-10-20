# firedrill

Disaster-recovery drills for Postgres on Kubernetes. Spins up a 4-node kind cluster running [CloudNativePG](https://cloudnative-pg.io) with WAL archiving to S3, breaks it four different ways, and times the recovery.

## Results

Apple Silicon laptop, kind, CloudNativePG 1.30.1, Barman Cloud Plugin 0.15.1:

| Drill | What breaks | Recovery |
|---|---|---|
| `failover` | Primary pod force-deleted | 5s to a writable new primary |
| `nodekill` | Node hosting the primary stopped (`docker stop`) | 54s to a writable new primary |
| `volumeloss` | Replica pod and its PVC deleted | 24s to a rebuilt replica |
| `pitr` | `DROP TABLE` on the primary | 49s to a restored cluster, 1002/1002 rows |

CI runs every drill on each push and weekly; numbers land in the job summary.

## Finding: node loss took 6 minutes, not 1

The first `nodekill` run took **353s**. Postgres was not the bottleneck. The CNPG operator pod happened to be on the same node as the primary, so killing that node killed the operator too. With nothing left to promote a replica, the cluster stayed down until Kubernetes evicted the operator (default `tolerationSeconds: 300` for unreachable nodes) and rescheduled it. The new operator failed over in under a second.

Shortening `tolerationSeconds` on the Postgres pods did nothing (355s). Pinning the operator off the database nodes took it to **54s**. In a real cluster that means the operator lives on a system node pool, never alongside the workloads it is supposed to rescue.

## Setup

- `kind.yaml`: 1 control plane, 3 workers
- `s3.yaml`: SeaweedFS as the S3 target (MinIO no longer publishes images)
- `cluster.yaml`: 3-instance Postgres, one per worker, WAL archived through the Barman Cloud Plugin
- `drill.sh`: install, drills, teardown

Recovery is measured from the moment of failure to a successful `INSERT` on the new primary, not from the operator's status field.

## Run

Needs Docker, kind, and kubectl.

```sh
./drill.sh up
./drill.sh all
./drill.sh down
```

Or one at a time: `./drill.sh failover|nodekill|volumeloss|pitr`.
