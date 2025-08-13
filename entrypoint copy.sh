#!/bin/bash
set -e

# 🆕 Define usuário/senha do painel WebAdmin diretamente via htpasswd
if [ -n "$LSWS_ADMIN_USER" ] && [ -n "$LSWS_ADMIN_PASS" ]; then
  if [ ${#LSWS_ADMIN_PASS} -ge 6 ]; then
    echo "🔐 Definindo WebAdmin para usuário: $LSWS_ADMIN_USER"

    # Garante que apache2-utils esteja instalado para usar htpasswd
    if ! command -v htpasswd >/dev/null 2>&1; then
      echo "📦 Instalando apache2-utils (htpasswd)..."
      apt update && apt install -y apache2-utils
    fi

    HASH=$(htpasswd -nbB "$LSWS_ADMIN_USER" "$LSWS_ADMIN_PASS" | cut -d ':' -f2-)
    echo "${LSWS_ADMIN_USER}:${HASH}" > /usr/local/lsws/admin/conf/htpasswd
  else
    echo "❌ Senha do WebAdmin precisa ter no mínimo 6 caracteres."
  fi
else
  echo "⚠️ Variáveis LSWS_ADMIN_USER ou LSWS_ADMIN_PASS não definidas."
fi


wait_for_db() {
  echo "⏳ Aguardando o banco de dados em $WORDPRESS_DB_HOST..."
  until mysqladmin ping -h"$WORDPRESS_DB_HOST" --silent; do
    sleep 2
  done
  echo "✅ Banco de dados disponível."
}

wait_for_redis() {
  echo "⏳ Aguardando o Redis em $WP_REDIS_HOST..."
  for i in {1..15}; do
    if redis-cli -h "$WP_REDIS_HOST" -a "$WP_REDIS_PASSWORD" ping | grep -q PONG; then
      echo "✅ Redis disponível."
      return 0
    fi
    sleep 2
  done
  echo "⚠️ Redis não respondeu a tempo, continuando sem ativar o cache..."
}

# Se o serviço mariadb estiver no profile, espera ele
if [ "$WORDPRESS_DB_HOST" != "rds-endpoint" ]; then
  wait_for_db
fi

WP_PATH="/var/www/vhosts/localhost/html"

# Baixa o WordPress se não existir
if [ ! -f "$WP_PATH/wp-config.php" ]; then
  echo "📥 Baixando WordPress..."
  curl -fSL -o latest.tar.gz https://pt-br.wordpress.org/latest-pt_BR.tar.gz
  tar -xzf latest.tar.gz
  rsync -a wordpress/ "$WP_PATH/"
  rm -rf wordpress latest.tar.gz

  echo "⚙️ Configurando wp-config.php..."
  wp config create \
    --path="$WP_PATH" \
    --dbname="$WORDPRESS_DB_NAME" \
    --dbuser="$WORDPRESS_DB_USER" \
    --dbpass="$WORDPRESS_DB_PASSWORD" \
    --dbhost="$WORDPRESS_DB_HOST" \
    --dbprefix="$WORDPRESS_TABLE_PREFIX" \
    --skip-check \
    --allow-root

  # Injeta configs adicionais do ambiente ANTES do require_once
  if [ -n "$WORDPRESS_CONFIG_EXTRA" ]; then
    sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i \
/* Extras do ambiente */\n$WORDPRESS_CONFIG_EXTRA\n" "$WP_PATH/wp-config.php"
  fi

  # Força instalação direta sem FTP
  #sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i \
#define('FS_METHOD', 'direct');" "$WP_PATH/wp-config.php"

  
  if ! wp core is-installed --path="$WP_PATH" --allow-root; then
    echo "🛠 Instalando WordPress..."
    wp core install \
      --path="$WP_PATH" \
      --url="http://localhost:8080" \
      --title="Maestro Ecommerce" \
      --admin_user="$WORDPRESS_ADMIN_USER" \
      --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
      --admin_email="$WORDPRESS_ADMIN_EMAIL" \
      --skip-email \
      --allow-root
  else
  echo "✅ WordPress já está instalado. Pulando instalação."
  fi

  # 🆕 Instala WooCommerce
  echo "🛒 Instalando WooCommerce..."
  wp plugin install https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip \
    --activate --allow-root --path="$WP_PATH" || true

  # 🆕 Converte para Multisite (Subdomínios)
  echo "🌐 Convertendo instalação para Multisite..."
  wp core multisite-convert \
    --title="Maestro Ecommerce Network" \
    --allow-root --path="$WP_PATH" || true

# 🆕 Configura .htaccess para Multisite

  echo "⚙️ Verificando .htaccess para Multisite..."

# Cria .htaccess vazio se não existir
if [ ! -f "$WP_PATH/.htaccess" ]; then
  echo "# Arquivo .htaccess inicializado" > "$WP_PATH/.htaccess"
fi

# Se o bloco do WordPress não estiver presente, insere
if ! grep -q "BEGIN WordPress" "$WP_PATH/.htaccess"; then
    echo "➕ Inserindo bloco de rewrite do WordPress no topo do .htaccess"
    cat > /tmp/.htaccess_wp <<'EOL'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]

# add a trailing slash to /wp-admin
RewriteRule ^wp-admin$ wp-admin/ [R=301,L]

RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^ - [L]
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOL
    cat "$WP_PATH/.htaccess" >> /tmp/.htaccess_wp
    mv /tmp/.htaccess_wp "$WP_PATH/.htaccess"
  fi
fi

# Verificando configurações PHP
echo "⚙️ Forçando alterações diretamente no php.ini (lsphp82)..."

PHP_INI="/usr/local/lsws/lsphp82/etc/php/8.2/litespeed/php.ini"

update_or_append() {
  local key="$1"
  local value="$2"

  if grep -q "^$key" "$PHP_INI"; then
    echo "🔁 Atualizando $key..."
    sed -i "s|^$key.*|$key = $value|" "$PHP_INI"
  else
    echo "➕ Adicionando $key..."
    echo "$key = $value" >> "$PHP_INI"
  fi
}

if [ -f "$PHP_INI" ]; then
  update_or_append "file_uploads" "On"
  update_or_append "memory_limit" "4096M"
  update_or_append "upload_max_filesize" "1000M"
  update_or_append "post_max_size" "1000M"
  update_or_append "max_execution_time" "600"

  update_or_append "opcache.enable" "1"
  update_or_append "opcache.enable_cli" "1"
  update_or_append "opcache.memory_consumption" "256"
  update_or_append "opcache.interned_strings_buffer" "16"
  update_or_append "opcache.max_accelerated_files" "10000"
  update_or_append "opcache.validate_timestamps" "1"
  update_or_append "opcache.revalidate_freq" "60"
  update_or_append "opcache.fast_shutdown" "1"

  update_or_append "realpath_cache_size" "4096K"
  update_or_append "realpath_cache_ttl" "600"
  update_or_append "max_input_vars" "5000"
  update_or_append "session.gc_maxlifetime" "2880"
  update_or_append "output_buffering" "4096"

  update_or_append "expose_php" "Off"
  update_or_append "display_errors" "Off"
  update_or_append "log_errors" "On"


  echo "✅ Configurações aplicadas com sucesso em $PHP_INI"
else
  echo "❌ Arquivo php.ini não encontrado: $PHP_INI"
fi


# Aguarda Redis antes de habilitar
wait_for_redis

# Garante configs fixas do Redis ANTES do require_once
#sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i \
#define('WP_REDIS_HOST', 'redis'); \
#define('WP_REDIS_SCHEME', 'tcp'); \
#define('WP_REDIS_PORT', 6379); \
#define('WP_CACHE_KEY_SALT', 'maestro_'); \
#define('WP_REDIS_PASSWORD', 'redispass'); \
#define('WP_REDIS_TIMEOUT', 1); \
#define('WP_REDIS_DATABASE', 0);" "$WP_PATH/wp-config.php"

echo "⚡ Instalando e ativando Redis Cache..."
rm -f "$WP_PATH/wp-content/object-cache.php"
wp plugin install redis-cache --activate --allow-root --path="$WP_PATH" || true
#wp redis enable --allow-root --path="$WP_PATH" --force || true
wp redis enable --allow-root --path="$WP_PATH" --url="$URL_SITE" --force || true
wp redis update-dropin --allow-root --path="$WP_PATH" || true

# Garante permissões corretas
chown -R nobody:nogroup "$WP_PATH"
chmod -R 775 "$WP_PATH/wp-content"

# Garante que uploads tenha conteúdo inicial se volume estiver vazio
if [ ! "$(ls -A $WP_PATH/wp-content/uploads)" ]; then
  mkdir -p "$WP_PATH/wp-content/uploads"
  chown -R nobody:nogroup "$WP_PATH/wp-content/uploads"
  chmod -R 775 "$WP_PATH/wp-content/uploads"
fi

/usr/local/lsws/bin/lswsctrl start
tail -f /usr/local/lsws/logs/error.log
