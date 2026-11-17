#!/usr/bin/env bash
# Uninstall OpenShift Data Foundation (internal mode) on the "luke" cluster.
# Based on Red Hat KCS: "Uninstalling OpenShift Data Foundation in Internal mode".
#
# Adapted for luke's actual state (ODF 4.22.7-rhodf, half-initialized install):
#   - No CephCluster/CephBlockPools/OBCs/user PVCs/snapshots exist yet
#   - NooBaa is stuck in "Creating" because its CNPG Postgres cluster
#     (noobaa-db-pg-cluster) is unrecoverable -> handled by forced mode +
#     finalizer removal below
#   - Monitoring/registry/logging are NOT on ODF; no local-storage operator
#   - No storage nodes labelled, no encryption devices (nothing to dm-crypt)
#
# This script DESTRUCTIVELY removes all ODF data and components.
set -uo pipefail

NS="openshift-storage"
SC_NAME="ocs-storagecluster"
DRY_RUN=false

log()  { echo -e "\n\033[1;34m== $* ==\033[0m"; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
fail() { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; }

run() {
  if $DRY_RUN; then
    # print the command without emitting its output (keeps $(...) loops clean)
    printf '  [dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

confirm() {
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ---------------------------------------------------------------------------
log "0. Sanity checks"
run oc whoami >/dev/null || { fail "not logged in"; exit 1; }
if ! run oc get storagecluster -n "$NS" "$SC_NAME" >/dev/null 2>&1; then
  warn "StorageCluster $SC_NAME not found - ODF may already be partially uninstalled."
fi

# ---------------------------------------------------------------------------
log "1. Uninstall annotations (cleanup-policy=delete, mode=forced)"
# forced: proceed even though internal PVCs (noobaa-db) still exist; the cluster
# is half-initialized and NooBaa can never become healthy.
run oc annotate storagecluster -n "$NS" "$SC_NAME" \
  uninstall.ocs.openshift.io/cleanup-policy="delete" --overwrite
run oc annotate storagecluster -n "$NS" "$SC_NAME" \
  uninstall.ocs.openshift.io/mode="forced" --overwrite

# ---------------------------------------------------------------------------
log "2. Delete user PVCs/OBCs/volumesnapshots using ODF"
# No user resources found on luke; delete any that appear (excluding internal).
for sc in $(run oc get storageclasses --no-headers 2>/dev/null | grep -E 'ceph|noobaa' | awk '{print $1}'); do
  for pvc in $(run oc get pvc --all-namespaces --no-headers 2>/dev/null | awk -v sc="$sc" '$7==sc {print $1"/"$2}'); do
    ns="${pvc%%/*}"; name="${pvc##*/}"
    [[ "$name" == noobaa-db* ]] && continue   # internal, handled by forced mode
    warn "deleting user PVC $ns/$name"
    run oc delete pvc "$name" -n "$ns" --wait=true --timeout=5m
  done
done
for obc in $(run oc get obc --all-namespaces --no-headers 2>/dev/null | awk '{print $1"/"$2}'); do
  ns="${obc%%/*}"; name="${obc##*/}"
  warn "deleting OBC $ns/$name"
  run oc delete obc "$name" -n "$ns" --wait=true --timeout=5m
done
for vs in $(run oc get volumesnapshot --all-namespaces --no-headers 2>/dev/null | awk '{print $1"/"$2}'); do
  ns="${vs%%/*}"; name="${vs##*/}"
  run oc delete volumesnapshot "$name" -n "$ns" --wait=true --timeout=5m
done

# ---------------------------------------------------------------------------
log "3. Allow NooBaa deletion + remove blockers (CNPG cluster is unrecoverable)"
run oc patch noobaa noobaa -n "$NS" --type='merge' \
  -p '{"spec":{"cleanupPolicy":{"allowNoobaaDeletion":true}}}'
# The CNPG Postgres cluster never became ready and blocks NooBaa init.
# Deleting it unblocks the uninstall (it has no data worth keeping).
if run oc get clusters.postgresql.cnpg.noobaa.io -n "$NS" >/dev/null 2>&1; then
  for c in $(run oc get clusters.postgresql.cnpg.noobaa.io -n "$NS" --no-headers | awk '{print $1}'); do
    warn "deleting CNPG cluster $c (unrecoverable, blocking NooBaa)"
    run oc delete clusters.postgresql.cnpg.noobaa.io "$c" -n "$NS" --wait=true --timeout=5m
  done
fi

# ---------------------------------------------------------------------------
log "4. Delete StorageCluster (ODF >= 4.19) and wait"
confirm "Delete StorageCluster $SC_NAME now? This removes all ODF data."
run oc delete -n "$NS" storagecluster --all --wait=true --timeout=10m

# ---------------------------------------------------------------------------
log "5. Remove leftover finalizers if resources are stuck"
for res in "configmap rook-ceph-mon-endpoints" "secret rook-ceph-mon"; do
  set -- $res
  if run oc get "$1" -n "$NS" "$2" >/dev/null 2>&1; then
    warn "removing disaster-protection finalizer from $1/$2"
    run oc patch "$1" -n "$NS" "$2" --type merge \
      -p '{"metadata":{"finalizers":null}}'
  fi
done
if run oc get configmap ocs-client-operator-config -n "$NS" >/dev/null 2>&1; then
  warn "removing finalizer from configmap/ocs-client-operator-config"
  run oc patch configmap ocs-client-operator-config -n "$NS" --type merge \
    -p '{"metadata":{"finalizers":null}}'
fi
if run oc get noobaa noobaa -n "$NS" >/dev/null 2>&1; then
  warn "removing finalizer from noobaa/noobaa"
  run oc patch noobaa noobaa -n "$NS" --type merge \
    -p '{"metadata":{"finalizers":null}}'
fi

# ---------------------------------------------------------------------------
log "6. Verify cleanup jobs (cleanup-policy=delete)"
if ! $DRY_RUN; then
  sleep 30
  oc get pods -n "$NS" | grep -i cleanup || warn "no cleanup jobs found"
  # Confirm /var/lib/rook is empty on any storage node
  for i in $(oc get node -l cluster.ocs.openshift.io/openshift-storage= -o name 2>/dev/null); do
    oc debug "$i" -- chroot /host ls -l /var/lib/rook 2>&1 | tail -3
  done
fi

# ---------------------------------------------------------------------------
log "7. Delete the openshift-storage namespace"
confirm "Delete namespace $NS (removes ODF operators and all remaining resources)?"
run oc project default
run oc delete project "$NS" --wait=true --timeout=5m

# ---------------------------------------------------------------------------
log "8. Post-uninstall cleanup"
run oc label nodes --all cluster.ocs.openshift.io/openshift-storage-
run oc label nodes --all topology.rook.io/rack-
run oc adm taint nodes --all node.ocs.openshift.io/storage-
# Leftover PVs in Released state
for pv in $(run oc get pv --no-headers 2>/dev/null | awk '$4=="Released" {print $1}'); do
  warn "deleting released PV $pv"
  run oc delete pv "$pv" --wait=true --timeout=5m
done
# Leftover ODF storageclasses
run oc delete sc openshift-storage.noobaa.io --wait=true --timeout=5m 2>/dev/null || true

log "9. Delete ODF CustomResourceDefinitions (NotFound is fine)"
run oc delete crd \
  backingstores.noobaa.io backups.postgresql.cnpg.noobaa.io \
  bucketclasses.noobaa.io cephblockpoolradosnamespaces.ceph.rook.io \
  cephblockpools.ceph.rook.io cephbucketnotifications.ceph.rook.io \
  cephbuckettopics.ceph.rook.io cephclients.ceph.rook.io \
  cephclusters.ceph.rook.io cephconnections.csi.ceph.io \
  cephcosidrivers.ceph.rook.io cephfilesystemmirrors.ceph.rook.io \
  cephfilesystems.ceph.rook.io cephfilesystemsubvolumegroups.ceph.rook.io \
  cephnfses.ceph.rook.io cephnvmeofgateways.ceph.rook.io \
  cephobjectrealms.ceph.rook.io cephobjectstoreaccounts.ceph.rook.io \
  cephobjectstores.ceph.rook.io cephobjectstoreusers.ceph.rook.io \
  cephobjectzonegroups.ceph.rook.io cephobjectzones.ceph.rook.io \
  cephrbdmirrors.ceph.rook.io clientprofilemappings.csi.ceph.io \
  clientprofilereplications.csi.ceph.io clientprofiles.csi.ceph.io \
  clusterimagecatalogs.postgresql.cnpg.noobaa.io \
  clusters.postgresql.cnpg.noobaa.io csiaddonsnodes.csiaddons.openshift.io \
  databases.postgresql.cnpg.noobaa.io drivers.csi.ceph.io \
  encryptionkeyrotationcronjobs.csiaddons.openshift.io \
  encryptionkeyrotationjobs.csiaddons.openshift.io \
  failoverquorums.postgresql.cnpg.noobaa.io \
  imagecatalogs.postgresql.cnpg.noobaa.io namespacestores.noobaa.io \
  networkfenceclasses.csiaddons.openshift.io \
  networkfences.csiaddons.openshift.io noobaaaccounts.noobaa.io \
  noobaas.noobaa.io objectbucketclaims.objectbucket.io \
  objectbuckets.objectbucket.io ocsinitializations.ocs.openshift.io \
  operatorconfigs.csi.ceph.io poolers.postgresql.cnpg.noobaa.io \
  publications.postgresql.cnpg.noobaa.io recipes.ramendr.openshift.io \
  reclaimspacecronjobs.csiaddons.openshift.io \
  reclaimspacejobs.csiaddons.openshift.io \
  scheduledbackups.postgresql.cnpg.noobaa.io \
  storageautoscalers.ocs.openshift.io storageclients.ocs.openshift.io \
  storageclusterpeers.ocs.openshift.io storageclusters.ocs.openshift.io \
  storageconsumers.ocs.openshift.io subscriptions.postgresql.cnpg.noobaa.io \
  tlsprofiles.ocs.openshift.io \
  volumegroupreplicationclasses.replication.storage.openshift.io \
  volumegroupreplicationcontents.replication.storage.openshift.io \
  volumegroupreplications.replication.storage.openshift.io \
  volumegroupsnapshotclasses.groupsnapshot.storage.openshift.io \
  volumegroupsnapshotcontents.groupsnapshot.storage.openshift.io \
  volumegroupsnapshots.groupsnapshot.storage.openshift.io \
  volumereplicationclasses.replication.storage.openshift.io \
  volumereplications.replication.storage.openshift.io \
  --wait=true --timeout=5m

# ODF 4.19.0-7 only: storageclient finalizer (harmless if absent)
run oc patch storageclient ocs-storagecluster --type merge \
  -p '{"metadata":{"finalizers": []}}' 2>/dev/null || true

# ---------------------------------------------------------------------------
log "10. Final verification"
if ! $DRY_RUN; then
  echo "--- namespace:"
  oc get project "$NS" 2>&1 | head -1
  echo "--- CSVs in openshift-storage:"
  oc get csv -n "$NS" --no-headers 2>&1 | head -5
  echo "--- ODF CRDs remaining:"
  oc get crd --no-headers 2>/dev/null | grep -E 'ceph|noobaa|ocs\.openshift|objectbucket|csiaddons' || echo "none"
  echo "--- PVs:"
  oc get pv --no-headers 2>/dev/null | awk '$4=="Released"' || true
fi

log "Done."
warn "If you plan to reinstall ODF on the same disks, follow the OSD disk"
warn "cleanup doc (sgdisk --zap-all /dev/<disk>) before redeploying."
