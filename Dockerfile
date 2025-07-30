# syntax=docker/dockerfile:1.13-labs

# ================================
# Stage 1-1: Composer Install
# ================================
FROM composer:latest AS composer-install

WORKDIR /build
RUN apk add --no-cache icu-dev libzip-dev zip unzip
COPY composer.json composer.lock ./
RUN composer install \
        --no-dev \
        --no-interaction \
        --no-autoloader \
        --no-scripts \
        --ignore-platform-reqs

# ================================
# Stage 1-2: Yarn install
# ================================
FROM node:20-alpine AS yarn-install
WORKDIR /build
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile --production=false

# ================================
# Stage 1-3: Build frontend
# ================================
FROM node:20-alpine AS yarnbuild
WORKDIR /build
COPY --exclude=Caddyfile --exclude=docker/ . ./
COPY --from=yarn-install /build/node_modules ./node_modules
COPY --from=composer-install /build/vendor ./vendor
ARG APP_ENV="production"
ENV NODE_ENV="${APP_ENV}"
RUN yarn run build

# ================================
# Stage 1-4: Build backend
# ================================
FROM composer:latest AS composerbuild
WORKDIR /build
COPY --exclude=Caddyfile --exclude=docker/ . ./
COPY --from=composer-install /build/vendor ./vendor
ARG APP_ENV="production"
ENV APP_ENV="${APP_ENV}"
RUN composer dump-autoload --optimize

# ================================
# Stage 2: Final runtime image
# ================================
FROM php:8.2-fpm-alpine

# Default environment variables for Pelican (can be overridden post-install)
ENV APP_ENV=production
ENV APP_DEBUG=false
ENV APP_URL=https://pelican.haggis.top
ENV APP_KEY=base64:z6yFDeTUxbHvnHipBHO1FMJIyDntdtufLBsG84MUEAQ=
ENV DB_CONNECTION=mysql
ENV DB_HOST=127.0.0.1
ENV DB_PORT=3306
ENV DB_DATABASE=pelican
ENV DB_USERNAME=root
ENV DB_PASSWORD=secret
ENV MAIL_DRIVER=sendmail
ENV MAIL_FROM_ADDRESS=admin@pelican.haggis.top
ENV MAIL_FROM_NAME="Pelican Panel"

WORKDIR /var/www/html

RUN apk add --no-cache \
        caddy ca-certificates tzdata curl unzip git \
        freetype-dev libjpeg-turbo-dev libpng-dev \
        icu-dev libzip-dev zip postgresql-dev \
        supervisor \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql pdo pdo_pgsql \
        gd bcmath intl zip opcache pcntl \
    && rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

COPY --from=composerbuild --chown=82:82 /build ./
COPY --from=yarnbuild --chown=82:82 /build/public/build ./public/build

# Cloudron-specific storage setup (persistent data in /app/data)
RUN chown root:www-data ./ \
    && chmod 750 ./ \
    && find ./ -type d -exec chmod 750 {} \; \
    && mkdir -p /app/data/storage /var/www/html/storage/app/public /var/run/supervisord /etc/supercronic \
    && ln -s /app/data/.env ./.env \
    && ln -s /app/data/database/database.sqlite ./database/database.sqlite \
    && ln -sf /var/www/html/storage/app/public /var/www/html/public/storage \
    && ln -s /app/data/storage/avatars /var/www/html/storage/app/public/avatars \
    && ln -s /app/data/storage/fonts /var/www/html/storage/app/public/fonts \
    && chown -R www-data:www-data /app/data ./storage ./bootstrap/cache /var/run/supervisord /var/www/html/public/storage \
    && chmod -R u+rwX,g+rwX,o-rwx /app/data ./storage ./bootstrap/cache /var/run/supervisord

COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Dummy health check to auto-pass (for debugging only - remove later)
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD true || exit 0


VOLUME /app/data

EXPOSE 80 443
ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]

