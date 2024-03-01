# Native Immich

This repository provides instructions and helper scripts to install [Immich](https://github.com/immich-app/immich) without Docker, natively.

### Notes

 * This is tested on Ubuntu 22.04 (on both x86 and aarch64) as the host distro, but it will be similar on other distros.

 * This guide installs Immich to `/var/lib/immich`. To change it, replace it to the directory you want in this README and `install.sh`'s `$IMMICH_PATH`.

 * The [install.sh](install.sh) script currently is using Immich v1.97.0 with some additional minor fixes. It should be noted that due to the fast-evolving nature of Immich, the install script may get broken if you replace the `$TAG` to something more recent.

 * `mimalloc` is deliberately disabled as this is a native install and sharing system library makes more sense.

 * Microservice and machine-learning's host is opened to 0.0.0.0 in the default configuration. This behavior is changed to only accept 127.0.0.1 during installation. Only the main Immich service's port, 3001, is opened to 0.0.0.0.

 * Only the basic CPU configuration is used. Hardware-acceleration such as CUDA is unsupported.

## 1. Install dependencies

 * [Node.js](https://github.com/nodesource/distributions)

 * [PostgreSQL](https://www.postgresql.org/download/linux/ubuntu)

 * [Redis](https://redis.io/docs/install/install-redis/install-redis-on-linux)

As the time of writing, Node.js v20 LTS, PostgreSQL 16 and Redis 7.2.4 was used.

 * [pgvector](https://github.com/pgvector/pgvector)

As the time of writing, pgvector v0.6.0 was used.

You need the `postgresql-server-dev(-16)` package installed to build and install pgvector.

It comes with a lot of other dependencies, but you can remove it all after pgvector is built and installed.

It is recommended to strip the `vector.so` to reduce memory footprint:

``` bash
sudo strip /usr/lib/postgresql/*/lib/vector.so
```

### Other APT packages

``` bash
sudo apt install python3-venv python3-dev
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
postgrse=# ALTER USER immich WITH SUPERUSER;
postgres=# \q
```

## 4. Prepare `env`

Save the [env](env) file to `/var/lib/immich`, and configure on your own.

You'll only have to set `DB_PASSWORD`.

``` bash
sudo cp env /var/lib/immich
sudo chown immich:immich /var/lib/immich/env
```

## 5. Build and install Immich

Clone this repository to somewhere anyone can access (like /tmp) and run `install.sh` as root.

Anytime Immich is updated, all you have to do is run it again.

## Done!

Your Immich installation should be running at :3001 port.

Immich will additionally use 3002 and 3003 ports, but those will only listen from localhost (127.0.0.1).

Please add firewall rules and apply https proxy and secure your Immich instance.
