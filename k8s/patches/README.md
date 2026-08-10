# Post-install patches

The retail-store-sample-chart's catalog and orders subcharts use
`readOnlyRootFilesystem: true` with a default `tmp-volume` emptyDir mount,
but expose no way to add extra volumes via Helm values. After `helm install`,
apply these patches so pods can (a) still write to /tmp and (b) mount DB
credentials synced from Secrets Manager via the Secrets Store CSI Driver.

Run after `helm install`:

kubectl patch deployment retail-store-catalog -n retail-app --type='json' \
  -p="$(cat catalog-volumes-patch.json)"

kubectl patch deployment retail-store-orders -n retail-app --type='json' \
  -p="$(cat orders-volumes-patch.json)"

Also required one-time cluster setup (see /terraform and IAM docs):
- CSIDriver secrets-store.csi.k8s.io needs spec.tokenRequests set for
  audience sts.amazonaws.com (not set by default Helm install):

  kubectl patch csidriver secrets-store.csi.k8s.io --type='json' -p='[
    {"op": "add", "path": "/spec/tokenRequests", "value": [{"audience": "sts.amazonaws.com"}]}
  ]'
