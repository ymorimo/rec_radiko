#!/bin/bash

set -e
umask 002

cd `dirname $0`

recordingdir=${RADIKO_OUTDIR:-.}

# Hard-coded radiko stream session id, as in rec_radiko.sh.
lsid="7423879e13315c189ff7d770e423c338"

# Timefree playlist host (timefree="1", areafree="0" from
# https://radiko.jp/v3/station/stream/pc_html5/<station>.xml).
tf_playlist="https://tf-f-rpaa-radiko.smartstream.ne.jp/tf/playlist.m3u8"


auth() {
    rm -f "playerCommon.$$"
    wget -q -O "playerCommon.$$" 'https://radiko.jp/apps/js/playerCommon.js?_=20171113'
    auth_key=`perl -ne "print \\$1 if (/new RadikoJSPlayer\(.*?'pc_html5',\s*'(\w+)'/)" playerCommon.$$`
    rm -f "playerCommon.$$"

    if [[ -z "$auth_key" ]]; then
        echo "retrieving auth_key from playerCommon.js failed"
        return 1
    fi

    rm -f "auth1.$$"
    wget -q \
        --header="pragma: no-cache" \
        --header="X-Radiko-App: pc_html5" \
        --header="X-Radiko-App-Version: 0.0.1" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --no-check-certificate \
        --save-headers \
        --tries=5 \
        --timeout=5 \
        -O "auth1.$$" \
        https://radiko.jp/v2/api/auth1

    if [ $? -ne 0 ]; then
        echo "auth1 failed"
        return 1
    fi

    authtoken=`perl -ne 'print $1 if(/x-radiko-authtoken: ([\w-]+)/i)' auth1.$$`
    offset=`perl -ne 'print $1 if(/x-radiko-keyoffset: (\d+)/i)' auth1.$$`
    length=`perl -ne 'print $1 if(/x-radiko-keylength: (\d+)/i)' auth1.$$`

    partialkey=`echo $auth_key | dd bs=1 skip=${offset} count=${length} 2> /dev/null | base64`

    rm -f "auth1.$$"

    rm -f "auth2.$$"
    wget -q \
        --header="pragma: no-cache" \
        --header="X-Radiko-User: test-stream" \
        --header="X-Radiko-Device: pc" \
        --header="X-Radiko-Authtoken: ${authtoken}" \
        --header="X-Radiko-Partialkey: ${partialkey}" \
        --no-check-certificate \
        --tries=5 \
        --timeout=5 \
        -O "auth2.$$" \
        https://radiko.jp/v2/api/auth2

    if [ $? -ne 0 -o ! -f "auth2.$$" ]; then
        echo "auth2 failed"
        return 1
    fi

    areaid=`perl -ne 'print $1 if(/^([^,]+),/i)' auth2.$$`

    rm -f "auth2.$$"
}


with_retries() {
    cmd=$1
    retries=0
    while :; do
        # `if $cmd` keeps set -e from aborting before the retry check, and runs
        # $cmd's body with errexit disabled so its `return 1` triggers a retry.
        if $cmd; then
            break
        elif [ $retries -ge 10 ]; then
            echo "\`$cmd\` failed after 10 retries"
            exit 1
        else
            retries=$(($retries + 1))
            echo "Retrying \`$cmd\` after sleeping $retries seconds"
            sleep $retries
        fi
    done
}


# radiko's broadcast day runs 05:00-28:59, so a program before 05:00 is listed
# under the previous calendar day. Subtract 5 hours from the start time and take
# the date. Try GNU date first, then fall back to BSD/macOS date.
broadcast_date() {
    local ft=$1
    date -d "${ft:0:4}-${ft:4:2}-${ft:6:2} ${ft:8:2}:${ft:10:2}:${ft:12:2} -5 hours" +%Y%m%d 2>/dev/null \
        || date -j -v-5H -f "%Y%m%d%H%M%S" "$ft" +%Y%m%d
}

# Convert a YYYYMMDDHHMMSS timestamp to epoch seconds (GNU date, then BSD date).
to_epoch() {
    local ts=$1
    date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +%s 2>/dev/null \
        || date -j -f "%Y%m%d%H%M%S" "$ts" +%s
}

# Look up a program's end time (to) from the station's program guide. Retries
# the fetch so a transient error doesn't look like a missing program, and
# returns non-zero (empty output) when the guide can't be fetched.
lookup_to() {
    local station=$1 ft=$2 d xml
    d=`broadcast_date "$ft"`
    xml=`curl -s -f --retry 3 --retry-delay 2 "https://radiko.jp/v3/program/station/date/$d/$station.xml"` || true
    if [ -z "$xml" ]; then
        echo "Failed to fetch the program guide for $station on $d" >&2
        return 1
    fi
    printf '%s' "$xml" | FT="$ft" perl -ne 'print $1 if (/ft="$ENV{FT}" to="(\d{14})"/)'
}

# Record a single timefree program to an AAC file. start_at/end_at are required
# (without them the server returns the live stream). The timefree medialist has
# no EXT-X-ENDLIST, so streamlink is bounded with --hls-duration set to the
# program length; it stops cleanly once that much media has been downloaded.
record_one() {
    local station=$1 ft=$2 to=$3 out=$4 secs dur url
    secs=$(( `to_epoch "$to"` - `to_epoch "$ft"` ))
    dur=`printf '%02d:%02d:%02d' $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))`
    url="$tf_playlist?station_id=$station&start_at=$ft&ft=$ft&end_at=$to&to=$to&l=15&lsid=$lsid&type=b"
    streamlink \
        --loglevel error \
        --progress no \
        --http-header "X-Radiko-AreaId=$areaid" \
        --http-header "X-Radiko-Authtoken=$authtoken" \
        --http-header "Referer=https://radiko.jp/" \
        --hls-duration "$dur" \
        --force \
        -o "$out" \
        "hls://$url" best
}


usage_exit() {
    echo "Usage: $0 name artist subdir url [url ...]"
    echo "  name:   program name (used as the m4a title)"
    echo "  artist: station name (used as the m4a artist)"
    echo "  subdir: output subdirectory under \$RADIKO_OUTDIR (created if needed)"
    echo "  url:    timefree program URL or station/datetime, e.g."
    echo "          https://radiko.jp/#!/ts/TBS/20260618140000  or  TBS/20260618140000"
    echo
    echo "Multiple URLs are recorded in parallel and concatenated in the given"
    echo "order into a single yyyymmdd.m4a (dated from the first URL)."
    exit 1
}


#
# main
#
if [ $# -lt 4 ]; then
    usage_exit
fi
name=$1; shift
artist=$1; shift
dir=$1; shift
urls=("$@")

outdir="$recordingdir/$dir"
mkdir -p "$outdir"

with_retries auth

# Parse each URL into station/ft, resolve its end time, and start recording.
pids=()
tempfiles=()
first_ft=""
i=0
for u in "${urls[@]}"; do
    # Accept a full timefree URL (https://radiko.jp/#!/ts/TBS/20260618165000)
    # or a bare station/datetime (TBS/20260618165000).
    if [[ "$u" =~ ([A-Za-z0-9_-]+)/([0-9]{14})$ ]]; then
        station=${BASH_REMATCH[1]}
        ft=${BASH_REMATCH[2]}
    else
        echo "Invalid timefree URL: $u"
        exit 1
    fi

    to=`lookup_to "$station" "$ft"` || true
    if [ -z "$to" ]; then
        echo "Couldn't find the program for $station at $ft in the guide."
        exit 1
    fi

    [ -z "$first_ft" ] && first_ft=$ft

    tf="$recordingdir/tf.$$.$i.aac"
    tempfiles+=("$tf")
    echo "Recording $station $ft-$to -> $tf"
    record_one "$station" "$ft" "$to" "$tf" &
    pids+=($!)
    i=$(($i + 1))
done

# Wait for all recordings; fail if any did.
rc=0
for p in "${pids[@]}"; do
    wait "$p" || rc=1
done
if [ $rc -ne 0 ]; then
    echo "A recording failed."
    rm -f "${tempfiles[@]}"
    exit 1
fi

# Concatenate the AAC files in the requested order (ADTS frames are
# self-contained, so byte concatenation is safe).
combined="$recordingdir/combined.$$.aac"
cat "${tempfiles[@]}" > "$combined"

# Output file name: yyyymmdd.m4a, dated from the first URL, with a numeric
# suffix when a file already exists.
date_part=${first_ft:0:8}
outfile="$outdir/$date_part.m4a"
if [ -e "$outfile" ]; then
    n=1
    while [ -e "$outdir/${date_part}_$n.m4a" ]; do
        n=$(($n + 1))
    done
    outfile="$outdir/${date_part}_$n.m4a"
fi

title="$name ${date_part:0:4}-${date_part:4:2}-${date_part:6:2}"
album="Radio: $name"

# Mux the combined AAC into an m4a container with metadata tags.
ffmpeg -loglevel error -nostats -y \
    -i "$combined" \
    -vn -acodec copy \
    -bsf:a aac_adtstoasc \
    -metadata title="$title" \
    -metadata album="$album" \
    -metadata artist="$artist" \
    -metadata genre="Radio" \
    -f mp4 "$outfile"

rm -f "${tempfiles[@]}" "$combined"

echo "Wrote $outfile"

# Local Variables:
# indent-tabs-mode: nil
# sh-basic-offset: 4
# sh-indentation: 4
# End:
