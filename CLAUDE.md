# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two Bash scripts that record radiko (Japanese internet radio) to tagged `.m4a` files, plus a Ruby driver that runs the timefree one on a schedule. There is no build system, test suite, or linter — "running it" is the only way to verify a change.

- `rec_radiko.sh` — records the **live** stream for a fixed duration.
- `rec_radiko_timefree.sh` — records one or more past programs from **timefree** (タイムフリー), recorded in parallel and concatenated in order into a single file.
- `rec_scheduler.rb` — reads per-program YAML files under `conf/` and runs `rec_radiko_timefree.sh` when an entry is due. Meant to be run once a minute from cron.

### Running

```sh
# Live: station_id, minutes, name(title), artist, subdir
RADIKO_OUTDIR=rec ./rec_radiko.sh TBS 60 'こねくと' 'TBSラジオ' golden

# Timefree: name(title), artist, subdir, then one or more program URLs.
# URL accepts full form or bare station/datetime.
RADIKO_OUTDIR=rec ./rec_radiko_timefree.sh 'こねくと' 'TBSラジオ' golden \
  'https://radiko.jp/#!/ts/TBS/20260618140000' TBS/20260618150000

# Premium / area-free (both scripts): -p, with credentials in env
RADIKO_EMAIL=… RADIKO_PASSWORD=… ./rec_radiko.sh -p TBS 60 name artist subdir
```

Output goes to `$RADIKO_OUTDIR/<subdir>/yyyymmdd.m4a` (`RADIKO_OUTDIR` defaults to `.`). Timefree adds a `_N` suffix on filename collision.

### Scheduling (`rec_scheduler.rb`)

One YAML file per program under `conf/`; `id` is the output subdir, `title`/`author` become the m4a title/artist. What to record is a local choice, so `conf/` is not checked in — `conf.sample.yaml` documents the format and is the file to copy there. It sits outside `conf/` on purpose, since the scheduler would otherwise record the sample along with everything else.

```yaml
---
id: cnt                                   # output subdir, also the state key
area: JP13                                # the program's area; -p is used when it isn't ours
station: TBS                              # default station (an entry may override it)
title: こねくと
author: TBSラジオ
image: https://…                          # unused by the scheduler
schedule:
  - wdays: [Mon, Tue, Wed, Thu]           # weekdays of the *execution*, not of the program
    program_times: ["14:00", "15:00", "16:00"]   # concatenated in this order into one file
    execution_time: "16:01"               # when to record; must be after the last program ends
```

```sh
./rec_scheduler.rb --list                     # every entry and its next execution
./rec_scheduler.rb -n -t '2026-07-23 16:01'   # dry run: what would be recorded at that time
./rec_scheduler.rb                            # run whatever is due now (conf/ by default)
```

Cron runs it every minute; a single line covers every program:

```crontab
* * * * * cd /path/to/rec_radiko && RADIKO_OUTDIR=rec RADIKO_EMAIL=… RADIKO_PASSWORD=… ./rec_scheduler.rb >> rec_scheduler.log 2>&1
```

Options: `-g/--grace MINUTES` (default 60) also runs entries that came due that recently, so a laptop asleep at the scheduled minute still records; `-f/--force` ignores the state file; `-d/--date` records a past day on demand (below); `-t/--time` fakes the current time; `-n/--dry-run`; `-l/--list`. `RADIKO_STATE` overrides the state file path (default `.rec_scheduler.state`), `RADIKO_AREA` skips the area lookup.

`-d/--date` records the entries whose *execution* falls on that date, instead of whatever is due now:

```sh
./rec_scheduler.rb -d 2026-07-30 conf/cnt.yaml   # that Thursday's こねくと
./rec_scheduler.rb -d 2026-07-30                 # everything scheduled that day
```

`YYYY-MM-DD`, `YYYYMMDD` and `MM-DD` (current year) are accepted, `/` works as a separator, and a date that doesn't exist is rejected rather than rolled over (`Time.new(2026, 2, 30)` is March 2nd). Since it is an explicit request, `--date` records regardless of the state file — a second run re-records, and `rec_radiko_timefree.sh` gives the file a `_N` suffix instead of overwriting. **The date is the execution date, matching `wdays`**, so a program radiko lists at 25:00 Monday is `-d` its Tuesday. When no entry matches the date, the run exits 1 and prints each entry's weekdays and nearest matching date rather than doing nothing silently. How far back timefree reaches depends on the account's plan, so no limit is imposed here; an out-of-range date fails in the recorder.

Verifying a change means running it (use a short live duration, or a short timefree program). Inspect the result with `ffprobe -v error -show_entries format=duration:format_tags=title,artist,album,genre -of default=nw=1 <file>`.

### Dependencies

`streamlink`, `ffmpeg`, `wget`, `curl`, `perl`, `base64`, `dd`. The scripts target both macOS and Linux: every `date` call tries GNU syntax first and falls back to BSD/macOS (see `broadcast_date`, `to_epoch`).

## Architecture

Both scripts share the same shape: **auth → record (streamlink) → tag (ffmpeg)**.

- **Auth** (`auth()`, duplicated in both): scrape `auth_key` from `playerCommon.js`, call `auth1` (returns a token + key offset/length), derive `partialkey` via `dd | base64`, call `auth2`. Sets `$authtoken` and `$areaid`, used as HTTP headers for the stream. `$lsid` is a hard-coded session id.
- **Record**: streamlink pulls the HLS playlist (`hls://…`) with `X-Radiko-Authtoken` / `X-Radiko-AreaId` / `Referer` headers into a raw `.aac`.
- **Tag**: ffmpeg remuxes the AAC into an m4a container (`-acodec copy -bsf:a aac_adtstoasc`) and writes `title`/`album`/`artist`/`genre` metadata. AAC tagging is done this way (not by streamlink) on purpose.

`set -e` is on in both scripts. `with_retries <fn>` retries a function up to 10×; it calls the function as `if $cmd` specifically so `set -e` does not abort before the retry check **and** so the called function's body runs with errexit disabled (letting it use `return 1` to signal a retry). Don't change that idiom without understanding this interaction.

Intermediate files live in a per-run working dir `<outdir>/.tmp.<date>.<pid>/`, removed (`rm -rf`) on success and failure.

## Non-obvious behaviors (learned the hard way — preserve these)

- **`--hls-duration` is mandatory, not optional.** radiko's medialist has no `#EXT-X-ENDLIST`, so streamlink treats the stream as live and never stops on its own. Both scripts bound the recording with `--hls-duration` computed from the requested length (live) or program length (timefree, `to − ft`). Removing it causes runaway recordings.
- **Timefree needs `start_at`/`end_at` in the playlist URL.** With only `ft`/`to`, the server returns the *live* stream (segments dated "now"), not the requested program.
- **Use `--hls-duration`, not `--stream-segmented-duration`.** The production environment runs an older streamlink; the newer flag name breaks there even though local streamlink deprecates the old one.
- **Program end time (`to`) comes from the program guide**, fetched per program in `lookup_to` from `https://radiko.jp/v3/program/station/date/<date>/<station>.xml`. radiko's broadcast day runs 05:00–28:59, so a program before 05:00 is listed under the previous calendar day — `broadcast_date` handles this by subtracting 5 hours.
- **The guide endpoint rate-limits with HTTP 200 + a non-guide body**, which looks like "program not found." `lookup_to` validates the response contains `<prog ` and retries with backoff; keep that validation.
- **Write a relative `date` offset as `5 hours ago`, never `-5 hours`.** GNU date reads the `-5` of `"2026-08-01 13:00:00 -5 hours"` as the time zone UTC−05:00, so it returns a day later — and *succeeds*, so the `|| date -j` BSD fallback never runs and nothing looks wrong. This made `broadcast_date` fetch the wrong day's guide on Linux while macOS, which takes the BSD branch, was fine. Any GNU/BSD `date` pair here needs testing on both, since the failure is a wrong answer rather than an error.
- **Premium / area-free uses different hosts.** Timefree switches the playlist host (`tf-f-…`/`type=b` → `tf-c-…`/`type=c`) and sends the login cookie during auth when `-p` is set.
- **Psych reads an unquoted `16:01` as the integer 57660** (YAML 1.1 sexagesimal), and an unquoted `[14:00, 15:00]` is a *syntax error*. Conf files quote their times; `parse_time_of_day` accepts the integer form anyway so an unquoted block-style list still works.
- **`program_times` are resolved backwards from `execution_time`.** A program time later than the execution time belongs to the previous day, which is what makes `"23:00"` recorded at `00:30`, and the `"25:00"` of a late-night program recorded at `02:30`, both land on the right date (`program_time_for`).
- **The scheduler must be idempotent per minute**, since cron fires it every minute and the grace window spans many. `.rec_scheduler.state` keys `<id>|<entry index>|<execution time>` and is written *before* the recording starts; a failed entry is retried on later minutes up to `MAX_ATTEMPTS`, and a `running` entry left behind by a killed process unblocks after `STALE_RUNNING`.

## Conventions

- Quiet by default: streamlink `--loglevel error --progress no`, ffmpeg `-loglevel error`. Successful runs should be near-silent; errors still surface.
- Keep the two scripts' shared `auth()` / `with_retries()` in sync when changing one.
