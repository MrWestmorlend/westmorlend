#!/bin/bash

# === Настройки ===
DOMAIN="youskillmind.pro"  # Замените на ваш домен, например skillmind.pro
EMAIL="admin@skillmind.pro"
WORDPRESS_DB="wordpress"
WORDPRESS_USER="wpuser"
WORDPRESS_PASS=$(openssl rand -base64 12)
MYSQL_ROOT_PASS=$(openssl rand -base64 12)

# === Обновление системы ===
echo "🔄 Обновление пакетов..."
apt update && apt upgrade -y

# === Установка необходимых пакетов ===
echo "📦 Установка зависимостей..."
apt install -y nginx mysql-server php php-cli php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-bcmath php-intl redis-server php-redis certbot python3-certbot-nginx ufw git curl zip unzip

# === Настройка MySQL ===
echo "🔐 Настройка MySQL..."
service mysql start
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASS';"
mysql -e "FLUSH PRIVILEGES;"
mysql -u root -p$MYSQL_ROOT_PASS -e "CREATE DATABASE $WORDPRESS_DB; CREATE USER '$WORDPRESS_USER'@'localhost' IDENTIFIED BY '$WORDPRESS_PASS'; GRANT ALL PRIVILEGES ON $WORDPRESS_DB.* TO '$WORDPRESS_USER'@'localhost'; FLUSH PRIVILEGES;"

# === Установка WordPress ===
echo "🌐 Установка WordPress..."
cd /tmp
wget https://wordpress.org/latest.tar.gz 
tar -xzvf latest.tar.gz
cp -R wordpress /var/www/$DOMAIN
chown -R www-data:www-data /var/www/$DOMAIN
chmod -R 755 /var/www
mkdir -p /var/www/$DOMAIN/wp-content/uploads

# === Конфиг wp-config.php ===
echo "⚙️ Настройка wp-config.php..."
cp /var/www/$DOMAIN/wp-config-sample.php /var/www/$DOMAIN/wp-config.php
sed -i "s/database_name_here/$WORDPRESS_DB/" /var/www/$DOMAIN/wp-config.php
sed -i "s/username_here/$WORDPRESS_USER/" /var/www/$DOMAIN/wp-config.php
sed -i "s/password_here/$WORDPRESS_PASS/" /var/www/$DOMAIN/wp-config.php
SECRET_KEY=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ )
echo "$SECRET_KEY" > /tmp/salt.tmp
sed -i '/AUTH_KEY/d' /var/www/$DOMAIN/wp-config.php
sed -i '/SECURE_AUTH_KEY/d' /var/www/$DOMAIN/wp-config.php
sed -i '/LOGGED_IN_KEY/d' /var/www/$DOMAIN/wp-config.php
sed -i '/NONCE_KEY/d' /var/www/$DOMAIN/wp-config.php
sed -i '/AUTH_SALT/d' /var/www/$DOMAIN/wp-config.php
sed -i '/SECURE_AUTH_SALT/d' /var/www/$DOMAIN/wp-config.php
sed -i '/LOGGED_IN_SALT/d' /var/www/$DOMAIN/wp-config.php
sed -i '/NONCE_SALT/d' /var/www/$DOMAIN/wp-config.php
cat /tmp/salt.tmp >> /var/www/$DOMAIN/wp-config.php
rm /tmp/salt.tmp

# === Добавляем опции WP_HOME и WP_SITEURL ===
echo "define('WP_HOME','https://$DOMAIN');" >> /var/www/$DOMAIN/wp-config.php
echo "define('WP_SITEURL','https://$DOMAIN');" >> /var/www/$DOMAIN/wp-config.php

# === Увеличиваем лимиты PHP для админки и курсов ===
echo "🔧 Увеличение лимитов PHP..."
sudo sed -i "s/memory_limit = .*/memory_limit = 256M/" /etc/php/8.1/fpm/php.ini
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/" /etc/php/8.1/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 128M/" /etc/php/8.1/fpm/php.ini
sudo sed -i "s/max_execution_time = .*/max_execution_time = 300/" /etc/php/8.1/fpm/php.ini
sudo sed -i "s/max_input_vars = .*/max_input_vars = 5000/" /etc/php/8.1/fpm/php.ini

# === Включаем OPcache ===
echo "🔧 Включение OPcache..."
phpenmod opcache
systemctl restart php8.1-fpm

# === Конфиг Nginx с gzip и безопасностью ===
echo "⚙️ Настройка Nginx..."
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/$DOMAIN;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    # GZIP
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_vary on;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' https: data:; script-src 'self' https://$DOMAIN https://*.google.com https://*.gstatic.com 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:;" always;
}
EOF

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# === Установка Let's Encrypt SSL ===
echo "🔒 Получение SSL-сертификата..."
ufw allow 'Nginx Full'
ufw delete allow 'Nginx HTTP'
certbot --nginx -d $DOMAIN --noninteractive --agree-tos -m $EMAIL --redirect

# === Автоматическое обновление сертификатов ===
echo "⚙️ Настройка автообновления Let's Encrypt..."
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/bin/certbot renew --quiet") | crontab -

# === Открытие портов брандмауэра ===
echo "🔓 Настройка UFW..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw enable

# === Информация о логинах ===
echo "✅ Установка завершена!"
echo "WordPress URL: https://$DOMAIN"
echo "MySQL root пароль: $MYSQL_ROOT_PASS"
echo "WordPress DB user: $WORDPRESS_USER"
echo "WordPress DB pass: $WORDPRESS_PASS"

# === Установка WP CLI для автоматической настройки плагинов ===
echo "🔧 Установка WP CLI..."
cd /tmp
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# === Перейдём в директорию сайта ===
cd /var/www/$DOMAIN

# === Установим WP Mail SMTP через WP CLI ===
echo "📧 Установка WP Mail SMTP..."
wp plugin install wp-mail-smtp --activate --allow-root

# === Пример настройки WP Mail SMTP через Gmail SMTP ===
cat > /tmp/wp-mail-smtp-config.php <<EOF
<?php
/**
 * WP Mail SMTP Configuration File
 */
if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

return array(
    'from_email' => 'support@skillmind.pro',
    'from_name'  => 'SkillMind.Pro',
    'mailer'     => 'smtp',
    'options'    => array(
        'smtp' => array(
            'host'     => 'smtp.gmail.com',
            'port'     => '465',
            'auth'     => true,
            'user'     => 'v89892297849@gmail.com',
            'pass'     => 'urbn vhhd dagb rweb',
            'secure'   => 'ssl',
            'autotls'  => false,
        ),
    ),
);
EOF

# === Копируем конфиг в wp-content ===
cp /tmp/wp-mail-smtp-config.php /var/www/$DOMAIN/wp-content/

# === Чистим временные файлы ===
rm /tmp/wp-mail-smtp-config.php

echo "ℹ️ Не забудьте:"
echo "1. Заменить значения в /var/www/$DOMAIN/wp-content/wp-mail-smtp-config.php"
echo "   - your-gmail@gmail.com"
echo "   - your-app-password"
echo "2. Использовать App Password от Gmail, а не обычный пароль"

# === Установка Redis Object Cache ===
echo "🔌 Настройка Redis для кэширования..."
wp plugin install redis-cache --activate --allow-root
wp redis enable --allow-root

# === Установка W3 Total Cache (или можно использовать WP Rocket) ===
echo "📦 Установка W3 Total Cache..."
wp plugin install w3-total-cache --activate --allow-root

# === Готово!
echo "🏁 Скрипт успешно выполнен!"
echo "👉 Теперь зайдите на https://$DOMAIN и завершите настройку WordPress."
echo "👉 Активируйте плагины и настройте W3 Total Cache и WP Mail SMTP."