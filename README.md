# openshift_odf_uninstall

Clean uninstall of OpenShift Data Foundation (ODF, internal mode) on any
OpenShift cluster, based on Red Hat KCS *"Uninstalling OpenShift Data
Foundation in Internal mode"*.

## What it does

`uninstall-odf.sh` walks through the full procedure:

1. Sanity checks and ODF version detection (picks `storagesystem` for ODF ≤ 4.18,
   `storagecluster` for ≥ 4.19).
2. Sets uninstall annotations on the StorageCluster
   (`cleanup-policy=delete`, `mode=forced`).
3. Deletes user PVCs / OBCs / volume snapshots provisioned on ODF storageclasses
   (internal NooBaa PVCs are skipped — forced mode handles them).
4. Removes monitoring stack, image registry, and cluster logging dependencies on
   ODF if present (registry is switched to `emptyDir` first).
5. Patches NooBaa with `cleanupPolicy.allowNoobaaDeletion: true` and deletes any
   CNPG Postgres cluster (`clusters.postgresql.cnpg.noobaa.io`) that blocks
   NooBaa initialization.
6. Deletes the StorageCluster and waits (10 min timeout).
7. Removes leftover finalizers if resources are stuck: `rook-ceph-mon-endpoints`,
   `rook-ceph-mon`, `ocs-client-operator-config`, `noobaa`, and `storageclient`
   (ODF 4.19.0-7).
8. Verifies cleanup jobs and that `/var/lib/rook` is empty on storage nodes.
9. Deletes the `openshift-storage` namespace.
10. Post-cleanup: unlabels/untaints nodes, deletes Released PVs, leftover ODF
    storageclasses, SCCs, and the `csv.odf.openshift.io` mutating webhook.
11. Deletes all ODF CustomResourceDefinitions.
12. Cleans up the local-storage operator (LSO) resources if ODF ran on local
    disks (LocalVolumeSets, LocalVolumes, discovery, node symlinks, namespace).

## Usage

```bash
# Preview every command without executing anything:
./uninstall-odf.sh --dry-run

# Real run (interactive confirmations at destructive steps):
./uninstall-odf.sh
```

Requires an authenticated `oc` client pointed at the target cluster with
cluster-admin rights.

## Notes

- This removes **all** data stored in ODF. There is no undo.
- `mode=forced` is used by default so a stuck/half-initialized install can still
  be removed; switch the annotation to `mode=graceful` if you want the
  uninstaller to wait for you to delete PVCs/OBCs first (orphaned resources are
  left behind in forced mode).
- If you plan to **reinstall** ODF on the same disks, first follow Red Hat's OSD
  disk cleanup guidance (`sgdisk --zap-all /dev/<disk>`) — Ceph replicates OSD
  metadata across locations on the disk and reinstall fails on unclean disks.
- Optional KMS/Vault steps from the KCS (clusterrolebinding `vault-tokenreview-binding`,
  vault KV metadata deletion) are not automated; do them manually if cluster-wide
  encryption with Vault was enabled.

## Test record

Tested end-to-end on an ODF 4.22.7-rhodf install (half-initialized: NooBaa stuck in
`Creating` behind an unrecoverable CNPG Postgres cluster) — the full run completed
in ~67s and left no ODF resources behind (namespace, CSVs, CRDs, SCCs, webhook all
verified gone). The session record is available at `local://odf-uninstall-luke.md`.
