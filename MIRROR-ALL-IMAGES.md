# ContentIQ - Mirror All Required Images (Air-Gapped)

This guide focuses on **fully air-gapped** deployments. It describes a two-phase process:
1) Build a portable mirror artifact on a **connected staging host**.
2) Transfer that artifact into the **air-gapped network** and publish to the internal registry.

It complements `contentiq-operator-deployment/CUSTOMER-GUIDE.md` and does not replace it.

## What to Mirror
The authoritative list of required images is in:
- `contentiq-operator-deployment/ansible/06-image-list.txt`

If you customize any images (different tags or a different nginx image), add those to the list **before** mirroring.

## Air-Gapped Overview
- **Connected staging host**: has access to DockerHub/Quay/GHCR and can run `oc mirror` (recommended) or `skopeo`.
- **Air-gapped network**: has the internal registry and the OpenShift cluster, but **no internet egress**.
- **Transfer**: use removable media or an approved offline transfer method to move the mirror artifact.

## Prerequisites
**Connected staging host**
- Access to source registries (DockerHub, Quay, GHCR)
- OpenShift `oc` CLI with `oc mirror` available (built-in or oc-mirror plugin)
- Optional: `skopeo` if you prefer manual mirroring

**Air-gapped network**
- An internal registry reachable by all cluster nodes
- Registry credentials and CA trust configured for OpenShift
- `oc` CLI with cluster-admin access to apply mirror manifests
- DNS/firewall rules so cluster nodes can resolve and reach the registry hostname
- A secure offline transfer method (removable media or approved transfer system)
- Ability to apply generated mirror manifests (IDMS/ICSP and CatalogSource) from `oc-mirror-workspace`

## Phase 1 (Connected Staging Host): Build a Mirror Artifact

### Option A (Recommended): oc mirror to a file archive

#### Step 1: Log in to registries
Use any container tool to log in (Docker, Podman, or Skopeo). `oc mirror` will read credentials from your container auth file.

```bash
# Example with skopeo (use docker/podman if preferred)
skopeo login docker.io
skopeo login quay.io
skopeo login ghcr.io
```

#### Step 2: Create the ImageSetConfiguration
Save as `imageset-config.yaml`:

```yaml
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
storageConfig:
  registry:
    imageURL: <internal-registry>/oc-mirror-metadata
    skipTLS: true  # Set to false if using HTTPS with a valid cert
mirror:
  operators: []
  additionalImages:
    - name: docker.io/symplisticai/contentiq-frontend:1.0.9
    - name: docker.io/symplisticai/contentiq-backend:1.0.16
    - name: docker.io/symplisticai/personalization-rag:1.0.3
    - name: docker.io/symplisticai/contentiq-operator:1.0.0
    - name: docker.io/symplisticai/contentiq-operator-bundle:1.0.0
    - name: docker.io/symplisticai/contentiq-operator-catalog:1.0.0
    - name: ghcr.io/cloudnative-pg/cloudnative-pg:1.24.1
    - name: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
    - name: quay.io/lakekeeper/catalog:v0.11.1
    - name: docker.io/trinodb/trino:477
    - name: docker.io/curlimages/curl:latest
    - name: docker.io/library/python:3.11-alpine
    - name: docker.io/library/nginx:1.27-alpine
```

#### Step 3: Mirror to a local directory
```bash
# Replace with a local directory for the mirror artifact
MIRROR_DIR=/path/to/mirror

oc mirror --config=imageset-config.yaml file://$MIRROR_DIR
```

This produces a portable mirror artifact and an `oc-mirror-workspace` directory with manifests and metadata.

### Step 4: Transfer to the air-gapped network
Copy the **entire mirror output directory** and the `oc-mirror-workspace` folder to the air-gapped environment.

## Phase 2 (Air-Gapped Network): Publish to the Internal Registry

### Step 1: Push the mirror artifact into the internal registry
```bash
# Replace with your actual registry URL
INTERNAL_REGISTRY=<internal-registry>

oc mirror --from=$MIRROR_DIR docker://$INTERNAL_REGISTRY
```

If your registry uses a self-signed cert or HTTP, configure OpenShift trust or use the appropriate `oc mirror` flags for your environment.

### Step 2: Apply the generated mirror manifests
Apply the ImageDigestMirrorSet/ImageContentSourcePolicy and any generated CatalogSource manifests from the `oc-mirror-workspace` results directory.

**Examples**

**Bash**
```bash
RESULTS_DIR=$(ls -d oc-mirror-workspace/results-* | tail -n 1)
ls "$RESULTS_DIR"

# Apply mirror rules (IDMS or ICSP, depending on output)
if [ -f "$RESULTS_DIR/imageDigestMirrorSet.yaml" ]; then
  oc apply -f "$RESULTS_DIR/imageDigestMirrorSet.yaml"
elif [ -f "$RESULTS_DIR/imageContentSourcePolicy.yaml" ]; then
  oc apply -f "$RESULTS_DIR/imageContentSourcePolicy.yaml"
fi

# Apply generated CatalogSource, if present
if ls "$RESULTS_DIR"/catalogSource*.yaml >/dev/null 2>&1; then
  oc apply -f "$RESULTS_DIR"/catalogSource*.yaml
fi
```

**PowerShell**
```powershell
$results = Get-ChildItem "oc-mirror-workspace\results-*" | Sort-Object Name | Select-Object -Last 1
if ($results) {
  $idms = Join-Path $results.FullName "imageDigestMirrorSet.yaml"
  $icsp = Join-Path $results.FullName "imageContentSourcePolicy.yaml"
  if (Test-Path $idms) { oc apply -f $idms }
  elseif (Test-Path $icsp) { oc apply -f $icsp }

  Get-ChildItem (Join-Path $results.FullName "catalogSource*.yaml") -ErrorAction SilentlyContinue | ForEach-Object {
    oc apply -f $_.FullName
  }
}
```

## Update OpenShift to Use the Internal Registry

### 1) CatalogSource
If you are not using the CatalogSource generated by `oc mirror`, update:
`contentiq-operator-deployment/ansible/manifests/02-catalogsource.yaml`

```yaml
image: <internal-registry>/symplisticai/contentiq-operator-catalog:1.0.0
```

### 2) ContentIQ Custom Resource
Update the CR to point to mirrored images:
- `spec.images.{frontend,backend,rag}`
- `spec.structuredData.images.{lakekeeper,trino,postgres}`

### 3) Pull secrets
Create and link pull secrets for the internal registry in these namespaces:
- `openshift-marketplace` (CatalogSource + bundle unpack)
- `openshift-operators` (operator pod)
- `contentiq` (application + Structured Data pods)

**Registry trust (required)**

If your internal registry uses a **self-signed cert**, add its CA to OpenShift:
```bash
# Save the registry CA cert locally (example path)
REGISTRY_CA=/path/to/registry-ca.crt

# Create a ConfigMap with the CA (key must match the registry host:port)
oc create configmap registry-ca -n openshift-config \
  --from-file=<internal-registry>:<port>=$REGISTRY_CA

# Tell OpenShift to trust that CA
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-ca"}}}'
```

If your registry is **HTTP/insecure** (not recommended for production):
```bash
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"registrySources":{"insecureRegistries":["<internal-registry>:<port>"]}}}'
```

**Pull secrets for internal registry (required)**
```bash
oc create secret docker-registry internal-registry-creds \
  --docker-server=<internal-registry>:<port> \
  --docker-username=<REGISTRY_USER> \
  --docker-password=<REGISTRY_PASSWORD> \
  --docker-email=unused \
  -n openshift-marketplace

oc create secret docker-registry internal-registry-creds \
  --docker-server=<internal-registry>:<port> \
  --docker-username=<REGISTRY_USER> \
  --docker-password=<REGISTRY_PASSWORD> \
  --docker-email=unused \
  -n openshift-operators

oc create secret docker-registry internal-registry-creds \
  --docker-server=<internal-registry>:<port> \
  --docker-username=<REGISTRY_USER> \
  --docker-password=<REGISTRY_PASSWORD> \
  --docker-email=unused \
  -n contentiq

oc secrets link default internal-registry-creds --for=pull -n openshift-marketplace
oc secrets link default internal-registry-creds --for=pull -n openshift-operators
oc secrets link default internal-registry-creds --for=pull -n contentiq
```

## Verify
- Catalog loads:
  ```bash
  oc get catalogsource -n openshift-marketplace
  oc describe catalogsource contentiq-operators -n openshift-marketplace
  ```
- Operator running:
  ```bash
  oc get pods -n openshift-operators | grep contentiq
  ```
- App and Structured Data pods:
  ```bash
  oc get pods -n contentiq
  ```

## Air-Gap Success Checklist
- Internal registry is reachable from all cluster nodes (DNS + firewall verified)
- Registry trust configured (CA or insecure registry in `image.config.openshift.io/cluster`)
- Pull secrets for internal registry linked in:
  - `openshift-marketplace`
  - `openshift-operators`
  - `contentiq`
- `oc mirror --from ...` completed successfully into the internal registry
- Generated mirror manifests applied (IDMS/ICSP and CatalogSource from `oc-mirror-workspace/results-*`)
- CatalogSource image and CR image references point to the internal registry

## Appendix: Connected-Only Mirroring (Not Air-Gapped)
Use the scripts below only when the host has **direct access** to both the source registries and the destination registry.

### skopeo (connected host)
```bash
# IMPORTANT: Replace with your actual registry URL
INTERNAL_REGISTRY=localhost:5000
LIST_FILE=contentiq-operator-deployment/ansible/06-image-list.txt

if ! command -v skopeo &> /dev/null; then
  echo "Error: skopeo is not installed"
  exit 1
fi

if [ ! -f "$LIST_FILE" ]; then
  echo "Error: Image list file not found: $LIST_FILE"
  exit 1
fi

SUCCESS=0
FAILED=0

while IFS= read -r img || [ -n "$img" ]; do
  img=$(echo "$img" | xargs)
  [[ -z "$img" || "$img" =~ ^# ]] && continue

  if [[ "$img" != *"."*"/"* ]]; then
    src="docker.io/$img"
  else
    src="$img"
  fi

  dest_path="${src#*/}"
  dst="$INTERNAL_REGISTRY/$dest_path"

  echo "Mirroring $src -> $dst"
  if skopeo copy "docker://$src" "docker://$dst"; then
    echo "  Success"
    ((SUCCESS++))
  else
    echo "  Failed"
    ((FAILED++))
  fi
done < "$LIST_FILE"

echo ""
echo "Mirroring complete: $SUCCESS succeeded, $FAILED failed"
```

### PowerShell (connected host, Docker Desktop)
```powershell
# IMPORTANT: Replace with your actual registry URL
$InternalRegistry = "localhost:5000"
$ListFile = "contentiq-operator-deployment/ansible/06-image-list.txt"

try {
    $null = docker --version 2>&1
    Write-Host "Docker found" -ForegroundColor Green
} catch {
    Write-Host "Error: Docker is not installed or not running" -ForegroundColor Red
    Write-Host "Please install Docker Desktop and ensure it is running" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $ListFile)) {
    Write-Host "Error: Image list file not found: $ListFile" -ForegroundColor Red
    Write-Host "Make sure you're in the workspace root directory" -ForegroundColor Yellow
    exit 1
}

try {
    $response = Invoke-WebRequest -Uri "http://$InternalRegistry/v2/" -Method GET -TimeoutSec 5 -ErrorAction Stop
    Write-Host "Local registry is accessible at $InternalRegistry" -ForegroundColor Green
} catch {
    Write-Host "Warning: Cannot access registry at $InternalRegistry" -ForegroundColor Yellow
    Write-Host "Make sure your Docker registry is running:" -ForegroundColor Yellow
    Write-Host "  docker run -d -p 5000:5000 --name local-registry registry:2" -ForegroundColor White
    $continue = Read-Host "Continue anyway? (y/n)"
    if ($continue -ne 'y') { exit 1 }
}

$success = 0
$failed = 0

$images = Get-Content $ListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$total = $images.Count
$current = 0

Write-Host "`nStarting image mirroring ($total images)...`n" -ForegroundColor Cyan

foreach ($img in $images) {
    $current++
    
    if ($img -match '^[^/]+\.[^/]+/') {
        $src = $img
    } else {
        $src = "docker.io/$img"
    }

    $destPath = $src -replace '^[^/]+/', ''
    $dst = "$InternalRegistry/$destPath"

    Write-Host "[$current/$total] Mirroring $src -> $dst" -ForegroundColor Cyan
    
    try {
        Write-Host "  Pulling..." -ForegroundColor Gray -NoNewline
        docker pull $src 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Pull failed" }
        
        Write-Host " Tagging..." -ForegroundColor Gray -NoNewline
        docker tag $src $dst 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Tag failed" }
        
        Write-Host " Pushing..." -ForegroundColor Gray -NoNewline
        docker push $dst 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Push failed" }
        
        Write-Host " Success" -ForegroundColor Green
        $success++
    } catch {
        Write-Host " Failed: $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "Mirroring complete!" -ForegroundColor Cyan
Write-Host "  Total: $total"
Write-Host "  Success: $success" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "============================================`n" -ForegroundColor Cyan
```

## Notes
- If you add or change any images, update `ansible/06-image-list.txt` and re-mirror.
- For true air-gapped installs, prefer `oc mirror` with a file-based archive and apply the generated mirror manifests.
