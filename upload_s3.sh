#!/bin/bash

# Upload finished recordings to S3 with `aws s3 sync`.
#
#   ./upload_s3.sh cnt golden   # those subdirectories of $RADIKO_OUTDIR
#   ./upload_s3.sh              # every subdirectory
#
# Does nothing at all unless RADIKO_S3_BUCKET names a bucket, so the recording
# scripts can call it unconditionally and a machine that only records needs no
# aws credentials. Syncing is idempotent, so this is also safe to run from cron
# to pick up whatever an earlier upload missed.
#
# Every uploaded file is named when run from a terminal, and nothing is printed
# when the output is not one, which is how it stays quiet under cron.

set -e
umask 002

cd `dirname $0`

recordingdir=${RADIKO_OUTDIR:-.}

[ -n "$RADIKO_S3_BUCKET" ] || exit 0

# From cron, by way of the recorders, this runs for every recording, and the
# interesting part of that log is the recording -- not a list of uploads.
quiet=
[ -t 1 ] || quiet=--quiet

if ! command -v aws >/dev/null 2>&1; then
    echo "RADIKO_S3_BUCKET is set but the aws command is not on PATH." >&2
    exit 1
fi

# No arguments: every subdirectory holding recordings.
if [ $# -eq 0 ]; then
    for d in "$recordingdir"/*/; do
        [ -d "$d" ] || continue
        set -- "$@" "`basename "$d"`"
    done
    [ $# -gt 0 ] || exit 0
fi

rc=0
for dir in "$@"; do
    src="$recordingdir/$dir" # $dir may contain '/'
    if [ ! -d "$src" ]; then
        echo "No such recording directory: $src" >&2
        rc=1
        continue
    fi
    # Nothing hidden belongs in the bucket: the per-run working directory,
    # which holds a partial .aac while a recording of the same subdirectory is
    # still going, and the .DS_Store and friends that turn up on their own.
    # Patterns are matched against the path relative to $src, so both forms are
    # needed -- ".*" alone leaves a hidden file below the first level.
    aws s3 sync "$src/" "s3://$RADIKO_S3_BUCKET/$dir/" \
        --exclude '.*' --exclude '*/.*' $quiet || rc=1
done

exit $rc

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
# End:
