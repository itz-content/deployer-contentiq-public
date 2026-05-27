# On-Prem Ansible Playbook — Errors and Fixes

Reference for failures seen while running `playbooks/deploy.yml` on OpenShift / TechZone / CRC-style clusters, plus common on-prem symptoms tied to files in this bundle.

**Related docs:** [CUSTOMER-GUIDE.md](../CUSTOMER-GUIDE.md) (full install + troubleshooting), [DEPLOYMENT-CONFIG.md](../DEPLOYMENT-CONFIG.md) (what to edit before install).

**Quick verify after deploy:**

```bash
cd ansible && ./scripts/verify-contentiq-deploy.sh
```

---

## Playbook flow (where checks run)

| Step | Task file / area | What it does | Common failure mode |
|------|------------------|--------------|---------------------|
| Pre | `deploy.yml` vars | IBM SM vs local secrets, pull secret, route hostnames | Missing credentials, `__CONTENTIQ_*__` placeholders left in CR |
| 1b | `fetch-and-apply-ibm-sm-secrets.yml` | Pull secrets from IBM Secrets Manager | Bad endpoint, API key, or secret UUID |
| 2 | Pull secret + SA links | `openshift-marketplace`, `openshift-operators`, `contentiq` | ImagePullBackOff on catalog/operator/app |
| 4–5 | OLM + secrets apply | Catalog, subscription, backend/RAG secrets | Operator not ready, `<REPLACE_ME>` in secrets |
| 6 | CR apply + rollouts | Phased: Redis → core → phase-2 structured data | Rollout timeout, OOM, SCC denied |
| 6a-pre | `ensure-frontend-runtime-patch.yml` | initContainer + emptyDir (stop CrashLoop) | Deployment / Routes / `frontend-config` not ready yet (retries) |
| 6b-pre | `patch-backend-secret-to-live-routes.yml` | Patch `FRONTEND_URL` / CORS (no restart yet) | Routes not created yet |
| 6d-pre | `annotate-route-timeouts.yml` | HAProxy `1800s` on frontend/backend routes | Long requests 504 without this |
| 6f | `verify-deployment-connectivity.yml` | Edge-gateway probe only (`contentiq_verify_env_json_and_cors: false`) | WARN if backend cannot reach `edge-gateway` |
| 6g | `align-lakehouse-ingress-port.yml` | `LAKEHOUSE_INGRESS_PORT=8080` + backend restart | Lakehouse timeouts if port stays 80 |
| **6-post** | `finalize-deployment-connectivity.yml` | Backend CORS restart, **Step 6c** frontend `/env.json`, full verify | See sections below — run **after** rollouts |
| 8–9 | Routes + OSB | Capture hostname, broker provision | Broker file/SM missing |

**Important ordering (1.3.x phased deploy):** Step **6-post** aligns `/env.json` and asserts CORS. Step **6f** runs **before** 6-post and must **not** assert `/env.json` (empty `{}` is expected until 6c runs). If an older playbook checks `/env.json` at 6f, upgrade to the split-verify version in this repo.

---

## Errors observed in practice (this playbook run)

### 1. `/env.json` apiBaseUrl assertion — empty `{}`

**Symptom (Ansible):**

```text
TASK [Verify: Assert /env.json apiBaseUrl matches backend route]
fatal: assertion contentiq_step6e_env_json.json.apiBaseUrl is defined
Got: {}
```

**Cause:**

- Browser config is served from `https://<frontend-route>/env.json`.
- Operator ConfigMap `frontend-config` often has only `ONPREM_API_URL`.
- Frontend image **1.3.x** `render_runtime_config.py` reads **`CONTENTIQ_API_BASE_URL`**.
- Without Step **6c** (merge-patch ConfigMap + deployment initContainer patch), the file stays `{}` or points at a default SaaS host.

**Fix:**

```bash
cd ansible && ./scripts/align-frontend-env-json.sh
# or combined backend + frontend:
./scripts/fix-app-connectivity.sh
```

**Playbook:** Step 6-post → `align-frontend-runtime-config.yml` → verify in `verify-deployment-connectivity.yml`.

**Files:** `manifests/frontend-runtime-config-patch.yaml`, `tasks/align-frontend-runtime-config.yml`, `tasks/verify-deployment-connectivity.yml`.

---

### 2. Verify ran before frontend align (playbook ordering)

**Symptom:** Same `/env.json` failure at **Step 6f** (after structured-data rollouts), before **Step 6-post**.

**Cause:** Connectivity verify included `/env.json` checks before `finalize-deployment-connectivity.yml` patched the frontend.

**Fix (in repo):** Step 6f sets `contentiq_verify_env_json_and_cors: false`; full check runs in 6-post only.

**Vars:** `contentiq_finalize_connectivity_after_deploy: true`, `contentiq_align_frontend_runtime_config: true`.

---

### 3. Recursive loop in Jinja (Step 6-post)

**Symptom:**

```text
Recursive loop detected in template: maximum recursion depth exceeded
Origin: deploy.yml:1413  contentiq_verify_edge_gateway_from_backend
```

**Cause:** Task `vars` set `contentiq_verify_edge_gateway_from_backend` using an expression that referenced the same variable name.

**Fix (in repo):** `set_fact` → `contentiq_step6_post_edge_gateway_verify`, then pass into finalize include.

---

### 4. Frontend `CrashLoopBackOff` — `PermissionError: /srv/app/env.json`

**Symptom (pod logs):**

```text
PermissionError: [Errno 13] Permission denied: '/srv/app/env.json'
```

**Also:** `oc logs ... -c render-frontend-env-json` → *container not valid* (initContainer missing on that ReplicaSet).

**Cause:**

- Image 1.3.x runs `render_runtime_config.py` at startup targeting `/srv/app/env.json`.
- OpenShift random UID cannot write into the image filesystem.
- Durable fix requires **initContainer** `render-frontend-env-json` + **emptyDir** volume; main container uses `CONTENTIQ_RUNTIME_CONFIG_PATH=/config/env.json`.
- Partial patch or operator reconcile can drop initContainers while a new ReplicaSet still crashes.

**Fix (automated):** `deploy.yml` applies `ensure-frontend-runtime-patch.yml` in **Step 6a-pre** (immediately after the CR, before Redis/backend rollout waits), re-checks on every Step 6 rollout iteration (`reassert-frontend-runtime-patch-if-needed.yml`), and uses **`wait-frontend-rollout-with-runtime-patch.yml`** during the `contentiq-frontend` rollout wait (re-applies the strategic patch and waits for initContainer stabilization while the operator reconciles). Step 6-post runs `align-frontend-runtime-config.yml` again. Defaults: `contentiq_frontend_apply_runtime_config_patch: true`, `contentiq_frontend_rollout_guard_enabled: true`, `contentiq_frontend_patch_early_after_cr: true`, `contentiq_frontend_watch_during_rollouts: true`.

**Fix (manual):**

```bash
cd ansible && ./scripts/fix-frontend-crashloop.sh
```

**Verify patch applied:**

```bash
oc get deployment contentiq-frontend -n contentiq \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
# expect: render-frontend-env-json
```

**Files:** `manifests/frontend-runtime-config-patch.yaml` (strategic merge), `scripts/fix-frontend-crashloop.sh`.

**Not normal:** One pod `Running` and one `CrashLoopBackOff` for `frontendReplicas: 1` — old ReplicaSet may still serve traffic with wrong `/env.json`.

---

### 5. Edge-gateway probe WARN (non-fatal)

**Symptom:**

```text
WARN: backend cannot reach http://edge-gateway/management/v1/warehouse within 8s
```

**Cause:** Structured-data stack not ready, `edge-gateway` / `lakekeeper` down, or backend `LAKEHOUSE_INGRESS_PORT` wrong (default 80 vs Service 8080).

**Fix:**

- Step **6g** sets `LAKEHOUSE_INGRESS_PORT` from Service port (playbook default).
- Manual: [DEPLOYMENT-CONFIG.md](../DEPLOYMENT-CONFIG.md) lakehouse patch + backend restart.
- Check pods: `edge-gateway`, `edge-auth-proxy`, `lakekeeper`, `trino-*`.

---

### 6. Backend CORS / UI calls wrong API host

**Symptom:** Browser DevTools CORS errors; requests to `https://backend.contentiq.symplistic.ai` instead of your Route; sidebar shows **User** not your name.

**Cause:** `contentiq-backend-secrets` still has placeholder URLs, or manual `oc apply` of secrets after routes were created without alignment.

**Fix:**

```bash
cd ansible && ./scripts/align-backend-secret-to-routes.sh
# or
./scripts/fix-app-connectivity.sh
```

**Playbook:** Step 6-post → `patch-backend-secret-to-live-routes.yml` (restart + wait).

---

### 7. Route / HAProxy timeouts (504)

**Symptom:** Ingest, export, or playground SSE closes at ~30s–5m.

**Fix:** Step 6d / 6-post annotates routes with `haproxy.router.openshift.io/timeout=1800s`, or:

```bash
cd ansible && ./scripts/apply-streaming-and-connectivity-fixes.sh
```

---

## Ansible `fail_msg` failures (by category)

### Preflight and configuration

| Message / check | Typical cause | What to do |
|-----------------|---------------|------------|
| `oc` client not available | Ansible host missing `oc` or wrong `PATH` | Install CLI, `oc login` |
| IBM SM: `contentiq_manage_pull_secret` must be false | Both SM and Step 2 pull secret enabled | `-e contentiq_manage_pull_secret=false` for SM runs |
| IBM SM: missing endpoint or secret UUIDs | Incomplete `ibm-sm-deploy.vars.local.yml` / env | Fill `contentiq_secrets_manager_*` vars; run `check-ibm-sm-apikey-access.sh` |
| Pull-secret credentials missing | `contentiq_manage_pull_secret=true` but empty `parameters.yml` registry fields | Set username/password/email or use SM mode |
| `ingress.config/cluster` domain unreadable | Not logged in or non-OpenShift cluster | `oc login`; or `contentiq_auto_route_hostnames: false` and set CR hostnames manually |
| `__CONTENTIQ_*__` placeholders still present | Auto hostnames disabled but manifests not edited | Enable auto hostnames or replace placeholders in CR |

### Rollouts (Step 6)

| Message / check | Typical cause | What to do |
|-----------------|---------------|------------|
| `Rollout failed for deployment/...` | Image pull, crash loop, memory, progress deadline 600s | `oc describe pod`, `oc logs`; increase `contentiq_rollout_timeout_seconds` / `contentiq_min_progress_deadline_seconds` (deploy defaults 4h); tight clusters: `contentiq_rollout_pause_between_deployments_seconds` |
| Progress deadline exceeded | Slow image pull on cold cluster | Playbook may auto `rollout restart` + re-patch deadline; retry deploy |
| Structured-data deployments never appear | Operator still reconciling; phase-2 deferred | Wait; set `contentiq_defer_phase2_and_structured_poststeps: false` when ready |

### Step 6c — frontend runtime config

| Message / check | Typical cause | What to do |
|-----------------|---------------|------------|
| `deployment missing initContainer render-frontend-env-json` | Operator reverted strategic patch between `oc patch` and assert | Playbook retries patch up to `contentiq_frontend_patch_assert_retries` (default 12×5s); or run `align-frontend-env-json.sh` after rollouts settle |
| In-pod `env.json` empty or wrong `apiBaseUrl` | ConfigMap missing `CONTENTIQ_API_BASE_URL` | Merge-patch `frontend-config`; rollout frontend |
| Route `/env.json` 502/503 until timeout | Rollout finished before router endpoints ready | Playbook retries (`contentiq_step6c_env_json_verify_retries`); wait and curl again |

### Step 6e / 6-post — verify connectivity

| Message / check | Typical cause | What to do |
|-----------------|---------------|------------|
| `/env.json apiBaseUrl must be https://... Got: {}` | 6c not run or old frontend pod still in endpoints | Run `fix-app-connectivity.sh`; confirm single Ready frontend with initContainer |
| Backend health / CORS curl failed | `FRONTEND_URL` / `CORS_ALLOWED_ORIGINS` not aligned | `align-backend-secret-to-routes.sh` |
| `CONTENTIQ_API_BASE_URL` missing (WARN) | Operator-only `ONPREM_API_URL` | Step 6c merge-patch (expected WARN before patch) |

### OSB / broker (Step 9)

| Message / check | Typical cause | What to do |
|-----------------|---------------|------------|
| Broker assignments file missing | No `broker.yml` / SM broker secret | `-e contentiq_skip_osb_provision=true` for lab; or provide `contentiq_broker_assignments_file` |
| Backend route required for OSB | Step 9 before routes exist | Complete Step 8; defer broker SM fetch is default (`contentiq_ibmsm_defer_broker_sm_fetch_until_osb`) |

---

## Cluster symptoms (often hit on-prem, not always Ansible failures)

These appear in `oc get pods` / events; the playbook may still exit 0 if verify is skipped or WARN-only.

| Symptom | Namespace / component | Playbook / script mitigation |
|---------|----------------------|------------------------------|
| CatalogSource `ImagePullBackOff` | `openshift-marketplace` | Step 2 pull secret + `02-catalogsource.yaml` `spec.secrets` |
| Operator pod `ImagePullBackOff` | `openshift-operators` | Link pull secret to `contentiq-operator-controller-manager` |
| CNPG controller SCC denied | `cnpg-system` | Step 7a grants `nonroot-v2` (deploy.yml) |
| CNPG webhook cert missing `ca.crt` | `cnpg-system` | Step 7a webhook cert copy (see CUSTOMER-GUIDE) |
| Lakekeeper / Trino SCC denied | `contentiq` | Step 7a `nonroot-v2` for `lakekeeper`, `trino` |
| `edge-gateway` up but lakehouse API timeout | `contentiq` backend secret | Step 6g `LAKEHOUSE_INGRESS_PORT=8080` |
| Postgres / Lakekeeper migration job failed | `contentiq` | pgvector Step 7b; optional delete migration job and retry |
| Pods `Pending` / `Evicted` / `OOMKilled` | any | README minimum 64 GB RAM / 300 GB disk; `contentiq_defer_phase2_and_structured_poststeps: true` on CRC |
| Two frontend pods, one CrashLoop | `contentiq` | Section 4 above — fix patch, rollout |

---

## Helper scripts (from `ansible/scripts/`)

| Script | When to use |
|--------|-------------|
| `verify-contentiq-deploy.sh` | Post-install smoke test (`/env.json`, CORS, configmap keys) |
| `fix-app-connectivity.sh` | Backend routes/CORS + frontend `/env.json` |
| `align-frontend-env-json.sh` | Frontend only — ConfigMap + strategic deployment patch |
| `fix-frontend-crashloop.sh` | Frontend `PermissionError` on `/env.json` (wraps align script) |
| `align-backend-secret-to-routes.sh` | Backend secret URLs vs live Routes |
| `apply-streaming-and-connectivity-fixes.sh` | Route timeouts + connectivity + verification |
| `push-ibm-sm-secrets.sh` | Upload local templates to IBM SM |
| `playbooks/scripts/check-ibm-sm-apikey-access.sh` | Preflight IBM SM API access |

---

## Key Ansible variables (connectivity / on-prem)

| Variable | Default (typical) | Purpose |
|----------|-------------------|---------|
| `contentiq_align_frontend_runtime_config` | `true` | Step 6c in 6-post |
| `contentiq_frontend_apply_runtime_config_patch` | `true` | Strategic patch + initContainer |
| `contentiq_frontend_patch_early_after_cr` | `true` | Patch right after CR apply (before other rollout waits) |
| `contentiq_frontend_watch_during_rollouts` | `true` | Re-apply patch if CrashLoop or missing initContainer during Step 6 |
| `contentiq_frontend_patch_before_rollout` | `true` | Patch before Step 6 frontend rollout wait (skipped if 6a-pre ran) |
| `contentiq_frontend_rollout_guard_enabled` | `true` | During frontend rollout wait: re-patch initContainer until stable |
| `contentiq_frontend_rollout_guard_poll_seconds` | `15` | Poll interval while waiting for frontend rollout |
| `contentiq_frontend_rollout_stable_checks` | `3` | Consecutive stable checks (initContainer + no CrashLoop) before success |
| `contentiq_finalize_connectivity_after_deploy` | `true` | Run 6-post after rollouts |
| `contentiq_verify_env_json_and_cors` | `true` (false at 6f only) | Split verify |
| `contentiq_align_backend_secret_to_live_routes` | `true` | CORS / `FRONTEND_URL` |
| `contentiq_enable_phased_rollout` | `true` | Redis → core → phase-2 |
| `contentiq_defer_phase2_and_structured_poststeps` | `false` | `true` on tight CRC to skip lakehouse rollouts |
| `contentiq_auto_route_hostnames` | `true` | Fill CR route hostnames from cluster ingress domain |

---

## Files commonly changed for on-prem (reference)

| Path | Role in failures above |
|------|-------------------------|
| `playbooks/deploy.yml` | Step order, vars, IBM SM vs local, phased rollouts |
| `playbooks/tasks/align-frontend-runtime-config.yml` | Step 6c — ConfigMap + patch + verify |
| `playbooks/tasks/verify-deployment-connectivity.yml` | `/env.json`, CORS, edge-gateway |
| `playbooks/tasks/finalize-deployment-connectivity.yml` | 6-post orchestration |
| `playbooks/tasks/patch-backend-secret-to-live-routes.yml` | Backend URL alignment |
| `playbooks/tasks/align-lakehouse-ingress-port.yml` | Port 8080 |
| `manifests/frontend-runtime-config-patch.yaml` | initContainer + emptyDir (CrashLoop fix) |
| `manifests/contentiq-custom-resource.yaml` | Images, routes, replicas |
| `secrets/backend-secrets-template.yaml` | CORS, OAuth, cloud keys — must match routes |
| `parameters.yml` | Registry pull creds, defer phase-2, toggles |
| `CUSTOMER-GUIDE.md` | SCC, CNPG, catalog pull, air-gap |

---

## Recommended recovery order (UI broken after deploy)

1. `oc get pods -n contentiq` — fix CrashLoop / ImagePullBackOff first.
2. `./scripts/fix-frontend-crashloop.sh` or `fix-app-connectivity.sh` if frontend/backend connectivity.
3. `./scripts/verify-contentiq-deploy.sh`
4. Hard-refresh browser; check DevTools → Network → `env.json` for correct `apiBaseUrl`.
5. Re-run deploy playbook only if you need full alignment (6-post is idempotent for patches).

---

*Last updated from playbook work: Step 6f/6-post verify split, recursive `set_fact` fix, frontend strategic patch + CrashLoop documentation.*
