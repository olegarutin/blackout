#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Blackout</xbar.title>
# <xbar.version>v2.0</xbar.version>
# <xbar.author>Oleg Arutin</xbar.author>
# <xbar.desc>Графік погодинних відключень: стан, відлік і сповіщення про зміни</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'digest'
require 'date'

# Без змінних локалі Ruby читає файли як US-ASCII, і кирилиця ламає розбір.
# Лише default_external: default_internal змусив би Ruby перекодовувати
# при записі, а Net::HTTP віддає тіло бінарним — запис падав би,
# лишаючи порожній файл у кеші.
Encoding.default_external = Encoding::UTF_8
require 'time'

# Шлях до себе підставляється в bash= пунктів меню. Якщо застосунок
# лежить у теці з пробілом, без лапок решта шляху стане окремими
# параметрами SwiftBar і меню зламається.
SELF = File.expand_path(__FILE__)

OE_SRC = 'https://raw.githubusercontent.com/yaroslav2901/OE_OUTAGE_DATA/main/data'
BK_SRC = 'https://raw.githubusercontent.com/Baskerville42/outage-data-ua/main/data'
ALERTS = 'https://vadimklimenko.com/map/statuses.json'
# Рівень обмежень по областях: 0 — немає даних чи відключень,
# 2 — погодинні графіки, 3 — аварійні. Саме звідси беремо «аварійні»,
# бо в самих графіках такої ознаки немає.
ENERGY = 'https://alerts.energy/api/v1/source-registry/areas/overview'
# Головна новина енергосистеми від Укренерго — пояснює, ЧОМУ відключають.
# Графік каже «коли», а це «через що»: атака, дефіцит, ремонт.
NOTICE = 'https://alerts.energy/api/v1/notices'
# Основне джерело графіків: свіжіше за GitHub-репозиторії й з явними
# статусами замість здогадок. Репозиторії лишаються запасним варіантом.
SHUTDOWNS = 'https://alerts.energy/api/v1/source-registry/areas/%s/shutdowns'
TTL_NEWS = 600 # новини не міняються щохвилини
CACHE  = File.join(Dir.home, '.cache', 'blackout')
CONFIG = File.join(Dir.home, '.config', 'blackout.json')
STATE  = File.join(CACHE, 'state.json')
# Джерело графіків оновлюється раз на 5 хв — частіше за нього не дізнаємось.
# Тривоги важливіші за часом, тож перевіряємо щохвилини.
TTL_DATA  = 170
TTL_ALERT = 55

REGIONS = {
  # id => [назва, запасне джерело, область, сайт, слаг alerts.energy]
  'Prykarpattiaoblenerho'    => ['Івано-Франківська', :oe, 'Івано-Франківська область', 'https://www.oe.if.ua/', 'ivano-frankivska-oblast'],
  'avtonomna-respublika-krym' => ['АР Крим', nil, 'Автономна Республіка Крим', 'https://alerts.energy/avtonomna-respublika-krym', 'avtonomna-respublika-krym'],
  'volynska-oblast'          => ['Волинська обл.', nil, 'Волинська область', 'https://alerts.energy/volynska-oblast', 'volynska-oblast'],
  'vinnytska-oblast'         => ['Вінницька обл.', nil, 'Вінницька область', 'https://alerts.energy/vinnytska-oblast', 'vinnytska-oblast'],
  'dnipro'                   => ['Дніпро та обл.', :bk, 'Дніпропетровська область', 'https://www.dtek-dnem.com.ua/ua/shutdowns', 'dnipropetrovska-oblast'],
  'donetska-oblast'          => ['Донецька обл.', nil, 'Донецька область', 'https://alerts.energy/donetska-oblast', 'donetska-oblast'],
  'Zhytomyroblenergo'        => ['Житомирська обл.', :oe, 'Житомирська область', 'https://www.ztoe.com.ua/unhooking-search.php', 'zhytomyrska-oblast'],
  'Zakarpattiaoblenerho'     => ['Закарпатська обл.', :oe, 'Закарпатська область', 'https://www.zakarpat.energy/', 'zakarpatska-oblast'],
  'Zaporizhzhiaoblenergo'    => ['Запорізька обл.', :oe, 'Запорізька область', 'https://www.zoe.com.ua/', 'zaporizka-oblast'],
  'kyiv-region'              => ['Київська обл.', :bk, 'Київська область', 'https://www.dtek-krem.com.ua/ua/shutdowns', 'kyivska-oblast'],
  'kirovogradska-oblast'     => ['Кіровоградська обл.', nil, 'Кіровоградська область', 'https://alerts.energy/kirovogradska-oblast', 'kirovogradska-oblast'],
  'luganska-oblast'          => ['Луганська обл.', nil, 'Луганська область', 'https://alerts.energy/luganska-oblast', 'luganska-oblast'],
  'Lvivoblenerho'            => ['Львівська обл.', :oe, 'Львівська область', 'https://loe.lviv.ua/', 'lvivska-oblast'],
  'mikolayivska-oblast'      => ['Миколаївська обл.', nil, 'Миколаївська область', 'https://alerts.energy/mikolayivska-oblast', 'mikolayivska-oblast'],
  'odesa'                    => ['Одеса та обл.', :bk, 'Одеська область', 'https://www.dtek-oem.com.ua/ua/shutdowns', 'odeska-oblast'],
  'Poltavaoblenergo'         => ['Полтавська обл.', :oe, 'Полтавська область', 'https://www.poe.pl.ua/', 'poltavska-oblast'],
  'Rivneoblenergo'           => ['Рівненська обл.', :oe, 'Рівненська область', 'https://www.roe.vsei.ua/', 'rivnenska-oblast'],
  'sumska-oblast'            => ['Сумська обл.', nil, 'Сумська область', 'https://alerts.energy/sumska-oblast', 'sumska-oblast'],
  'Ternopiloblenerho'        => ['Тернопільська обл.', :oe, 'Тернопільська область', 'https://www.toe.com.ua/', 'ternopilska-oblast'],
  'Kharkivoblenerho'         => ['Харківська обл.', :oe, 'Харківська область', 'https://www.hoe.com.ua/', 'kharkivska-oblast'],
  'khersonska-oblast'        => ['Херсонська обл.', nil, 'Херсонська область', 'https://alerts.energy/khersonska-oblast', 'khersonska-oblast'],
  'Khmelnytskoblenerho'      => ['Хмельницька обл.', :oe, 'Хмельницька область', 'https://www.hoe.com.ua/', 'khmelnytska-oblast'],
  'Cherkasyoblenergo'        => ['Черкаська обл.', :oe, 'Черкаська область', 'https://www.cherkasyoblenergo.com/static/perelik-gpv', 'cherkaska-oblast'],
  'chernivecka-oblast'       => ['Чернівецька обл.', nil, 'Чернівецька область', 'https://alerts.energy/chernivecka-oblast', 'chernivecka-oblast'],
  'Chernihivoblenergo'       => ['Чернігівська обл.', :oe, 'Чернігівська область', 'https://www.chernihiv.energy/', 'chernigivska-oblast'],
  'kyiv'                     => ['Київ', :bk, 'м. Київ', 'https://kyiv.yasno.com.ua/schedule-turn-off-electricity', 'kyiv']
}.freeze

SRC = { oe: OE_SRC, bk: BK_SRC }.freeze

# ── Конфіг ──────────────────────────────────────────────────────────

def load_config
  File.exist?(CONFIG) ? JSON.parse(File.read(CONFIG, encoding: 'UTF-8')) : {}
rescue StandardError
  {}
end

def save_config(cfg)
  FileUtils.mkdir_p(File.dirname(CONFIG))
  File.write(CONFIG, JSON.pretty_generate(cfg))
end

cfg = load_config

case ARGV[0]
when '--set'
  exit unless REGIONS.key?(ARGV[1]) && ARGV[2].to_s.match?(/\AGPV\d{1,3}\.\d{1,2}\z/)

  cfg['region'] = ARGV[1]
  cfg['queue']  = ARGV[2]
  save_config(cfg)
  exit
when '--warn'
  cfg['warn_minutes'] = ARGV[1].to_i.clamp(1, 720)
  save_config(cfg)
  exit
when '--notify'
  cfg['notify'] = (ARGV[1] == 'on')
  save_config(cfg)
  exit
when '--alerts'
  cfg['alerts'] = (ARGV[1] == 'on')
  save_config(cfg)
  exit
when '--district'
  # Порожнє значення означає «вся область». Назва району приходить
  # із меню, побудованого з даних мережі, тож перевіряємо форму.
  d = ARGV[1].to_s
  exit unless d.empty? || d.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/)

  cfg['district'] = d.empty? ? nil : d
  save_config(cfg)
  exit
end

# Регіон стає частиною URL і шляху до кешу, тож приймаємо лише відомі ключі.
# Чергу — лише за суворим шаблоном: вона потрапляє у текст меню,
# а SwiftBar читає '|' як початок параметрів.
raw_region = ENV['BLACKOUT_REGION'] || cfg['region'] || 'Cherkasyoblenergo'
raw_queue  = ENV['BLACKOUT_QUEUE']  || cfg['queue']  || 'GPV1.1'

REGION = REGIONS.key?(raw_region) ? raw_region : 'Cherkasyoblenergo'
QUEUE  = raw_queue.to_s.match?(/\AGPV\d{1,3}\.\d{1,2}\z/) ? raw_queue : 'GPV1.1'
WARN   = (cfg['warn_minutes'] || 15).to_i
NOTIFY = cfg.fetch('notify', true)
ALERTS_ON = cfg.fetch('alerts', true)
# Назва району приходила з меню, яке будується з даних мережі,
# тож перевіряємо форму, перш ніж довіряти
raw_district = ENV['BLACKOUT_DISTRICT'] || cfg['district']
DISTRICT = raw_district.to_s.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/) ? raw_district : nil

# ── Дані ────────────────────────────────────────────────────────────

# Значення годин, які документує джерело (preset.time_type).
# 'maybe*' зараз у даних не трапляються, але закладені у формат —
# без них валідатор відкинув би валідний файл цілком.
HOUR_VALUES = %w[yes no first second maybe mfirst msecond].freeze

MAX_BODY  = 2 * 1024 * 1024 # 2 МБ — реальні файли важать 15–300 КБ
OPEN_TIME = 5               # секунд на встановлення з'єднання
READ_TIME = 8               # секунд на читання відповіді

# Net::HTTP.get не має таймаутів: зависле з'єднання тримало б процес вічно,
# а SwiftBar щохвилини запускає новий. Тому власний виклик із обмеженнями.
# Умовний запит: якщо дані не змінились, сервер відповідає 304 без тіла.
# Київський файл важить 300 КБ, тож це різниця між 475 МБ і кількома МБ на добу.
# Повертає [тіло або nil, новий etag].
def http_get(url, etag = nil)
  uri = URI(url)
  raise "refusing non-https url: #{uri.scheme}" unless uri.scheme == 'https'

  Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                      open_timeout: OPEN_TIME,
                                      read_timeout: READ_TIME) do |http|
    req = Net::HTTP::Get.new(uri.request_uri)
    req['If-None-Match'] = etag if etag
    res = http.request(req)

    return [nil, etag] if res.is_a?(Net::HTTPNotModified)
    raise "http #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    raise 'response too large' if res.body.bytesize > MAX_BODY

    # Net::HTTP віддає ASCII-8BIT; позначаємо як UTF-8, щоб запис
    # у кеш і розбір JSON працювали передбачувано
    [res.body.dup.force_encoding(Encoding::UTF_8), res['etag']]
  end
end

# Рівень обмежень для нашої області. nil — якщо даних немає.
def fetch_energy
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, 'energy.json')

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_ALERT
    cached = read_cache(path)
    return cached if cached
  end

  body, etag = http_get(ENERGY, read_etag(path))

  if body.nil?
    FileUtils.touch(path)
    return read_cache(path)
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Array)

  File.write(path, body)
  write_etag(path, etag)
  parsed
rescue StandardError
  File.exist?(path) ? read_cache(path) : nil
end

# Головна новина енергосистеми. nil, якщо її немає.
def fetch_notice
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, 'notice.json')

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_NEWS
    cached = read_cache(path)
    return cached&.dig('breaking')
  end

  body, etag = http_get(NOTICE, read_etag(path))

  if body.nil?
    FileUtils.touch(path)
    return read_cache(path)&.dig('breaking')
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Hash)

  File.write(path, body)
  write_etag(path, etag)
  parsed['breaking']
rescue StandardError
  File.exist?(path) ? read_cache(path)&.dig('breaking') : nil
end

# Графіки з alerts.energy. Повертає nil, якщо даних немає — тоді
# працює запасне джерело.
def fetch_shutdowns(slug)
  return nil unless slug

  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, "sd-#{slug}.json")

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA
    cached = read_cache(path)
    return cached.nil? || cached.empty? ? nil : cached
  end

  body, etag = http_get(format(SHUTDOWNS, slug), read_etag(path))

  if body.nil?
    FileUtils.touch(path)
    cached = read_cache(path)
    return cached.nil? || cached.empty? ? nil : cached
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Array)
  raise 'bad rows' unless parsed.all? { |r| r.is_a?(Hash) && r['queue'].to_s.match?(/\A\d{1,3}\.\d{1,2}\z/) }

  File.write(path, body)
  write_etag(path, etag)
  parsed.empty? ? nil : parsed
rescue StandardError
  cached = File.exist?(path) ? read_cache(path) : nil
  cached.nil? || cached.empty? ? nil : cached
end

# Рядок потрібної черги у форматі, який розуміє решта коду.
# У джерелі 1 — відключення, тож інвертуємо: у нас true означає «світло є».
def schedule_from(rows, queue)
  num = queue.sub('GPV', '')
  row = rows.find { |r| r['queue'] == num && r['initiator'].to_s.include?('oblenergo') } ||
        rows.find { |r| r['queue'] == num }
  return nil unless row

  hours = lambda do |key|
    a = row[key]
    a.is_a?(Array) && a.size == 24 ? a.map { |v| v.to_i.zero? } : nil
  end

  { today: hours.call('today'), tomorrow: hours.call('tomorrow'),
    today_status: row['todayStatus'], tomorrow_status: row['tomorrowStatus'],
    date: row['todayDate'], checked: row['todayCheckedAt'] }
end

# ETag має сенс лише тоді, коли сам кеш читається. Інакше сервер
# відповідатиме 304 на порожній або зіпсований файл, і дані вже
# ніколи не завантажаться — тихо й назавжди.
def read_etag(path)
  return nil unless File.exist?("#{path}.etag")
  return nil unless read_cache(path)

  File.read("#{path}.etag")
rescue StandardError
  nil
end

def write_etag(path, etag)
  etag ? File.write("#{path}.etag", etag) : FileUtils.rm_f("#{path}.etag")
rescue StandardError
  nil
end

# Читання кешу теж може впасти на пошкодженому файлі
def read_cache(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue StandardError
  nil
end

# Дані приходять із чужого репозиторію. Приймаємо лише те, що розуміємо:
# невідома структура — краще сказати про це, ніж показати сміття як графік.
def valid_schedule?(doc)
  return false unless doc.is_a?(Hash)

  days = doc.dig('fact', 'data')
  return true if days.nil? || (days.respond_to?(:empty?) && days.empty?)
  return false unless days.is_a?(Hash)

  days.all? do |day, groups|
    next false unless day.to_s.match?(/\A\d{9,11}\z/) && groups.is_a?(Hash)

    groups.all? do |name, hours|
      name.match?(/\AGPV\d{1,3}\.\d{1,2}\z/) &&
        hours.is_a?(Hash) &&
        hours.keys.all? { |h| (1..24).cover?(h.to_i) } &&
        hours.values.all? { |v| HOUR_VALUES.include?(v) }
    end
  end
end

# Перетворює рядки alerts.energy у той самий формат, що й GitHub-джерела,
# щоб решта коду не знала, звідки прийшли дані.
def as_schedule(rows)
  # На одну чергу буває кілька постачальників (обленерго і, скажімо,
  # залізниця) з різними графіками. Беремо обленерго — він стосується
  # переважної більшості споживачів.
  rows = rows.group_by { |r| r['queue'] }.map do |_, same|
    same.find { |r| r['initiator'].to_s.include?('oblenergo') } || same.first
  end

  days = {}
  update = nil

  %w[today tomorrow].each do |slot|
    date = rows.map { |r| r["#{slot}Date"] }.compact.first
    next unless date

    ts = Date.parse(date).to_time.to_i
    group = {}
    rows.each do |r|
      hrs = r[slot]
      next unless hrs.is_a?(Array) && hrs.size == 24

      maybe = r["#{slot}Possible"]
      maybe = [] unless maybe.is_a?(Array)
      group["GPV#{r['queue']}"] = (0..23).to_h do |i|
        v = if hrs[i].to_i == 1 then 'no'
            elsif maybe[i].to_i == 1 then 'maybe'
            else 'yes'
            end
        [(i + 1).to_s, v]
      end
    end
    # NoShutdowns — відключень немає, порожні години означають «світло весь день»
    if group.empty? && rows.any? { |r| r["#{slot}Status"] == 'NoShutdowns' }
      rows.each { |r| group["GPV#{r['queue']}"] = (1..24).to_h { |h| [h.to_s, 'yes'] } }
    end
    days[ts.to_s] = group unless group.empty?
    update ||= rows.map { |r| r['todayCheckedAt'] }.compact.max
  end

  return nil if days.empty?

  today_ts = rows.map { |r| r['todayDate'] }.compact.first
  { 'lastUpdated' => update,
    'fact' => { 'data' => days,
                'update' => update,
                'today' => today_ts ? Date.parse(today_ts).to_time.to_i : days.keys.min.to_i } }
end

def fetch_data(region)
  # Спершу alerts.energy: свіжіше й з явними статусами
  rows = fetch_shutdowns(REGIONS.dig(region, 4))
  if rows && (built = as_schedule(rows)) && valid_schedule?(built)
    return [built, :fresh]
  end

  fetch_from_github(region)
end

def fetch_from_github(region)
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, "#{region}.json")

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_DATA
    cached = read_cache(path)
    return [cached, :cache] if cached
  end

  body, etag = http_get("#{SRC[REGIONS.dig(region, 1)] || OE_SRC}/#{region}.json",
                        read_etag(path))

  # 304 — дані ті самі, лише відсуваємо час наступної перевірки
  if body.nil?
    FileUtils.touch(path)
    return [read_cache(path), :cache]
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless valid_schedule?(parsed)

  File.write(path, body)
  write_etag(path, etag)
  [parsed, :fresh]
rescue StandardError
  # Свіжі дані не прийшли або не пройшли перевірку — останні відомі
  old = File.exist?(path) ? read_cache(path) : nil
  old ? [old, :stale] : [nil, :error]
end

# Година N у джерелі = інтервал [N-1, N)
def hours_for(data, queue, day_key)
  raw = data.dig('fact', 'data', day_key, queue)
  return nil unless raw

  # Світло є лише при 'yes'. Усе інше — відключення повне, часткове
  # або ймовірне; усі ці випадки трактуємо як «світла не буде»,
  # бо помилитись у цей бік безпечніше.
  (1..24).map { |h| raw[h.to_s] == 'yes' }
end

def segments(hours)
  hours.each_with_index.chunk_while { |(a, _), (b, _)| a == b }
       .map { |chunk| [chunk.first[1], chunk.last[1] + 1, chunk.first[0]] }
end

def minutes_until_change(today, tomorrow, now)
  idx = now.hour
  state = today[idx]
  elapsed = (now.hour * 60) + now.min

  ((idx + 1)..23).each { |h| return (h * 60) - elapsed if today[h] != state }
  return nil unless tomorrow

  (0..23).each do |h|
    return ((24 * 60) - elapsed) + (h * 60) if tomorrow[h] != state
  end
  nil
end

# SwiftBar розділяє текст і параметри символом '|' —
# чистимо все, що прийшло з мережі, щоб воно не могло підмінити атрибути
def safe(str)
  str.to_s.delete('|').strip
end

# Значення параметра SwiftBar (href=, bash= тощо) не може містити пробілів —
# інакше решта рядка стає окремими параметрами. Для даних із мережі
# повертаємо nil, якщо вони не схожі на безпечний фрагмент URL.
def url_part(str)
  v = str.to_s
  v.match?(%r{\A[\w.~-]{1,120}\z}) ? v : nil
end

# Джерела віддають час по-різному: alerts.energy — ISO в UTC,
# репозиторії — вже відформатований рядок. Зводимо до місцевого часу.
def fmt_updated(str)
  v = safe(str)
  return v unless v.match?(/\A\d{4}-\d{2}-\d{2}T/)

  Time.parse(v).localtime.strftime('%d.%m %H:%M')
rescue StandardError
  v
end

def fmt(minutes)
  format('%d:%02d', minutes / 60, minutes % 60)
end

# ── Повітряна тривога ───────────────────────────────────────────────

def fetch_alerts
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, 'alerts.json')

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_ALERT
    cached = read_cache(path)
    return cached if cached
  end

  body, etag = http_get(ALERTS, read_etag(path))

  if body.nil?
    FileUtils.touch(path)
    return read_cache(path)
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Hash) && parsed['states'].is_a?(Hash)

  File.write(path, body)
  write_etag(path, etag)
  parsed
rescue StandardError
  File.exist?(path) ? read_cache(path) : nil
end

# Префікс у menu bar: 🔴 ракети · 🟡 дрони · '' якщо тихо
def siren_prefix(alert)
  return '' unless alert

  # Рівень може бути відсутній — документація alerts.in.ua каже
  # трактувати таку тривогу як червону, а не ховати її
  alert[:level] == 'yellow' ? '🟡 ' : '🔴 '
end

# Перелік районів області для меню вибору
def alert_districts(oblast)
  return nil unless oblast

  st = (fetch_alerts || {}).dig('states', oblast)
  names = ((st && st['districts']) || {}).keys
  names.empty? ? nil : names.sort
end

def render_alert(alert)
  unless alert
    if ALERTS_ON && REGIONS.dig(REGION, 2)
      puts '---'
      puts '🟢 Тривоги немає | color=green size=12'
    end
    return
  end

  puts '---'
  label, colour = case alert[:level]
                  when 'yellow' then ['🟡 Тривога — дрони', 'orange']
                  when 'red'    then ['🔴 Тривога — ракетна загроза', 'red']
                  else               ['🔴 Повітряна тривога (рівень не вказано)', 'red']
                  end
  puts "#{label} | color=#{colour} size=14"

  # Коли обрано район, показувати область було б неточно
  where = DISTRICT && !alert[:whole] ? safe(DISTRICT) : REGIONS.dig(REGION, 2)
  if alert[:since]
    mins = ((Time.now - alert[:since]) / 60).to_i
    puts "#{where} · триває #{mins / 60} год #{mins % 60} хв | size=12 color=gray"
  else
    puts "#{where} | size=12 color=gray"
  end

  if alert[:whole]
    puts 'Уся область | size=11 color=gray'
  elsif alert[:districts].any? && !DISTRICT
    puts "Райони: #{safe(alert[:districts].join(', '))} | size=11 color=gray"
  end
  puts 'Жовтий — дрони · червоний — ракети | size=11 color=gray'
end

# ── Сповіщення ──────────────────────────────────────────────────────

def load_state
  File.exist?(STATE) ? JSON.parse(File.read(STATE)) : {}
rescue StandardError
  {}
end

def save_state(st)
  FileUtils.mkdir_p(CACHE)
  File.write(STATE, JSON.generate(st))
end

def notify(title, message)
  # Екрануємо зворотну косу й лапки, прибираємо переноси — інакше рядок
  # може вирватись із літерала AppleScript
  esc = lambda do |str|
    str.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\\\"').delete("\n\r")
  end
  system('osascript', '-e',
         %(display notification "#{esc.call(message)}" with title "#{esc.call(title)}" sound name "Submarine"))
end

# ── Збір ────────────────────────────────────────────────────────────

# Остання лінія оборони: несподівана помилка не має показувати стек трейс
# у menu bar. Краще один зрозумілий рядок, ніж сторінка Ruby-виводу.
begin

  alert = nil
  if ALERTS_ON && (oblast = REGIONS.dig(REGION, 2))
    if (al = fetch_alerts)
      st = al.dig('states', oblast)
      if st
        # Тривогу можуть оголосити по всій області або лише по окремих районах —
        # у другому випадку прапорець області лишається false
        hot = (st['districts'] || {}).select { |_, v| v['enabled'] }
        # Якщо обрано конкретний район, тривога в сусідньому не стосується.
        # Оголошення на всю область лишається значущим у будь-якому разі.
        hot = hot.select { |name, _| name == DISTRICT } if DISTRICT && !st['enabled']
        if st['enabled'] || hot.any?
          levels = ([st['alert_level']] + hot.values.map { |v| v['alert_level'] }).compact
          # red важливіший за yellow; якщо рівня немає — за замовчуванням червоний
          level = levels.include?('red') ? 'red' : levels.first
          starts = ([st['enabled_at']] + hot.values.map { |v| v['enabled_at'] }).compact
          # Дата приходить із мережі — зіпсоване значення не має класти застосунок
          since = begin
            starts.min ? Time.parse(starts.min) : nil
          rescue ArgumentError, TypeError
            nil
          end
          alert = { since: since, level: level, districts: hot.keys,
                    whole: st['enabled'] }
        end
      end
    end
  end

  # Рівень обмежень по області — потрібен і для аварійних,
  # і щоб пояснити відсутність графіка
  area = (fetch_energy || []).find { |a| a['name'] == REGIONS.dig(REGION, 2) }
  emergency = area && area['level'].to_i >= 3 ? safe(area['label']) : nil

  data, status = fetch_data(REGION)

  if data.nil?
    # Графіка немає — це не обов'язково збій. Рівень обмежень
    # зазвичай пояснює причину краще за наше «не вдалося».
    label = area && safe(area['label'])
    puts(emergency ? "#{siren_prefix(alert)}🚨" : "#{siren_prefix(alert)}❔")
    puts '---'
    puts "#{REGIONS.dig(REGION, 0) || REGION} | size=12 color=gray"
    puts "#{label || 'Графіка немає'} | color=#{emergency ? 'red' : 'orange'} size=14"
    puts 'Оператор не публікує графіків для цієї області | size=11 color=gray' unless emergency
    render_alert(alert)
    exit
  end

  raw_days = data.dig('fact', 'data')
  # Коли відключень немає, джерело інколи віддає порожній масив замість об'єкта
  raw_days = nil unless raw_days.is_a?(Hash)
  day_keys = (raw_days&.keys || []).sort_by(&:to_i)

  if day_keys.empty?
    puts "#{siren_prefix(alert)}💡"
    puts '---'
    puts "#{REGIONS.dig(REGION, 0) || REGION} | size=12 color=gray"
    puts 'Графіків немає | color=green size=14'
    puts 'Джерело не публікує відключень для цього регіону | size=11 color=gray'
    puts "Оновлено: #{safe(data['lastUpdated'])} | size=11 color=gray"
    render_alert(alert)
    exit
  end

  # Спершу шукаємо день із сьогоднішньою датою: поле fact.today опівночі
  # відстає, і без цієї перевірки ми показували б учорашній графік,
  # хоча сьогоднішній уже лежить у файлі.
  declared = data.dig('fact', 'today')&.to_s
  actual = day_keys.find { |k| Time.at(k.to_i).to_date == Date.today }
  today_key = actual || (day_keys.include?(declared) ? declared : day_keys.last)
  tomorrow_key = day_keys[day_keys.index(today_key) + 1]

  day_date = Time.at(today_key.to_i).to_date
  age = (Date.today - day_date).to_i
  STALE = age != 0
  # Немає даних саме на сьогодні, але відхилення невелике:
  # графік ще не опублікували, скасували, або джерело вже віддає завтрашній день.
  # Якщо відставання більше двох днів — джерело просто померло.
  UNKNOWN = STALE && age <= 2

  today    = hours_for(data, QUEUE, today_key)
  tomorrow = tomorrow_key ? hours_for(data, QUEUE, tomorrow_key) : nil

  # Під час аварійних графіка для черги просто немає — це очікувано,
  # і казати «черга відсутня» було б дезорієнтуванням
  if today.nil? && emergency
    puts "#{siren_prefix(alert)}🚨"
    puts '---'
    puts "#{REGIONS.dig(REGION, 0) || REGION} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    puts "#{emergency} | color=red size=14"
    puts 'Графіка на цю чергу немає — відключають поза ним | size=11 color=gray'
    render_alert(alert)
    exit
  end

  unless today
    puts '❌ немає черги'
    puts '---'
    puts "Черга #{QUEUE.sub('GPV', '')} відсутня в даних цього регіону | color=red"
    puts "Доступні: #{safe((raw_days&.dig(today_key) || {}).keys.map { |k| k.sub('GPV', '') }.join(', '))} | size=11 color=gray"
    exit
  end

  now  = Time.now
  on   = today[now.hour]
  left = minutes_until_change(today, tomorrow, now)

  # ── Перевірка змін і попередження ───────────────────────────────────

  state = load_state
  key = "#{REGION}/#{QUEUE}/#{today_key}"
  digest = Digest::SHA256.hexdigest(today.map { |b| b ? '1' : '0' }.join)

  if NOTIFY && !STALE
    # 1. Графік на сьогодні змінився
    if state['key'] == key && state['digest'] && state['digest'] != digest
      changed = segments(today).reject { |_, _, lit| lit }
                               .map { |f, t, _| format('%02d–%02d', f, t) }.join(', ')
      notify('Графік змінився', "Черга #{QUEUE.sub('GPV', '')} · без світла: #{changed}")
    end

    # 2. Почались або скінчились аварійні відключення
    if state['emergency'] != emergency.to_s
      notify('Аварійні відключення', 'Графік не діє — відключають поза ним') if emergency
      notify('Повернулись до графіка', 'Аварійні відключення скасовано') if state['emergency'].to_s != '' && !emergency
      state['emergency'] = emergency.to_s
    end

    # 3. Скоро зміна стану
    if left && left <= WARN
      slot = "#{key}/#{on ? 'off' : 'on'}/#{(now.to_i + (left * 60)) / 3600}"
      if state['warned'] != slot
        if on
          notify('Скоро вимкнуть', "Через #{left} хв. Черга #{QUEUE.sub('GPV', '')}")
        else
          notify('Скоро увімкнуть', "Через #{left} хв. Черга #{QUEUE.sub('GPV', '')}")
        end
        state['warned'] = slot
      end
    end
  end

  state['key'] = key
  state['digest'] = digest
  save_state(state)

  # ── Menu bar ────────────────────────────────────────────────────────

  region_name = REGIONS.dig(REGION, 0) || REGION
  region_url  = REGIONS.dig(REGION, 3)

  if UNKNOWN
    puts '❔'
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    puts 'Графіка на сьогодні немає | color=orange size=14'
    if age.negative?
      puts "Джерело віддає дані на #{day_date.strftime('%d.%m')} | size=12 color=gray"
    else
      puts "Останній відомий — за #{day_date.strftime('%d.%m')} | size=12 color=gray"
      puts 'Або ще не опублікували, або відключення скасували | size=11 color=gray'
    end
  elsif STALE
    puts "📅 #{day_date.strftime('%d.%m')}"
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    puts 'Дані застарілі | color=red size=14'
    puts "Графік за #{day_date.strftime('%d.%m.%Y')} — #{age} дн. тому | color=red size=12"
    puts 'Джерело не оновлює цей регіон. Не покладайся на розклад нижче. | size=11 color=gray'
  else
    # 🚨 аварійні відключення — графік не діє, відлік за ним показувати нечесно
    icon = emergency ? '🚨' : (on ? '💡' : '🕯️')
    urgent = left && left <= WARN ? ' ⏳' : ''
    siren = siren_prefix(alert)
    puts(if emergency then "#{siren}🚨"
         elsif left then "#{siren}#{icon} #{fmt(left)}#{urgent}"
         else "#{siren}#{icon}"
         end)
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    if emergency
      puts "#{emergency} | color=red size=14"
      puts 'Графік не діє — відключають поза ним | size=12 color=gray'
      puts "За графіком зараз #{on ? 'мало бути світло' : 'і так відключення'} | size=11 color=gray"
    elsif on
      puts(if left then "Світло є · вимкнуть через #{fmt(left)} | color=green size=14"
           elsif today.all? then 'Світло є · відключень сьогодні немає | color=green size=14'
           else 'Світло є · більше відключень сьогодні не буде | color=green size=14'
           end)
    else
      puts(left ? "Світла немає · увімкнуть через #{fmt(left)} | color=red size=14"
                : 'Світла немає | color=red size=14')
    end
  end

  puts '---'
  render_alert(alert)

  if (news = fetch_notice)
    puts '---'
    puts "📰 #{safe(news['title'])} | size=12 color=gray"
    excerpt = safe(news['excerpt']).to_s
    puts "#{excerpt[0, 150]}#{'…' if excerpt.length > 150} | size=11 color=gray length=90" unless excerpt.empty?
    slug = url_part(news['slug'])
    date_slug = url_part(news['dateSlug'])
    if slug && date_slug
      puts "Читати | size=11 color=gray href=https://alerts.energy/news/#{date_slug}/#{slug}"
    end
  end

  label = if UNKNOWN then "Останній графік · #{day_date.strftime('%d.%m')}"
          elsif STALE then day_date.strftime('%d.%m.%Y')
          else 'Сьогодні'
          end
  puts "#{label} | size=12 color=gray"
  if today.all?
    puts '● Відключень немає | color=green size=13 font=Menlo'
  end
  segments(today).each do |from, to, lit|
    next if today.all?

    here = !STALE && (from..(to - 1)).cover?(now.hour) ? '  ←' : ''
    puts format('%s  %02d:00 – %02d:00%s | color=%s font=Menlo size=13',
                lit ? '●' : '○', from, to, here, lit ? 'green' : 'red')
  end

  puts '---'
  puts 'Завтра | size=12 color=gray'

  if tomorrow.nil?
    puts 'Графіка ще немає | size=13 color=gray'
    puts 'Зазвичай публікують увечері напередодні | size=11 color=gray'
  elsif tomorrow.all?
    puts '● Відключень немає | color=green size=13 font=Menlo'
  else
    segments(tomorrow).each do |from, to, lit|
      puts format('%s  %02d:00 – %02d:00 | color=%s font=Menlo size=13',
                  lit ? '●' : '○', from, to, lit ? 'green' : 'red')
    end
  end

  # ── Налаштування ────────────────────────────────────────────────────

  puts '---'
  updated = fmt_updated(data.dig('fact', 'update') || data['lastUpdated'])
  mark = { cache: '', fresh: '', stale: '  (без мережі)' }[status]
  puts "Оновлено: #{updated}#{mark} | size=11 color=gray"

  puts 'Налаштування | size=11 color=gray'

  puts '--Регіон і черга | size=11'
  REGIONS.each_key do |id|
    puts "----#{id == REGION ? '✓ ' : ''}#{REGIONS.dig(id, 0)} | size=11"
    groups = if id == REGION
               (raw_days&.dig(today_key) || {}).keys
             else
               (1..6).flat_map { |q| (1..2).map { |sub| "GPV#{q}.#{sub}" } }
             end
    groups.sort_by { |g| g[3..].split('.').map(&:to_i) }.each do |k|
      sel = (id == REGION && k == QUEUE) ? '✓ ' : ''
      puts "------#{sel}черга #{k.sub('GPV', '')} | size=11 bash=\"#{SELF}\" " \
           "terminal=false refresh=true param1=--set param2=#{id} param3=#{k}"
    end
  end

  puts "--Не знаю свою чергу | size=11#{region_url ? " href=#{region_url}" : ''}"

  puts "--#{ALERTS_ON ? '✓ ' : ''}Показувати повітряну тривогу | size=11 bash=\"#{SELF}\" " \
       "terminal=false refresh=true param1=--alerts param2=#{ALERTS_ON ? 'off' : 'on'}"

  if ALERTS_ON && (districts = alert_districts(REGIONS.dig(REGION, 2)))
    puts '--Район для тривог | size=11'
    puts "----#{DISTRICT ? '' : '✓ '}Уся область | size=11 bash=\"#{SELF}\" " \
         'terminal=false refresh=true param1=--district param2=""'
    districts.each do |d|
      next unless d.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/)

      puts "----#{DISTRICT == d ? '✓ ' : ''}#{d} | size=11 bash=\"#{SELF}\" " \
           "terminal=false refresh=true param1=--district param2=\"#{d}\""
    end
  end
  puts '--Сповіщення | size=11'
  puts "----#{NOTIFY ? '✓ ' : ''}Увімкнені | size=11 bash=\"#{SELF}\" terminal=false " \
       "refresh=true param1=--notify param2=#{NOTIFY ? 'off' : 'on'}"
  puts '----Попереджати за | size=11'
  [5, 10, 15, 30, 60].each do |m|
    puts "------#{WARN == m ? '✓ ' : ''}#{m} хв | size=11 bash=\"#{SELF}\" " \
         "terminal=false refresh=true param1=--warn param2=#{m}"
  end

  puts "Оновити зараз | refresh=true size=11"
  puts '---'
  puts 'Дані з відкритих джерел, можливі неточності | size=10 color=gray'
  puts 'Джерела даних | size=10 color=gray href=https://alerts.energy/'
rescue Errno::EPIPE
  # Читач закрив потік (наприклад `| head`) — це не помилка
  exit 0
rescue StandardError => e
  puts '❌'
  puts '---'
  puts 'Несподівана помилка | color=red size=13'
  puts "#{e.class}: #{e.message.to_s.delete('|')[0, 120]} | size=11 color=gray"
  puts 'Оновити | refresh=true size=11'
end
