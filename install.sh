#!/bin/bash

set -xeuo pipefail

REV=v2.5.2

IMMICH_PATH=/var/lib/immich
APP=$IMMICH_PATH/app

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is not activated, please follow README's Node.js setup"
  exit 1
fi

# Prevent Javascript OOM
export NODE_OPTIONS="--max-old-space-size=4096"

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

# Sanity check, users should have VectorChord enabled
if psql -U immich -c "SELECT 1;" > /dev/null 2>&1; then
  # Immich is installed, check VectorChord
  if ! psql -U immich -c "SELECT * FROM pg_extension;" | grep "vchord" > /dev/null 2>&1; then
    echo "VectorChord is not enabled for Immich."
    echo "Please read https://github.com/immich-app/immich/blob/main/docs/docs/administration/postgres-standalone.md"
    exit 1
  fi
fi
if [ -e "$IMMICH_PATH/env" ]; then
  if grep -q DB_VECTOR_EXTENSION "$IMMICH_PATH/env"; then
    echo "Please remove DB_VECTOR_EXTENSION from your env file"
    exit 1
  fi
fi

BASEDIR=$(dirname "$0")
umask 077

rm -rf $APP $APP/../i18n
mkdir -p $APP

# Wipe pnpm, uv, etc
# This expects immich user's home directory to be on $IMMICH_PATH/home
rm -rf $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home/.local/bin
echo 'umask 077' > $IMMICH_PATH/home/.bashrc
export PATH="$HOME/.local/bin:$PATH"

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

# Setup pnpm
corepack use pnpm@latest

# Install extism/js-pdk for extism-js
curl -O https://raw.githubusercontent.com/extism/js-pdk/main/install.sh
sed -i \
  -e 's@sudo@@g' \
  -e "s@/usr/local/binaryen@$HOME/binaryen@g" \
  -e "s@/usr/local/bin@$HOME/.local/bin@g" \
    install.sh
./install.sh
rm install.sh

# immich-server
cd server
pnpm install --frozen-lockfile --force
pnpm run build
pnpm prune --prod --no-optional --config.ci=true
cd -

cd open-api/typescript-sdk
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cd web
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cd plugins
pnpm install --frozen-lockfile --force
pnpm run build
cd -

cp -aL server/node_modules server/dist server/bin $APP/
cp -a web/build $APP/www
cp -a server/resources server/package.json pnpm-lock.yaml $APP/
mkdir -p $APP/corePlugin
cp -a plugins/dist $APP/corePlugin/
cp -a plugins/manifest.json $APP/corePlugin/
cp -a LICENSE $APP/
cp -a i18n $APP/../
cd $APP
pnpm store prune
cd -

# immich-machine-learning
mkdir -p $APP/machine-learning
python3 -m venv $APP/machine-learning/venv
(
  # Initiate subshell to setup venv
  . $APP/machine-learning/venv/bin/activate
  pip3 install uv
  if [ "$(python3 -c 'import sys; print(sys.version_info[:2] > (3, 12))')" = "True" ]; then
    echo "Python > 3.12, pinning to 3.12"
    uv venv --python 3.12 --allow-existing $APP/machine-learning/venv
    # Reload
    deactivate
    . $APP/machine-learning/venv/bin/activate
  fi
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
# https://github.com/lovell/sharp/blob/main/src/common.h#L20
VIPS_LOCAL_VERSION="$(pkg-config --modversion vips || true)"
VIPS_TARGET_VERSION="8.17.3"
if [[ "$(printf '%s\n' $VIPS_TARGET_VERSION $VIPS_LOCAL_VERSION | sort -V | tail -n1)" == "$VIPS_LOCAL_VERSION" ]]; then
  echo "Local libvips-dev is installed, manually building sharp"
  pnpm remove sharp
  SHARP_FORCE_GLOBAL_LIBVIPS=1 npm_config_build_from_source=true pnpm add sharp --ignore-scripts=false --allow-build=sharp
else
  if [ ! -z "$VIPS_LOCAL_VERSION" ]; then
    echo "Local libvips-dev is installed, but it's too out-of-date"
    echo "Detected $VIPS_LOCAL_VERSION, but $VIPS_TARGET_VERSION or higher is required"
    sleep 5
  fi
  pnpm install sharp
fi

# Setup upload directory
mkdir -p $IMMICH_PATH/upload
ln -s $IMMICH_PATH/upload $APP/
ln -s $IMMICH_PATH/upload $APP/machine-learning/

# Custom start.sh script
cat <<EOF > $APP/start.sh
#!/bin/bash

export PATH=/usr/lib/jellyfin-ffmpeg:$HOME/.local/bin:$PATH

set -a
. $IMMICH_PATH/env
set +a

cd $APP
exec node $APP/dist/main "\$@"
EOF

chmod 700 $APP/start.sh

cat <<EOF > $APP/machine-learning/start.sh
#!/bin/bash

export PATH=/usr/lib/jellyfin-ffmpeg:$HOME/.local/bin:$PATH

set -a
. $IMMICH_PATH/env
set +a

cd $APP/machine-learning
. venv/bin/activate

set -a

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S:=2}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=300}"
: "\${MACHINE_LEARNING_CACHE_FOLDER:=$IMMICH_PATH/cache}"
: "\${TRANSFORMERS_CACHE:=$IMMICH_PATH/cache}"

exec gunicorn immich_ml.main:app \\
	-k immich_ml.config.CustomUvicornWorker \\
	-c immich_ml/gunicorn_conf.py \\
	-b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \\
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
  $IMMICH_PATH/home/.local/share/pnpm \
  $IMMICH_PATH/home/.cache

echo
echo "Done."
echo
