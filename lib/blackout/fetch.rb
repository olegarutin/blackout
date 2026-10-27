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
     .gsub('&nbsp;', ' ').gsub('&lt;', '<').gsub('&gt;', '>')
     .gsub('&quot;', '"').gsub('&apos;', "'").gsub('&amp;', '&')
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
  primary = rows && as_schedule(rows)
  primary = nil unless primary && valid_schedule?(primary)

  github, status = fetch_from_github(region)

  # Three candidates, one rule: whichever was published last. The
  # operator's own site usually wins — it is where the others read from
  # — but only on the timestamp, so a broken scrape cannot promote
  # itself past a mirror that is actually newer.
  found = [[primary, :fresh], [github, status], [fetch_operator(region), :fresh]]
          .select { |doc, _| doc }
  return [nil, :error] if found.empty?

  found.max_by { |doc, _| published_at(doc) || Time.at(0) }
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

# When the operator last revised this region's schedule, according to
# the aggregator's public page. Used only to compare against what the
# mirror holds — never as schedule data.
def fetch_revision(slug)
  return nil unless slug

  ensure_dir(CACHE)
  path = File.join(CACHE, "rev-#{slug}.txt")

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA
    cached = File.read(path, encoding: 'UTF-8').strip
    return cached.empty? ? nil : Time.parse(cached)
  end

  body, = http_get(format(REGION_PAGE, slug))
  at = page_revised_at(body)
  atomic_write(path, at ? at.iso8601 : '')
  at
rescue StandardError
  nil
end

# The operator's own schedule posts, for the regions that publish them.
# nil whenever anything is missing: the mirrors remain the floor.
def fetch_operator(region)
  base = OPERATOR_POSTS[region]
  return nil unless base

  ensure_dir(CACHE)
  path = File.join(CACHE, "op-#{region}.json")
  return read_schedule(path) if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA

  list = JSON.parse(http_get("#{base}/main?lang=uk&limit=200").first)
  days, published = operator_days(base, newest_schedule_posts(list['data']))

  doc = as_operator_schedule(days, published)
  return nil unless doc && valid_schedule?(doc)

  atomic_write(path, JSON.generate(doc))
  doc
rescue StandardError
  read_schedule(path)
end

# Each day's post fetched and parsed, with the latest publication time.
def operator_days(base, posts)
  days = {}
  published = nil
  posts.each do |date, (slug, at)|
    body = JSON.parse(http_get("#{base}/#{slug}?lang=uk").first)
    queues = parse_outage_text(html_to_text(body.dig('data', 'content')))
    next if queues.empty?

    days[date] = queues
    published = at if published.nil? || at > published
  end
  [days, published]
end

# The newest post per day whose title announces a schedule.
def newest_schedule_posts(items)
  return {} unless items.is_a?(Array)

  today = Date.today
  items.first(500).each_with_object({}) do |item, acc|
    next unless item.is_a?(Hash)

    slug = item['slug'].to_s
    next unless item['title'].to_s[0, 300].match?(/графік\w{0,2}\s+погодинних\s+відключень/i)
    next unless slug.match?(/\A[a-z0-9-]{1,200}\z/)

    date = title_date(item['title'].to_s[0, 300], today)
    next unless date && (date - today).to_i.between?(0, 1)

    at = begin
      Time.parse(item['publishedAt'].to_s)
    rescue StandardError
      nil
    end
    acc[date] = [slug, at] if at && (acc[date].nil? || at > acc[date][1])
  end
end

def html_to_text(html)
  unescape_xml(html.to_s.gsub(%r{<br\s*/?>}, "\n").gsub(%r{</p>}, "\n").gsub(/<[^>]+>/, '')).to_s
end
