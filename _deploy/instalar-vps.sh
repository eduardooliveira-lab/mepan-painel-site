#!/usr/bin/env bash
# Instala o painel MEPAN numa VPS Debian/Ubuntu (rodar UMA vez, como root).
#   curl -fsSL https://raw.githubusercontent.com/eduardooliveira-lab/mepan-painel-site/main/_deploy/instalar-vps.sh | sudo bash
# O que faz: nginx + HTTPS (Let's Encrypt), site em /var/www/mepan clonado do repositório
# público de build, e atualização automática a cada 2 minutos (git pull).
set -euo pipefail
DOMINIO="${DOMINIO:-mepan.metrixinsigths.com}"
EMAIL="${EMAIL:-eduardo.oliveira@metrixconsultoria.com}"
DIR=/var/www/mepan
REPO=https://github.com/eduardooliveira-lab/mepan-painel-site.git

[ "$(id -u)" = 0 ] || { echo "Rode como root (sudo bash)."; exit 1; }

echo "==> Pacotes"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot python3-certbot-nginx git dnsutils curl cron >/dev/null
systemctl enable --now cron >/dev/null 2>&1 || true

echo "==> Site em $DIR"
mkdir -p /var/www
if [ -d "$DIR/.git" ]; then
  sudo -u www-data git -C "$DIR" pull -q --ff-only
else
  rm -rf "$DIR"
  git clone -q "$REPO" "$DIR"
  chown -R www-data:www-data "$DIR"
fi

echo "==> Atualização automática (a cada 2 min)"
cat > /etc/cron.d/mepan-painel <<EOF
*/2 * * * * www-data cd $DIR && git pull -q --ff-only >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/mepan-painel

echo "==> nginx"
cat > /etc/nginx/sites-available/mepan <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMINIO__;
    root __DIR__;
    index index.html;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    location ~ /(\.git|_deploy|\.htaccess|_redirects) { return 404; }

    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files $uri =404;
    }

    location / {
        add_header Cache-Control "no-cache";
        try_files $uri $uri/ /index.html;
    }
}
NGINX
sed -i "s#__DOMINIO__#$DOMINIO#; s#__DIR__#$DIR#" /etc/nginx/sites-available/mepan
ln -sf /etc/nginx/sites-available/mepan /etc/nginx/sites-enabled/mepan
nginx -t
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 'Nginx Full' >/dev/null
fi

echo "==> HTTPS"
IP=$(curl -fsS4 --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
DNS=$(dig +short "$DOMINIO" A | tail -1)
if [ "$DNS" = "$IP" ]; then
  certbot --nginx -d "$DOMINIO" -m "$EMAIL" --agree-tos --no-eff-email --redirect -n
  echo "PRONTO: https://$DOMINIO"
else
  echo "ATENÇÃO: o DNS de $DOMINIO aponta para '${DNS:-nada}', e este servidor é $IP."
  echo "Crie o registro A  mepan -> $IP  no GoDaddy e rode depois:"
  echo "  sudo certbot --nginx -d $DOMINIO -m $EMAIL --agree-tos --no-eff-email --redirect -n"
  echo "Enquanto isso o site já responde em http://$IP (sem HTTPS)."
fi
