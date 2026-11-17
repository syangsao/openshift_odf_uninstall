# ODF uninstall — test record (luke cluster)

**Date:** 2026-11-17
**Cluster:** luke (`api-luke-syangsao-net:6443`), OpenShift 4.22.20
**ODF version:** 4.22.7-rhodf (all CSVs Succeeded)
**User:** system:admin

## Pre-uninstall state

- `storagecluster/ocs-storagecluster`: **Progressing** (stuck ~6 days in init)
- NooBaa stuck in `Creating` — its CNPG Postgres cluster `noobaa-db-pg-cluster`
  was "unrecoverable, needs manual intervention"; the `initdb` job kept failing
  and no instance pods ever came up
- No CephCluster / CephBlockPools / OBCs / user PVCs / volume snapshots existed
- Only internal PVC: `noobaa-db-pg-cluster-1` (50Gi, `nfs-csi`)
- Monitoring/registry/logging not on ODF; no local-storage operator; no
  encryption devices; no storage nodes labelled

## Run

```
./uninstall-odf.sh          # full run, interactive confirms
Wall time: 67.20 seconds
```

Key steps that mattered for this state:

1. `uninstall.ocs.openshift.io/mode=forced` — internal PVCs could not be
   deleted cleanly while NooBaa was wedged
2. `noobaa.cleanupPolicy.allowNoobaaDeletion=true` patch
3. Delete of the unrecoverable CNPG cluster `noobaa-db-pg-cluster` — this
   unblocked NooBaa teardown, which unblocked the StorageCluster delete
4. No finalizer intervention was needed (mon/mon-endpoints/noobaa all went away
   on their own)

## Post-run verification

| Check | Result |
|---|---|
| `oc get project openshift-storage` | NotFound ✓ |
| CSVs in openshift-storage / cluster-wide ODF CSVs | none ✓ |
| ODF CRDs remaining (`ceph\|noobaa\|ocs.openshift\|objectbucket\|csiaddons`) | none ✓ |
| Pods matching rook/noobaa/ceph/cnpg (all namespaces) | none ✓ |
| PVs in Released state | none ✓ |
| Node labels `cluster.ocs.openshift.io/openshift-storage`, taint `node.ocs.openshift.io/storage` | removed ✓ |

## Gap found and fixed after the run

Namespace deletion left behind cluster-scoped resources:

- SCCs: `rook-ceph`, `rook-ceph-csi`, `noobaa` (deleted manually)
- Mutating webhook: `csv.odf.openshift.io` (deleted manually)

Both were added to step 11 of the script (commit adding "SCC and mutating
webhook cleanup").
