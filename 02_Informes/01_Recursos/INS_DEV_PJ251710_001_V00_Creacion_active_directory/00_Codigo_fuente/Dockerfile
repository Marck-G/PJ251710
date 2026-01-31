# syntax=docker/dockerfile:1
FROM debian:bookworm

LABEL maintainer="YourName <you@example.com>"
ENV DEBIAN_FRONTEND=noninteractive

# --- Install dependencies ---
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        samba \
        samba-dsdb-modules \
        samba-vfs-modules \
        samba-ad-provision \
        winbind \
        krb5-config \
        dnsutils \
        ldap-utils \
        smbclient \
        openssl \
        supervisor && \
    rm -rf /var/lib/apt/lists/*

# --- Create directories ---
RUN mkdir -p /var/lib/samba /etc/samba /var/log/samba /var/cache/samba && \
    chmod -R 755 /var/lib/samba /etc/samba /var/log/samba /var/cache/samba
RUN mkdir -p /var/lib/samba /etc/samba /var/log/samba 
RUN chown -R root:root /var/lib/samba /etc/samba /var/log/samba 
RUN chmod -R 755 /var/lib/samba /etc/samba /var/log/samba
# --- Add entrypoint ---
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN rm -f /etc/samba/smb.conf
EXPOSE 53/udp 53/tcp 88 135 137/udp 138/udp 139 389 445 464 636 3268 3269
VOLUME ["/etc/samba", "/var/lib/samba", "/var/log/samba"]

ENTRYPOINT ["/entrypoint.sh"]
