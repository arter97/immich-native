#!/bin/bash

set -xeuo pipefail

REV=v2.0.1

IMMICH_PATH=/var/lib/immich
APP=$IMMICH_PATH/app

if [[ "$USER" != "immich" ]]; then
  # Disable systemd services, if installed
  (
    systemctl list-unit-files --type=service | grep "^immich" | while read i unused; do
      systemctl stop $i && \
        systemctl disable $i && \
        rm /*/systemd/system/$i &&
        systemctl daemon-reload
    done
  ) || true

  mkdir -p $IMMICH_PATH
  chown immich:immich $IMMICH_PATH

  mkdir -p /var/log/immich
  chown immich:immich /var/log/immich

  echo "Forking the script as user immich"
  sudo -u immich $0 $*

  echo "Starting systemd services"
  cp immich*.service /lib/systemd/system/
  systemctl daemon-reload
  for i in immich*.service; do
    systemctl enable $i
    systemctl start $i
  done
  exit 0
fi

BASEDIR=$(dirname "$0")
umask 077

rm -rf $APP $APP/../i18n
mkdir -p $APP

# Wipe pnpm, uv, etc
# This expects immich user's home directory to be on $IMMICH_PATH/home
rm -rf $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home
echo 'umask 077' > $IMMICH_PATH/home/.bashrc

TMP=/tmp/immich-$(uuidgen)
if [[ $REV =~ ^[0-9A-Fa-f]+$ ]]; then
  # REV is a full commit hash, full clone is required
  git clone https://github.com/immich-app/immich $TMP
else
  git clone https://github.com/immich-app/immich $TMP --depth=1 -b $REV
fi
cd $TMP
git reset --hard $REV
rm -rf .git

# Replace /usr/src
grep -Rl /usr/src | xargs -n1 sed -i -e "s@/usr/src@$IMMICH_PATH@g"
mkdir -p $IMMICH_PATH/cache
grep -RlE "\"/build\"|'/build'" | xargs -n1 sed -i -e "s@\"/build\"@\"$APP\"@g" -e "s@'/build'@'$APP'@g"

# immich-server
cd server
pnpm install --frozen-lockfile
pnpm run build
pnpm prune --prod --no-optional
cd -

cd open-api/typescript-sdk
pnpm install --frozen-lockfile
pnpm run build
cd -

cd web
pnpm install --frozen-lockfile
pnpm run build
cd -

cp -aL server/node_modules server/dist server/bin $APP/
cp -a web/build $APP/www
cp -a server/resources server/package.json pnpm-lock.yaml $APP/
cp -a LICENSE $APP/
cp -a i18n $APP/../
cd $APP
pnpm store prune
cd -

# immich-machine-learning
mkdir -p $APP/machine-learning
python3.12 -m venv $APP/machine-learning/venv
(
  # Initiate subshell to setup venv
  . $APP/machine-learning/venv/bin/activate
  pip3 install uv
  cd machine-learning
  uv sync --no-install-project --no-install-workspace --extra cpu --no-cache --active --link-mode=copy
  cd ..
)
cp -a \
  machine-learning/immich_ml \
    $APP/machine-learning/

# Install GeoNames
mkdir -p $APP/geodata
cd $APP/geodata
wget -o - https://download.geonames.org/export/dump/admin1CodesASCII.txt &
wget -o - https://download.geonames.org/export/dump/admin2Codes.txt &
wget -o - https://download.geonames.org/export/dump/cities500.zip &
wget -o - https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson &
wait
unzip cities500.zip
date --iso-8601=seconds | tr -d "\n" > geodata-date.txt
rm cities500.zip

# Install sharp
cd $APP
pnpm install sharp

# Setup upload directory
mkdir -p $IMMICH_PATH/upload
ln -s $IMMICH_PATH/upload $APP/
ln -s $IMMICH_PATH/upload $APP/machine-learning/

# Custom start.sh script
cat <<EOF > $APP/start.sh
#!/bin/bash

set -a
. $IMMICH_PATH/env
set +a

cd $APP
exec node $APP/dist/main "\$@"
EOF

cat <<EOF > $APP/machine-learning/start.sh
#!/bin/bash

set -a
. $IMMICH_PATH/env
set +a

cd $APP/machine-learning
. venv/bin/activate

set -a

: "\${IMMICH_HOST:=127.0.0.1}"
: "\${IMMICH_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S:=2}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=300}"
: "\${MACHINE_LEARNING_CACHE_FOLDER:=$IMMICH_PATH/cache}"
: "\${TRANSFORMERS_CACHE:=$IMMICH_PATH/cache}"

exec gunicorn immich_ml.main:app \\
	-k immich_ml.config.CustomUvicornWorker \\
	-c immich_ml/gunicorn_conf.py \\
	-b "\$IMMICH_HOST":"\$IMMICH_PORT" \\
	-w "\$MACHINE_LEARNING_WORKERS" \\
	-t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \\
	--log-config-json log_conf.json \\
	--keep-alive "\$MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S" \\
	--graceful-timeout 10
EOF
chmod 700 $APP/machine-learning/start.sh

# Migrate env file
if [ -e "$IMMICH_PATH/env" ]; then
  if grep -q "^MACHINE_LEARNING_HOST=" "$IMMICH_PATH/env"; then
    # Simply change MACHINE_LEARNING_HOST to IMMICH_HOST
    sed -i -e 's/MACHINE_LEARNING_HOST/IMMICH_HOST/g' "$IMMICH_PATH/env"
  fi
fi

# Cleanup
rm -rf \
  $TMP \
  $IMMICH_PATH/home/.wget-hsts \
  $IMMICH_PATH/home/.pnpm \
  $IMMICH_PATH/home/.cache

echo
echo "Done."
echo
