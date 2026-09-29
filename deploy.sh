#!/bin/bash
set -euo pipefail

# ============================================================
# VIRGOZKI ENVOY + OPENRESTY + gRPC | CLOUD RUN
# DEBIAN BOOKWORM
#
# PUBLIC:
#   Cloud Run -> Envoy :8080
#
# INTERNAL:
#   OpenResty    :8084
#   Xray         :10000-10015
# ============================================================

BOLD='\033[1m'
RESET='\033[0m'

GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-virgozki-proxy}"
REPOSITORY="${REPOSITORY:-virgozki}"
IMAGE_NAME="${IMAGE_NAME:-virgozki}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"
DEPLOY="${DEPLOY:-false}"

MAX_INSTANCES="${MAX_INSTANCES:-4}"
CONCURRENCY="${CONCURRENCY:-80}"
TIMEOUT="${TIMEOUT:-3600}"

loading() {
    local text="$1"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    for ((i=0; i<2; i++)); do
        for ((j=0; j<${#spinner}; j++)); do
            echo -ne "\r  ${CYAN}${spinner:$j:1} ${text}...${RESET}"
            sleep 0.05
        done
    done
    echo -ne "\r  ${GREEN}DONE: ${text}${RESET}\n"
}

info() { echo -e "  ${CYAN}[INFO]${RESET} $1"; }
ok() { echo -e "  ${GREEN}[ OK ]${RESET} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $1"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; exit 1; }

clear

echo
echo -e "  ${BOLD}${WHITE}VIRGOZKI ENVOY + OPENRESTY + gRPC${RESET}"
echo -e "  ${MAGENTA}CLOUD RUN • DEBIAN BOOKWORM${RESET}"
echo

echo -e "  ${GREEN}PUBLIC:${RESET}"
echo -e "    Cloud Run -> Envoy :8080"

echo
echo -e "  ${GREEN}INTERNAL:${RESET}"
echo -e "    OpenResty    :8084"

echo
echo -e "  ${GREEN}XRAY:${RESET}"
echo -e "    :10000-10015"
echo

echo -e "  ${BOLD}${YELLOW}SELECT RESOURCE SPECIFICATION (CPU / RAM):${RESET}"
echo -e "  ------------------------------------------"
echo -e "  ${CYAN}[1]${RESET} Low Profile    : 1 CPU, 1Gi RAM"
echo -e "  ${CYAN}[2]${RESET} Mid Profile    : 1 CPU, 2Gi RAM"
echo -e "  ${CYAN}[3]${RESET} Standard       : 2 CPU, 4Gi RAM  ${WHITE}(Default Recommended)${RESET}"
echo -e "  ${CYAN}[4]${RESET} High Profile   : 4 CPU, 8Gi RAM"
echo -e "  ${CYAN}[5]${RESET} Ultra Profile  : 8 CPU, 16Gi RAM"
echo -e "  ------------------------------------------"

read -rp "  Pumili ng option [1-5] (Default: 3): " RESOURCE_OPT

case "${RESOURCE_OPT}" in
    1) CPU="1"; RAM="1Gi" ;;
    2) CPU="1"; RAM="2Gi" ;;
    4) CPU="4"; RAM="8Gi" ;;
    5) CPU="8"; RAM="16Gi" ;;
    *) CPU="2"; RAM="4Gi" ;;
esac

echo
ok "Selected Specs: CPU=${CPU}, RAM=${RAM}"
echo

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    fail "No active GCP project detected."
fi

loading "CHECKING REQUIRED FILES"

REQUIRED_FILES=(
    "Dockerfile"
    "entrypoint.sh"
    "supervisord.conf"
    "config.json"
    "nginx.conf"
    "envoy.yaml"
    "index.html"
    "anti_ddos.py"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        fail "Missing file: ${file}"
    fi
    ok "Found ${file}"
done

loading "CHECKING config.json"
python3 - <<'PY'
import json, sys
try:
    with open("config.json", "r", encoding="utf-8") as f:
        json.load(f)
    print("  [ OK ] config.json is valid JSON")
except Exception as e:
    print("  [FAIL] config.json is invalid", e)
    sys.exit(1)
PY

loading "ENABLING REQUIRED GOOGLE CLOUD APIS"
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="${PROJECT_ID}"

info "Checking Artifact Registry..."
if ! gcloud artifacts repositories describe "${REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud artifacts repositories create "${REPOSITORY}" \
        --repository-format=docker \
        --location="${REGION}" \
        --description="VIRGOZKI Cloud Run images" \
        --project="${PROJECT_ID}"
    ok "Artifact Registry repository created"
fi

echo
echo "============================================================"
echo " BUILDING CONTAINER IMAGE"
echo "============================================================"
echo

gcloud builds submit \
    --tag="${IMAGE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}"

ok "Container image built successfully"

if [[ "${DEPLOY}" != "true" ]]; then
    echo
    echo "============================================================"
    echo -e " ${GREEN}BUILD / VALIDATION COMPLETE${RESET}"
    echo "============================================================"
    echo "  DEPLOY=true ./deploy.sh para mag-deploy sa Cloud Run."
    exit 0
fi

echo
echo "============================================================"
echo " DEPLOYING TO CLOUD RUN (CPU: ${CPU} | RAM: ${RAM})"
echo "============================================================"
echo

gcloud run deploy "${SERVICE_NAME}" \
    --image="${IMAGE}" \
    --platform=managed \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --cpu="${CPU}" \
    --memory="${RAM}" \
    --port=8080 \
    --concurrency="${CONCURRENCY}" \
    --timeout="${TIMEOUT}" \
    --min-instances=0 \
    --max-instances="${MAX_INSTANCES}" \
    --session-affinity \
    --allow-unauthenticated \
    --quiet

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --platform=managed --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"

if [[ -z "${SERVICE_URL}" ]]; then
    fail "Unable to obtain Cloud Run service URL"
fi

ok "Cloud Run URL: ${SERVICE_URL}"

info "Checking /health..."
HEALTH_OK=false
for i in {1..10}; do
    HTTP_CODE="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 10 --max-time 30 "${SERVICE_URL}/health" || true)"
    if [[ "${HTTP_CODE}" == "200" ]]; then
        HEALTH_OK=true
        ok "Cloud Run -> Envoy /health passed"
        break
    fi
    warn "Health attempt ${i}/10 failed: HTTP ${HTTP_CODE}"
    sleep 5
done

if [[ "${HEALTH_OK}" != "true" ]]; then
    fail "Cloud Run /health check failed."
fi

echo
echo "============================================================"
echo -e " ${GREEN}CLOUD RUN DEPLOYMENT COMPLETE${RESET}"
echo "============================================================"
echo -e "  URL: ${GREEN}${SERVICE_URL}${RESET}"
