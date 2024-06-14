# Native Immich on macOS

Installing immich natively on macOS is 99% the same as installing on linux. This document highlights the differences

### Notes

 * This is tested on macOS Monterey and Sonoma (x86).

 * This guide installs Immich to `/opt/services/immich`. To change it, replace it to the directory you want in this README and `install.sh`'s `$IMMICH_PATH`.

 * The [install.sh](install.sh) script currently is using Immich v1.106.3. It should be noted that due to the fast-evolving nature of Immich, the install script may get broken if you replace the `$TAG` to something more recent.

 * `pgvector` is used instead of `pgvecto.rs` that the official Immich uses to remove an additional Rust build dependency.

 * Microservice and machine-learning's host is opened to 0.0.0.0 in the default configuration. This behavior is changed to only accept 127.0.0.1 during installation. Only the main Immich service's port, 3001, is opened to 0.0.0.0.

 * Only the basic CPU configuration is used. Hardware-acceleration such as CUDA is unsupported. In my personal experience, importing about 10K photos on a x86 processor doesn't take an unreasonable amount of time (less than 30 minutes).

 * JPEG XL support may differ official Immich due to base-image's dependency differences.

## 1. Install dependencies

Dependencies are installed with (brew)[https://brew.sh]
 * [Node.js](https://github.com/nodesource/distributions)

 * [PostgreSQL](https://www.postgresql.org/download/linux)

 * [Redis](https://redis.io/docs/install/install-redis/install-redis-on-linux)

 * [FFmpeg](https://github.com/FFmpeg/FFmpeg)

``` bash
brew install postgresql pgvector node redis ffmpeg
```

Immich uses FFmpeg to process media.

### Other APT packages

``` bash
brew install wget
```

A separate Python's virtualenv will be stored to `/var/lib/immich`.

## 2. Prepare `immich` user

This guide isolates Immich to run on a separate `immich` user.

This provides basic permission isolation and protection.

* Using the Settings app, create a new "Sharing only" user named "immich".
* Create a new group named "immich"
* Add the immich user to the immich group

sudo mkdir -p /opt/services/immich
sudo chown immich:immich /opt/services/immich
sudo chmod 700 /opt/services/immich
```

## 3. Prepare PostgreSQL DB

Create a strong random string to be used with PostgreSQL immich database.

You need to save this and write to the `env` file later.

``` bash
psql
postgres=# create database immich;
postgres=# create user immich with encrypted password 'YOUR_STRONG_RANDOM_PW';
postgres=# grant all privileges on database immich to immich;
postgrse=# ALTER USER immich WITH SUPERUSER;
postgres=# \q
```

## 4. Prepare `env`

Save the [env](env) file to `/opt/services/immich`, and configure on your own.

You'll only have to set `DB_PASSWORD`.

``` bash
sudo cp env /opt/services/immich
sudo chown immich:immich /opt/services/immich/env
```

## 5. Build and install Immich

Clone this repository to somewhere anyone can access (like /tmp) and run `install.sh` as root.

Anytime Immich is updated, all you have to do is run it again.

In summary, the `install.sh` script does the following:

#### 1. Clones and builds Immich.

#### 2. Installs Immich to `/opt/services/immich` with minor patches.

  * Sets up a dedicated Python venv to `/opt/services/immich/app/machine-learning/venv`.

  * Replaces `/usr/src` to `/opt/services/immich`.

  * Limits listening host from 0.0.0.0 to 127.0.0.1. If you do not want this to happen (make sure you fully understand the security risks!), comment out the `sed` command in `install.sh`'s "Use 127.0.0.1" part.

## 6. Install daemon scripts

Because the install script switches to the immich user during installation, you must install systemd services manually:

``` bash
sudo cp com.immich*plist /Library/LaunchDaemons/
for i in com.immich*plist; do
  sudo launchctl load -w /Library/LaunchDaemons/$i
done
```

## Done!

Your Immich installation should be running at 3001 port, listening from localhost (127.0.0.1).

Immich will additionally use localhost's 3002 and 3003 ports.

Please add firewall rules and apply https proxy and secure your Immich instance.

## Uninstallation

``` bash
# Run as root!

# Remove Immich systemd services
for i in com.immich.*plist do
  launchctl unload -w /Library/LaunchDaemons/$i
done
rm /Library/LaunchDaemons/com.immich*plist

# Remove Immich files
rm -rf /opt/services/immich

# Delete immich user
Use the Settings app to delete the immich user and group

# Remove Immich DB
sudo -u postgres psql
postgres=# drop user immich;
postgres=# drop database immich;
postgres=# \q
```
