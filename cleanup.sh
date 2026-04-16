echo "=========================================="
echo "  ContentIQ Complete Cleanup"
echo "=========================================="
echo ""
echo "⚠️  WARNING: This will delete ALL resources for this project!"
echo "   Namespace: ${NAMESPACE}"
echo ""
echo "Starting cleanup automatically..."

echo ""
echo ">>> Starting cleanup..."

# Check if logged in
oc whoami >/dev/null 2>&1 || { echo "❌ Not logged into OpenShift. Run 'oc login' first."; exit 1; }

# Step 1: Delete Helm releases (must be done before namespace deletion)
echo ""
echo ">>> Step 1: Deleting Helm releases..."
if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  oc project "${NAMESPACE}" >/dev/null 2>&1 || true
  
  # Delete Helm releases
  for release in lakekeeper trino edge; do
    if helm list -n "${NAMESPACE}" | grep -q "^${release}"; then
      echo "  Deleting Helm release: ${release}"
      helm uninstall "${release}" -n "${NAMESPACE}" || true
    fi
  done
  
  # Wait a bit for resources to start terminating
  sleep 5
else
  echo "  Namespace ${NAMESPACE} does not exist, skipping Helm releases"
fi

# Step 2: Delete CNPG PostgreSQL cluster (if exists)
echo ""
echo ">>> Step 2: Deleting PostgreSQL cluster..."
if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  if oc get cluster postgres -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "  Deleting CNPG cluster: postgres"
    oc delete cluster postgres -n "${NAMESPACE}" --wait=true --timeout=300s || true
    # Wait for cluster to be fully deleted
    echo "  Waiting for cluster deletion to complete..."
    oc wait --for=delete cluster/postgres -n "${NAMESPACE}" --timeout=300s || true
  else
    echo "  PostgreSQL cluster not found"
  fi
fi

# Step 3: Remove SCC permissions
echo ""
echo ">>> Step 3: Removing SCC permissions..."
if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  # Remove anyuid from default service account
  oc adm policy remove-scc-from-user anyuid "system:serviceaccount:${NAMESPACE}:default" 2>/dev/null || true
  
  # Remove anyuid from lakekeeper service account
  oc adm policy remove-scc-from-user anyuid "system:serviceaccount:${NAMESPACE}:lakekeeper" 2>/dev/null || true
  echo "  SCC permissions removed"
else
  echo "  Namespace does not exist, skipping SCC cleanup"
fi

# Step 4: Delete the entire namespace (cascades to all resources)
echo ""
echo ">>> Step 4: Deleting namespace ${NAMESPACE}..."
if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  This will delete all resources in the namespace..."
  oc delete namespace "${NAMESPACE}" --wait=true --timeout=600s || true
  
  # Wait for namespace to be fully deleted
  echo "  Waiting for namespace deletion to complete..."
  while oc get namespace "${NAMESPACE}" >/dev/null 2>&1; do
    echo "    Still deleting... (this may take a few minutes)"
    sleep 10
  done
  echo "  ✅ Namespace deleted"
else
  echo "  Namespace ${NAMESPACE} does not exist"
fi

# Step 5: Remove CNPG operator (cluster-scoped)
echo ""
echo ">>> Step 5: Removing CNPG operator..."
# Remove SCC permissions for CNPG
oc adm policy remove-scc-from-user nonroot-v2 "system:serviceaccount:cnpg-system:cnpg-manager" 2>/dev/null || true

# Delete CNPG operator
if oc get deployment cnpg-controller-manager -n cnpg-system >/dev/null 2>&1; then
  oc delete -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.1.yaml 2>/dev/null || true
  
  # Delete CNPG namespace if it exists and is empty
  if oc get namespace cnpg-system >/dev/null 2>&1; then
    oc delete namespace cnpg-system --wait=true --timeout=300s 2>/dev/null || true
  fi
  
  echo "  ✅ CNPG operator removed"
else
  echo "  CNPG operator not found"
fi

# Step 6: Remove Helm repos
echo ""
echo ">>> Step 6: Removing Helm repositories..."
helm repo remove lakekeeper 2>/dev/null || true
helm repo remove trino 2>/dev/null || true
echo "  ✅ Helm repositories removed"

# Step 7: Clean up images (OpenShift will handle this automatically via GC, but we can trigger it)
echo ""
echo ">>> Step 7: Image cleanup..."
echo "  Note: OpenShift automatically garbage collects unused images."
echo "  To manually trigger image pruning (requires cluster-admin):"
echo "    oc adm prune images --keep-tag-revisions=3 --keep-younger-than=60m --confirm"
echo "  (Skipping automatic image pruning - requires cluster-admin privileges)"

echo ""
echo "=========================================="
echo "  Cleanup Complete!"
echo "=========================================="
echo ""
echo "All ContentIQ resources have been removed:"
echo "  - Namespace: ${NAMESPACE}"
echo "  - Helm releases: lakekeeper, trino, edge"
echo "  - PostgreSQL cluster"
echo "  - All secrets, configmaps, deployments, services, routes"
echo "  - CNPG operator (cluster-scoped)"
echo "  - Helm repositories: lakekeeper, trino"
echo ""
echo "To start fresh, run:"
echo "  bash ${SCRIPT_DIR}/06-scripts/deploy-all.sh"
echo ""