# =============================================================================
# Dockerfile — AgFarm (Multi-stage build)
#
# Stage 1 — node-builder : npm ci + npm run build  → public/build/
# Stage 2 — php-app      : Composer + source code  → image App (PHP-FPM :9000)
# Stage 3 — nginx-web    : Nginx + public/         → image Nginx (:80)
#
# Build dua image dari satu Dockerfile menggunakan --target:
#   docker build --target php-app   -t ghcr.io/<USER>/agfarm-app:<TAG>  .
#   docker build --target nginx-web -t ghcr.io/<USER>/agfarm-web:<TAG>  .
# =============================================================================


# =============================================================================
# Stage 1 — node-builder
# Membangun asset frontend (Vite) untuk disalin ke stage berikutnya.
# =============================================================================
FROM node:20-alpine AS node-builder

WORKDIR /app

# Salin manifest npm terlebih dahulu agar layer Composer dapat di-cache
COPY package.json package-lock.json* ./
RUN npm ci

# Salin file yang dibutuhkan Vite untuk build
COPY vite.config.js ./
COPY resources/ resources/
COPY public/     public/

RUN npm run build
# Hasil: public/build/ berisi manifest Vite + asset ter-bundle


# =============================================================================
# Stage 2 — php-app
# Image aplikasi Laravel dengan PHP-FPM.
# =============================================================================
FROM php:8.3-fpm-bookworm AS php-app

# ── Ekstensi PHP yang dibutuhkan AgFarm ──────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        libonig-dev \
        libzip-dev \
        libicu-dev \
        libxml2-dev \
        unzip \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        bcmath \
        zip \
        intl \
        opcache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Konfigurasi OPcache untuk production ─────────────────────────────────────
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=10000'; \
    echo 'opcache.revalidate_freq=0'; \
    echo 'opcache.validate_timestamps=0'; \
} > /usr/local/etc/php/conf.d/opcache-agfarm.ini

# ── Composer ─────────────────────────────────────────────────────────────────
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# ── Install PHP dependencies (layer terpisah agar Docker dapat meng-cache) ───
# Salin manifest Composer lebih dulu; layer ini hanya di-rebuild jika
# composer.json atau composer.lock berubah.
COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-scripts \
    --optimize-autoloader \
    --prefer-dist
    
# ── Salin seluruh source code aplikasi ───────────────────────────────────────
COPY . .

# ── Salin hasil build Vite dari stage node-builder ───────────────────────────
COPY --from=node-builder /app/public/build ./public/build

# ── Laravel Package Discovery ────────────────────────────────────────────────
RUN rm -f bootstrap/cache/*.php \
    && php artisan package:discover --ansi

# ── Permission ───────────────────────────────────────────────────────────────
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 9000

CMD ["php-fpm"]


# =============================================================================
# Stage 3 — nginx-web
# Image Nginx yang melayani request HTTP dan meneruskan PHP ke php-app.
# =============================================================================
FROM nginx:stable-alpine AS nginx-web

# Hapus konfigurasi default Nginx
RUN rm /etc/nginx/conf.d/default.conf

# Salin konfigurasi virtual host AgFarm
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

# Salin direktori public dari stage php-app
# (termasuk public/build/ hasil Vite yang sudah di-copy ke php-app)
COPY --from=php-app /var/www/html/public /var/www/html/public

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

