#!/usr/bin/env bash
# Uninstall OpenShift Data Foundation (ODF) in internal mode on any OpenShift cluster.
# Based on Red Hat KCS: "Uninstalling OpenShift Data Foundation in Internal mode".
#
# Covers the full procedure:
#   - uninstall annotations (cleanup-policy, mode)
#   - user PVC / OBC / volume snapshot cleanup
#   - monitoring stack, image registry, cluster logging dependencies
#   - StorageCluster deletion (storagesystem for <= 4.18, storagecluster for >= 4.19)
#   - NooBaa allowNoobaaDeletion + CNPG Postgres cluster blockers
#   - finalizer removal (mon, mon-endpoints, ocs-client-operator-config, noobaa,
#     storageclient on ODF 4.19.0-7)
#   - cleanup job verification, /var/lib/rook checks on storage nodes
#   - namespace deletion, node label/taint removal, PV/storageclass/CRD cleanup
#   - local-storage operator (LSO) cleanup if ODF ran on local disks
#   - SCC and csv.odf.openshift.io mutating webhook removal
#
# This script DESTRUCTIVELY removes all ODF data. There is no undo.
set -uo pipefail

NS="openshift-storage"
SC_NAME="ocs-storagecluster"
DRY_RUN=false

log()  { echo -e "\n\033[1;34m== $* ==\033[0m"; }
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
run oc whoami >/dev/null || { fail "not logged in to an OpenShift cluster"; exit 1; }
if ! run oc get storagecluster -n "$NS" "$SC_NAME" >/dev/null 2>&1; then
  warn "StorageCluster $SC_NAME not found - ODF may already be partially uninstalled."
fi

# Detect ODF major.minor from the ocs-operator CSV to pick the right delete resource.
ODF_VER=""
if ! $DRY_RUN; then
  ODF_VER=$(oc get csv -n "$NS" --no-headers 2>/dev/null | awk '/^ocs-operator/ {print $2}')
fi
case "$ODF_VER" in
  4.1[0-8]*|4.[0-9]*) DELETE_RES="storagesystem";;   # ODF <= 4.18
  *)                  DELETE_RES="storagecluster";;  # ODF >= 4.19 (default)
esac
echo "  deleting resource type: $DELETE_RES (ODF version: ${ODF_VER:-unknown})"

# ---------------------------------------------------------------------------
log "1. Uninstall annotations"
# cleanup-policy=delete: Rook cleans physical drives and DataDirHostPath.
# mode=forced: proceed even if PVCs/OBCs still exist (orphaned resources remain).
# Use mode=graceful instead to make the uninstaller wait for you to delete them.
run oc annotate storagecluster -n "$NS" "$SC_NAME" \
  uninstall.ocs.openshift.io/cleanup-policy="delete" --overwrite
run oc annotate storagecluster -n "$NS" "$SC_NAME" \
  uninstall.ocs.openshift.io/mode="forced" --overwrite

# ---------------------------------------------------------------------------
log "2. Delete user PVCs/OBCs/volumesnapshots using ODF"
# Internal NooBaa PVCs (noobaa-db*, noobaa-default-backing-store*) are skipped;
# forced mode handles them. Everything else on an ODF storageclass is deleted.
for sc in $(run oc get storageclasses --no-headers 2>/dev/null | grep -E 'ceph|noobaa' | awk '{print $1}'); do
  for pvc in $(run oc get pvc --all-namespaces --no-headers 2>/dev/null | awk -v sc="$sc" '$7==sc {print $1"/"$2}'); do
    ns="${pvc%%/*}"; name="${pvc##*/}"
    [[ "$name" == noobaa-db* || "$name" == noobaa-default-backing-store* ]] && continue
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
log "3. Remove monitoring stack dependency (if any)"
if ! $DRY_RUN && oc get pvc -n openshift-monitoring --no-headers 2>/dev/null | grep -q 'ocs-storagecluster\|ceph'; then
  warn "openshift-monitoring has PVCs on ODF storageclasses."
  warn "Remove the alertmanagerMain/prometheusK8s volumeClaimTemplate sections from"
  warn "configmap cluster-monitoring-config in openshift-monitoring first, or delete"
  warn "the PVCs manually. Deleting them now:"
  for pvc in $(oc get pvc -n openshift-monitoring --no-headers | awk '$6 ~ /ocs-storagecluster|ceph/ {print $1}'); do
    run oc delete pvc "$pvc" -n openshift-monitoring --wait=true --timeout=5m
  done
fi

# ---------------------------------------------------------------------------
log "4. Remove image registry dependency (if any)"
if ! $DRY_RUN; then
  REG_PVC=$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.storage.pvc.claim}' 2>/dev/null)
  if [[ -n "$REG_PVC" ]]; then
    warn "image registry uses ODF PVC $REG_PVC - switching to emptyDir and deleting the PVC."
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
      -p '{"spec":{"storage":{"emptyDir":{}},"managementState":"Managed"}}'
    run oc delete pvc "$REG_PVC" -n openshift-image-registry --wait=true --timeout=5m
  fi
fi

# ---------------------------------------------------------------------------
log "5. Remove cluster logging dependency (if any)"
if ! $DRY_RUN && oc get pvc -n openshift-logging --no-headers 2>/dev/null | grep -q 'ocs-storagecluster\|ceph'; then
  warn "openshift-logging has PVCs on ODF storageclasses - deleting ClusterLogging and PVCs."
  run oc delete clusterlogging instance -n openshift-logging --wait=true --timeout=5m
  for pvc in $(oc get pvc -n openshift-logging --no-headers | awk '$6 ~ /ocs-storagecluster|ceph/ {print $1}'); do
    run oc delete pvc "$pvc" -n openshift-logging --wait=true --timeout=5m
  done
fi

# ---------------------------------------------------------------------------
log "6. Allow NooBaa deletion + remove blockers (CNPG Postgres cluster)"
run oc patch noobaa noobaa -n "$NS" --type='merge' \
  -p '{"spec":{"cleanupPolicy":{"allowNoobaaDeletion":true}}}'
# Since ODF 4.19 NooBaa uses a CNPG (CloudNativePG) Postgres cluster for its DB.
# If it never became ready it blocks NooBaa init forever; deleting it unblocks the uninstall.
if run oc get clusters.postgresql.cnpg.noobaa.io -n "$NS" >/dev/null 2>&1; then
  for c in $(run oc get clusters.postgresql.cnpg.noobaa.io -n "$NS" --no-headers | awk '{print $1}'); do
    warn "deleting CNPG cluster $c (blocking NooBaa)"
    run oc delete clusters.postgresql.cnpg.noobaa.io "$c" -n "$NS" --wait=true --timeout=5m
  done
fi

# ---------------------------------------------------------------------------
log "7. Delete StorageCluster ($DELETE_RES) and wait"
confirm "Delete $DELETE_RES $SC_NAME now? This removes all ODF data."
run oc delete -n "$NS" "$DELETE_RES" --all --wait=true --timeout=10m

# ---------------------------------------------------------------------------
log "8. Remove leftover finalizers if resources are stuck"
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
# ODF 4.19.0-7 only: storageclient has no namespace and can survive project deletion,
# blocking reinstall if not finalized.
run oc patch storageclient ocs-storagecluster --type merge \
  -p '{"metadata":{"finalizers": []}}' 2>/dev/null || true

# ---------------------------------------------------------------------------
log "9. Verify cleanup jobs (cleanup-policy=delete)"
if ! $DRY_RUN; then
  sleep 30
  oc get pods -n "$NS" | grep -i cleanup || warn "no cleanup jobs found"
  # Confirm /var/lib/rook is empty on any storage node
  for i in $(oc get node -l cluster.ocs.openshift.io/openshift-storage= -o name 2>/dev/null); do
    oc debug "$i" -- chroot /host ls -l /var/lib/rook 2>&1 | tail -3
  done
fi

# ---------------------------------------------------------------------------
log "10. Delete the openshift-storage namespace"
confirm "Delete namespace $NS (removes ODF operators and all remaining resources)?"
run oc project default
run oc delete project "$NS" --wait=true --timeout=5m

# ---------------------------------------------------------------------------
log "11. Post-uninstall cleanup"
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
# Leftover SCCs (not removed by namespace deletion)
run oc delete scc rook-ceph-csi rook-ceph ocs-metrics-exporter noobaa-endpoint noobaa noobaa-db 2>/dev/null || true
# ODF mutating webhook (needed for clean reinstall)
run oc delete mutatingwebhookconfigurations csv.odf.openshift.io 2>/dev/null || true

log "12. Delete ODF CustomResourceDefinitions (NotFound is fine)"
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

# ---------------------------------------------------------------------------
log "13. Local storage operator cleanup (only if ODF ran on local disks)"
if ! $DRY_RUN && oc get ns openshift-local-storage >/dev/null 2>&1; then
  warn "openshift-local-storage namespace exists - cleaning up LSO resources."
  # LocalVolumeSets used by ODF
  for lvs in $(oc get localvolumesets.local.storage.openshift.io -n openshift-local-storage --no-headers 2>/dev/null | awk '{print $1}'); do
    run oc delete localvolumesets.local.storage.openshift.io "$lvs" -n openshift-local-storage --wait=true --timeout=5m
  done
  # LocalVolume resources
  for lv in $(oc get localvolume -n openshift-local-storage --no-headers 2>/dev/null | awk '{print $1}'); do
    run oc delete localvolume -n openshift-local-storage --wait=true "$lv"
  done
  # LocalVolumeDiscovery
  run oc delete localvolumediscovery.local.storage.openshift.io auto-discover-devices \
    -n openshift-local-storage --wait=true --timeout=5m 2>/dev/null || true
  # Symlinks on storage nodes
  for i in $(oc get node -l cluster.ocs.openshift.io/openshift-storage= -o name 2>/dev/null); do
    oc debug "$i" -- chroot /host bash -c 'rm -rfv /mnt/local-storage/*/ 2>/dev/null' || true
  done
  run oc delete project openshift-local-storage --wait=true --timeout=5m
fi

# ---------------------------------------------------------------------------
log "14. Final verification"
if ! $DRY_RUN; then
  echo "--- namespace:"
  oc get project "$NS" 2>&1 | head -1
  echo "--- CSVs in openshift-storage:"
  oc get csv -n "$NS" --no-headers 2>&1 | head -5
  echo "--- ODF CRDs remaining:"
  oc get crd --no-headers 2>/dev/null | grep -E 'ceph|noobaa|ocs\.openshift|objectbucket|csiaddons' || echo "none"
  echo "--- PVs in Released state:"
  oc get pv --no-headers 2>/dev/null | awk '$4=="Released"' || true
fi

log "Done."
warn "If you plan to reinstall ODF on the same disks, follow Red Hat's OSD disk"
warn "cleanup doc (sgdisk --zap-all /dev/<disk>) before redeploying - Ceph"
warn "replicates OSD metadata across locations on the disk and reinstall fails on unclean disks."
