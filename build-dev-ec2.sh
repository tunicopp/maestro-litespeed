#!/usr/bin/env bash
set -euo pipefail

echo "🚀 [PROD] Build & Up (profile: prod) — maestro-litespeed"

# =================== Configs ===================
REPO_URL="${REPO_URL:-https://github.com/tunicopp/maestro-litespeed.git}"
REPO_DIR="${REPO_DIR:-maestro-litespeed}"
REPO_BRANCH="${REPO_BRANCH:-main}"
URL_SITE="${URL_SITE:-18.206.164.94}"

# Serviço do docker-compose que atende HTTP
SERVICE_NAME="${SERVICE_NAME:-litespeed}"

# Porta do HOST mapeada para o HTTP do container (ajuste se necessário)
HOST_HTTP_PORT="${HOST_HTTP_PORT:-80}"

# Git auto push? (1 = sim, 0 = não)
GIT_PUSH="${GIT_PUSH:-1}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker compose}"

AMBIENTE="${AMBIENTE:-dev}"
# ===============================================

echo "🔧 REPO_URL.............: ${REPO_URL}"
echo "🔧 REPO_BRANCH..........: ${REPO_BRANCH}"
echo "🔧 SERVICE_NAME.........: ${SERVICE_NAME}"
echo "🔧 HOST_HTTP_PORT.......: ${HOST_HTTP_PORT}"
echo "🔧 GIT_PUSH.............: ${GIT_PUSH}"

# 0) Clonar/atualizar repositório
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "📥 Clonando ${REPO_URL} em ${REPO_DIR}..."
  git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${REPO_DIR}"
else
  echo "🔄 Atualizando repositório existente..."
  git -C "${REPO_DIR}" fetch origin "${REPO_BRANCH}" --depth 1
  git -C "${REPO_DIR}" checkout "${REPO_BRANCH}"
  git -C "${REPO_DIR}" reset --hard "origin/${REPO_BRANCH}"
fi

cd "${REPO_DIR}"

# 1) (Opcional) configurar identidade Git e push de mudanças locais
if [[ "${GIT_PUSH}" = "1" ]]; then
  if [[ -n "${GIT_USER_NAME}" ]]; then git config user.name "${GIT_USER_NAME}"; fi
  if [[ -n "${GIT_USER_EMAIL}" ]]; then git config user.email "${GIT_USER_EMAIL}"; fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "${REPO_URL}"
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "📝 Mudanças detectadas — fazendo commit & push..."
    git add -A
    git commit -m "ci: prod build $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    # para usar HTTPS com token, exporte GIT_ASKPASS ou use credential helper da máquina
    git push -u origin "${REPO_BRANCH}" --force
  else
    echo "ℹ️  Sem mudanças locais para enviar ao Git."
  fi
fi

# 2) Build + Up com profile prod (somente o serviço alvo ou toda a stack)
echo "🧱 Buildando imagens (profile=prod)..."
${DOCKER_COMPOSE} --profile ${AMBIENTE} build

echo "🔼 Subindo a stack (profile=prod)..."
${DOCKER_COMPOSE} --profile ${AMBIENTE} up -d --remove-orphans

# 3) Diagnóstico rápido
echo "📦 Containers em execução:"
${DOCKER_COMPOSE} --profile ${AMBIENTE} ps

echo "🌐 Teste rápido de HTTP local (curl) na porta ${HOST_HTTP_PORT}..."
if command -v curl >/dev/null 2>&1; then
  set +e
  curl -sS -I "http://${URL_SITE}:${HOST_HTTP_PORT}" | sed -n '1,5p' || true
  set -e
else
  echo "⚠️  curl não encontrado; pulando teste HTTP."
fi

echo "✅ Build PROD finalizado com sucesso!"
echo "👉 Acesse via: http://${URL_SITE}:${HOST_HTTP_PORT} (ou ajuste para 80/443 e SG/NACL)"