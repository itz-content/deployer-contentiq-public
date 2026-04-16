# ContentIQ Operator - Customer Package

## Overview

This folder is the customer-facing deployment bundle for ContentIQ on OpenShift. The operator manages the frontend, backend, RAG service, and the Structured Data stack using embedded manifests/charts; customers configure images, hostnames, and secrets in a single Custom Resource.

Redis is **operator-managed by default**. Configure modes (ephemeral, persistent, external) in the Custom Resource (`spec.redis`).

---

## Requirements (host running OpenShift / CRC)

These numbers are a practical minimum for a **single-node lab-style cluster** (for example CodeReady Containers) plus pulling images and running ContentIQ workloads.

| Resource | Minimum |
|----------|---------|
| RAM | **64 GB** |
| Disk | **300 GB** free space |

Use a physical machine or VM that meets the above. You will **SSH** into that machine to install dependencies, start the cluster, and run Ansible from there (or from your laptop against a remote `oc`—the steps below assume you run commands on the same host that can reach the cluster API).

**If you see disk or resource pressure** (pods stuck `Pending`, `Evicted`, `OOMKilled`, operators or workloads crash-looping, image pulls timing out, or the node running out of ephemeral storage), treat the table above as the first place to look: increase **free disk** on the host, **RAM** allocated to the cluster (for CRC, raise memory in `crc config` and restart), and leave headroom for image layers and logs. For broader scenarios and commands, see [CUSTOMER-GUIDE.md](CUSTOMER-GUIDE.md).

---

## What you have in this bundle

Everything the Ansible playbooks need lives under **`ansible/`**: inventory, parameters, manifests, secrets templates, and playbooks. You do **not** need the rest of a larger repo to run install or teardown—only this folder (or a copy of it) with `ansible/` intact.

---

## Before you run Ansible (cluster must be up)

1. **SSH** into the server you will use (the one that meets the requirements above).
2. **Install OpenShift** in whatever way your environment uses. For local development, many teams use **CodeReady Containers (CRC)**:
   - Install CRC and its prerequisites for your OS (for Linux: typically `libvirt`, KVM, and user in the `libvirt` group—follow the current [CRC getting started](https://developers.redhat.com/products/openshift-local/getting-started) documentation).
   - Run `crc setup` once, then `crc start` (allocate enough memory/CPU in `crc config` to fit within your 64 GB and workload needs).
   - When the cluster is ready, run `crc console --credentials` or `crc status` and log in with **`oc login`** using the printed API URL and credentials.
3. **Verify** you can talk to the cluster:
   ```bash
   oc whoami
   oc get nodes
   ```
   You need a user with permissions to create namespaces, subscriptions, and resources in `openshift-marketplace` and `openshift-operators` (cluster admin is typical for CRC).

4. **Install tools on the machine where you will run Ansible** (often the same SSH session):
   - **Ansible** (`ansible-playbook` on your `PATH`)
   - **Python 3** (used by Ansible)
   - **`oc`** CLI matching your cluster (CRC bundles instructions to put `oc` on your path)

5. **Install Ansible collections** required by this bundle (once per machine):
   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ```

---

## Configure this bundle (first time)

1. Go to the **`ansible/`** directory inside `contentiq-operator-deployment`:
   ```bash
   cd contentiq-operator-deployment/ansible
   ```

2. **Edit `parameters.yml`** (or pass equivalent `-e` variables). At minimum, with pull-secret management enabled, you must set registry credentials used to create image pull secrets:
   - `contentiq_registry_username`
   - `contentiq_registry_password`
   - `contentiq_registry_email`

3. **Review manifests and secrets** under `ansible/manifests/` and `ansible/secrets/` as needed (catalog image, subscription, images in the Custom Resource, credentials in backend/RAG secrets). **`playbooks/deploy.yml` fills route URLs and CR hostnames automatically** from `ingress.config/cluster` (see `contentiq_auto_route_hostnames` and `contentiq_route_*_label` in the playbook vars). You still must supply real credentials and image references.

4. **Inventory**: `inventory.yml` targets `localhost` and uses your current `oc` context—so your shell must already be logged in with `oc login` before running the playbook.

---

## The two playbooks (what they are for)

| Playbook | Purpose |
|----------|---------|
| **`playbooks/deploy.yml`** | **Install / deploy** ContentIQ via this bundle: applies namespace, pull secrets (if enabled), CatalogSource, Subscription, secrets, ContentIQ Custom Resource, then waits for rollouts. Run this when you want to bring the stack up or re-apply configuration. |
| **`playbooks/teardown.yml`** | **Remove / reset** what this install path created (workloads, CR, namespace pieces, OLM subscription/catalog steps as configured) so you can install again cleanly or free resources. This is destructive; it requires an explicit confirmation flag (see below). |

---

## Run the install (`deploy.yml`)

From the **`ansible/`** directory:

```bash
cd contentiq-operator-deployment/ansible
ansible-playbook -i inventory.yml playbooks/deploy.yml -e @parameters.yml
```

Wait until the playbook finishes. If something fails, use `oc get pods -n contentiq` and `oc describe` on the failing resource, and see **Documentation** below for deeper guides.

### SCC and `oc adm policy` (Structured Data)

With the default install path, **`deploy.yml` applies the Security Context Constraints you need** for the Structured Data stack: it grants the **`nonroot-v2` SCC** to the CloudNativePG controller service account (in the CNPG namespace) and to the **Lakekeeper** and **Trino** service accounts in `contentiq`, using `oc adm policy add-scc-to-user`. You should not need to run those commands by hand unless you have turned off or heavily customized structured-data post-steps—in that case, use [CUSTOMER-GUIDE.md](CUSTOMER-GUIDE.md) and align SCC with your cluster policy.

**Requirement:** the user in your `oc` session must have permission to bind SCCs (typically **cluster admin** on lab clusters such as CRC). If SCC-related tasks fail with permission errors, log in as a sufficiently privileged user and re-run the playbook.

### Running end-to-end without interactive prompts

`deploy.yml` is written so a complete install does **not** rely on you typing into Ansible mid-run: there is no `vars_prompt` for secrets, and pauses in the playbook are **timed waits** (seconds), not “press Enter to continue.” To avoid surprises:

| Before you run | Why |
|----------------|-----|
| **`oc login`** to the right cluster | The playbook uses your current context; it will not open a login prompt for you. |
| **`parameters.yml` filled in** (registry credentials, and any other required `-e` overrides) | Missing values surface as task failures, not interactive questions. |
| **`ansible-galaxy collection install -r requirements.yml`** (once) | Otherwise collection-related tasks fail immediately. |
| **Enough RAM / disk** (see Requirements) | Prevents opaque failures during image pull or rollout. |
| **Cluster-admin (or equivalent)** for namespace, OLM, and SCC steps | See SCC note above. |

**Things that can still appear (normal to watch for):**

- **OLM / CSV** — the operator subscription can sit in `Installing` while the catalog syncs; the playbook uses waits/retries, but a slow registry or network can extend runtime significantly.
- **First-time image pulls** — large images can take a long time; low disk or memory makes this worse (see Requirements and **Troubleshooting** below).
- **Long wall-clock time** — full install is not a quick smoke test; allow enough session time or run under `tmux`/`screen`.
- **Optional timed pauses** — if memory-preparation or phased-rollout pause variables are non-zero in your parameters, the playbook will sleep for those durations; that is not a prompt, but it adds delay.
- **Customized flags** — if you disable structured-data post-steps or change namespaces, you may need to perform equivalent SCC or rollout steps yourself (see CUSTOMER-GUIDE).

---

## Run the teardown (`teardown.yml`)

Use this when you want to **uninstall** or **clean up** the ContentIQ install created by this path.

From **`ansible/`**:

```bash
cd contentiq-operator-deployment/ansible
ansible-playbook -i inventory.yml playbooks/teardown.yml -e @parameters.yml -e contentiq_teardown_confirm=true
```

Or from **`contentiq-operator-deployment/`** (one level above `ansible/`):

```bash
./teardown.sh
```

`teardown.sh` loads `parameters.yml` if present and sets `contentiq_teardown_confirm=true` for you. Optional teardown behavior is documented as comments in `ansible/playbooks/teardown.yml`.

---

## Documentation

- **[DEPLOYMENT-CONFIG.md](DEPLOYMENT-CONFIG.md)** — install flow, playbook commands, and what to edit under `ansible/`
- [CUSTOMER-GUIDE.md](CUSTOMER-GUIDE.md) — full install, air-gap, troubleshooting
- CNPG webhook config: no longer needed (operator now creates/patches CNPG webhooks automatically)

---

## Quick reference (manual `oc apply`)

If you are not using Ansible, paths are relative to **`contentiq-operator-deployment/`**:

1. Create namespace: `oc apply -f ansible/manifests/00-namespace.yaml`
2. Configure pull secrets in `openshift-marketplace`, `openshift-operators`, and `contentiq`
3. Register catalog: `oc apply -f ansible/manifests/02-catalogsource.yaml`
4. Install operator: `oc apply -f ansible/manifests/03-subscription.yaml`
5. Create backend and RAG secrets: `oc apply -f ansible/secrets/backend-secrets-template.yaml` and `oc apply -f ansible/secrets/rag-secrets-template.yaml`
6. Edit/apply the Custom Resource: `oc apply -f ansible/manifests/contentiq-custom-resource.yaml`

---

## File structure

```
contentiq-operator-deployment/
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.yml
│   ├── parameters.yml
│   ├── requirements.yml
│   ├── 06-image-list.txt          # Image list for mirroring (reference)
│   ├── manifests/
│   │   ├── 00-namespace.yaml
│   │   ├── 02-catalogsource.yaml
│   │   ├── 03-subscription.yaml
│   │   └── contentiq-custom-resource.yaml
│   ├── secrets/
│   │   ├── backend-secrets-template.yaml
│   │   └── rag-secrets-template.yaml
│   ├── playbooks/
│   │   ├── deploy.yml               # Install (entrypoint)
│   │   └── teardown.yml           # Uninstall / reset
│   ├── roles/…
│   └── tasks/…
├── teardown.sh
├── DEPLOYMENT-CONFIG.md
├── CUSTOMER-GUIDE.md
└── README.md
```

---

## File notes

- `ansible/manifests/00-namespace.yaml`: Creates the `contentiq` namespace (apply once).
- `ansible/manifests/02-catalogsource.yaml`: Points to the operator catalog image; update if using an internal registry.
- `ansible/manifests/03-subscription.yaml`: Installs and upgrades the operator through OLM; includes an explicit operator resource override to avoid OOMKilled crash loops from low defaults.
- `ansible/secrets/backend-secrets-template.yaml`: Populate and apply; the operator reads `contentiq-backend-secrets` directly.
- `ansible/secrets/rag-secrets-template.yaml`: Populate and apply; the operator mounts `personalization-api-secrets` on the RAG deployment when supported.
- `ansible/manifests/contentiq-custom-resource.yaml`: Customer config for images, hostnames, pull secrets, Structured Data overrides.
- `ansible/06-image-list.txt`: Reference for mirroring all required images in disconnected clusters.
- CNPG webhook config: not required in current builds; webhooks are created and patched automatically.

---

## How upgrades work

1. Vendor publishes new operator/bundle/catalog images.
2. Platform team mirrors images (if disconnected) and updates `ansible/manifests/02-catalogsource.yaml` if needed.
3. OLM upgrades the operator automatically (per Subscription).
4. Operator reconciles existing `ContentIQ` CR; app/Structured Data roll out with the new version.

---

## Troubleshooting (quick pointers)

- **Disk / RAM / CPU** — revisit the **Requirements** table at the top of this README. Symptoms include `OOMKilled`, `Evicted`, pods `Pending` for memory or ephemeral storage, and slow or failed image pulls. For CRC, raise memory and disk in `crc config` and ensure the physical host has headroom.
- **SCC / “can’t schedule” for Lakekeeper, Trino, or CNPG** — with the default playbook, SCC grants are applied automatically; ensure you ran `deploy.yml` with structured-data post-steps enabled and a user that can bind SCCs. If you bypass those tasks, compare with [CUSTOMER-GUIDE.md](CUSTOMER-GUIDE.md).
- Operator pod: `oc logs -n openshift-operators -l name=contentiq-operator`
- Catalog visibility: `oc get catalogsource -n openshift-marketplace`
- CR status/events: `oc describe contentiq contentiq-instance -n contentiq`
- Pods/routes: `oc get pods,svc,route -n contentiq`
- CNPG webhook config: not required in current builds; the operator creates/patches CNPG webhooks automatically

For step-by-step diagnostics (air-gap, mirroring, and deeper troubleshooting), use **[CUSTOMER-GUIDE.md](CUSTOMER-GUIDE.md)**.
