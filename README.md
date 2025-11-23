# Native Immich

This repository provides instructions and helper scripts to install [Immich](https://github.com/immich-app/immich) without Docker, natively.

### Notes

 * This is tested on Ubuntu 24.04 (on both x86 and aarch64) as the host distro, but it will be similar on other distros. If you want to run this on a macOS, see [4v3ngR's unofficial macOS port](https://github.com/4v3ngR/immich-native-macos).

 * This guide installs Immich to `/var/lib/immich`. To change it, replace it to the directory you want in this README, `install.sh`, `immich.service`, `immich-machine-learning.service`.

 * The [install.sh](install.sh) script currently is using Immich v2.3.1. It should be noted that due to the fast-evolving nature of Immich, the install script may get broken if you replace the `$REV` to something more recent.

 * `mimalloc` is deliberately disabled as this is a native install and sharing system library makes more sense.

 * Machine-learning's host is opened to 0.0.0.0 in the default configuration. This behavior is changed to only accept 127.0.0.1 during installation.

 * Only the basic CPU configuration is used. Hardware-acceleration such as CUDA is unsupported. In my personal experience, importing about 10K photos on a x86 processor doesn't take an unreasonable amount of time (less than 30 minutes).

 * JPEG XL/RAW support may differ official Immich due to base-image's dependency differences.

 * For HEIF support, see [below](#HEIF-Support).

## 1. Install dependencies

 * [Node.js](https://nodesource.com/products/distributions)

You need corepack enabled to use pnpm.

```bash
sudo npm install npm@latest -g
sudo npm install corepack@latest -g
sudo corepack enable
```

 * [PostgreSQL](https://www.postgresql.org/download/linux)

 * [Redis](https://redis.io/docs/latest/operate/oss_and_stack/install/archive/install-redis/install-redis-on-linux)

As the time of writing, Node.js v24 LTS, PostgreSQL 18 and Redis 8.4.0 was used.

 * [pgvector](https://github.com/pgvector/pgvector)

pgvector is included in the official PostgreSQL's APT repository:

``` bash
sudo apt install postgresql(-18)-pgvector
```

 * [VectorChord](https://docs.vectorchord.ai/vectorchord/getting-started/installation.html)

 * [FFmpeg](https://github.com/FFmpeg/FFmpeg)

Immich uses FFmpeg to process media.

FFmpeg provided by the distro is typically too old.
Either install it from [jellyfin](https://github.com/jellyfin/jellyfin-ffmpeg/releases)
or use [FFmpeg Static Builds](https://johnvansickle.com/ffmpeg) and install it to `/usr/bin`.

Adding [Jellyfin APT repository](https://jellyfin.org/downloads/server) will automatically provide updates.
Follow the instructions and press Control+C when `jellyfin` package is about to get installed to abort.
You only need the repository, not the `jellyfin` package itself.
After that, install `jellyfin-ffmpeg7`:

``` bash
sudo apt install jellyfin-ffmpeg7
```

### Other APT packages

``` bash
sudo apt install --no-install-recommends \
        python3-pip \
        python3-venv \
        python3-dev \
        uuid-runtime \
        autoconf \
        build-essential \
        unzip \
        jq \
        perl \
        libnet-ssleay-perl \
        libio-socket-ssl-perl \
        libcapture-tiny-perl \
        libfile-which-perl \
        libfile-chdir-perl \
        libpkgconfig-perl \
        libffi-checklib-perl \
        libtest-warnings-perl \
        libtest-fatal-perl \
        libtest-needs-perl \
        libtest2-suite-perl \
        libsort-versions-perl \
        libpath-tiny-perl \
        libtry-tiny-perl \
        libterm-table-perl \
        libany-uri-escape-perl \
        libmojolicious-perl \
        libfile-slurper-perl \
        liblcms2-2 \
        wget \
        libgl1
```

A separate Python's virtualenv will be stored to `/var/lib/immich`.

## 2. Prepare `immich` user

This guide isolates Immich to run on a separate `immich` user.

This provides basic permission isolation and protection.

``` bash
sudo adduser \
  --home /var/lib/immich/home \
  --shell=/sbin/nologin \
  --no-create-home \
  --disabled-password \
  --disabled-login \
  immich
sudo mkdir -p /var/lib/immich
sudo chown immich:immich /var/lib/immich
sudo chmod 700 /var/lib/immich
```

## 3. Prepare PostgreSQL DB

Create a strong random string to be used with PostgreSQL immich database.

You need to save this and write to the `env` file later.

``` bash
sudo -u postgres psql
postgres=# create database immich;
postgres=# create user immich with encrypted password 'YOUR_STRONG_RANDOM_PW';
postgres=# grant all privileges on database immich to immich;
postgres=# ALTER USER immich WITH SUPERUSER;
postgres=# CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
postgres=# \q

sudo -u immich psql -U immich
postgres=# CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
postgres=# \q
```

## 4. Prepare `env`

Save the [env](env) file to `/var/lib/immich`, and configure on your own.

You'll only have to set `DB_PASSWORD`.

``` bash
sudo cp env /var/lib/immich
sudo chown immich:immich /var/lib/immich/env
sudo chmod 600 /var/lib/immich/env
```

## 5. Build and install Immich

Clone this repository to somewhere anyone can access (like /tmp) and run `install.sh` as root.

Anytime Immich is updated, all you have to do is run it again.

In summary, the `install.sh` script does the following:

#### 1. Clones and builds Immich.

#### 2. Installs Immich to `/var/lib/immich` with minor patches.

  * Sets up a dedicated Python venv to `/var/lib/immich/app/machine-learning/venv`.

  * Replaces `/usr/src` to `/var/lib/immich`.

  * Limits listening host from 0.0.0.0 to 127.0.0.1. If you do not want this to happen (make sure you fully understand the security risks!), change `IMMICH_HOST=127.0.0.1` to `IMMICH_HOST=0.0.0.0` from the `env` file.

## Done!

Your Immich installation should be running at 2283 port, listening from localhost (127.0.0.1).

Immich will additionally use localhost's 3003 ports.

Please add firewall rules and [apply https proxy](https://docs.immich.app/administration/reverse-proxy) and secure your Immich instance.

## Uninstallation

``` bash
# Run as root!

# Remove Immich systemd services
systemctl list-unit-files --type=service | grep "^immich" | while read i unused; do
  systemctl stop $i
  systemctl disable $i
done
rm /lib/systemd/system/immich*.service
systemctl daemon-reload

# Remove Immich files
rm -rf /var/lib/immich

# Delete immich user
deluser immich

# Remove Immich DB
sudo -u postgres psql
postgres=# drop database immich;
postgres=# drop user immich;
postgres=# \q

# Optionally remove dependencies
# Review /var/log/apt/history.log and remove packages you've installed
```

## HEIF Support

 * Apple devices use HEIF images instead of JPG.

 * Immich supports HEIF but installing it natively requires building [Sharp](https://github.com/lovell/sharp) from source.

 * Building Sharp from source in turn requires the latest `libvips-dev` to be installed.

 * For Ubuntu, see my [arter97/libvips PPA](https://launchpad.net/~arter97/+archive/ubuntu/libvips) to install the latest `libvips`:

``` bash
sudo add-apt-repository ppa:arter97/libvips
sudo apt install libvips-dev
sudo apt remove libvips*t64
```

 * If you installed the latest `libvips-dev`, the install script will detect this automatically and proceed to install Sharp from source.
