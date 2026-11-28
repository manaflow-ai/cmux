# Sourced by login shells in the experimental image. The provider supplies the
# tenant's mount, and all cache writes run with the normal guest user's rights.
cmux_npm_host_cache() {
    [ "${npm_config_cache+x}${NPM_CONFIG_CACHE+x}" = "" ] || return 1
    [ "$(id -un)" = cmux ] && [ "$(id -u)" != 0 ] || return 1

    (
        cd -P -- "$1" && [ "$(pwd -P)" = "$1" ] || exit 1
        mountpoint -q -- . && [ -w . ] && [ -x . ] || exit 1

        cache_ready() {
            [ ! -L npm ] && [ -d npm ] && [ -w npm ] &&
                [ ! -L npm/_cacache ] && [ -d npm/_cacache ] && [ -w npm/_cacache ]
        }
        cache_ready && exit 0

        # Lock the mount directory itself. The kernel releases the lock when
        # the initializer exits, even if the guest shell is interrupted.
        exec 9<.
        flock -x -w 15 9 || exit 1
        cache_ready && exit 0
        [ ! -e npm ] && [ ! -L npm ] || exit 1
        [ -d "$2" ] && [ "$(realpath -e -- "$2")" = "$2" ] || exit 1

        stage=$(mktemp -d -- .npm-seed.XXXXXXXX) || exit 1
        trap 'rm -rf -- "$stage"' EXIT
        (
            cd -P -- "$stage" && [ "$(pwd -P)" = "$1/$stage" ] || exit 1
            cp -RP -- "$2" _cacache || exit 1
            # npm's baked seed contains only directories and regular files.
            # Reject links (including dangling ones) and special files.
            other=$(find _cacache ! -type d ! -type f -print -quit) || exit 1
            [ -z "$other" ]
        ) || exit 1
        # Same mount: publish the whole seed at once. A failed or interrupted
        # copy never exposes a partially populated cache.
        mv -T -- "$stage" npm && cache_ready
    ) 2>/dev/null || return 1

    export npm_config_cache="$1/npm"
}

cmux_npm_host_cache /var/cache/cmux-pkg /usr/local/share/cmux/npm-seed/_cacache || :
