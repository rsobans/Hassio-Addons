#!/bin/bash

set -e

# set environment variables
export TZ
TZ="${TZ:-Etc/UTC}"
SMALL_FILES="${SMALL_FILES:-false}"
MANAGE_HTTP_PORT="${MANAGE_HTTP_PORT:-8088}"
MANAGE_HTTPS_PORT="${MANAGE_HTTPS_PORT:-8043}"
PORTAL_HTTP_PORT="${PORTAL_HTTP_PORT:-8088}"
PORTAL_HTTPS_PORT="${PORTAL_HTTPS_PORT:-8843}"
SHOW_SERVER_LOGS="${SHOW_SERVER_LOGS:-true}"
SHOW_MONGODB_LOGS="${SHOW_MONGODB_LOGS:-false}"
SSL_CERT_NAME="${SSL_CERT_NAME:-tls.crt}"
SSL_KEY_NAME="${SSL_KEY_NAME:-tls.key}"
TLS_1_11_ENABLED="${TLS_1_11_ENABLED:-false}"
PUID="${PUID:-508}"
PGID="${PGID:-508}"

# validate user/group exist with correct UID/GID
echo "INFO: Validating user/group (omada:omada) exists with correct UID/GID (${PUID}:${PGID})"

# check to see if group exists; if not, create it
if grep -q -E "^omada:" /etc/group > /dev/null 2>&1
then
  # exiting group found; also make sure the omada user matches the GID
  echo "INFO: Group (omada) exists; skipping creation"
  EXISTING_GID="$(id -g omada)"
  if [ "${EXISTING_GID}" != "${PGID}" ]
  then
    echo "ERROR: Group (omada) has an unexpected GID; was expecting '${PGID}' but found '${EXISTING_GID}'!"
    exit 1
  fi
else
  # make sure the group doesn't already exist with a different name
  if awk -F ':' '{print $3}' /etc/group | grep -q "^${PGID}$"
  then
    # group ID exists but has a different group name
    EXISTING_GROUP="$(grep ":${PGID}:" /etc/group | awk -F ':' '{print $1}')"
    echo "INFO: Group (omada) already exists with a different name; renaming '${EXISTING_GROUP}' to 'omada'"
    groupmod -n omada "${EXISTING_GROUP}"
  else
    # create the group
    echo "INFO: Group (omada) doesn't exist; creating"
    groupadd -g "${PGID}" omada
  fi
fi

# check to see if user exists; if not, create it
if id -u omada > /dev/null 2>&1
then
  # exiting user found; also make sure the omada user matches the UID
  echo "INFO: User (omada) exists; skipping creation"
  EXISTING_UID="$(id -u omada)"
  if [ "${EXISTING_UID}" != "${PUID}" ]
  then
    echo "ERROR: User (omada) has an unexpected UID; was expecting '${PUID}' but found '${EXISTING_UID}'!"
    exit 1
  fi
else
  # make sure the user doesn't already exist with a different name
  if awk -F ':' '{print $3}' /etc/passwd | grep -q "^${PUID}$"
  then
    # user ID exists but has a different user name
    EXISTING_USER="$(grep ":${PUID}:" /etc/passwd | awk -F ':' '{print $1}')"
    echo "INFO: User (omada) already exists with a different name; renaming '${EXISTING_USER}' to 'omada'"
    usermod -g "${PGID}" -d /data/EAPController/data -l omada -s /bin/sh -c "" "${EXISTING_USER}"
  else
    # create the user
    echo "INFO: User (omada) doesn't exist; creating"
    useradd -u "${PUID}" -g "${PGID}" -d /data/EAPController/data -s /bin/sh -c "" omada
  fi
fi

# set default time zone and notify user of time zone
echo "INFO: Time zone set to '${TZ}'"

# append smallfiles if set to true
if [ "${SMALL_FILES}" = "true" ]
then
  echo "WARN: smallfiles was passed but is not supported in >= 4.1 with the WiredTiger engine in use by MongoDB"
  echo "INFO: Skipping setting smallfiles option"
fi


  chown -R omada:omada /data/EAPController/properties/omada.properties


set_port_property() {
  # check to see if we are trying to bind to privileged port
  if [ "${3}" -lt "1024" ] && [ "$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)" = "1024" ]
  then
    echo "ERROR: Unable to set '${1}' to ${3}; 'ip_unprivileged_port_start' has not been set.  See https://github.com/mbentley/docker-omada-controller#unprivileged-ports"
    exit 1
  fi

  echo "INFO: Setting '${1}' to ${3} in omada.properties"
  sed -i "s/^${1}=${2}$/${1}=${3}/g" /opt/tplink/EAPController/properties/omada.properties
}

# replace MANAGE_HTTP_PORT if not the default
if [ "${MANAGE_HTTP_PORT}" != "8088" ]
then
  set_port_property manage.http.port 8088 "${MANAGE_HTTP_PORT}"
fi

# replace MANAGE_HTTPS_PORT if not the default
if [ "${MANAGE_HTTPS_PORT}" != "8043" ]
then
  set_port_property manage.https.port 8043 "${MANAGE_HTTPS_PORT}"
fi

# replace PORTAL_HTTP_PORT if not the default
if [ "${PORTAL_HTTP_PORT}" != "8088" ]
then
  set_port_property portal.http.port 8088 "${PORTAL_HTTP_PORT}"
fi

# replace PORTAL_HTTPS_PORT if not the default
if [ "${PORTAL_HTTPS_PORT}" != "8843" ]
then
  set_port_property portal.https.port 8843 "${PORTAL_HTTPS_PORT}"
fi

mkdir -p /data/EAPController/data
mkdir -p /data/EAPController/logs
mkdir -p /data/EAPController/data/db
chown -R omada:omada /data
chown -R omada:omada /opt/tplink/EAPController/data/keystore

# make sure that the html directory exists
if [ ! -d "/data/EAPController/data/html" ] && [ -f "/data/EAPController/data-html.tar.gz" ]
then
  # missing directory; extract from original
  echo "INFO: Report HTML directory missing; extracting backup to '/data/EAPController/data/html'"
  tar zxvf /data/EAPController/data-html.tar.gz -C /data/EAPController/data
  chown -R omada:omada /data/EAPController/data/html
fi

# make sure that the pdf directory exists
if [ ! -d "/data/EAPController/data/pdf" ]
then
  # missing directory; extract from original
  echo "INFO: Report PDF directory missing; creating '/data/EAPController/data/pdf'"
  mkdir /data/EAPController/data/pdf
  chown -R omada:omada /data/EAPController/data/pdf
fi

# make sure permissions are set appropriately on each directory
for DIR in data logs
do
  OWNER="$(stat -c '%u' /data/EAPController/${DIR})"
  GROUP="$(stat -c '%g' /data/EAPController/${DIR})"

  if [ "${OWNER}" != "${PUID}" ] || [ "${GROUP}" != "${PGID}" ]
  then
    # notify user that uid:gid are not correct and fix them
    echo "WARN: Ownership not set correctly on '/data/EAPController/${DIR}'; setting correct ownership (omada:omada)"
    chown -R omada:omada "/data/EAPController/${DIR}"
  fi
done

# validate permissions on /tmp
TMP_PERMISSIONS="$(stat -c '%a' /tmp)"
if [ "${TMP_PERMISSIONS}" != "1777" ]
then
  echo "WARN: Permissions are not set correctly on '/tmp' (${TMP_PERMISSIONS}); setting correct permissions (1777)"
  chmod -v 1777 /tmp
fi

# check to see if there is a db directory; create it if it is missing
if [ ! -d "/data/EAPController/data/db" ]
then
  echo "INFO: Database directory missing; creating '/data/EAPController/data/db'"
  mkdir /data/EAPController/data/db
  chown omada:omada /data/EAPController/data/db
  echo "done"
fi

# Import a cert from a possibly mounted secret or file at /cert
if [ -f "/cert/${SSL_KEY_NAME}" ] && [ -f "/cert/${SSL_CERT_NAME}" ]
then
  # see where the keystore directory is; check for old location first
  if [ -d /opt/tplink/EAPController/keystore ]
  then
    # keystore in the parent folder before 5.3.1
    KEYSTORE_DIR="/opt/tplink/EAPController/keystore"
  else
    # keystore directory moved to the data directory in 5.3.1
    KEYSTORE_DIR="/data/EAPController/data/keystore"

    # check to see if the KEYSTORE_DIR exists (it won't on upgrade)
    if [ ! -d "${KEYSTORE_DIR}" ]
    then
      echo "INFO: Creating keystore directory (${KEYSTORE_DIR})"
      mkdir "${KEYSTORE_DIR}"
      echo "INFO: Setting permissions on ${KEYSTORE_DIR}"
      chown omada:omada "${KEYSTORE_DIR}"
    fi
  fi

  echo "INFO: Importing cert from /cert/tls.[key|crt]"
  # delete the existing keystore
  rm -f "${KEYSTORE_DIR}/eap.keystore"

  # example certbot usage: ./certbot-auto certonly --standalone --preferred-challenges http -d mydomain.net
  openssl pkcs12 -export \
    -inkey "/cert/${SSL_KEY_NAME}" \
    -in "/cert/${SSL_CERT_NAME}" \
    -certfile "/cert/${SSL_CERT_NAME}" \
    -name eap \
    -out "${KEYSTORE_DIR}/eap.keystore" \
    -passout pass:tplink

  # set ownership/permission on keystore
  chown omada:omada "${KEYSTORE_DIR}/eap.keystore"
  chmod 400 "${KEYSTORE_DIR}/eap.keystore"
fi

# re-enable disabled TLS versions 1.0 & 1.1
if [ "${TLS_1_11_ENABLED}" = "true" ]
then
  echo "INFO: Re-enabling TLS 1.0 & 1.1"
  if [ -f "/etc/java-8-openjdk/security/java.security" ]
  then
    # openjdk8
    sed -i 's#^jdk.tls.disabledAlgorithms=SSLv3, TLSv1, TLSv1.1,#jdk.tls.disabledAlgorithms=SSLv3,#' /etc/java-8-openjdk/security/java.security
  elif [ -f "/etc/java-17-openjdk/security/java.security" ]
  then
    # openjdk17
    sed -i 's#^jdk.tls.disabledAlgorithms=SSLv3, TLSv1, TLSv1.1,#jdk.tls.disabledAlgorithms=SSLv3,#' /etc/java-17-openjdk/security/java.security
  else
    # not running openjdk8 or openjdk17
    echo "WARN: Unable to re-enable TLS 1.0 & 1.1; unable to detect openjdk version"
  fi
fi

# see if any of these files exist; if so, do not start as they are from older versions
if [ -f /data/EAPController/data/db/tpeap.0 ] || [ -f /data/EAPController/data/db/tpeap.1 ] || [ -f /data/EAPController/data/db/tpeap.ns ]
then
  echo "ERROR: The data volume mounted to /data/EAPController/data appears to have data from a previous version!"
  echo "  Follow the upgrade instructions at https://github.com/mbentley/docker-omada-controller#upgrading-to-41"
  exit 1
fi

# check to see if the CMD passed contains the text "com.tplink.omada.start.OmadaLinuxMain" which is the old classpath from 4.x
if [ "$(echo "${@}" | grep -q "com.tplink.omada.start.OmadaLinuxMain"; echo $?)" = "0" ]
then
  echo -e "\n############################"
  echo "WARNING: CMD from 4.x detected!  It is likely that this container will fail to start properly with a \"Could not find or load main class com.tplink.omada.start.OmadaLinuxMain\" error!"
  echo "  See the note on old CMDs at https://github.com/mbentley/docker-omada-controller/blob/master/KNOWN_ISSUES.md#upgrade-issues for details on why and how to resolve the issue."
  echo -e "############################\n"
fi

# compare version from the image to the version stored in the persistent data (last ran version)
if [ -f "/opt/tplink/EAPController/IMAGE_OMADA_VER.txt" ]
then
  # file found; read the version that is in the image
  IMAGE_OMADA_VER="$(cat /opt/tplink/EAPController/IMAGE_OMADA_VER.txt)"
else
  echo "ERROR: Missing image version file (/opt/tplink/EAPController/IMAGE_OMADA_VER.txt); this should never happen!"
  exit 1
fi

# load LAST_RAN_OMADA_VER, if file present
if [ -f "/data/EAPController/data/LAST_RAN_OMADA_VER.txt" ]
then
  # file found; read the version that was last recorded
  LAST_RAN_OMADA_VER="$(cat /data/EAPController/data/LAST_RAN_OMADA_VER.txt)"
else
  # no file found; set version to 0.0.0 as we don't know the last version
  LAST_RAN_OMADA_VER="0.0.0"
fi

# use sort to check which version is newer; should sort the newest version to the top
if [ "$(printf '%s\n' "${IMAGE_OMADA_VER}" "${LAST_RAN_OMADA_VER}" | sort -rV | head -n1)" != "${IMAGE_OMADA_VER}" ]
then
  # version in the image is didn't match newest image version; this means we are trying to start and older version
  echo "ERROR: The version from the image (${IMAGE_OMADA_VER}) is older than the last version executed (${LAST_RAN_OMADA_VER})!  Refusing to start to prevent data loss!"
  echo "  To bypass this check, remove /data/EAPController/data/LAST_RAN_OMADA_VER.txt only if you REALLY know what you're doing!"
  exit 1
else
  echo "INFO: Version check passed; image version (${IMAGE_OMADA_VER}) >= the last version ran (${LAST_RAN_OMADA_VER}); writing image version to last ran file..."
  echo "${IMAGE_OMADA_VER}" > /data/EAPController/data/LAST_RAN_OMADA_VER.txt
fi

echo "INFO: Starting Omada Controller as user omada"

# tail the omada logs if set to true
if [ "${SHOW_SERVER_LOGS}" = "true" ]
then
  gosu omada tail -F -n 0 /data/EAPController/logs/server.log &
fi

# tail the mongodb logs if set to true
if [ "${SHOW_MONGODB_LOGS}" = "true" ]
then
  gosu omada tail -F -n 0 /data/EAPController/logs/mongod.log &
fi

# run the actual command as the omada user
exec gosu omada "${@}"