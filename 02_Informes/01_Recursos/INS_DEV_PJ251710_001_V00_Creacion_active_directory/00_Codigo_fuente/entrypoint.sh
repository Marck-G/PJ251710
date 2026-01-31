#!/bin/bash
set -e

DOMAIN=${DOMAIN:-example.local}
REALM=${REALM:-EXAMPLE.LOCAL}
ADMIN_PASS=${ADMIN_PASS:-Passw0rd!}
HOSTNAME=${HOSTNAME:-ad}
DEBUG=${DEBUG:-0}

if [ "$DEBUG" -eq 1 ]; then
    set -x
    echo "Debug mode is ON. Sleeping indefinitely..."
    while true; do sleep 1000; done
fi
# Ensure correct permissions
mkdir -p /var/lib/samba /etc/samba /var/log/samba
chown -R root:root /var/lib/samba /etc/samba /var/log/samba
chmod -R 750 /var/lib/samba /etc/samba /var/log/samba

# If not yet provisioned, set up AD
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    echo "Provisioning new Samba AD domain: ${REALM}"
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="${REALM}" \
        --domain="${DOMAIN%%.*}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="${ADMIN_PASS}" \
        --option="tls enabled = no" \
        --option="tls keyfile = /var/lib/samba/private/tls/key.pem" \
        --option="tls certfile = /var/lib/samba/private/tls/cert.pem" \
        --option="tls cafile = /var/lib/samba/private/tls/ca.pem" \
        --option="idmap_ldb:use rfc2307 = yes" \
        --option="winbind nss info = rfc2307" \
        --option="winbind enum users = yes" \
        --option= "vfs objects = dfs_samba4" 
fi

# Ensure TLS directory exists and certs are valid
mkdir -p /var/lib/samba/private/tls
chmod 600 /var/lib/samba/private/tls
if [ ! -f /var/lib/samba/private/tls/cert.pem ]; then
    echo "Generating self-signed TLS certificates..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /var/lib/samba/private/tls/key.pem \
        -out /var/lib/samba/private/tls/cert.pem \
        -days 3650 -subj "/CN=${HOSTNAME}.${DOMAIN}"
    cp /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem
fi

echo "Starting Samba Active Directory Domain Controller..."
exec samba -i --debug-stdout --no-process-group
