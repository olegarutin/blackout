# frozen_string_literal: true

# Restriction level for our oblast, or nil when there is no data.
def fetch_energy
  ensure_dir(CACHE)
  path = File.join(CACHE, 'energy.json')

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_ALERT
    cached = read_cache(path)
    return cached if cached
  end

  body, etag = http_get(ENERGY, read_etag(path))

  if body.nil?
    touch_cache(path)
    return read_cache(path)
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Array)

  atomic_write(path, body)
  write_etag(path, etag)
  parsed
rescue StandardError
  recent_cache(path, ENERGY_MAX_AGE)
end

# A cache this old is no longer evidence about now.
def recent_cache(path, max_age)
  return nil unless File.exist?(path) && (Time.now - File.mtime(path)) < max_age

  read_cache(path)
end

def unescape_xml(str)
  return nil unless str

  str.gsub(/&#(\d{1,6});/) { Integer(Regexp.last_match(1)).chr(Encoding::UTF_8) }
     .gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"')
     .gsub('&apos;', "'").gsub('&amp;', '&')
rescue StandardError
  str
end

# Schedules from the primary source. nil hands the job to the mirror.
def fetch_shutdowns(slug)
  return nil unless slug

  ensure_dir(CACHE)
  path = File.join(CACHE, "sd-#{slug}.json")

  # A fresh cache is the final answer even when empty: otherwise every
  # run would go to the network to be told there is nothing
  return cached_rows(path) if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA

  body, etag = http_get(format(SHUTDOWNS, slug), read_etag(path))

  if body.nil?
    touch_cache(path)
    return cached_rows(path)
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless valid_rows?(parsed)

  atomic_write(path, body)
  write_etag(path, etag)
  parsed.empty? ? nil : parsed
rescue StandardError
  cached_rows(path)
end

def cached_rows(path)
  rows = read_cache(path)
  rows.nil? || rows.empty? || !valid_rows?(rows) ? nil : rows
end

# Sources disagree, and it is not always the mirror that is wrong. On
# 18 October the utility rewrote the schedule at 10:01 and the mirror had
# it, while the primary source still served yesterday's revision — fresh
# looking, because it had just been re-polled. The app said "power on"
# while there was none. So read both and take whichever was published
# later; files months out of date lose that comparison on their own.
def fetch_data(region)
  rows = fetch_shutdowns(REGIONS.dig(region, 4))
  built = rows && as_schedule(rows)
  built = nil unless built && valid_schedule?(built)

  github, status = fetch_from_github(region)

  return [built, :fresh] if github.nil?
  return [github, status] if built.nil?

  mine = published_at(built)
  theirs = published_at(github)
  theirs && (mine.nil? || theirs > mine) ? [github, status] : [built, :fresh]
end

def fetch_from_github(region)
  ensure_dir(CACHE)
  path = File.join(CACHE, "#{region}.json")

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA
    cached = read_schedule(path)
    return [cached, :cache] if cached
  end

  body, etag = http_get("#{SRC[REGIONS.dig(region, 1)] || OE_SRC}/#{region}.json",
                        read_etag(path))

  # 304: same data, only push out the next check
  if body.nil?
    touch_cache(path)
    return [read_schedule(path), :cache]
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless valid_schedule?(parsed)

  atomic_write(path, body)
  write_etag(path, etag)
  [parsed, :fresh]
rescue StandardError
  # Nothing fresh arrived, or it failed validation — use the last known
  old = read_schedule(path)
  old ? [old, :stale] : [nil, :error]
end

# The operator's latest system-state notice, straight from the source.
def fetch_grid
  ensure_dir(CACHE)
  path = File.join(CACHE, 'grid.json')

  return read_cache(path) if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_NEWS

  body, etag = http_get(UKRENERGO, read_etag(path))

  if body.nil?
    touch_cache(path)
    return read_cache(path)
  end

  posts = telegram_posts(body)
  raise 'no posts' if posts.empty?

  latest = posts.last
  atomic_write(path, JSON.generate(latest))
  write_etag(path, etag)
  latest
rescue StandardError
  recent_cache(path, GRID_MAX_AGE)
end
