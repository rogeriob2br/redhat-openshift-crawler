#!/usr/bin/env python3
"""
OpenShift Application Assessment & Discovery Map Generator
Lê os JSONs coletados pelo 01-collect-cluster-raw.sh e gera CSVs e um relatório Markdown
para apoiar a decisão de divisão dos clusters.
Usa apenas a biblioteca padrão do Python 3.
"""

import csv
import json
import os
import re
import sys
from collections import defaultdict


def load_json_items(raw_dir: str, filename: str) -> list:
    path = os.path.join(raw_dir, f"{filename}.json")
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("items", [])
    except Exception as e:
        print(f"[AVISO] Erro ao ler {path}: {e}", file=sys.stderr)
        return []


def parse_cpu_cores(val: str) -> float:
    if not val:
        return 0.0
    val = str(val).strip()
    if val.endswith("m"):
        return float(val[:-1]) / 1000.0
    if val.endswith("n"):
        return float(val[:-1]) / 1_000_000_000.0
    try:
        return float(val)
    except ValueError:
        return 0.0


def parse_mem_gib(val: str) -> float:
    if not val:
        return 0.0
    val = str(val).strip()
    units = {
        "Ki": 1 / (1024 ** 2),
        "Mi": 1 / 1024,
        "Gi": 1.0,
        "Ti": 1024.0,
        "K": 1000 / (1024 ** 3),
        "M": 1_000_000 / (1024 ** 3),
        "G": 1_000_000_000 / (1024 ** 3),
        "T": 1_000_000_000_000 / (1024 ** 3),
    }
    for suffix, mult in units.items():
        if val.endswith(suffix):
            try:
                return float(val[: -len(suffix)]) * mult
            except ValueError:
                return 0.0
    try:
        return float(val) / (1024 ** 3)
    except ValueError:
        return 0.0


DEP_ENV_PATTERN = re.compile(
    r"(HOST|URL|URI|ENDPOINT|ADDR|SERVER|BROKER|JDBC|DB_|DATABASE|POSTGRES|MYSQL|ORACLE|SQL|"
    r"KAFKA|RABBIT|AMQP|REDIS|MONGO|ELASTIC|S3_|BUCKET|API_|AUTH|KEYCLOAK|LDAP|SMTP|QUEUE)",
    re.IGNORECASE,
)


def extract_pod_spec_info(pod_spec: dict, replicas: int = 1):
    containers = pod_spec.get("containers", []) or []
    images = []
    cpu_req = 0.0
    cpu_lim = 0.0
    mem_req = 0.0
    mem_lim = 0.0
    env_hints = []
    cm_refs = set()
    secret_refs = set()

    for c in containers:
        if c.get("image"):
            images.append(c["image"])
        res = c.get("resources", {}) or {}
        reqs = res.get("requests", {}) or {}
        lims = res.get("limits", {}) or {}
        cpu_req += parse_cpu_cores(reqs.get("cpu")) * replicas
        cpu_lim += parse_cpu_cores(lims.get("cpu")) * replicas
        mem_req += parse_mem_gib(reqs.get("memory")) * replicas
        mem_lim += parse_mem_gib(lims.get("memory")) * replicas

        for env in c.get("env", []) or []:
            name = env.get("name", "")
            val = env.get("value")
            val_from = env.get("valueFrom", {}) or {}
            if "configMapKeyRef" in val_from:
                cm_refs.add(val_from["configMapKeyRef"].get("name", ""))
            if "secretKeyRef" in val_from:
                secret_refs.add(val_from["secretKeyRef"].get("name", ""))
            if DEP_ENV_PATTERN.search(name):
                if val is not None:
                    # Mascara possíveis senhas em URLs (ex: user:pass@host)
                    safe_val = re.sub(r"://([^:@/]+):([^@/]+)@", r"://\1:***@", str(val))
                    env_hints.append((name, safe_val))
                else:
                    src = "secret/cm"
                    if "configMapKeyRef" in val_from:
                        src = f"cm:{val_from['configMapKeyRef'].get('name')}"
                    elif "secretKeyRef" in val_from:
                        src = f"secret:{val_from['secretKeyRef'].get('name')}"
                    env_hints.append((name, f"<{src}>"))

        for env_from in c.get("envFrom", []) or []:
            if "configMapRef" in env_from:
                cm_refs.add(env_from["configMapRef"].get("name", ""))
            if "secretRef" in env_from:
                secret_refs.add(env_from["secretRef"].get("name", ""))

    pvc_refs = set()
    for v in pod_spec.get("volumes", []) or []:
        if "persistentVolumeClaim" in v:
            pvc_refs.add(v["persistentVolumeClaim"].get("claimName", ""))
        if "configMap" in v:
            cm_refs.add(v["configMap"].get("name", ""))
        if "secret" in v:
            secret_refs.add(v["secret"].get("secretName", ""))

    return {
        "images": images,
        "cpu_req": cpu_req,
        "cpu_lim": cpu_lim,
        "mem_req": mem_req,
        "mem_lim": mem_lim,
        "env_hints": env_hints,
        "cm_refs": sorted(x for x in cm_refs if x),
        "secret_refs": sorted(x for x in secret_refs if x),
        "pvc_refs": sorted(x for x in pvc_refs if x),
        "sa": pod_spec.get("serviceAccountName", "default"),
    }


def is_system_namespace(ns: str) -> bool:
    return (
        ns.startswith("openshift-")
        or ns.startswith("kube-")
        or ns in {"default", "openshift", "open-cluster-management"}
    )


def main():
    if len(sys.argv) < 2:
        print("Uso: python3 02-generate-assessment-map.py <diretorio_output_coleta>", file=sys.stderr)
        sys.exit(1)

    out_dir = sys.argv[1].rstrip("/")
    raw_dir = os.path.join(out_dir, "raw")
    report_dir = os.path.join(out_dir, "report")
    os.makedirs(report_dir, exist_ok=True)

    if not os.path.isdir(raw_dir):
        print(f"ERRO: Diretório {raw_dir} não encontrado.", file=sys.stderr)
        sys.exit(1)

    namespaces = load_json_items(raw_dir, "namespaces")
    nodes = load_json_items(raw_dir, "nodes")
    deployments = load_json_items(raw_dir, "deployments")
    dcs = load_json_items(raw_dir, "deploymentconfigs")
    statefulsets = load_json_items(raw_dir, "statefulsets")
    daemonsets = load_json_items(raw_dir, "daemonsets")
    cronjobs = load_json_items(raw_dir, "cronjobs")
    pods = load_json_items(raw_dir, "pods")
    services = load_json_items(raw_dir, "services")
    routes = load_json_items(raw_dir, "routes")
    ingresses = load_json_items(raw_dir, "ingresses")
    pvcs = load_json_items(raw_dir, "pvcs")
    netpols = load_json_items(raw_dir, "networkpolicies")
    quotas = load_json_items(raw_dir, "resourcequotas")
    subs = load_json_items(raw_dir, "olm_subscriptions")

    # Mapear exposição por namespace e service
    exposure_rows = []
    svc_to_hosts = defaultdict(list)
    ns_routes_count = defaultdict(int)

    for r in routes:
        meta = r.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = r.get("spec", {})
        host = spec.get("host", "")
        path = spec.get("path", "/")
        tls = "Yes" if spec.get("tls") else "No"
        to = spec.get("to", {}) or {}
        svc = to.get("name", "")
        port = (spec.get("port", {}) or {}).get("targetPort", "")
        ns_routes_count[ns] += 1
        if svc and host:
            svc_to_hosts[(ns, svc)].append(host)
        exposure_rows.append([ns, "Route", name, host, path, tls, svc, str(port)])

    for ing in ingresses:
        meta = ing.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = ing.get("spec", {})
        tls = "Yes" if spec.get("tls") else "No"
        for rule in spec.get("rules", []) or []:
            host = rule.get("host", "")
            http = rule.get("http", {}) or {}
            for p in http.get("paths", []) or []:
                path = p.get("path", "/")
                backend = p.get("backend", {}) or {}
                svc = (backend.get("service", {}) or {}).get("name") or backend.get("serviceName", "")
                port = (backend.get("service", {}) or {}).get("port", {}).get("number") or backend.get("servicePort", "")
                ns_routes_count[ns] += 1
                if svc and host:
                    svc_to_hosts[(ns, svc)].append(host)
                exposure_rows.append([ns, "Ingress", name, host, path, tls, svc, str(port)])

    with open(os.path.join(report_dir, "network_exposure.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Namespace", "Kind", "Name", "Host", "Path", "TLS", "TargetService", "TargetPort"])
        w.writerows(exposure_rows)

    # Mapear PVCs por namespace
    ns_pvc_count = defaultdict(int)
    ns_pvc_gib = defaultdict(float)
    rwx_pvcs = []
    for pvc in pvcs:
        meta = pvc.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = pvc.get("spec", {})
        req_storage = (spec.get("resources", {}) or {}).get("requests", {}).get("storage", "0")
        gib = parse_mem_gib(req_storage)
        modes = spec.get("accessModes", []) or []
        sc = spec.get("storageClassName", "")
        ns_pvc_count[ns] += 1
        ns_pvc_gib[ns] += gib
        if "ReadWriteMany" in modes and not is_system_namespace(ns):
            rwx_pvcs.append((ns, name, f"{gib:.1f}Gi", sc))

    # Mapear Workloads
    app_rows = []
    dep_rows = []
    ns_cpu_req = defaultdict(float)
    ns_cpu_lim = defaultdict(float)
    ns_mem_req = defaultdict(float)
    ns_mem_lim = defaultdict(float)
    ns_app_count = defaultdict(int)

    def process_workload(kind: str, item: dict, pod_spec: dict, replicas: int):
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        info = extract_pod_spec_info(pod_spec, replicas)

        ns_app_count[ns] += 1
        ns_cpu_req[ns] += info["cpu_req"]
        ns_cpu_lim[ns] += info["cpu_lim"]
        ns_mem_req[ns] += info["mem_req"]
        ns_mem_lim[ns] += info["mem_lim"]

        # Tentar associar hosts por nome parecido ou label
        hosts = set()
        for (s_ns, s_name), h_list in svc_to_hosts.items():
            if s_ns == ns and (s_name == name or name in s_name or s_name in name):
                hosts.update(h_list)

        app_rows.append([
            ns,
            kind,
            name,
            replicas,
            "; ".join(info["images"]),
            f"{info['cpu_req']:.2f}",
            f"{info['cpu_lim']:.2f}",
            f"{info['mem_req']:.2f}",
            f"{info['mem_lim']:.2f}",
            info["sa"],
            "; ".join(sorted(hosts)),
            "; ".join(info["pvc_refs"]),
            "; ".join(info["cm_refs"]),
            "; ".join(info["secret_refs"]),
        ])

        for env_k, env_v in info["env_hints"]:
            dep_rows.append([ns, kind, name, "EnvVar", env_k, env_v])

    for d in deployments:
        spec = d.get("spec", {})
        reps = spec.get("replicas", 1) or 0
        pod_spec = (spec.get("template", {}) or {}).get("spec", {}) or {}
        process_workload("Deployment", d, pod_spec, reps)

    for dc in dcs:
        spec = dc.get("spec", {})
        reps = spec.get("replicas", 1) or 0
        pod_spec = (spec.get("template", {}) or {}).get("spec", {}) or {}
        process_workload("DeploymentConfig", dc, pod_spec, reps)

    for sts in statefulsets:
        spec = sts.get("spec", {})
        reps = spec.get("replicas", 1) or 0
        pod_spec = (spec.get("template", {}) or {}).get("spec", {}) or {}
        process_workload("StatefulSet", sts, pod_spec, reps)

    for ds in daemonsets:
        spec = ds.get("spec", {})
        pod_spec = (spec.get("template", {}) or {}).get("spec", {}) or {}
        process_workload("DaemonSet", ds, pod_spec, 1)

    for cj in cronjobs:
        spec = cj.get("spec", {})
        pod_spec = (((spec.get("jobTemplate", {}) or {}).get("spec", {}) or {}).get("template", {}) or {}).get("spec", {}) or {}
        process_workload("CronJob", cj, pod_spec, 1)

    # Services ExternalName (dependências externas explícitas)
    external_svcs = []
    for svc in services:
        meta = svc.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = svc.get("spec", {})
        if spec.get("type") == "ExternalName":
            ext_name = spec.get("externalName", "")
            dep_rows.append([ns, "Service", name, "ExternalName", "externalName", ext_name])
            external_svcs.append((ns, name, ext_name))

    with open(os.path.join(report_dir, "applications_inventory.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "Namespace", "Kind", "Name", "Replicas", "Images",
            "CPU_Req_Cores", "CPU_Lim_Cores", "Mem_Req_GiB", "Mem_Lim_GiB",
            "ServiceAccount", "Exposed_Hosts_Heuristic", "PVCs", "ConfigMaps", "Secrets"
        ])
        w.writerows(app_rows)

    with open(os.path.join(report_dir, "dependencies_hints.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Namespace", "Kind", "Name", "SourceType", "Key", "Value_Or_Target"])
        w.writerows(dep_rows)

    # Sumário por Namespace
    ns_pods_count = defaultdict(int)
    for p in pods:
        ns_pods_count[p.get("metadata", {}).get("namespace", "")] += 1

    ns_netpol_count = defaultdict(int)
    for np in netpols:
        ns_netpol_count[np.get("metadata", {}).get("namespace", "")] += 1

    ns_quota_count = defaultdict(int)
    for q in quotas:
        ns_quota_count[q.get("metadata", {}).get("namespace", "")] += 1

    ns_rows = []
    user_namespaces = []
    for ns_obj in namespaces:
        meta = ns_obj.get("metadata", {})
        ns = meta.get("name", "")
        labels = meta.get("labels", {}) or {}
        ann = meta.get("annotations", {}) or {}
        owner = (
            labels.get("owner")
            or labels.get("team")
            or labels.get("app.kubernetes.io/part-of")
            or ann.get("openshift.io/requester")
            or ""
        )
        is_sys = is_system_namespace(ns)
        row = [
            ns,
            "System" if is_sys else "Application",
            owner,
            ns_app_count[ns],
            ns_pods_count[ns],
            f"{ns_cpu_req[ns]:.2f}",
            f"{ns_mem_req[ns]:.2f}",
            ns_pvc_count[ns],
            f"{ns_pvc_gib[ns]:.2f}",
            ns_routes_count[ns],
            ns_netpol_count[ns],
            ns_quota_count[ns],
        ]
        ns_rows.append(row)
        if not is_sys:
            user_namespaces.append((ns, ns_cpu_req[ns], ns_mem_req[ns], ns_pvc_gib[ns], ns_app_count[ns]))

    with open(os.path.join(report_dir, "namespaces_summary.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "Namespace", "Type", "Owner_Or_Requester", "Workloads", "Pods",
            "CPU_Req_Cores", "Mem_Req_GiB", "PVCs", "Storage_GiB",
            "Routes_Ingresses", "NetworkPolicies", "ResourceQuotas"
        ])
        w.writerows(ns_rows)

    # Gerar Relatório Markdown Executivo
    top_cpu = sorted(user_namespaces, key=lambda x: x[1], reverse=True)[:15]
    top_mem = sorted(user_namespaces, key=lambda x: x[2], reverse=True)[:15]

    report_md = os.path.join(report_dir, "assessment-report.md")
    with open(report_md, "w", encoding="utf-8") as f:
        f.write("# Relatório de Assessment e Descoberta — OpenShift\n\n")
        f.write("## 1. Visão Geral do Cluster\n")
        f.write(f"- **Nodes:** {len(nodes)}\n")
        f.write(f"- **Namespaces Totais:** {len(namespaces)} ({len(user_namespaces)} de aplicações/usuários)\n")
        f.write(f"- **Workloads mapeados:** {len(app_rows)} (Deployments, DCs, StatefulSets, DaemonSets, CronJobs)\n")
        f.write(f"- **Pods em execução/registrados:** {len(pods)}\n")
        f.write(f"- **Routes/Ingresses:** {len(exposure_rows)}\n")
        f.write(f"- **PVCs:** {len(pvcs)}\n")
        f.write(f"- **Operators (OLM Subscriptions):** {len(subs)}\n\n")

        f.write("## 2. Top Namespaces de Aplicação por CPU Request\n")
        f.write("| Namespace | Workloads | CPU Req (Cores) | Mem Req (GiB) | Storage (GiB) |\n")
        f.write("|---|---:|---:|---:|---:|\n")
        for ns, cpu, mem, stg, apps in top_cpu:
            f.write(f"| `{ns}` | {apps} | {cpu:.2f} | {mem:.2f} | {stg:.2f} |\n")
        f.write("\n")

        f.write("## 3. Top Namespaces de Aplicação por Memória Request\n")
        f.write("| Namespace | Workloads | Mem Req (GiB) | CPU Req (Cores) | Storage (GiB) |\n")
        f.write("|---|---:|---:|---:|---:|\n")
        for ns, cpu, mem, stg, apps in top_mem:
            f.write(f"| `{ns}` | {apps} | {mem:.2f} | {cpu:.2f} | {stg:.2f} |\n")
        f.write("\n")

        f.write("## 4. Pontos de Atenção para Divisão dos Clusters\n")
        f.write(f"- **PVCs ReadWriteMany (RWX) em namespaces de aplicação:** {len(rwx_pvcs)}\n")
        for ns, name, size, sc in rwx_pvcs[:20]:
            f.write(f"  - `{ns}/{name}` ({size}, StorageClass: `{sc}`)\n")
        f.write(f"- **Services ExternalName (dependências externas):** {len(external_svcs)}\n")
        for ns, name, ext in external_svcs[:20]:
            f.write(f"  - `{ns}/{name}` -> `{ext}`\n")
        f.write("\n")

        f.write("## 5. Arquivos Gerados\n")
        f.write("- `namespaces_summary.csv`: Visão consolidada por namespace (recursos, quotas, network policies).\n")
        f.write("- `applications_inventory.csv`: Inventário completo de workloads, imagens, requests/limits e volumes.\n")
        f.write("- `network_exposure.csv`: Mapa de Routes e Ingresses (hosts, paths, TLS, services).\n")
        f.write("- `dependencies_hints.csv`: Pistas de dependências externas/internas extraídas de variáveis de ambiente e Services ExternalName.\n")

    print(f"Relatórios gerados com sucesso em: {report_dir}")


if __name__ == "__main__":
    main()
