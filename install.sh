#!/bin/bash

set -xeuo pipefail

TAG=v1.106.3

UNAME=$(uname)

IMMICH_PATH=/var/lib/immich

if [ "$UNAME" = "Darwin" ]; then
  # we select a path that is writable and doesn't interfere with brew or other package managers
  IMMICH_PATH=/opt/services/immich
fi

APP=$IMMICH_PATH/app

if [[ "$USER" != "immich" ]]; then
  if [ "$UNAME" = "Darwin" ]; then
    for i in com.immich*.plist; do
      [ -f /Library/LaunchDaemons/$i ] && \
      launchctl unload -w /Library/LaunchDaemons/$i && \
      rm -f /Library/LaunchDaemons/$i
    done
  else
    # Disable systemd services, if installed
    (
      for i in immich*.service; do
        systemctl stop $i && \
          systemctl disable $i && \
          rm /etc/systemd/system/$i &&
          systemctl daemon-reload
      done
    ) || true
  fi

  mkdir -p $IMMICH_PATH
  chown immich:immich $IMMICH_PATH

  mkdir -p /var/log/immich
  chown immich:immich /var/log/immich

  echo "Restarting the script as user immich"
  exec sudo -u immich $0 $*
fi

BASEDIR=$(dirname "$0")
umask 077

rm -rf $APP
mkdir -p $APP

# Wipe npm, pypoetry, etc
# This expects immich user's home directory to be on $IMMICH_PATH/home
rm -rf $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home
echo 'umask 077' > $IMMICH_PATH/home/.bashrc

if [ "$UNAME" = "Darwin" ]; then
  export HOME=$IMMICH_PATH/home
fi

TMP="/tmp/immich-$(uuidgen)"
git clone https://github.com/immich-app/immich $TMP
cd $TMP
git reset --hard $TAG

# immich-server
cd server
npm ci
npm run build
npm prune --omit=dev --omit=optional
cd -

cd open-api/typescript-sdk
npm ci
npm run build
cd -

cd web
npm ci
npm run build
cd -

cp -a server/node_modules server/dist server/bin $APP/
cp -a web/build $APP/www
cp -a server/resources server/package.json server/package-lock.json $APP/
cp -a server/start*.sh $APP/
cp -a LICENSE $APP/
cd $APP
npm cache clean --force
cd -

# immich-machine-learning
mkdir -p $APP/machine-learning
python3 -m venv $APP/machine-learning/venv
(
  # Initiate subshell to setup venv
  . $APP/machine-learning/venv/bin/activate
  pip3 install poetry
  cd machine-learning
  if python -c 'import sys; exit(0) if sys.version_info.major == 3 and sys.version_info.minor > 11 else exit(1)'; then
    echo "Python > 3.11 detected, forcing poetry update"
    # Allow Python 3.12 (e.g., Ubuntu 24.04)
    sed -i -e 's/<3.12/<4/g' pyproject.toml
    poetry update
  fi
  poetry install --no-root --with dev --with cpu
  cd ..
)
cp -a machine-learning/ann machine-learning/start.sh machine-learning/app $APP/machine-learning/

# Replace /usr/src
cd $APP
grep -Rl /usr/src | xargs -n1 sed -i -e "s@/usr/src@$IMMICH_PATH@g"
ln -sf $IMMICH_PATH/app/resources $IMMICH_PATH/
mkdir -p $IMMICH_PATH/cache
sed -i -e "s@\"/cache\"@\"$IMMICH_PATH/cache\"@g" $APP/machine-learning/app/config.py

# Install GeoNames
cd $IMMICH_PATH/app/resources
wget -o - https://download.geonames.org/export/dump/admin1CodesASCII.txt &
wget -o - https://download.geonames.org/export/dump/admin2Codes.txt &
wget -o - https://download.geonames.org/export/dump/cities500.zip &
wait
unzip cities500.zip

if [ "$UNAME" = "Darwin" ]; then
  date -Iseconds | tr -d "\n" > geodata-date.txt
else
  date --iso-8601=seconds | tr -d "\n" > geodata-date.txt
fi

rm cities500.zip

# Install sharp
cd $APP
npm install sharp

# Setup upload directory
mkdir -p $IMMICH_PATH/upload
ln -s $IMMICH_PATH/upload $APP/
ln -s $IMMICH_PATH/upload $APP/machine-learning/

# Use 127.0.0.1
sed -i -e "s@app.listen(port)@app.listen(port, '127.0.0.1')@g" $APP/dist/main.js

# Custom start.sh script
cat <<EOF > $APP/start.sh
#!/bin/bash

PATH=\$PATH:/usr/local/bin

set -a
. $IMMICH_PATH/env
set +a

cd $APP
exec node $APP/dist/main "\$@"
EOF

cat <<EOF > $APP/machine-learning/start.sh
#!/bin/bash

PATH=\$PATH:/usr/local/bin

set -a
. $IMMICH_PATH/env
set +a

cd $APP/machine-learning
. venv/bin/activate

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=120}"

exec gunicorn app.main:app \
        -k app.config.CustomUvicornWorker \
        -w "\$MACHINE_LEARNING_WORKERS" \
        -b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \
        -t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \
        --log-config-json log_conf.json \
        --graceful-timeout 0
EOF

# Cleanup
rm -rf $TMP

echo
if [ "$UNAME" = "Darwin" ]; then
  echo "Done. Please install the LaunchDaemon files in /Library/LaunchDaemons and load to begin using Immich."
else
  echo "Done. Please install the systemd services to start using Immich."
fi
echo
