#!/bin/bash
set -e

# Nome da imagem base (vinda do docker-compose.yml)
IMAGE_NAME="wordpress-litespeed"
TAG="dev"
FULL_TAG="${IMAGE_NAME}:${TAG}"

echo "🚀 Iniciando build do ambiente de desenvolvimento: ${FULL_TAG}"

# Verifica se já existe uma imagem com essa tag
if docker image inspect "$FULL_TAG" > /dev/null 2>&1; then
  echo "💾 Usando cache da imagem existente: $FULL_TAG"
else
  echo "⚠️ Nenhuma imagem cache encontrada para $FULL_TAG"
fi

# Executa o build com docker compose e profile dev
echo "🧱 Executando: docker compose --profile dev up -d --build"
docker compose --profile dev up -d --build

# Tagueia a imagem principal com nome fixo para reaproveitamento
# OBS: Substitua o nome correto do serviço abaixo, se não for 'wordpress'
SERVICE_NAME="wordpress"

# Obtém ID da imagem construída
IMAGE_ID=$(docker compose images -q $SERVICE_NAME)

if [ -n "$IMAGE_ID" ]; then
  echo "🏷️ Tagueando imagem ID $IMAGE_ID como $FULL_TAG..."
  docker tag "$IMAGE_ID" "$FULL_TAG"
else
  echo "❌ Não foi possível identificar a imagem para o serviço $SERVICE_NAME"
fi

# Limpa imagens <none>
echo "🧹 Limpando imagens <none> (dangling)..."
docker image prune -f

echo "✅ Build DEV finalizado com sucesso!"