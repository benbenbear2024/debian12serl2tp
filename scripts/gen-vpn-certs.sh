#!/bin/bash
set -euo pipefail

SWANCTL="${SWANCTL_ETC:-/etc/swanctl}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

ID="${VPN_SERVER_ID:?请设置 VPN_SERVER_ID}"
IP="${VPN_SERVER_IP:-}"

san="DNS:${ID}"
if [[ -n "${IP}" ]]; then
  san="${san},IP:${IP}"
elif [[ "${ID}" =~ ^[0-9.]+$ ]]; then
  san="IP:${ID}"
fi

echo "生成 CA 证书..."
openssl genrsa -out "${TMP}/ca-key.pem" 4096
openssl req -x509 -new -nodes -key "${TMP}/ca-key.pem" -sha256 -days 3650 \
  -subj "/CN=VPN IKEv2 CA" -out "${TMP}/ca-cert.pem"

echo "生成服务器证书..."
openssl genrsa -out "${TMP}/vpn-server-key.pem" 4096
openssl req -new -key "${TMP}/vpn-server-key.pem" -out "${TMP}/server.csr" -subj "/CN=${ID}"

printf "subjectAltName=%s\n" "${san}" > "${TMP}/ext.cnf"
openssl x509 -req -in "${TMP}/server.csr" \
  -CA "${TMP}/ca-cert.pem" -CAkey "${TMP}/ca-key.pem" -CAcreateserial \
  -out "${TMP}/vpn-server-cert.pem" -days 825 -sha256 -extfile "${TMP}/ext.cnf"

echo "安装证书..."
install -d -m 0755 "${SWANCTL}/private" "${SWANCTL}/x509" "${SWANCTL}/x509ca"
install -m 0600 "${TMP}/vpn-server-key.pem" "${SWANCTL}/private/vpn-server-key.pem"
install -m 0644 "${TMP}/vpn-server-cert.pem" "${SWANCTL}/x509/vpn-server-cert.pem"
install -m 0644 "${TMP}/ca-cert.pem" "${SWANCTL}/x509ca/vpn-ca-cert.pem"

OUT_DIR="${VPN_CERT_EXPORT:-/root/vpn-ikev2-certs}"
install -d -m 0700 "${OUT_DIR}"
cp -f "${TMP}/ca-cert.pem" "${OUT_DIR}/ca-cert.pem"
chmod 0644 "${OUT_DIR}/ca-cert.pem"

echo "证书已安装到 ${SWANCTL}"
echo "CA 证书已导出到 ${OUT_DIR}/ca-cert.pem"
