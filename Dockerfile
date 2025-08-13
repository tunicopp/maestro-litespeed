FROM litespeedtech/openlitespeed:1.8.4-lsphp82

# Variáveis de ambiente
ENV WP_PATH=/var/www/vhosts/localhost/html

# Atualiza pacotes e instala dependências adicionais
RUN apt-get update && apt-get install -y \
    mariadb-client redis-tools unzip curl less rsync wget apache2-utils \
    && rm -rf /var/lib/apt/lists/*

# Instala WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# Baixa WooCommerce para instalação posterior
RUN mkdir -p /tmp/plugins \
    && curl -L -o /tmp/plugins/woocommerce.zip https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip \
    && unzip /tmp/plugins/woocommerce.zip -d /tmp/plugins/ \
    && rm /tmp/plugins/woocommerce.zip

# Cria diretório do WordPress
RUN mkdir -p $WP_PATH && chown -R nobody:nogroup /var/www/vhosts/localhost

# Copia entrypoint customizado
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR $WP_PATH

ENTRYPOINT ["/entrypoint.sh"]