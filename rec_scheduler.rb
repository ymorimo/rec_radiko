#!/usr/bin/env ruby
# Scheduled timefree recording driver.
#
# Reads per-program YAML files (see conf.sample.yaml) and, for every schedule
# entry that is due, launches rec_radiko_timefree.sh with the program start
# times of that entry. Designed to be run once a minute from cron:
#
#   * * * * * cd /path/to/rec_radiko && RADIKO_OUTDIR=rec ./rec_scheduler.rb >> rec_scheduler.log 2>&1
#
# Entries missed while the machine was asleep are still run, as long as they
# came due within the grace window (--grace, 60 minutes by default); a state
# file keeps every entry from running twice for the same day.

require 'yaml'
require 'json'
require 'optparse'
require 'time'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
RECORDER = File.join(SCRIPT_DIR, 'rec_radiko_timefree.sh')

WDAYS = {
  'sun' => 0, 'sunday' => 0,
  'mon' => 1, 'monday' => 1,
  'tue' => 2, 'tues' => 2, 'tuesday' => 2,
  'wed' => 3, 'weds' => 3, 'wednesday' => 3,
  'thu' => 4, 'thur' => 4, 'thurs' => 4, 'thursday' => 4,
  'fri' => 5, 'friday' => 5,
  'sat' => 6, 'saturday' => 6
}.freeze

MAX_ATTEMPTS = 3

# Retries back off exponentially instead of happening on the next cron minute.
# Most failures come from the program guide endpoint rate-limiting us, and three
# tries in three minutes only make that worse. The wait starts at RETRY_BACKOFF
# and doubles with every attempt, so the retries of a 3-attempt entry fall about
# 5 and 15 minutes after it first came due -- well inside the default grace
# window, which is what lets a retry be seen at all.
RETRY_BACKOFF = 5 * 60

# A recording left in the "running" state for this long is assumed dead.
STALE_RUNNING = 3 * 60 * 60

# How long to wait after `attempts` failed attempts before trying again.
def retry_delay(attempts)
  RETRY_BACKOFF * 2**([attempts, 1].max - 1)
end


# Render a command for display. Shellwords.join backslash-escapes every
# non-ASCII byte, which makes a Japanese program name unreadable.
def command_line(cmd)
  cmd.map { |a| a =~ %r{\A[\w./:@%+=,-]+\z} ? a : "'#{a.gsub("'", %q('\\\\''))}'" }.join(' ')
end

def log(msg)
  puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
  $stdout.flush
end

def warn_log(msg)
  $stderr.puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
  $stderr.flush
end


# A time of day, in minutes since midnight. Hours may exceed 24 (radiko lists
# late-night programs as 25:00 etc.).
#
# YAML gives us either a string ("16:01", when quoted) or an integer (Psych
# reads an unquoted 16:01 as the YAML 1.1 sexagesimal 16*3600+1*60), so both
# forms are accepted.
def parse_time_of_day(value, where)
  case value
  when Integer
    # Sexagesimal seconds, as produced by an unquoted HH:MM.
    raise "#{where}: invalid time #{value}" if value < 0 || value >= 30 * 3600
    value / 60
  when String
    unless value =~ /\A(\d{1,2}):(\d{2})\z/
      raise "#{where}: invalid time #{value.inspect} (expected \"HH:MM\")"
    end
    h = Regexp.last_match(1).to_i
    m = Regexp.last_match(2).to_i
    raise "#{where}: invalid time #{value.inspect}" if m > 59 || h > 29
    h * 60 + m
  else
    raise "#{where}: invalid time #{value.inspect} (expected \"HH:MM\")"
  end
end

def format_time_of_day(minutes)
  format('%02d:%02d', minutes / 60, minutes % 60)
end

# A calendar date, as "YYYY-MM-DD", "YYYYMMDD" or "MM-DD" (the current year).
# "/" works as a separator too.
def parse_date(value)
  y, m, d =
    case value
    when %r{\A(\d{4})[-/](\d{1,2})[-/](\d{1,2})\z}, /\A(\d{4})(\d{2})(\d{2})\z/
      [Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)]
    when %r{\A(\d{1,2})[-/](\d{1,2})\z}
      [Time.now.year, Regexp.last_match(1), Regexp.last_match(2)]
    else
      raise ArgumentError, "invalid date #{value.inspect} (expected \"YYYY-MM-DD\")"
    end
  y, m, d = y.to_i, m.to_i, d.to_i
  t = begin
    Time.new(y, m, d, 0, 0, 0)
  rescue StandardError
    raise ArgumentError, "invalid date #{value.inspect}"
  end
  # Time.new rolls a day past the end of the month over into the next one
  # (February 30th becomes March 2nd), which would silently record the wrong day.
  raise ArgumentError, "invalid date #{value.inspect}" unless [t.year, t.month, t.day] == [y, m, d]
  t
end

# Midnight of t's date, plus `minutes`.
def at_time_of_day(t, minutes)
  Time.new(t.year, t.month, t.day, 0, 0, 0) + minutes * 60
end

# The airing time of a program, relative to the execution time it belongs to.
# A program can only be recorded from timefree after it has ended, so a program
# time that would fall after the execution time belongs to the day before --
# that is what makes 23:00 (recorded at 00:30) and 25:00 (recorded at 02:30)
# both resolve correctly.
def program_time_for(exec_at, minutes)
  t = at_time_of_day(exec_at, minutes)
  t -= 24 * 60 * 60 if t > exec_at
  t
end


class Entry
  attr_reader :conf, :index, :wdays, :program_times, :execution_time, :station

  def initialize(conf, index, wdays, program_times, execution_time, station)
    @conf = conf
    @index = index
    @wdays = wdays
    @program_times = program_times
    @execution_time = execution_time
    @station = station
  end

  def key(exec_at)
    "#{conf.id}|#{index}|#{exec_at.strftime('%Y%m%d%H%M')}"
  end

  # The execution times of this entry that have already come due and are still
  # within the grace window, most recent first.
  def due_at(now, grace_minutes)
    times = []
    # Look back over the whole grace window (at least yesterday, so an entry
    # that came due just before midnight is still seen).
    (0..(grace_minutes / (24 * 60) + 1)).each do |back|
      day = now - back * 24 * 60 * 60
      exec_at = at_time_of_day(day, execution_time)
      next unless wdays.include?(exec_at.wday)
      next if exec_at > now
      next if now - exec_at > grace_minutes * 60
      times << exec_at
    end
    times
  end

  def next_at(now)
    (0..7).each do |ahead|
      day = now + ahead * 24 * 60 * 60
      exec_at = at_time_of_day(day, execution_time)
      return exec_at if wdays.include?(exec_at.wday) && exec_at >= now
    end
    nil
  end

  # This entry's execution time on a given date, or nil if it does not run on
  # that weekday. Note that the date is the date of the *execution*, like
  # `wdays` -- a program airing at 25:00 is executed, and so dated, the day
  # after radiko lists it.
  def at_date(date)
    exec_at = at_time_of_day(date, execution_time)
    wdays.include?(exec_at.wday) ? exec_at : nil
  end

  # The nearest date around `date` on which this entry does run, preferring the
  # past, or nil if it never does. Used to explain an empty --date run.
  def nearest_date(date)
    offset = (1..7).flat_map { |d| [-d, d] }.find { |o| at_date(date + o * 24 * 60 * 60) }
    offset && at_date(date + offset * 24 * 60 * 60)
  end

  def urls(exec_at)
    program_times.map do |m|
      "#{station}/#{program_time_for(exec_at, m).strftime('%Y%m%d%H%M%S')}"
    end
  end

  def description
    days = wdays.sort.map { |w| %w[Sun Mon Tue Wed Thu Fri Sat][w] }.join(',')
    "#{days} #{format_time_of_day(execution_time)} " \
      "#{station} #{program_times.map { |m| format_time_of_day(m) }.join(',')}"
  end
end


class Conf
  attr_reader :path, :id, :title, :author, :area, :station, :entries

  def initialize(path)
    @path = path
    data = YAML.load_file(path)
    raise "#{path}: not a YAML mapping" unless data.is_a?(Hash)

    @id = require_string(data, 'id')
    @title = require_string(data, 'title')
    @author = require_string(data, 'author')
    @area = data['area'] && data['area'].to_s
    @station = data['station'] && data['station'].to_s

    schedule = data['schedule']
    raise "#{path}: schedule is missing or not a list" unless schedule.is_a?(Array)

    @entries = schedule.each_with_index.map do |e, i|
      where = "#{path}: schedule[#{i}]"
      raise "#{where}: not a mapping" unless e.is_a?(Hash)

      wdays = Array(e['wdays'] || e['wday']).map do |w|
        WDAYS[w.to_s.downcase] or raise "#{where}: unknown weekday #{w.inspect}"
      end
      raise "#{where}: wdays is empty" if wdays.empty?

      times = e['program_times']
      raise "#{where}: program_times is missing or not a list" unless times.is_a?(Array) && !times.empty?
      program_times = times.map { |t| parse_time_of_day(t, "#{where}: program_times") }

      raise "#{where}: execution_time is missing" if e['execution_time'].nil?
      execution_time = parse_time_of_day(e['execution_time'], "#{where}: execution_time")
      raise "#{where}: execution_time must be within a day" if execution_time >= 24 * 60

      st = (e['station'] && e['station'].to_s) || @station
      raise "#{where}: no station (set it at the top level or on the entry)" if st.nil? || st.empty?

      Entry.new(self, i, wdays, program_times, execution_time, st)
    end
  end

  private

  def require_string(data, key)
    v = data[key]
    raise "#{path}: #{key} is missing" if v.nil? || v.to_s.empty?
    v.to_s
  end
end


# Remembers which entries have already run, so that a minute-by-minute cron run
# does not start the same recording again during the grace window.
class State
  def initialize(path)
    @path = path
    @data = begin
      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end
    @data = {} unless @data.is_a?(Hash)
  end

  # A recording is not started again once it succeeded, and a failing one is
  # retried only up to MAX_ATTEMPTS times, each retry waiting out its backoff.
  def done?(key)
    v = @data[key]
    return false if v.nil?
    return true if v['status'] == 'ok'
    return true if v['attempts'].to_i >= MAX_ATTEMPTS
    return true if v['status'] == 'failed' && !retry_due?(v)
    # A recording still in flight blocks a second start, unless it is old
    # enough that the process must have died with the state left behind.
    v['status'] == 'running' && !stale?(v)
  end

  # Whether enough time has passed since the failure recorded in `v`. An
  # unreadable timestamp retries right away, as it did before the backoff.
  def retry_due?(v)
    at = Time.parse(v['at'].to_s)
    Time.now - at >= retry_delay(v['attempts'].to_i)
  rescue StandardError
    true
  end

  def stale?(v)
    at = Time.parse(v['at'].to_s)
    Time.now - at > STALE_RUNNING
  rescue StandardError
    true
  end

  # How many times the recording of this key has been started so far.
  def attempts(key)
    (@data[key] || {})['attempts'].to_i
  end

  def start(key)
    v = @data[key] || {}
    @data[key] = {
      'status' => 'running',
      'attempts' => v['attempts'].to_i + 1,
      'at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
    }
  end

  def finish(key, status)
    v = @data[key] || {}
    @data[key] = v.merge('status' => status, 'at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'))
  end

  def save
    merge_disk
    prune
    tmp = "#{@path}.#{Process.pid}"
    File.open(tmp, 'w') { |f| f.write(JSON.pretty_generate(@data)) }
    File.rename(tmp, @path)
  rescue StandardError => e
    warn_log "Couldn't write the state file #{@path}: #{e.message}"
  end

  private

  # A run started a minute later may have finished while we were still
  # recording, so the file on disk can be newer than what we loaded. Keep the
  # more recent record of each key instead of overwriting it.
  def merge_disk
    disk = begin
      JSON.parse(File.read(@path))
    rescue StandardError
      nil
    end
    return unless disk.is_a?(Hash)
    disk.each do |k, v|
      ours = @data[k]
      @data[k] = v if ours.nil? || v['at'].to_s > ours['at'].to_s
    end
  end

  # Keys are "<id>|<index>|<YYYYMMDDHHMM>"; drop anything older than 30 days.
  def prune
    cutoff = (Time.now - 30 * 24 * 60 * 60).strftime('%Y%m%d%H%M')
    @data.delete_if { |k, _| (k.split('|')[2] || '') < cutoff }
  end
end


# The area this machine records from, as reported by radiko (JP13, ...).
# Looked up once, and only when a conf file declares an area.
def current_area
  return @current_area if defined?(@current_area)

  @current_area =
    if ENV['RADIKO_AREA'] && !ENV['RADIKO_AREA'].empty?
      ENV['RADIKO_AREA']
    else
      body = `curl -sf --max-time 10 https://radiko.jp/area 2>/dev/null`
      body =~ /(JP\d+)/ ? Regexp.last_match(1) : nil
    end
end

def have_credentials?
  !ENV['RADIKO_EMAIL'].to_s.empty? && !ENV['RADIKO_PASSWORD'].to_s.empty?
end

# Area-free recording is needed when the program's area is not ours. If the
# area lookup failed we can't tell, so premium is used whenever credentials are
# available -- an area-free recording of a local station still works.
#
# The area is not the only thing that needs a login: timefree only reaches back
# a week without one, however local the station is, so a program older than that
# has to be recorded as premium as well. That case can't be told from the conf
# file, which is why `force` (--premium) exists.
def premium?(conf, force = false)
  if force
    unless have_credentials?
      warn_log "#{conf.id}: --premium was given but RADIKO_EMAIL / RADIKO_PASSWORD " \
               'are unset; the recording will fail'
    end
    return true
  end

  return false if conf.area.nil? || conf.area.empty?
  area = current_area
  if area.nil?
    warn_log "Couldn't determine the current area; " \
             "#{have_credentials? ? 'recording as premium' : 'recording without premium'}"
    return have_credentials?
  end
  return false if area == conf.area

  unless have_credentials?
    warn_log "#{conf.id}: area #{conf.area} is not ours (#{area}) but " \
             'RADIKO_EMAIL / RADIKO_PASSWORD are unset; the recording will fail'
  end
  true
end


# Say what becomes of a failed recording: when the next retry is due, or that
# there will not be one -- `done?` skips it from then on, so without this the
# recording is simply never mentioned again. Only for the automatic path;
# --date and --force ignore the state file and never retry on their own.
def report_failure(state, job, grace_minutes)
  attempts = state.attempts(job[:key])
  scheduled = job[:exec_at].strftime('%Y-%m-%d %H:%M')
  give_up = lambda do |why|
    warn_log "Giving up on #{job[:conf].id} (scheduled #{scheduled}) #{why}; " \
             "to record it by hand: #{command_line(job[:cmd])}"
  end

  return give_up.call("after #{MAX_ATTEMPTS} attempts") if attempts >= MAX_ATTEMPTS

  delay = retry_delay(attempts)
  # A retry only happens while the entry is still within the grace window, so a
  # backoff that reaches past it is the end of the road too.
  if Time.now + delay > job[:exec_at] + grace_minutes * 60
    return give_up.call("after #{attempts} attempt#{attempts == 1 ? '' : 's'}: the next retry " \
                        "would fall outside the #{grace_minutes} minute grace window")
  end

  warn_log "Retrying #{job[:conf].id} (scheduled #{scheduled}) in about #{delay / 60} minutes " \
           "(attempt #{attempts + 1} of #{MAX_ATTEMPTS})"
end


def collect_conf_paths(args)
  paths = []
  args.each do |arg|
    if File.directory?(arg)
      paths.concat(Dir.glob(File.join(arg, '*.{yaml,yml}')).sort)
    elsif File.exist?(arg)
      paths << arg
    else
      warn_log "No such conf file or directory: #{arg}"
      exit 1
    end
  end
  paths
end

def load_confs(paths)
  paths.map do |p|
    begin
      Conf.new(p)
    rescue StandardError => e
      warn_log "Skipping #{p}: #{e.message}"
      nil
    end
  end.compact
end


#
# main
#
options = { grace: 60, dry_run: false, list: false, force: false, premium: false, date: nil, now: nil }

parser = OptionParser.new do |o|
  o.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] [conf ...]"
  o.separator ''
  o.separator '  conf: YAML file, or a directory of *.yaml files (default: ./conf)'
  o.separator ''
  o.on('-n', '--dry-run', 'Print the recording commands instead of running them') { options[:dry_run] = true }
  o.on('-l', '--list', 'List every schedule entry and its next execution') { options[:list] = true }
  o.on('-g', '--grace MINUTES', Integer,
       'Also run entries that came due up to MINUTES ago (default: 60)') { |v| options[:grace] = v }
  o.on('-t', '--time TIME', 'Pretend the current time is TIME ("YYYY-mm-dd HH:MM"), for testing') do |v|
    options[:now] = Time.parse(v)
  end
  o.on('-f', '--force', 'Run due entries even if the state file says they already ran') { options[:force] = true }
  o.on('-d', '--date DATE',
       'Record the execution of DATE ("YYYY-MM-DD") instead of what is due now') do |v|
    options[:date] = parse_date(v)
  end
  o.on('-p', '--premium',
       'Log in for every recording, as a program older than a week needs') { options[:premium] = true }
  o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError, ArgumentError => e
  warn_log e.message
  exit 1
end

args = ARGV.empty? ? [File.join(SCRIPT_DIR, 'conf')] : ARGV
if ARGV.empty? && !File.directory?(args.first)
  warn_log "No conf directory at #{args.first}; pass a YAML file or a directory instead."
  exit 1
end

confs = load_confs(collect_conf_paths(args))
if confs.empty?
  warn_log 'No usable conf files.'
  exit 1
end

# Truncate to the minute: cron fires at second 0, but a delayed start should
# still match the minute it was scheduled for.
now = options[:now] || Time.now
now = Time.new(now.year, now.month, now.day, now.hour, now.min, 0)

if options[:list]
  confs.each do |conf|
    puts "#{conf.path}  (#{conf.id}: #{conf.title} / #{conf.author}#{conf.area ? ", #{conf.area}" : ''})"
    conf.entries.each do |entry|
      nxt = entry.next_at(now)
      puts "  #{entry.description}"
      puts "    next: #{nxt ? nxt.strftime('%Y-%m-%d (%a) %H:%M') : 'never'}" \
           "#{nxt ? "  ->  #{entry.urls(nxt).join(' ')}" : ''}"
    end
  end
  exit 0
end

state = State.new(ENV['RADIKO_STATE'] || File.join(SCRIPT_DIR, '.rec_scheduler.state'))

# Collect everything that is due, then start the recordings in parallel.
jobs = []
confs.each do |conf|
  conf.entries.each do |entry|
    exec_ats =
      if options[:date]
        [entry.at_date(options[:date])].compact
      else
        entry.due_at(now, options[:grace])
      end
    exec_ats.each do |exec_at|
      key = entry.key(exec_at)
      # An explicitly requested date is always recorded; the state file only
      # guards the automatic, minute-by-minute runs.
      next if !options[:date] && !options[:force] && state.done?(key)

      cmd = [RECORDER]
      cmd << '-p' if premium?(conf, options[:premium])
      cmd += [conf.title, conf.author, conf.id]
      cmd += entry.urls(exec_at)
      jobs << { key: key, conf: conf, exec_at: exec_at, cmd: cmd }
    end
  end
end

if jobs.empty?
  # A cron run with nothing due is the normal case and stays quiet, but an
  # explicit date that matches nothing is a mistake worth explaining -- most
  # likely a late-night program, whose execution falls on the day after the one
  # radiko lists it under.
  if options[:date]
    warn_log "Nothing scheduled on #{options[:date].strftime('%Y-%m-%d (%a)')}:"
    confs.each do |conf|
      conf.entries.each do |entry|
        nearest = entry.nearest_date(options[:date])
        warn_log "  #{conf.id}: #{entry.description}" \
                 "#{nearest ? "  (nearest: #{nearest.strftime('%Y-%m-%d (%a)')})" : ''}"
      end
    end
    exit 1
  end
  exit 0
end

if options[:dry_run]
  jobs.each { |job| puts command_line(job[:cmd]) }
  exit 0
end

# --date and --force bypass the state file, so nothing is retried or given up on
# for them; only the plain cron path has a next attempt to report.
automatic = !options[:date] && !options[:force]

pids = {}
jobs.each do |job|
  log "Running #{job[:conf].id} (scheduled #{job[:exec_at].strftime('%Y-%m-%d %H:%M')}): " \
      "#{command_line(job[:cmd])}"
  begin
    pid = Process.spawn(*job[:cmd], chdir: SCRIPT_DIR)
  rescue StandardError => e
    warn_log "Couldn't start #{job[:conf].id}: #{e.message}"
    state.start(job[:key])
    state.finish(job[:key], 'failed')
    report_failure(state, job, options[:grace]) if automatic
    next
  end
  pids[pid] = job
end

# Mark the started jobs right away, so the next cron minute doesn't start them
# again while they are still recording.
pids.each_value { |job| state.start(job[:key]) }
state.save

failed = false
pids.each do |pid, job|
  _, status = Process.waitpid2(pid)
  if status.success?
    state.finish(job[:key], 'ok')
    log "Finished #{job[:conf].id}"
  else
    state.finish(job[:key], 'failed')
    warn_log "Recording #{job[:conf].id} failed (exit #{status.exitstatus})"
    report_failure(state, job, options[:grace]) if automatic
    failed = true
  end
end
state.save

exit(failed ? 1 : 0)

# Local Variables:
# ruby-indent-level: 2
# End:
