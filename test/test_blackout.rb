#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for Blackout.
#
# Two levels:
#   1. Pure functions, lifted out of lib/ and called directly
#   2. Integration: the plugin runs as a process with a temporary HOME
#      and a pre-seeded cache, so it never touches the network
#
# Run: ruby test/test_blackout.rb

# Without locale variables Ruby reads files and subprocess output as
# US-ASCII, and Cyrillic breaks the comparisons. Pin it.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Fixtures are source data, and their day key is always Kyiv midnight.
# The plugin counts in Kyiv too, so the tests must build timestamps the
# same way — on a UTC runner they would otherwise mean different days.
ENV['TZ'] = 'Europe/Kyiv'

require 'minitest/autorun'
require 'date'
require 'time'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

PLUGIN = File.expand_path('../plugin/blackout.1m.rb', __dir__)
LIB    = File.expand_path('../lib', __dir__)

# Pure functions live in lib/blackout/*.rb; the plugin file is only the
# entry point. Read them all so a function can be lifted out by name.
SOURCE = (Dir[File.join(LIB, 'blackout', '*.rb')].sort + [PLUGIN])
         .map { |f| File.read(f, encoding: 'UTF-8') }.join("\n")

# Tests must never reach the network. A deny marker makes http_get
# refuse instantly, the same way a refused host would.
DENY_KEYS = %w[t.me_s alerts.energy_api alerts.energy_rss.xml
               raw.githubusercontent.com_yaroslav2901
               raw.githubusercontent.com_Baskerville42
               vadimklimenko.com_map].freeze

def offline!(cache)
  FileUtils.mkdir_p(cache)
  DENY_KEYS.each { |k| FileUtils.touch(File.join(cache, "deny-#{k}")) }
end

# Lift pure functions out without running the plugin
module Pure
  # Constants they lean on
  %w[HOUR_VALUES].each do |const|
    body = SOURCE[/^#{const}\s*=.*?freeze$/m]
    raise "не знайдено константу #{const}" unless body

    module_eval(body)
  end

  %w[safe valid_schedule? hours_for segments minutes_until_change fmt
     siren_prefix as_schedule fmt_updated read_etag read_cache
     atomic_write touch_cache ensure_dir read_schedule valid_rows?
     published_at unescape_xml news_url
     telegram_posts telegram_text oblast_stem oblasts_named
     age_phrase page_revised_at].each do |name|
    body = SOURCE[/^def #{Regexp.escape(name)}(?![\w?!]).*?\n^end$/m]
    raise "не знайдено метод #{name}" unless body

    module_eval(body)
    module_eval { module_function name.to_sym }
  end
end

# ── Pure functions ───────────────────────────────────────────────────

class TestSafe < Minitest::Test
  def test_strips_the_parameter_separator
    # The host reads '|' as the start of parameters, and bash= runs commands
    refute_includes Pure.safe('Район | bash=/bin/sh'), '|'
  end

  def test_leaves_ordinary_text_alone
    assert_equal 'Черкаський район, Уманський район',
                 Pure.safe('Черкаський район, Уманський район')
  end

  def test_trims_whitespace
    assert_equal 'текст', Pure.safe('  текст  ')
  end

  def test_accepts_nil
    assert_equal '', Pure.safe(nil)
  end
end

class TestValidSchedule < Minitest::Test
  def valid_doc(groups)
    { 'fact' => { 'data' => { '1791406800' => groups }, 'today' => 1_791_406_800 } }
  end

  def test_accepts_valid_data
    assert Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => 'yes', '2' => 'no' }))
  end

  def test_accepts_first_and_second_values
    assert Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => 'first', '2' => 'second' }))
  end

  def test_accepts_kyiv_queue_numbers
    assert Pure.valid_schedule?(valid_doc('GPV60.1' => { '1' => 'yes' }))
  end

  def test_rejects_unknown_hour_values
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '1' => '<script>' }))
  end

  def test_rejects_injection_in_a_queue_name
    refute Pure.valid_schedule?(valid_doc('GPV1.1 | bash=sh' => { '1' => 'yes' }))
  end

  def test_rejects_hours_out_of_range
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '99' => 'yes' }))
    refute Pure.valid_schedule?(valid_doc('GPV1.1' => { '0' => 'yes' }))
  end

  def test_rejects_a_bogus_date
    doc = { 'fact' => { 'data' => { 'не-дата' => { 'GPV1.1' => { '1' => 'yes' } } } } }
    refute Pure.valid_schedule?(doc)
  end

  def test_rejects_a_non_object
    refute Pure.valid_schedule?({ 'fact' => { 'data' => 'сміття' } })
    refute Pure.valid_schedule?('зовсім не те')
  end

  def test_accepts_empty_data
    # Some regions send an empty array when there are no outages
    assert Pure.valid_schedule?({ 'fact' => { 'data' => [] } })
    assert Pure.valid_schedule?({ 'fact' => {} })
  end
end

class TestHoursFor < Minitest::Test
  def doc(hours)
    { 'fact' => { 'data' => { 'd' => { 'GPV1.1' => hours } } } }
  end

  def test_hour_n_is_the_interval_before_it
    # key "22" in the source means 21:00-22:00
    h = Pure.hours_for(doc((1..24).to_h { |i| [i.to_s, i == 22 ? 'no' : 'yes'] }), 'GPV1.1', 'd')
    refute h[21], 'індекс 21 має бути без світла'
    assert h[20]
    assert h[22]
  end

  def test_first_counts_as_no_power
    h = Pure.hours_for(doc('1' => 'first'), 'GPV1.1', 'd')
    refute h[0]
  end

  def test_unknown_queue
    assert_nil Pure.hours_for(doc('1' => 'yes'), 'GPV9.9', 'd')
  end
end

class TestSegments < Minitest::Test
  def test_groups_equal_hours
    hours = ([true] * 3) + ([false] * 2) + ([true] * 19)
    assert_equal [[0, 3, true], [3, 5, false], [5, 24, true]], Pure.segments(hours)
  end

  def test_a_whole_day_is_one_segment
    assert_equal [[0, 24, true]], Pure.segments([true] * 24)
  end
end

class TestMinutesUntilChange < Minitest::Test
  def at(hour, min)
    Time.new(2026, 10, 8, hour, min)
  end

  def test_counts_to_the_change_today
    today = ([true] * 16) + ([false] * 8)
    assert_equal 120, Pure.minutes_until_change(today, nil, at(14, 0))
  end

  def test_rolls_over_to_tomorrow
    today = [true] * 24
    tomorrow = [false] * 24
    assert_equal 60, Pure.minutes_until_change(today, tomorrow, at(23, 0))
  end

  def test_no_change_at_all
    assert_nil Pure.minutes_until_change([true] * 24, [true] * 24, at(12, 0))
  end
end

class TestSirenPrefix < Minitest::Test
  def test_yellow_means_drones
    assert_equal '🟡 ', Pure.siren_prefix({ level: 'yellow' })
  end

  def test_red_means_missiles
    assert_equal '🔴 ', Pure.siren_prefix({ level: 'red' })
  end

  def test_an_unknown_level_counts_as_red
    # Published semantics: a missing level is treated as red
    assert_equal '🔴 ', Pure.siren_prefix({ level: nil })
  end

  def test_no_alert_no_prefix
    assert_equal '', Pure.siren_prefix(nil)
  end
end

class TestFmt < Minitest::Test
  def test_formats_hours_and_minutes
    assert_equal '2:05', Pure.fmt(125)
    assert_equal '0:07', Pure.fmt(7)
    assert_equal '12:00', Pure.fmt(720)
  end
end

# ── Integration ──────────────────────────────────────────────────────

class TestIntegration < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-test')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    offline!(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # An empty array means the primary source has nothing; mirror takes over
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def write_cache(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  # Restriction levels per oblast. Without this the tests hit the network.
  def write_notice(title = nil)
    write_cache('grid', title ? { 'text' => "#{title}\nтекст", 'at' => Time.now.utc.iso8601,
                                  'link' => 'https://t.me/Ukrenergo/1' } : nil)
  end

  def write_energy(level = 2)
    write_cache('energy', [{ 'name' => 'Черкаська область', 'slug' => 'cherkaska-oblast',
                             'level' => level, 'label' => level >= 3 ? 'Аварійні відключення' : 'Погодинні графіки відключень',
                             'updated' => Time.now.iso8601 }])
  end

  def schedule(day_offset: 0, hours: nil)
    day = Date.today + day_offset
    ts = Time.new(day.year, day.month, day.day).to_i
    hours ||= (1..24).to_h { |i| [i.to_s, 'yes'] }
    { 'regionId' => 'test', 'lastUpdated' => Time.now.iso8601,
      'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                  'update' => '08.10.2026 21:24', 'today' => ts } }
  end

  def run_plugin(env = {})
    base = { 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
             'BLACKOUT_QUEUE' => 'GPV1.1' }
    out, err, st = Open3.capture3(base.merge(env), 'ruby', PLUGIN)
    [out, err, st]
  end

  def test_shows_the_cached_schedule_offline
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
    assert_match(/💡/, out)
  end

  def test_stale_data_is_labelled
    write_cache('Cherkasyoblenergo', schedule(day_offset: -90))
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    assert_match(/📅/, out.lines.first)
    assert_match(/застаріл/i, out)
  end

  def test_yesterdays_schedule_is_unknown_not_stale
    write_cache('Cherkasyoblenergo', schedule(day_offset: -1))
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    assert_match(/❔/, out.lines.first)
    assert_match(/на сьогодні немає/, out)
  end

  def test_an_unknown_region_falls_back
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, _, st = run_plugin('BLACKOUT_REGION' => '../../etc/passwd')
    assert_equal 0, st.exitstatus
    assert_match(/Черкаська/, out)
  end

  def test_injection_through_the_queue_fails
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin('BLACKOUT_QUEUE' => 'GPV1.1 | bash=/bin/sh')
    refute_match(%r{bash=/bin/sh}, out)
  end

  def test_a_district_name_from_the_network_is_sanitised
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => false, 'alert_level' => nil,
                      'districts' => {
                        'Злий | bash=/bin/sh' => {
                          'enabled' => true, 'alert_level' => 'red',
                          'enabled_at' => Time.now.iso8601
                        }
                      }
                    }
                  }
                })
    out, = run_plugin
    line = out.lines.find { |l| l.start_with?('Райони:') }
    refute_nil line, 'рядок з районами має бути'

    # The host splits text from parameters on the FIRST '|'. If the
    # sanitiser worked, bash= stays in the text instead of becoming one.
    _title, params = line.split('|', 2)
    refute_includes params.to_s, 'bash=',
                    'назва району з мережі не має ставати параметром меню'
    assert_match(/Тривога/, out)
  end

  def test_a_corrupt_cache_does_not_crash_it
    File.write(File.join(@home, '.cache', 'blackout', 'Cherkasyoblenergo.json'), '{зламано')
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    _, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
  end

  def test_a_broken_alert_date_does_not_crash_it
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => true, 'alert_level' => 'yellow',
                      'enabled_at' => 'зовсім-не-дата', 'districts' => {}
                    }
                  }
                })
    out, err, st = run_plugin
    assert_equal 0, st.exitstatus
    assert_empty err
    assert_match(/Тривога/, out)
  end

  def test_a_district_only_alert_is_noticed
    # The oblast flag stays false; only districts are lit
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', {
                  'states' => {
                    'Черкаська область' => {
                      'enabled' => false, 'alert_level' => nil,
                      'districts' => {
                        'Уманський район' => { 'enabled' => true, 'alert_level' => 'red',
                                               'enabled_at' => Time.now.iso8601 }
                      }
                    }
                  }
                })
    out, = run_plugin
    assert_match(/🔴/, out.lines.first)
    assert_match(/Уманський район/, out)
  end

  def test_the_switch_rejects_an_unknown_region
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--set', 'зловмисний', 'GPV1.1')
    cfg = File.join(@home, '.config', 'blackout.json')
    refute File.exist?(cfg), 'конфіг не мав створитись'
  end

  def test_the_switch_accepts_a_known_region
    write_cache('kyiv', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--set', 'kyiv', 'GPV5.1')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 'kyiv', cfg['region']
    assert_equal 'GPV5.1', cfg['queue']
  end

  def test_the_warning_window_is_clamped
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, '--warn', '999999')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 720, cfg['warn_minutes']
  end

  # A queue name from the cache lands in a menu item's param3. While the
  # schema was checked on write only, a tampered cache could add its own
  # bash= there.
  def test_a_poisoned_queue_name_stays_out_of_parameters
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |i| [i.to_s, 'yes'] }
    poison = 'GPV9.9 bash=/usr/bin/touch param1=/tmp/BLACKOUT_PWNED'
    write_cache('Cherkasyoblenergo',
                'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours, poison => hours } },
                            'today' => ts })
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })

    out = run_plugin.first
    refute_match(/BLACKOUT_PWNED/, out, 'отруєна назва черги потрапила у вивід')
    out.each_line do |line|
      params = line.split('|', 2)[1]
      next unless params

      assert_operator params.scan(/(?:\A|\s)bash=/).size, :<=, 1,
                      "два bash= в одному пункті: #{line}"
    end
  end

  def test_no_variation_selectors_in_the_output
    # U+FE0F renders as a tofu box in the menu-bar font
    write_cache('Cherkasyoblenergo', schedule)
    write_energy
    write_notice
    write_cache('alerts', { 'states' => {} })
    out, = run_plugin
    refute_includes out.lines.first, '️',
                    'перший рядок не має містити U+FE0F'
  end
end

class TestHourValues < Minitest::Test
  def doc(value)
    { 'fact' => { 'data' => { '1791406800' => { 'GPV1.1' => { '1' => value } } } } }
  end

  def test_accepts_every_documented_value
    # preset.time_type in the source: yes, no, first, second, maybe, …
    %w[yes no first second maybe mfirst msecond].each do |v|
      assert Pure.valid_schedule?(doc(v)), "значення #{v} має прийматись"
    end
  end

  def test_rejects_undocumented_values
    refute Pure.valid_schedule?(doc('<script>'))
    refute Pure.valid_schedule?(doc('possibly'))
  end

  def test_power_is_on_only_for_yes
    # Partial and possible outages both count as "no power"
    %w[no first second maybe mfirst msecond].each do |v|
      h = Pure.hours_for({ 'fact' => { 'data' => { 'd' => { 'GPV1.1' => { '1' => v } } } } },
                         'GPV1.1', 'd')
      refute h[0], "значення #{v} не має рахуватись як світло"
    end
  end
end

class TestEmergency < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-emergency')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    offline!(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # An empty array means the primary source has nothing; mirror takes over
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    write('Cherkasyoblenergo',
          'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                      'today' => ts })
    write('alerts', 'states' => {})
    write('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def write(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  def energy(level, label)
    write('energy', [{ 'name' => 'Черкаська область', 'level' => level, 'label' => label }])
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_level_3_means_emergency
    energy(3, 'Аварійні відключення')
    out = run_plugin
    assert_match(/🚨/, out.lines.first)
    assert_match(/Графік не діє/, out)
  end

  def test_no_countdown_during_an_emergency
    # The schedule does not apply, so a countdown from it would lie
    energy(3, 'Аварійні відключення')
    assert_equal '🚨', run_plugin.lines.first.strip
  end

  def test_level_2_is_an_ordinary_schedule
    energy(2, 'Погодинні графіки відключень')
    out = run_plugin
    refute_match(/🚨/, out.lines.first)
    assert_match(/💡/, out.lines.first)
  end

  def test_an_unknown_oblast_does_not_break_it
    write('energy', [{ 'name' => 'Марсіанська область', 'level' => 3, 'label' => 'Аварійні' }])
    out, err, st = Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                                    'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN)
    assert_equal 0, st.exitstatus
    assert_empty err
    refute_match(/🚨/, out.lines.first)
  end

  def test_a_label_from_the_network_is_sanitised
    energy(3, 'Аварійні | bash=/bin/sh')
    line = run_plugin.lines.find { |l| l.include?('Аварійні') }
    _title, params = line.split('|', 2)
    refute_includes params.to_s, 'bash='
  end
end

class TestDaySelection < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-day')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    offline!(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # An empty array means the primary source has nothing; mirror takes over
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'alerts.json'), '{"states":{}}')
    File.write(File.join(@home, '.cache', 'blackout', 'energy.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'notice.json'), '{}')
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def ts(offset)
    d = Date.today + offset
    Time.new(d.year, d.month, d.day).to_i
  end

  def test_picks_today_even_when_the_today_field_lags
    # Around midnight the source still sends yesterday's fact.today even
    # though today's schedule is already in the file.
    doc = { 'fact' => {
      'data' => {
        ts(-1).to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'no'] } },
        ts(0).to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } }
      },
      'today' => ts(-1)
    } }
    File.write(File.join(@home, '.cache', 'blackout', 'Cherkasyoblenergo.json'),
               JSON.generate(doc))
    out, = Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                            'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN)
    refute_match(/❔/, out.lines.first, 'мав взяти сьогоднішній день')
    assert_match(/💡/, out.lines.first)
    assert_match(/Сьогодні/, out)
  end
end

class TestNotice < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-notice')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    offline!(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
    # An empty array means the primary source has nothing; mirror takes over
    File.write(File.join(@home, '.cache', 'blackout', 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(@home, '.cache', 'blackout', 'sd-kyiv.json'), '[]')
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    w('Cherkasyoblenergo', 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h do |i|
      [i.to_s, 'yes']
    end } }, 'today' => ts })
    w('alerts', 'states' => {})
    w('energy', [])
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@home, '.cache', 'blackout', "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_shows_the_notice
    w('grid', 'text' => "Обмеження 16:00-22:00\nЧерез атаку",
              'at' => Time.now.utc.iso8601, 'link' => 'https://t.me/Ukrenergo/42')
    out = run_plugin

    assert_match(/📰 Обмеження 16:00-22:00/, out)
    assert_match(%r{href=https://t.me/Ukrenergo/42}, out)
  end

  def test_shows_nothing_without_a_notice
    w('grid', nil)
    refute_match(/📰/, run_plugin)
  end

  def test_a_notice_from_the_network_is_sanitised
    w('grid', 'text' => 'Атака | bash=/bin/sh', 'at' => Time.now.utc.iso8601)
    line = run_plugin.lines.find { |l| l.include?('📰') }
    _title, params = line.split('|', 2)

    refute_includes params.to_s, 'bash='
  end
end

class TestShutdownsSource < Minitest::Test
  def rows(extra = [])
    base = { 'initiator' => 'cherkaska_oblast_oblenergo', 'queue' => '1.1',
             'today' => (([0] * 10) + [1, 1] + ([0] * 12)),
             'todayPossible' => [0] * 24,
             'tomorrow' => [], 'todayStatus' => 'ScheduleApplies',
             'tomorrowStatus' => 'WaitingForSchedule',
             'todayDate' => Date.today.to_s,
             'todayCheckedAt' => Time.now.utc.iso8601 }
    [base] + extra
  end

  def built(rows)
    Pure.as_schedule(rows)
  end

  def test_one_means_an_outage
    d = built(rows)
    ts = d['fact']['data'].keys.first
    h = d['fact']['data'][ts]['GPV1.1']
    assert_equal 'yes', h['1']   # година 0–1
    assert_equal 'no', h['11']   # година 10–11
    assert_equal 'no', h['12']
    assert_equal 'yes', h['13']
  end

  def test_prefers_the_utility_over_the_railway
    # One queue can have several suppliers with different schedules
    uz = { 'initiator' => 'cherkaska_oblast_uz', 'queue' => '1.1',
           'today' => (([0] * 15) + [1, 1] + ([0] * 7)), 'todayPossible' => [0] * 24,
           'todayStatus' => 'ScheduleApplies', 'todayDate' => Date.today.to_s }
    d = built(rows([uz]))
    h = d['fact']['data'].values.first['GPV1.1']
    assert_equal 'no', h['11'], 'має бути графік обленерго'
    assert_equal 'yes', h['16'], 'не має бути графік залізниці'
  end

  def test_possible_becomes_maybe
    rs = rows
    rs[0]['todayPossible'] = ([0] * 5) + [1] + ([0] * 18)
    h = built(rs)['fact']['data'].values.first['GPV1.1']
    assert_equal 'maybe', h['6']
  end

  def test_noshutdowns_means_power_all_day
    rs = [{ 'initiator' => 'x_oblenergo', 'queue' => '1.1', 'today' => [],
            'todayStatus' => 'NoShutdowns', 'todayDate' => Date.today.to_s }]
    h = built(rs)['fact']['data'].values.first['GPV1.1']
    assert_equal 24, h.values.count('yes')
  end

  def test_empty_rows_give_nil
    assert_nil built([])
  end

  def test_the_result_passes_validation
    assert Pure.valid_schedule?(built(rows))
  end
end

class TestParamInjection < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-param')
    c = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(c)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    File.write(File.join(c, 'sd-cherkaska-oblast.json'), '[]')
    File.write(File.join(c, 'Cherkasyoblenergo.json'), JSON.generate(
                                                         'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h do |i|
                                                           [i.to_s, 'yes']
                                                         end } }, 'today' => ts }
                                                       ))
    File.write(File.join(c, 'alerts.json'), '{"states":{}}')
    File.write(File.join(c, 'energy.json'), '[]')
    @cache = c
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  # Parameters are separated by SPACES, so safe() is not enough here —
  # it only strips '|'. A value from the network either passes a strict
  # check or is not printed at all.
  def notice(link)
    File.write(File.join(@cache, 'grid.json'),
               JSON.generate('text' => "СТАН ЕНЕРГОСИСТЕМИ\nКоротко.",
                             'at' => Time.now.utc.iso8601, 'link' => link))
  end

  def test_a_notice_link_cannot_inject_a_parameter
    notice('https://t.me/Ukrenergo/1 terminal=true bash=/bin/sh param1=-c')
    out = run_plugin

    refute_match(%r{bash=/bin/sh}, out, 'a link with spaces must not become a parameter')
    refute_match(/Читати/, out, 'a suspicious link is not printed at all')
    assert_match(/📰/, out, 'the notice itself stays')
  end

  def test_an_ordinary_link_is_printed
    notice('https://t.me/Ukrenergo/5581')

    assert_match(%r{href=https://t.me/Ukrenergo/5581}, run_plugin)
  end

  def test_a_link_to_another_host_is_refused
    notice('https://evil.example/Ukrenergo/5581')
    out = run_plugin

    refute_match(/evil\.example/, out)
    refute_match(/Читати/, out)
  end

  def test_a_path_with_spaces_is_quoted
    # In a directory with a space, an unquoted path would split into
    # separate parameters
    line = run_plugin.lines.find { |l| l.include?('param1=--set') }
    refute_nil line
    assert_match(/bash="[^"]+"/, line, 'шлях має бути в лапках')
  end
end

class TestFmtUpdated < Minitest::Test
  def test_iso_becomes_local_time
    # The primary source sends ISO in UTC; showing that raw is ugly
    out = Pure.fmt_updated('2026-10-14T17:54:18.249Z')
    assert_match(/\A\d{2}\.\d{2} \d{2}:\d{2}\z/, out)
    refute_match(/T|Z/, out)
  end

  def test_an_already_formatted_string_is_kept
    # The mirrors send an already formatted time
    assert_equal '14.10.2026 20:54', Pure.fmt_updated('14.10.2026 20:54')
  end

  def test_garbage_does_not_break_it
    assert_equal 'хтозна', Pure.fmt_updated('хтозна')
    assert_equal '', Pure.fmt_updated(nil)
  end
end

class TestCacheIntegrity < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-cache')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  # With a corrupt cache and a valid ETag the server answers 304 to an
  # empty file, and the data never loads again.
  def test_a_corrupt_cache_drops_the_etag
    path = File.join(@cache, 'alerts.json')
    File.write(path, '')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_nil Pure.read_etag(path), 'ETag не має віддаватись для нечитабельного кешу'
  end

  def test_a_sound_cache_yields_its_etag
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_equal 'W/"abc123"', Pure.read_etag(path)
  end

  def test_no_etag_without_its_cache
    path = File.join(@cache, 'nope.json')
    File.write("#{path}.etag", 'W/"abc123"')
    assert_nil Pure.read_etag(path)
  end

  # The ETag goes into If-None-Match. Ruby rejects CR/LF itself, but it
  # would send a megabyte-long value as-is.
  def test_an_oversized_etag_is_rejected
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", 'A' * 100_000)
    assert_nil Pure.read_etag(path)
  end

  def test_an_etag_with_a_newline_is_rejected
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{"states":{}}')
    File.write("#{path}.etag", %(x\r\nX-Injected: 1))
    assert_nil Pure.read_etag(path)
  end

  # The schema was checked on write only, so a damaged cache came back as-is
  def test_a_cache_with_an_unknown_schema_is_ignored
    path = File.join(@cache, 'Cherkasyoblenergo.json')
    File.write(path, JSON.generate('fact' => { 'data' => { 'не-дата' => {} } }))
    assert_nil Pure.read_schedule(path)
  end

  def test_a_sound_schedule_cache_is_accepted
    ts = Time.new(Date.today.year, Date.today.month, Date.today.day).to_i
    path = File.join(@cache, 'Cherkasyoblenergo.json')
    File.write(path, JSON.generate(
                       'fact' => { 'data' => { ts.to_s => {
                         'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] }
                       } } }
                     ))
    refute_nil Pure.read_schedule(path)
  end

  def test_rows_with_a_strange_queue_are_rejected
    refute Pure.valid_rows?([{ 'queue' => '1.1 bash=/bin/sh' }])
    refute Pure.valid_rows?([{ 'queue' => 'x' }])
    refute Pure.valid_rows?('не масив')
    assert Pure.valid_rows?([{ 'queue' => '1.1' }])
    assert Pure.valid_rows?([])
  end
end

# A program with no special rights can plant a symlink in the cache
# pointing at any of the user's files. While writes went through
# File.write, we overwrote the target with network data.
# The schedule is in Kyiv hours. On a Mac in another zone the same data
# gave the opposite answer: "no power" in Kyiv, "power on" in Lisbon.
# An empty schedule means "we do not know", not "plenty of power".
# A region with zero data used to render a cheerful green bulb.
# On 18 October the utility rewrote the schedule at 10:01 and the mirror
# had it, while the primary source still served yesterday's revision,
# fresh looking. The app said "power on" when there was none.
class TestFreshestWins < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-fresh')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    @day = Date.today
    @ts = Time.new(@day.year, @day.month, @day.day).to_i
    w('alerts', 'states' => {})
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  # Primary source: yesterday's revision, power all day
  def seed_primary(published)
    w('sd-cherkaska-oblast',
      [{ 'queue' => '1.1', 'initiator' => 'cherkaska_oblast_oblenergo',
         'updated' => published, 'todayDate' => @day.strftime('%Y-%m-%d'),
         'todayStatus' => 'ScheduleApplies', 'today' => Array.new(24, 0),
         'todayPossible' => Array.new(24, 0) }])
  end

  # Mirror: a newer revision, outage from 10 to 12
  def seed_github(published)
    hours = (1..24).to_h { |h| [h.to_s, [11, 12].include?(h) ? 'no' : 'yes'] }
    w('Cherkasyoblenergo',
      'fact' => { 'data' => { @ts.to_s => { 'GPV1.1' => hours } },
                  'update' => published, 'today' => @ts })
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_the_newer_revision_beats_the_primary_source
    seed_primary((Time.now - (14 * 3600)).utc.iso8601)
    seed_github(Time.now.strftime('%d.%m.%Y %H:%M'))
    out = run_plugin

    assert_match(/10:00 – 12:00/, out, 'узято стару редакцію без вимкнення 10–12')
  end

  def test_a_stale_mirror_does_not_beat_fresh_primary
    seed_primary(Time.now.utc.iso8601)
    seed_github('01.07.2026 09:00')
    out = run_plugin

    refute_match(/10:00 – 12:00/, out, 'липневий файл переміг сьогоднішні дані')
  end

  def test_updated_is_publication_time_not_poll_time
    seed_primary((Time.now - (14 * 3600)).utc.iso8601)
    seed_github(Time.now.strftime('%d.%m.%Y %H:%M'))

    assert_match(/Оновлено: #{Time.now.strftime('%d\\.%m\\.%Y')}/, run_plugin)
  end
end

class TestPublishedAt < Minitest::Test
  def test_both_date_formats_parse
    iso = Pure.published_at('lastUpdated' => '2026-10-17T17:15:00.000Z')
    txt = Pure.published_at('fact' => { 'update' => '18.10.2026 10:01' })

    refute_nil iso
    refute_nil txt
    assert_operator txt, :>, iso, 'ранкова редакція має бути новішою за вечірню'
  end

  def test_garbage_does_not_break_it
    assert_nil Pure.published_at(nil)
    assert_nil Pure.published_at({})
    assert_nil Pure.published_at('fact' => { 'update' => 'хтозна' })
  end
end

class TestEmptySchedule < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-empty')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    w('sd-cherkaska-oblast', [])
    w('alerts', 'states' => {})
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_an_empty_schedule_does_not_claim_power
    w('Cherkasyoblenergo', 'fact' => { 'data' => {} }, 'lastUpdated' => Time.now.iso8601)
    out = run_plugin

    assert_match(/❔/, out.lines.first, 'порожній графік показано як «світло є»')
    refute_match(/💡/, out.lines.first)
    # "No alert" is legitimately green; the ban on green applies only
    # to the line that talks about the schedule
    schedule_line = out.lines.find { |l| l.include?('графіка немає') }
    refute_nil schedule_line
    refute_match(/color=green/, schedule_line)
  end

  def test_an_empty_schedule_shows_no_raw_timestamp
    w('Cherkasyoblenergo', 'fact' => { 'data' => {} }, 'lastUpdated' => Time.now.iso8601)
    refute_match(/\d{4}-\d\d-\d\dT/, run_plugin, 'ISO-штамп замість людської дати')
  end
end

# The grid says "no planned outages in the available schedules" for one
# region and "no confirmed current data" for seventeen others. Those are
# different answers and must not share an icon.
class TestNoOutagesVsNoData < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-nodata')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo', {})
    w('alerts', 'states' => {})
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def energy(state, level, label)
    w('energy', [{ 'name' => 'Черкаська область', 'slug' => 'cherkaska-oblast',
                   'level' => level, 'dataState' => state, 'label' => label }])
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_no_outages_reads_as_good_news
    energy('available', 0, 'У доступних графіках немає планових відключень')
    out = run_plugin

    assert_match(/💡/, out.lines.first)
    refute_match(/❔/, out.lines.first)
    assert_match(/color=green/, out)
  end

  def test_no_data_stays_a_question_mark
    energy('unknown', 0, 'Немає підтверджених актуальних даних')
    out = run_plugin

    assert_match(/❔/, out.lines.first)
    refute_match(/💡/, out.lines.first)
    assert_match(/Немає підтверджених/, out)
  end

  def test_emergency_still_wins
    energy('available', 3, 'Аварійні відключення')
    assert_match(/🚨/, run_plugin.lines.first)
  end
end

# On 27 October the primary source started answering 401 for everyone.
# Losing the schedule is survivable — mirrors cover it. Losing the
# restriction level is not: without it an emergency day looks exactly
# like an ordinary one, and the countdown becomes a confident lie.
class TestSourceLockedOut < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-401')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |i| [i.to_s, 'yes'] }
    w('Cherkasyoblenergo', 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                                       'update' => Time.now.strftime('%d.%m.%Y %H:%M'),
                                       'today' => ts })
    w('sd-cherkaska-oblast', [])
    w('alerts', 'states' => {})
    w('notice', {})
    # Pretend the host refused us, so no test ever reaches the network
    FileUtils.touch(File.join(@cache, 'deny-alerts.energy'))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_says_it_cannot_check_for_emergencies
    assert_match(/Аварійні відключення не перевіряються/, run_plugin)
  end

  def test_still_shows_the_schedule_from_the_mirror
    out = run_plugin

    assert_match(/Світло є/, out)
    assert_match(/Сьогодні/, out)
  end

  def test_a_stale_level_cache_is_not_served_as_current
    old = File.join(@cache, 'energy.json')
    File.write(old, JSON.generate([{ 'name' => 'Черкаська область', 'level' => 3,
                                     'dataState' => 'available',
                                     'label' => 'Аварійні відключення' }]))
    File.utime(Time.now - (3 * 3600), Time.now - (3 * 3600), old)
    out = run_plugin

    refute_match(/🚨/, out.lines.first, 'three-hour-old level claimed as current')
    assert_match(/не перевіряються/, out)
  end

  def test_a_fresh_level_cache_is_still_used
    File.write(File.join(@cache, 'energy.json'),
               JSON.generate([{ 'name' => 'Черкаська область', 'level' => 3,
                                'dataState' => 'available',
                                'label' => 'Аварійні відключення' }]))
    out = run_plugin

    assert_match(/🚨/, out.lines.first)
    refute_match(/не перевіряються/, out)
  end
end

# The transmission operator's own channel is the primary source for
# system-state notices. Its website answers automated clients with a
# Cloudflare challenge, including robots.txt, so this public page is
# what is left — and it is where the aggregator's notices come from.
class TestGridChannel < Minitest::Test
  PAGE = <<~HTML
    <div class="tgme_widget_message" data-post="Ukrenergo/5580">
      <time datetime="2026-10-26T17:20:57+00:00"></time>
      <div class="tgme_widget_message_text js-message_text">Старіший пост</div>
    </div>
    <div class="tgme_widget_message" data-post="Ukrenergo/5581">
      <time datetime="2026-10-27T08:46:43+00:00"></time>
      <div class="tgme_widget_message_text js-message_text">СТАН ЕНЕРГОСИСТЕМИ<br/>Внаслідок обстрілів є нові знеструмлення у Сумській, Харківській та Чернігівській областях.<br/>У Львівській області роботи завершено&#33;</div>
    </div>
  HTML

  def test_takes_the_newest_post_with_its_time_and_link
    post = Pure.telegram_posts(PAGE).last

    assert_match(/СТАН ЕНЕРГОСИСТЕМИ/, post['text'])
    assert_equal '2026-10-27T08:46:43+00:00', post['at']
    assert_equal 'https://t.me/Ukrenergo/5581', post['link']
  end

  def test_numeric_entities_come_back_as_characters
    refute_includes Pure.telegram_posts(PAGE).last['text'], '&#'
  end

  # The post names regions in several contexts. Only the ones it says
  # lost power count — a region where repairs finished is not a warning.
  def test_only_regions_named_as_de_energised_count
    text = Pure.telegram_posts(PAGE).last['text']
    names = ['Сумська область', 'Харківська область', 'Чернігівська область',
             'Львівська область', 'Черкаська область']
    named = Pure.oblasts_named(text, names)

    assert_includes named, 'Сумська область'
    assert_includes named, 'Харківська область'
    refute_includes named, 'Львівська область', 'repairs finished is not an outage'
    refute_includes named, 'Черкаська область', 'not mentioned at all'
  end

  # Oblast names arrive declined: "Харківська" is written "Харківській".
  def test_declined_names_still_match
    assert_equal 'Харківсь', Pure.oblast_stem('Харківська область')
    assert_equal 'Київ', Pure.oblast_stem('м. Київ')
  end

  def test_rubbish_gives_nothing
    assert_empty Pure.telegram_posts('<html>nothing here</html>')
    assert_empty Pure.oblasts_named('', ['Сумська область'])
  end
end

# The mirrors commit about twice a day, so a schedule that looks like
# today's plan can be half a day old and already superseded. The
# timestamp alone did not say that; the age does.
class TestAgePhrase < Minitest::Test
  def test_recent_counts_as_just_now
    assert_equal 'щойно', Pure.age_phrase(Time.now - 600)
  end

  def test_hours_are_spelled_out
    assert_equal '12 год тому', Pure.age_phrase(Time.now - (12 * 3600))
  end

  def test_past_a_day_it_counts_days
    assert_equal '2 дн. тому', Pure.age_phrase(Time.now - (50 * 3600))
  end

  def test_nothing_to_say_without_a_time
    assert_nil Pure.age_phrase(nil)
    assert_nil Pure.age_phrase(Time.now + 3600)
  end
end

# The mirrors land about twice a day, so the operator can already have
# published a newer revision. One line of a public page says when —
# which the source's own llms.txt allows citing, unlike its API.
class TestPageRevision < Minitest::Test
  def test_reads_the_revision_time
    page = '<p>Графік оновлено: 27.10, 10:49 за київським часом.</p>'
    at = Pure.page_revised_at(page)

    assert_equal [27, 10, 10, 49], [at.day, at.month, at.hour, at.min]
  end

  def test_markup_and_scripts_do_not_confuse_it
    page = '<script>var x="Графік оновлено: 01.01, 00:00";</script>' \
           '<div><b>Графік</b> оновлено: 27.10, 10:49 за київським</div>'

    assert_equal 10, Pure.page_revised_at(page).hour
  end

  def test_a_page_without_the_line_gives_nothing
    assert_nil Pure.page_revised_at('<p>нічого</p>')
    assert_nil Pure.page_revised_at(nil)
    assert_nil Pure.page_revised_at('Графік оновлено: 99.99, 99:99')
  end
end

class TestTimezone < Minitest::Test
  ZONES = ['Europe/Kyiv', 'Europe/Lisbon', 'America/New_York', 'Asia/Tokyo', 'UTC'].freeze

  def setup
    @home = Dir.mktmpdir('blackout-tz')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    File.write(File.join(@home, '.config', 'blackout.json'),
               JSON.generate('region' => 'Cherkasyoblenergo', 'queue' => 'GPV1.1',
                             'notify' => false, 'alerts' => false))
    # A Kyiv day with power only in the first half
    day = Date.today
    ts = Time.new(day.year, day.month, day.day).to_i
    hours = (1..24).to_h { |i| [i.to_s, i <= 12 ? 'yes' : 'no'] }
    w('Cherkasyoblenergo', 'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => hours } },
                                       'today' => ts })
    w('sd-cherkaska-oblast', [])
    w('alerts', 'states' => {})
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def test_the_answer_is_the_same_in_any_timezone
    answers = ZONES.map do |tz|
      out, = Open3.capture3({ 'HOME' => @home, 'TZ' => tz }, 'ruby', PLUGIN)
      [tz, out.lines.first.to_s.strip]
    end
    first = answers.first.last
    refute_empty first
    answers.each do |tz, line|
      assert_equal first, line, "пояс #{tz} дав іншу відповідь"
    end
  end
end

# The first run must not pretend some default region is the user's
class TestFirstRun < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-first')
    FileUtils.mkdir_p(File.join(@home, '.cache', 'blackout'))
    offline!(File.join(@home, '.cache', 'blackout'))
    FileUtils.mkdir_p(File.join(@home, '.config'))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def run_plugin(*args)
    Open3.capture3({ 'HOME' => @home }, 'ruby', PLUGIN, *args).first
  end

  def test_with_no_config_it_asks_instead_of_guessing
    out = run_plugin
    assert_match(/Регіон не вибрано/, out)
    refute_match(/Черкаська обл\. · черга/, out, 'показано чужу область як свою')
    refute_match(/через \d+:\d\d/, out, 'показано відлік для невибраної області')
  end

  def test_the_picker_makes_no_network_calls
    out = run_plugin
    written = Dir.children(File.join(@home, '.cache', 'blackout'))
                 .reject { |f| f.start_with?('deny-') }

    assert_empty written, 'the picker must make no requests at all'
    assert_match(/Черкаська обл\./, out)
  end

  def test_nothing_is_ticked_before_a_choice
    refute_match(/✓/, run_plugin, 'до вибору галочки стояти не має')
  end

  # 26 regions x 12 queues came to 364 menu lines. Queues moved into
  # Settings, where only the chosen region is expanded.
  def test_the_picker_lists_regions_only
    out = run_plugin
    clickable = out.lines.count { |l| l.include?('param1=--set') }

    assert_operator clickable, :>=, 26
    refute_match(/черга \d/, out, 'черги на цьому екрані зайві')
    assert_operator out.lines.size, :<, 40, 'екран вибору має лишатись коротким'
  end

  def test_after_choosing_it_shows_the_schedule
    run_plugin('--set', 'Lvivoblenerho', 'GPV3.2')
    cfg = JSON.parse(File.read(File.join(@home, '.config', 'blackout.json')))
    assert_equal 'Lvivoblenerho', cfg['region']
    assert_equal 'GPV3.2', cfg['queue']
    refute_match(/Регіон не вибрано/, run_plugin)
  end
end

class TestSymlinkSafety < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-symlink')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    @victim = File.join(@home, 'victim.txt')
    File.write(@victim, "важливі дані\n")
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def test_a_write_does_not_follow_a_symlink
    path = File.join(@cache, 'alerts.json')
    File.symlink(@victim, path)
    Pure.atomic_write(path, '{"states":{}}')

    assert_equal "важливі дані\n", File.read(@victim), 'жертву перезаписано'
    refute File.symlink?(path), 'посилання мало зникнути'
    assert_equal '{"states":{}}', File.read(path)
  end

  def test_touch_leaves_a_symlink_alone
    path = File.join(@cache, 'alerts.json')
    File.symlink(@victim, path)
    before = File.mtime(@victim)
    Pure.touch_cache(path)

    assert_equal before, File.mtime(@victim), 'час жертви змінено'
  end

  def test_touch_updates_a_regular_file
    path = File.join(@cache, 'alerts.json')
    File.write(path, '{}')
    File.utime(Time.now - 3600, Time.now - 3600, path)
    Pure.touch_cache(path)

    assert_operator File.mtime(path), :>, Time.now - 60
  end

  def test_the_write_is_atomic_and_leaves_no_litter
    path = File.join(@cache, 'alerts.json')
    Pure.atomic_write(path, 'x' * 1000)

    assert_equal 1000, File.size(path)
    assert_empty Dir.glob("#{path}*.tmp"), 'тимчасовий файл не прибрано'
  end

  def test_a_failed_write_leaves_no_temp_file
    path = File.join(@home, 'немає-такої-теки', 'alerts.json')
    assert_raises(StandardError) { Pure.atomic_write(path, '{}') }
    assert_empty Dir.glob(File.join(@home, '**', '*.tmp'))
  end

  # If the directory itself is a link, our files land in someone else's
  def test_a_symlinked_directory_is_refused
    other = File.join(@home, 'чужа')
    FileUtils.mkdir_p(other)
    link = File.join(@home, 'link-cache')
    File.symlink(other, link)

    assert_raises(RuntimeError) { Pure.ensure_dir(link) }
    assert_empty Dir.children(other)
  end

  def test_a_new_cache_directory_is_owner_only
    dir = File.join(@home, 'fresh', 'blackout')
    Pure.ensure_dir(dir)

    assert_equal 0o700, File.stat(dir).mode & 0o777
  end
end

class TestDistrict < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-district')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    ts = Time.new(d.year, d.month, d.day).to_i
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'data' => { ts.to_s => { 'GPV1.1' => (1..24).to_h do |i|
        [i.to_s, 'yes']
      end } }, 'today' => ts })
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  # The alert covers one district; the user sits in another
  def alerts_in(*hot)
    districts = ['Уманський район', 'Черкаський район'].to_h do |n|
      [n, { 'enabled' => hot.include?(n), 'alert_level' => 'yellow',
            'enabled_at' => Time.now.utc.iso8601 }]
    end
    w('alerts', 'states' => { 'Черкаська область' => {
        'enabled' => false, 'alert_level' => nil, 'districts' => districts
      } })
  end

  def run_plugin(env = {})
    base = { 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
             'BLACKOUT_QUEUE' => 'GPV1.1' }
    Open3.capture3(base.merge(env), 'ruby', PLUGIN).first
  end

  def test_another_district_raises_no_alert
    alerts_in('Черкаський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/Тривоги немає/, out)
    refute_match(/🟡/, out.lines.first)
  end

  def test_your_own_district_raises_the_alert
    alerts_in('Уманський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/Тривога — дрони/, out)
    assert_match(/Уманський район · триває/, out)
  end

  def test_with_no_choice_the_whole_oblast_counts
    alerts_in('Черкаський район')
    out = run_plugin
    assert_match(/Тривога — дрони/, out)
    assert_match(/Черкаська область/, out)
  end

  def test_an_oblast_wide_alert_applies_to_everyone
    # An oblast-wide announcement matters even with a district chosen
    w('alerts', 'states' => { 'Черкаська область' => {
        'enabled' => true, 'alert_level' => 'red',
        'enabled_at' => Time.now.utc.iso8601, 'districts' => {}
      } })
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський район')
    assert_match(/ракетна загроза/, out)
    assert_match(/Уся область/, out)
  end

  def test_a_district_name_with_injection_is_ignored
    alerts_in('Уманський район')
    out = run_plugin('BLACKOUT_DISTRICT' => 'Уманський bash=/bin/sh')
    refute_match(%r{bash=/bin/sh}, out)
  end
end

class TestLimits < Minitest::Test
  def test_safe_truncates_long_text
    # A 100 KB headline would stretch a menu item across the screen
    out = Pure.safe('A' * 100_000)
    assert_operator out.length, :<=, 201
    assert out.end_with?('…')
  end

  def test_safe_leaves_short_text_alone
    assert_equal 'Новина', Pure.safe('Новина')
  end

  def test_safe_takes_a_custom_limit
    assert_equal 'abc…', Pure.safe('abcdefgh', 3)
  end
end

class TestOversizedData < Minitest::Test
  def setup
    @home = Dir.mktmpdir('blackout-big')
    @cache = File.join(@home, '.cache', 'blackout')
    FileUtils.mkdir_p(@cache)
    offline!(@cache)
    FileUtils.mkdir_p(File.join(@home, '.config'))
    d = Date.today
    @ts = Time.new(d.year, d.month, d.day).to_i
    w('energy', [])
    w('notice', {})
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def w(name, doc)
    File.write(File.join(@cache, "#{name}.json"), JSON.generate(doc))
  end

  def run_plugin
    Open3.capture3({ 'HOME' => @home, 'BLACKOUT_REGION' => 'Cherkasyoblenergo',
                     'BLACKOUT_QUEUE' => 'GPV1.1' }, 'ruby', PLUGIN).first
  end

  def test_hundreds_of_districts_do_not_blow_up_the_menu
    districts = (0...500).to_h do |i|
      ["Район #{i}", { 'enabled' => true, 'alert_level' => 'red',
                       'enabled_at' => Time.now.utc.iso8601 }]
    end
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'data' => { @ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                  'today' => @ts })
    w('alerts', 'states' => { 'Черкаська область' => {
        'enabled' => false, 'alert_level' => 'red', 'districts' => districts
      } })
    out = run_plugin
    line = out.lines.find { |l| l.start_with?('Райони:') }
    refute_nil line
    assert_operator line.length, :<, 300
    assert_match(/та ще \d+/, line)
  end

  def test_no_line_grows_beyond_reason
    w('sd-cherkaska-oblast', [])
    w('Cherkasyoblenergo',
      'fact' => { 'update' => 'U' * 50_000,
                  'data' => { @ts.to_s => { 'GPV1.1' => (1..24).to_h { |i| [i.to_s, 'yes'] } } },
                  'today' => @ts })
    w('alerts', 'states' => {})
    w('notice', 'breaking' => { 'title' => 'T' * 50_000, 'excerpt' => 'E' * 50_000 })
    longest = run_plugin.lines.map(&:length).max
    assert_operator longest, :<, 500, 'рядок меню не має бути нескінченним'
  end
end
