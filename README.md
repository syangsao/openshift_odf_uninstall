# openshift_odf_uninstall

Clean uninstall of OpenShift Data Foundation (ODF, internal mode) on the **luke**
OpenShift cluster (4.22.x), based on Red Hat KCS *"Uninstalling OpenShift Data
Foundation in Internal mode"*.

## What it does

`uninstall-odf.sh` walks through the full procedure:

1. Sets uninstall annotations (`cleanup-policy=delete`, `mode=forced`) on the
   StorageCluster — forced because luke's install is half-initialized and NooBaa
   can never become healthy (its CNPG Postgres cluster `noobaa-db-pg-cluster`
   is unrecoverable; the `initdb` job keeps failing).
2. Deletes any user PVCs/OBCs/volume snapshots provisioned on ODF storageclasses
   (none exist on luke; internal `noobaa-db` PVCs are skipped and handled by
   forced mode).
3. Patches NooBaa with `cleanupPolicy.allowNoobaaDeletion: true` and deletes the
   stuck CNPG cluster that blocks NooBaa initialization.
4. Deletes the StorageCluster (ODF ≥ 4.19 path) and waits.
5. Removes leftover finalizers (`rook-ceph-mon-endpoints`, `rook-ceph-mon`,
   `ocs-client-operator-config`, `noobaa`) if anything is stuck.
6. Verifies cleanup jobs and that `/var/lib/rook` is empty on storage nodes.
7. Deletes the `openshift-storage` namespace.
8. Post-cleanup: unlabels/untaints nodes, deletes Released PVs, leftover ODF
   storageclasses, and all ODF CRDs; final verification.

## Usage

```bash
# Preview every command without executing anything:
./uninstall-odf.sh --dry-run

# Real run (interactive confirmations at destructive steps):
./uninstall-odf.sh
```

Requires an authenticated `oc` client pointed at the target cluster
(`system:admin` on luke).

## Notes

- This removes **all** data stored in ODF. There is no undo.
- The script was adapted to luke's state (no CephCluster, no user PVCs/OBCs,
  no monitoring/registry/logging on ODF, no local-storage operator, no
  encryption devices). On a fully initialized cluster the same flow applies;
  steps that find nothing are no-ops.
- If you plan to **reinstall** ODF on the same disks, first follow Red Hat's
  OSD disk cleanup guidance (`sgdisk --zap-all /dev/<disk>`) — Ceph replicates
  OSD metadata across locations on the disk and reinstall fails on unclean disks.
