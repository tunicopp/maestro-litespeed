#!/usr/bin/env bash
set -euo pipefail

echo "🚀 [PROD] Build e push da imagem (profile: prod) para o AWS ECR"

# =================== Configs ===================
IMAGE_NAME="${IMAGE_NAME:-wordpress-litespeed}"   # nome do repositório no ECR
SERVICE_NAME="${SERVICE_NAME:-wordpress}"         # serviço do docker-compose que gera a imagem
TAG="${TAG:-latest}"                              # ex: prod / latest / v1.2.3

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-528757804774}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}}"

DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker compose}"
# ===============================================

echo "🔧 IMAGE_NAME..........: ${IMAGE_NAME}"
echo "🔧 SERVICE_NAME........: ${SERVICE_NAME}"
echo "🔧 TAG.................: ${TAG}"
echo "🔧 AWS_REGION..........: ${AWS_REGION}"
echo "🔧 ECR_REPO............: ${ECR_REPO}"

# 1) Build apenas (não sobe containers) usando o profile "prod"
echo "🧱 Buildando com Compose (profile=prod) apenas o serviço ${SERVICE_NAME}..."
${DOCKER_COMPOSE} --profile prod build "${SERVICE_NAME}"

# 2) Descobrir a imagem construída para o serviço
echo "🔎 Obtendo IMAGE_ID do serviço ${SERVICE_NAME}..."
IMAGE_ID="$(${DOCKER_COMPOSE} images -q "${SERVICE_NAME}")"

if [[ -z "${IMAGE_ID}" ]]; then
  echo "❌ Não foi possível identificar a imagem do serviço ${SERVICE_NAME}."
  exit 1
fi

echo "✅ IMAGE_ID encontrado: ${IMAGE_ID}"

# 3) Tag local e tag do ECR
LOCAL_TAG="${IMAGE_NAME}:${TAG}"
echo "🏷️  Tagueando ${IMAGE_ID} como ${LOCAL_TAG} e ${ECR_REPO}:${TAG} ..."
docker tag "${IMAGE_ID}" "${LOCAL_TAG}"
docker tag "${IMAGE_ID}" "${ECR_REPO}:${TAG}"

# 4) Garantir que o repositório existe no ECR
echo "📦 Conferindo/criando repositório no ECR..."
if ! aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "${IMAGE_NAME}" --region "${AWS_REGION}" >/dev/null
  echo "🆕 Repositório ${IMAGE_NAME} criado."
else
  echo "ℹ️  Repositório ${IMAGE_NAME} já existe."
fi

# 5) Login no ECR
echo "🔐 Autenticando no ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# 6) Push
echo "📤 Enviando ${ECR_REPO}:${TAG} para o ECR..."
docker push "${ECR_REPO}:${TAG}"

# 7) Limpeza opcional (apenas <none>)
echo "🧹 Limpando imagens dangling..."
docker image prune -f >/dev/null || true

echo "✅ [PROD] Build & Push concluído! Imagem disponível em: ${ECR_REPO}:${TAG}"
