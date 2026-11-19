#!/usr/bin/env bash
set -euo pipefail

# OpenShift Application Discovery & Assessment Collector
# Pré-requisito: estar conectado ao cluster via `oc login`

if ! command -v oc >/dev/null 2>&1; then
  echo "ERRO: 'oc' CLI não encontrado no PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERRO: 'jq' não encontrado no PATH. Instale o jq para sanitização de Secrets." >&2
  exit 1
fi

echo "Verificando conexão com o cluster OpenShift..."
USER_NAME=$(oc whoami 2>/dev/null || true)
if [[ -z "$USER_NAME" ]]; then
  echo "ERRO: Você não está autenticado no cluster. Execute 'oc login' primeiro." >&2
  exit 1
fi

API_SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUT_DIR="output/assessment-${TIMESTAMP}"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${RAW_DIR}"

echo "Conectado como: ${USER_NAME}"
echo "API Server:     ${API_SERVER}"
echo "Salvando dados em: ${OUT_DIR}"

# Salva metadados da coleta
cat > "${OUT_DIR}/metadata.txt" <<EOF
timestamp=${TIMESTAMP}
user=${USER_NAME}
api_server=${API_SERVER}
oc_version=$(oc version -o json 2>/dev/null | jq -c '.' || oc version 2>/dev/null | tr '\n' ' ')
EOF

collect_resource() {
  local resource="$1"
  local filename="$2"
  local scope="${3:-all}" # 'all' para -A, 'cluster' para cluster-scoped

  echo "  -> Coletando ${resource}..."
  if [[ "$scope" == "cluster" ]]; then
    if ! oc get "${resource}" -o json > "${RAW_DIR}/${filename}.json" 2>"${RAW_DIR}/${filename}.err"; then
      echo "     [AVISO] Não foi possível coletar ${resource} (ver ${filename}.err)"
    else
      rm -f "${RAW_DIR}/${filename}.err"
    fi
  else
    if ! oc get "${resource}" -A -o json > "${RAW_DIR}/${filename}.json" 2>"${RAW_DIR}/${filename}.err"; then
      echo "     [AVISO] Não foi possível coletar ${resource} (ver ${filename}.err)"
    else
      rm -f "${RAW_DIR}/${filename}.err"
    fi
  fi
}

echo ""
echo "=== 1. Infraestrutura e Cluster ==="
collect_resource "nodes" "nodes" "cluster"
collect_resource "clusterversion" "clusterversion" "cluster"
collect_resource "infrastructures.config.openshift.io" "infrastructure" "cluster"
collect_resource "networks.config.openshift.io" "network_config" "cluster"
collect_resource "ingresses.config.openshift.io" "ingress_config" "cluster"
collect_resource "storageclasses" "storageclasses" "cluster"
collect_resource "persistentvolumes" "persistentvolumes" "cluster"
collect_resource "namespaces" "namespaces" "cluster"

echo ""
echo "=== 2. Workloads ==="
collect_resource "deployments" "deployments" "all"
collect_resource "deploymentconfigs" "deploymentconfigs" "all"
collect_resource "statefulsets" "statefulsets" "all"
collect_resource "daemonsets" "daemonsets" "all"
collect_resource "cronjobs" "cronjobs" "all"
collect_resource "jobs" "jobs" "all"
collect_resource "pods" "pods" "all"
collect_resource "horizontalpodautoscalers" "hpas" "all"
collect_resource "poddisruptionbudgets" "pdbs" "all"

echo ""
echo "=== 3. Rede e Exposição ==="
collect_resource "services" "services" "all"
collect_resource "routes" "routes" "all"
collect_resource "ingresses" "ingresses" "all"
collect_resource "networkpolicies" "networkpolicies" "all"
collect_resource "egressfirewalls" "egressfirewalls" "all"
collect_resource "egressnetworkpolicies" "egressnetworkpolicies" "all"

echo ""
echo "=== 4. Storage, Quotas e Configuração ==="
collect_resource "persistentvolumeclaims" "pvcs" "all"
collect_resource "resourcequotas" "resourcequotas" "all"
collect_resource "limitranges" "limitranges" "all"
collect_resource "serviceaccounts" "serviceaccounts" "all"
collect_resource "configmaps" "configmaps" "all"

# Secrets: NUNCA salvar .data ou .stringData, apenas metadados e chaves
echo "  -> Coletando secrets (somente metadados e nomes das chaves, sem valores)..."
if oc get secrets -A -o json 2>"${RAW_DIR}/secrets.err" | \
  jq '{apiVersion, kind, items: [.items[] | {metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels, annotations: (.metadata.annotations // {} | del(.["kubectl.kubernetes.io/last-applied-configuration"]))}, type: .type, keys: ((.data // {}) | keys)}]}' \
  > "${RAW_DIR}/secrets_metadata.json"; then
  rm -f "${RAW_DIR}/secrets.err"
else
  echo "     [AVISO] Não foi possível coletar secrets (ver secrets.err)"
fi

echo ""
echo "=== 5. Operators, Builds e GitOps (se disponíveis) ==="
collect_resource "subscriptions.operators.coreos.com" "olm_subscriptions" "all"
collect_resource "clusterserviceversions.operators.coreos.com" "olm_csvs" "all"
collect_resource "buildconfigs" "buildconfigs" "all"
collect_resource "imagestreams" "imagestreams" "all"
collect_resource "applications.argoproj.io" "argocd_applications" "all"

echo ""
echo "=== 6. Compactação dos dados ==="
ARCHIVE_BASE="output/assessment-${TIMESTAMP}"
ARCHIVE_FILE=""

if command -v xz >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  ARCHIVE_FILE="${ARCHIVE_BASE}.tar.xz"
  echo "Compactando com tar + xz (-6)..."
  tar -cf - -C output "assessment-${TIMESTAMP}" | xz -6 > "${ARCHIVE_FILE}"
elif command -v gzip >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  ARCHIVE_FILE="${ARCHIVE_BASE}.tar.gz"
  echo "Compactando com tar + gzip (-9)..."
  tar -cf - -C output "assessment-${TIMESTAMP}" | gzip -9 > "${ARCHIVE_FILE}"
elif command -v zip >/dev/null 2>&1; then
  ARCHIVE_FILE="${ARCHIVE_BASE}.zip"
  echo "Compactando com zip (-9)..."
  (cd output && zip -9 -rq "assessment-${TIMESTAMP}.zip" "assessment-${TIMESTAMP}")
else
  echo "[AVISO] Nenhum compactador (xz, gzip ou zip) encontrado. Dados mantidos sem compactação em ${OUT_DIR}."
fi

echo ""
echo "Coleta concluída com sucesso!"
if [[ -n "${ARCHIVE_FILE}" ]]; then
  ARCHIVE_SIZE=$(du -h "${ARCHIVE_FILE}" 2>/dev/null | cut -f1 || echo "desconhecido")
  echo "Arquivo compactado gerado: ${ARCHIVE_FILE} (${ARCHIVE_SIZE})"
  echo "Envie este arquivo para análise."
fi
echo ""
echo "Próximo passo (após descompactar, se necessário): gerar o mapa e relatórios com:"
echo "  python3 02-generate-assessment-map.py ${OUT_DIR}"
