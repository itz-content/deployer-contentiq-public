# ContentIQ Image Mirroring to OpenShift Internal Registry (amd64)

This document provides an end-to-end, **amd64-only** mirroring workflow for all ContentIQ images into the **OpenShift internal registry**, using **port-forward + skopeo**. It also includes the required **post-mirror configuration** (IDMS, CatalogSource, and ContentIQ CR updates).

> Assumptions
> - You are logged into the OpenShift cluster (`oc login`).
> - The OpenShift internal registry is **Available**.
> - Your target namespace is `contentiq`.
> - You are running commands from a machine with `oc` and `skopeo` installed.

---

## 0) Verify Internal Registry is Available

```bash
oc get co image-registry
oc get pods -n openshift-image-registry
oc get svc -n openshift-image-registry
```

Expected:
- `image-registry` operator is `Available=True`.
- `image-registry-...` pod is `Running`.
- Service `image-registry` exists (ClusterIP, port 5000).

---

## 1) Start Port-Forward (Required for Push)

Open a **separate terminal** and keep this running:

```bash
oc port-forward svc/image-registry -n openshift-image-registry 5000:5000
```

---

## 2) Set Variables

```bash
export REGISTRY_PUSH=localhost:5000
export REGISTRY_PULL=image-registry.openshift-image-registry.svc:5000
export MIRROR_NS=contentiq
```

---

## 3) Login to Registries

### DockerHub (required if private, recommended otherwise)
```bash
skopeo login docker.io -u <dockerhub-user> -p <dockerhub-token>
```

### GHCR and Quay (only if needed)
If public access works, you can skip these.

```bash
skopeo login ghcr.io -u <github-user> -p <github-PAT>
skopeo login quay.io -u <quay-user> -p <quay-token>
```

### Login to OpenShift internal registry
```bash
skopeo login --tls-verify=false "$REGISTRY_PUSH" -u "$(oc whoami)" -p "$(oc whoami -t)"
```

---

## 4) Mirror Images (amd64 only)

```bash
skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/contentiq-frontend:1.0.9 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/contentiq-frontend:1.0.9

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/contentiq-backend:1.0.16 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/contentiq-backend:1.0.16

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/personalization-rag:1.0.3 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/personalization-rag:1.0.3

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/contentiq-operator:1.0.0 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/contentiq-operator:1.0.0

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/contentiq-operator-bundle:1.0.0 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/contentiq-operator-bundle:1.0.0

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/symplisticai/contentiq-operator-catalog:1.0.0 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/contentiq-operator-catalog:1.0.0

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://ghcr.io/cloudnative-pg/cloudnative-pg:1.24.1 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/cloudnative-pg:1.24.1

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://ghcr.io/cloudnative-pg/postgresql:18-standard-trixie \
  docker://$REGISTRY_PUSH/$MIRROR_NS/postgresql:18-standard-trixie

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://quay.io/lakekeeper/catalog:v0.11.1 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/catalog:v0.11.1

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/trinodb/trino:477 \
  docker://$REGISTRY_PUSH/$MIRROR_NS/trino:477

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/curlimages/curl:latest \
  docker://$REGISTRY_PUSH/$MIRROR_NS/curl:latest

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/library/python:3.11-alpine \
  docker://$REGISTRY_PUSH/$MIRROR_NS/python:3.11-alpine

skopeo copy --override-os linux --override-arch amd64 --dest-tls-verify=false \
  docker://docker.io/library/nginx:1.27-alpine \
  docker://$REGISTRY_PUSH/$MIRROR_NS/nginx:1.27-alpine
```

---

## 5) Verify Images in the Project

```bash
oc get is -n contentiq
oc get istag -n contentiq | egrep 'contentiq-|cloudnative|postgres|catalog|trino|curl|python|nginx'
```

---

## 6) Allow Other Namespaces to Pull from `contentiq`

CatalogSource and operator run outside the `contentiq` namespace:

```bash
oc policy add-role-to-group system:image-puller system:serviceaccounts:openshift-marketplace -n contentiq
oc policy add-role-to-group system:image-puller system:serviceaccounts:openshift-operators -n contentiq
```

---

## 7) Apply Mirror Rules (IDMS)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: contentiq-mirrors
spec:
  imageDigestMirrors:
  - source: docker.io/symplisticai
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
  - source: ghcr.io/cloudnative-pg
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
  - source: quay.io/lakekeeper
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
  - source: docker.io/trinodb
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
  - source: docker.io/curlimages
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
  - source: docker.io/library
    mirrors:
    - image-registry.openshift-image-registry.svc:5000/contentiq
EOF
```

---

## 8) Update CatalogSource to Internal Registry

```bash
oc patch catalogsource contentiq-operators -n openshift-marketplace --type=merge \
  -p '{"spec":{"image":"image-registry.openshift-image-registry.svc:5000/contentiq/contentiq-operator-catalog:1.0.0"}}'

# Restart CatalogSource pod so it pulls from the internal registry
oc delete pod -n openshift-marketplace -l olm.catalogSource=contentiq-operators
```

---

## 9) Update ContentIQ CR to Internal Images

```bash
CR_NAME=$(oc get contentiq -n contentiq -o jsonpath='{.items[0].metadata.name}')

oc patch contentiq "$CR_NAME" -n contentiq --type=merge -p '{
  "spec": {
    "images": {
      "frontend": "image-registry.openshift-image-registry.svc:5000/contentiq/contentiq-frontend:1.0.9",
      "backend":  "image-registry.openshift-image-registry.svc:5000/contentiq/contentiq-backend:1.0.16",
      "rag":      "image-registry.openshift-image-registry.svc:5000/contentiq/personalization-rag:1.0.3"
    },
    "structuredData": {
      "images": {
        "lakekeeper": "image-registry.openshift-image-registry.svc:5000/contentiq/catalog:v0.11.1",
        "trino":      "image-registry.openshift-image-registry.svc:5000/contentiq/trino:477",
        "postgres":   "image-registry.openshift-image-registry.svc:5000/contentiq/postgresql:18-standard-trixie"
      }
    }
  }
}'
```

---

## 10) Verify Pods Pull Internal Images

```bash
oc get pods -n openshift-marketplace | grep contentiq
oc get pods -n openshift-operators | grep contentiq
oc get pods -n contentiq

# Check actual image values
oc get pods -n contentiq -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
```

---

## Notes

- `python:3.11-alpine` and `nginx:1.27-alpine` are used by embedded Structured Data manifests. With `useEmbeddedCharts: true`, you do **not** update them in the CR; IDMS handles the rewrite.
- If the internal registry is restricted, ensure the correct pull secrets are linked to `default` or relevant service accounts in `openshift-marketplace`, `openshift-operators`, and `contentiq`.

