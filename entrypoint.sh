#!/bin/bash
set -e

# ========================
# LiteSpeed WebAdmin setup
# ========================
if [ -n "$LSWS_ADMIN_USER" ] && [ -n "$LSWS_ADMIN_PASS" ]; then
  if [ ${#LSWS_ADMIN_PASS} -ge 6 ]; then
    echo "🔐 Definindo WebAdmin para usuário: $LSWS_ADMIN_USER"
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

# ===============
# Helpers
# ===============
wait_for_db() {
  echo "⏳ Aguardando o banco de dados em $WORDPRESS_DB_HOST..."
  until mysqladmin ping -h"$WORDPRESS_DB_HOST" --silent; do sleep 2; done
  echo "✅ Banco de dados disponível."
}

wait_for_redis() {
  echo "⏳ Aguardando o Redis em $WP_REDIS_HOST..."
  for i in {1..15}; do
    if redis-cli -h "$WP_REDIS_HOST" -a "$WP_REDIS_PASSWORD" ping | grep -q PONG; then
      echo "✅ Redis disponível."; return 0
    fi; sleep 2
  done
  echo "⚠️ Redis não respondeu a tempo, continuando sem ativar o cache..."
}

ensure_htaccess() {
  local WP_PATH="$1"
  echo "⚙️ Verificando .htaccess para Multisite..."
  [ -f "$WP_PATH/.htaccess" ] || echo "# Arquivo .htaccess inicializado" > "$WP_PATH/.htaccess"
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
}

apply_config_extras() {
  local WP_PATH="$1"
  if [ -z "$WORDPRESS_CONFIG_EXTRA" ]; then
    echo "ℹ️ Sem WORDPRESS_CONFIG_EXTRA para aplicar."; return 0
  fi

  echo "🔧 Aplicando WORDPRESS_CONFIG_EXTRA no wp-config.php..."
  IFS=';' read -ra DEFINES <<< "$WORDPRESS_CONFIG_EXTRA"
  for item in "${DEFINES[@]}"; do
    [[ -z "$item" ]] && continue

    # Evita forçar MULTISITE/SUBDOMAIN_INSTALL por EXTRA; deixamos o script garantir isso
    if echo "$item" | grep -qi "define('MULTISITE'"; then continue; fi
    if echo "$item" | grep -qi "define('SUBDOMAIN_INSTALL'"; then continue; fi

    key=$(echo "$item" | sed -E "s/.*define\(\s*'([^']+)'.*/\1/")
    rawval=$(echo "$item" | sed -E "s/.*define\(\s*'[^']+'\s*,\s*(.+)\s*\).*/\1/")
    rawval=${rawval%;}

    if [[ "$rawval" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"; is_string=1
    else
      value="$rawval"; is_string=0
    fi

    sed_key=$(printf "%s" "$key" | sed 's/[][\\/.*^$]/\\&/g')
    sed -i "/define\s*(\s*'${sed_key}'\s*,/Id" "$WP_PATH/wp-config.php" 2>/dev/null || true

    if [[ "$value" =~ ^([0-9]+|true|false)$ ]]; then
      echo "  • $key = $value   (raw)"
      wp config set "$key" "$value" --raw --path="$WP_PATH" --allow-root
    else
      echo "  • $key = '$value'"
      wp config set "$key" "$value" --path="$WP_PATH" --allow-root
    fi
  done
}

add_dynamic_urls_block() {
  local WP_PATH="$1"
  if [ "${DYNAMIC_URLS:-0}" = "1" ] && ! grep -q "php_sapi_name()" "$WP_PATH/wp-config.php"; then
    echo "🧠 Inserindo bloco de URL dinâmica (WP_HOME/WP_SITEURL)..."
    {
      echo ""
      echo "if ( php_sapi_name() !== 'cli' ) {"
      echo "    \$proto = (!empty(\$_SERVER['HTTPS']) || (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')) ? 'https://' : 'http://';"
      echo "    define('WP_HOME', \$proto . \$_SERVER['HTTP_HOST']);"
      echo "    define('WP_SITEURL', \$proto . \$_SERVER['HTTP_HOST']);"
      echo "}"
    } >> "$WP_PATH/wp-config.php"
  fi
}

# --- NOVO: garante que a rede exista de fato quando o config pede multisite
ensure_multisite() {
  local WP_PATH="$1"
  local PREFIX="${WORDPRESS_TABLE_PREFIX:-wp_}"

  # Checa se o WP acha que é multisite
  local IS_MS
  IS_MS=$(wp eval 'echo (int) is_multisite();' --allow-root --path="$WP_PATH" || echo 0)

  # Checa tabelas essenciais
  local HAS_BLOGS HAS_SITE
  HAS_BLOGS=$(wp db query --skip-column-names "SHOW TABLES LIKE '${PREFIX}blogs';" --allow-root --path="$WP_PATH" || true)
  HAS_SITE=$(wp db query --skip-column-names "SHOW TABLES LIKE '${PREFIX}site';"  --allow-root --path="$WP_PATH" || true)

  if [ "$IS_MS" -eq 1 ] && { [ -z "$HAS_BLOGS" ] || [ -z "$HAS_SITE" ]; }; then
    echo "🧩 Detectado MULTISITE sem tabelas de rede. Executando multisite-convert..."
    # Define modo (subdomínios ou subdiretórios) se quiser via env
    local SUBDOMAIN=${SUBDOMAIN_INSTALL:-true}
    wp core multisite-convert \
      --title="${NETWORK_TITLE:-Maestro Ecommerce Network}" \
      $( [ "$SUBDOMAIN" = "true" ] && echo --subdomains ) \
      --allow-root --path="$WP_PATH" || true

    # 🔐 garante os defines no wp-config.php
    wp config set MULTISITE true --raw --path="$WP_PATH" --allow-root
    wp config set SUBDOMAIN_INSTALL ${SUBDOMAIN_INSTALL:-true} --raw --path="$WP_PATH" --allow-root

    echo "🔄 Atualizando DB da rede..."
    wp core update-db --network --allow-root --path="$WP_PATH" || true
  fi
}

# ———————— SSL/Certbot: configurar listener e recarregar quando necessário ————————
configure_ssl_listener() {
  local DOMAIN="${DOMAIN}"
  local CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
  local HTTPD_CONF="/usr/local/lsws/conf/httpd_config.conf"

  [ -d "$CERT_DIR" ] || { echo "🔎 Certificados ainda não presentes em $CERT_DIR"; return 0; }
  [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/privkey.pem" ] || { echo "⚠️ Cert incompleto em $CERT_DIR"; return 0; }

  if ! grep -q "listener SSL" "$HTTPD_CONF"; then
    echo "🧩 Criando listener SSL no OpenLiteSpeed..."
    cat >> "$HTTPD_CONF" <<EOF

listener SSL {
  address                 *:443
  secure                  1
  keyFile                 /etc/letsencrypt/live/reusclub.com.br/privkey.pem
  certFile                /etc/letsencrypt/live/reusclub.com.br/fullchain.pem
}

listener SSLmap {
  address                 *:443
  secure                  1
  map                     wordpress reusclub.com.br
  map                     wordpress www.reusclub.com.br
}

EOF
    /usr/local/lsws/bin/lswsctrl reload || true
  else
    echo "🔁 Listener SSL já existe; garantindo paths atualizados..."
    sed -i "s|keyFile.*|keyFile                 ${CERT_DIR}/privkey.pem|g" "$HTTPD_CONF"
    sed -i "s|certFile.*|certFile               ${CERT_DIR}/fullchain.pem|g" "$HTTPD_CONF"
    /usr/local/lsws/bin/lswsctrl reload || true
  fi
}

watch_certs_and_reload() {
  local CERT="${DOMAIN:-example.com}"
  local CERT_FILE="/etc/letsencrypt/live/${CERT}/fullchain.pem"
  local LAST_MTIME=""

  while :; do
    if [ -f "$CERT_FILE" ]; then
      configure_ssl_listener
      MTIME=$(stat -c %Y "$CERT_FILE" 2>/dev/null || echo "")
      if [ -n "$MTIME" ] && [ "$MTIME" != "$LAST_MTIME" ]; then
        echo "🔔 Detectada alteração no certificado (${CERT}); recarregando OLS..."
        /usr/local/lsws/bin/lswsctrl reload || true
        LAST_MTIME="$MTIME"
      fi
    fi
    sleep 600  # verifica a cada 10 minutos
  done
}

bootstrap_wordpress() {
  local WP_PATH="$1"

  echo "📥 Baixando WordPress (primeira execução)..."
  curl -fSL -o /tmp/latest.tar.gz https://pt-br.wordpress.org/latest-pt_BR.tar.gz
  tar -xzf /tmp/latest.tar.gz -C /tmp
  rsync -a /tmp/wordpress/ "$WP_PATH/"
  rm -rf /tmp/wordpress /tmp/latest.tar.gz

  echo "⚙️ Gerando wp-config.php..."
  wp config create \
    --path="$WP_PATH" \
    --dbname="$WORDPRESS_DB_NAME" \
    --dbuser="$WORDPRESS_DB_USER" \
    --dbpass="$WORDPRESS_DB_PASSWORD" \
    --dbhost="$WORDPRESS_DB_HOST" \
    --dbprefix="$WORDPRESS_TABLE_PREFIX" \
    --skip-check \
    --allow-root

  echo "🛠 Instalando WordPress..."
  wp core install \
    --path="$WP_PATH" \
    --url="${URL_SITE:-http://localhost:8080}" \
    --title="Maestro Ecommerce" \
    --admin_user="$WORDPRESS_ADMIN_USER" \
    --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
    --admin_email="$WORDPRESS_ADMIN_EMAIL" \
    --skip-email \
    --allow-root

  apply_config_extras "$WP_PATH"
  add_dynamic_urls_block "$WP_PATH"

  echo "🌐 Convertendo para Multisite..."
  wp core multisite-convert \
    --title="${NETWORK_TITLE:-Maestro Ecommerce Network}" \
    $( [ "${SUBDOMAIN_INSTALL:-true}" = "true" ] && echo --subdomains ) \
    --allow-root --path="$WP_PATH" || true

  # 🔐 garante os defines no wp-config.php
  wp config set MULTISITE true --raw --path="$WP_PATH" --allow-root
  wp config set SUBDOMAIN_INSTALL ${SUBDOMAIN_INSTALL:-true} --raw --path="$WP_PATH" --allow-root
  wp config set DOMAIN_CURRENT_SITE "${DOMAIN_CURRENT_SITE:-$(wp option get siteurl --allow-root --path="$WP_PATH" | sed -E 's#^https?://##')}" --path="$WP_PATH" --allow-root
  wp config set PATH_CURRENT_SITE "/" --path="$WP_PATH" --allow-root
  wp config set SITE_ID_CURRENT_SITE 1 --raw --path="$WP_PATH" --allow-root
  wp config set BLOG_ID_CURRENT_SITE 1 --raw --path="$WP_PATH" --allow-root

  ensure_htaccess "$WP_PATH"
}

# ========== Execução ==========
if [ "$WORDPRESS_DB_HOST" != "rds-endpoint" ]; then
  wait_for_db
fi

WP_PATH="/var/www/vhosts/localhost/html"

if wp core is-installed --path="$WP_PATH" --allow-root 2>/dev/null; then
  echo "✅ WordPress já instalado. Pulando bootstrap; aplicando apenas ajustes..."
  [ -f "$WP_PATH/wp-config.php" ] || {
    echo "⚠️ wp-config.php ausente. Gerando com credenciais básicas..."
    wp config create \
      --path="$WP_PATH" \
      --dbname="$WORDPRESS_DB_NAME" \
      --dbuser="$WORDPRESS_DB_USER" \
      --dbpass="$WORDPRESS_DB_PASSWORD" \
      --dbhost="$WORDPRESS_DB_HOST" \
      --dbprefix="$WORDPRESS_TABLE_PREFIX" \
      --skip-check \
      --allow-root
  }
  apply_config_extras "$WP_PATH"
  add_dynamic_urls_block "$WP_PATH"
  ensure_htaccess "$WP_PATH"
  ensure_multisite "$WP_PATH"   # <- NOVO: garante tabelas da rede
else
  if [ ! -f "$WP_PATH/wp-config.php" ]; then
    bootstrap_wordpress "$WP_PATH"
  else
    echo "⚠️ wp-config.php existe, mas WP não está instalado. Instalando e aplicando extras..."
    wp core install \
      --path="$WP_PATH" \
      --url="${URL_SITE:-http://localhost:8080}" \
      --title="Maestro Ecommerce" \
      --admin_user="$WORDPRESS_ADMIN_USER" \
      --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
      --admin_email="$WORDPRESS_ADMIN_EMAIL" \
      --skip-email \
      --allow-root
    apply_config_extras "$WP_PATH"
    add_dynamic_urls_block "$WP_PATH"
    ensure_htaccess "$WP_PATH"
    ensure_multisite "$WP_PATH"
  fi
fi

# Ajustes de PHP (ini)
echo "⚙️ Forçando alterações diretamente no php.ini (lsphp82)..."
PHP_INI="/usr/local/lsws/lsphp82/etc/php/8.2/litespeed/php.ini"
update_or_append() { local key="$1"; local value="$2";
  if grep -q "^$key" "$PHP_INI" 2>/dev/null; then
    echo "🔁 Atualizando $key..."; sed -i "s|^$key.*|$key = $value|" "$PHP_INI"
  else
    echo "➕ Adicionando $key..."; echo "$key = $value" >> "$PHP_INI"
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

# Redis plugin
wait_for_redis
echo "⚡ Instalando/ativando Redis Cache (idempotente)..."
rm -f "$WP_PATH/wp-content/object-cache.php" || true
wp plugin install redis-cache --activate --allow-root --path="$WP_PATH" || true
wp redis enable --allow-root --path="$WP_PATH" --url="${URL_SITE:-http://localhost:8080}" --force || true
wp redis update-dropin --allow-root --path="$WP_PATH" || true

# Permissões
chown -R nobody:nogroup "$WP_PATH" || true
chmod -R 775 "$WP_PATH/wp-content" || true
mkdir -p "$WP_PATH/wp-content/uploads" && chown -R nobody:nogroup "$WP_PATH/wp-content/uploads" && chmod -R 775 "$WP_PATH/wp-content/uploads"

/usr/local/lsws/bin/lswsctrl start
tail -f /usr/local/lsws/logs/error.log
